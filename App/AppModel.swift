import BeadsKit
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    /// Per-project UI state. Data and errors are independent: a failed refresh keeps showing the last snapshot.
    struct ProjectState {
        var board: BoardIndex?
        var snapshot: URL?
        var isSyncing = false
        var error: String?
    }

    /// Result of the "Check access" step in the Add Project sheet.
    struct AccessCheck {
        var account: Result<String, Error>
        var data: Result<String?, Error>
    }

    private(set) var projects: [Project] = []
    private(set) var states: [UUID: ProjectState] = [:]
    private(set) var toolStatus: String = "Checking tools…"
    private(set) var setupError: String?

    private var service: SyncService?
    private var projectsFile: ProjectsFile?
    private(set) var env: ToolEnvironment?

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "uz.dkamaloff.beads" }

    func start() async {
        do {
            let paths = try AppPaths.standard(bundleID: Self.bundleID)
            try paths.prepare()
            let dolt = Bundle.main.bundleURL.appending(path: "Contents/Helpers/dolt")
            guard FileManager.default.isExecutableFile(atPath: dolt.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Bundled dolt binary is missing"])
            }

            let env = ToolEnvironment(paths: paths, doltExecutable: dolt)
            self.env = env
            service = SyncService(env: env)
            projectsFile = ProjectsFile(url: paths.projectsFile)
            projects = try projectsFile?.load() ?? []

            async let gitVersion = GitClient(env: env).version()
            async let doltVersion = DoltClient(env: env).version()
            toolStatus = try await "\(gitVersion) · \(doltVersion)"
        } catch {
            setupError = "\(error)"
            toolStatus = "Setup failed"
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for project in projects { group.addTask { await self.loadCachedThenSync(project.id) } }
        }
    }

    func state(of id: UUID) -> ProjectState { states[id] ?? ProjectState() }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    // MARK: - Projects

    func addProject(address: String, keyPath: String?) async throws -> Project {
        let remote = try RemoteURL.parse(address)
        if let existing = projects.first(where: { $0.remote == remote }) { return existing }
        let project = Project(remote: remote, identity: SSHIdentity(privateKeyPath: keyPath))
        projects.append(project)
        try save()
        Task { await sync(project.id) }
        return project
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        states[id] = nil
        try? save()
        if let env { try? FileManager.default.removeItem(at: env.paths.projectDir(id)) }
    }

    func checkAccess(address: String, keyPath: String?) async throws -> AccessCheck {
        guard let env else { throw CocoaError(.featureUnsupported) }
        let remote = try RemoteURL.parse(address)
        let identity = SSHIdentity(privateKeyPath: keyPath)
        async let account = Result { try await SSHProbe(env: env).account(host: remote.host, user: remote.user, identity: identity) }
        async let data = Result { try await GitClient(env: env).remoteDataRef(remote, identity: identity) }
        return await AccessCheck(account: account, data: data)
    }

    // MARK: - Sync

    func loadCachedThenSync(_ id: UUID) async {
        guard let service, let project = project(id) else { return }
        if let (data, url) = try? await service.loadCached(project) {
            await apply(data, snapshot: url, to: id)
        }
        await sync(id)
    }

    func syncAll() async {
        await withTaskGroup(of: Void.self) { group in
            for project in projects { group.addTask { await self.sync(project.id) } }
        }
    }

    func sync(_ id: UUID) async {
        guard let service, let project = project(id) else { return }
        states[id, default: ProjectState()].isSyncing = true
        defer { states[id]?.isSyncing = false }
        do {
            switch try await service.sync(project) {
            case .unchanged:
                if state(of: id).board == nil, let (data, url) = try await service.loadCached(project) {
                    await apply(data, snapshot: url, to: id)
                }
            case let .updated(data, snapshot):
                await apply(data, snapshot: snapshot, to: id)
                update(id) { $0.lastCommit = data.commit }
            }
            update(id) { $0.lastSyncAt = .now }
            states[id]?.error = nil
        } catch {
            states[id, default: ProjectState()].error = "\(error)"
        }
    }

    private func apply(_ data: BeadsData, snapshot: URL, to id: UUID) async {
        let board = await Task.detached(priority: .userInitiated) { BoardIndex(data) }.value
        guard projects.contains(where: { $0.id == id }) else { return }
        states[id, default: ProjectState()].board = board
        states[id]?.snapshot = snapshot
    }

    // MARK: - Detail

    func detail(_ issueID: String, project id: UUID) async throws -> IssueDetail? {
        guard let env, let snapshot = state(of: id).snapshot else { return nil }
        return try await BeadsReader(dolt: DoltClient(env: env)).detail(issueID: issueID, snapshot: snapshot)
    }

    // MARK: - Persistence

    private func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
        try? save()
    }

    private func save() throws { try projectsFile?.save(projects) }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
