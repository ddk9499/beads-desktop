import BeadsKit
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    enum ProjectState {
        case idle
        case syncing
        case loaded(BeadsData, snapshot: URL)
        case failed(String)
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
        for project in projects { await loadCachedThenSync(project.id) }
    }

    func state(of id: UUID) -> ProjectState { states[id] ?? .idle }

    func addProject(address: String, keyPath: String?) async throws -> Project {
        let remote = try RemoteURL.parse(address)
        if let existing = projects.first(where: { $0.remote == remote }) { return existing }
        let project = Project(remote: remote, identity: SSHIdentity(privateKeyPath: keyPath))
        projects.append(project)
        try save()
        await sync(project.id)
        return project
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        states[id] = nil
        try? save()
        if let env { try? FileManager.default.removeItem(at: env.paths.projectDir(id)) }
    }

    func loadCachedThenSync(_ id: UUID) async {
        guard let service, let project = projects.first(where: { $0.id == id }) else { return }
        if let (data, url) = try? await service.loadCached(project) { states[id] = .loaded(data, snapshot: url) }
        await sync(id)
    }

    func sync(_ id: UUID) async {
        guard let service, let project = projects.first(where: { $0.id == id }) else { return }
        if case .loaded = state(of: id) {} else { states[id] = .syncing }
        do {
            switch try await service.sync(project) {
            case .unchanged:
                if case .loaded = state(of: id) {} else if let (data, url) = try await service.loadCached(project) {
                    states[id] = .loaded(data, snapshot: url)
                }
            case let .updated(data, snapshot):
                states[id] = .loaded(data, snapshot: snapshot)
                update(id) { $0.lastCommit = data.commit }
            }
            update(id) { $0.lastSyncAt = .now }
        } catch {
            states[id] = .failed("\(error)")
        }
    }

    func detail(_ issueID: String, project id: UUID) async throws -> IssueDetail? {
        guard let env, case let .loaded(_, snapshot) = state(of: id) else { return nil }
        return try await BeadsReader(dolt: DoltClient(env: env)).detail(issueID: issueID, snapshot: snapshot)
    }

    func whoAmI(host: String, keyPath: String?) async -> String {
        guard let env else { return "—" }
        do { return try await SSHProbe(env: env).account(host: host, identity: SSHIdentity(privateKeyPath: keyPath)) }
        catch { return "\(error)" }
    }

    private func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
        try? save()
    }

    private func save() throws { try projectsFile?.save(projects) }
}
