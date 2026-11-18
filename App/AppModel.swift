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
    /// Issues changed by recent refreshes, per project: issue id → (what, when). Drives card highlights.
    private(set) var recentChanges: [UUID: [String: RecentChange]] = [:]
    /// Set when something (a notification click) asks to show a project/issue; views consume and clear it.
    var focusRequest: FocusRequest?

    struct RecentChange: Hashable {
        let kind: IssueChange.Kind
        let at: Date
    }

    struct FocusRequest: Equatable {
        let project: UUID
        let issue: String?
    }

    /// How long a changed card stays highlighted.
    static let highlightDuration: TimeInterval = 10 * 60

    private var pollTask: Task<Void, Never>?
    private var failures: [UUID: Int] = [:]
    private var nextAttempt: [UUID: Date] = [:]
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
        Notifier.shared.onOpen = { [weak self] project, issue in self?.focusRequest = FocusRequest(project: project, issue: issue) }
        Task { await Notifier.shared.requestAuthorizationIfNeeded() }
        await withTaskGroup(of: Void.self) { group in
            for project in projects { group.addTask { await self.loadCachedThenSync(project.id) } }
        }
        startPolling()
    }

    // MARK: - Polling

    /// Poll interval in seconds from Settings; 0 = off.
    static var pollInterval: TimeInterval {
        let value = UserDefaults.standard.object(forKey: SettingsKeys.pollSeconds) as? Double ?? 30
        return value
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = AppModel.pollInterval
                try? await Task.sleep(for: .seconds(interval > 0 ? min(interval, 15) : 15))
                guard let self, interval > 0 else { continue }
                await self.syncDue(olderThan: interval)
            }
        }
    }

    /// Syncs projects whose last sync is older than `age` and that aren't in failure backoff.
    func syncDue(olderThan age: TimeInterval) async {
        let now = Date.now
        let due = projects.filter { p in
            !state(of: p.id).isSyncing
                && (nextAttempt[p.id].map { $0 <= now } ?? true)
                && (p.lastSyncAt.map { now.timeIntervalSince($0) >= age - 1 } ?? true)
        }
        await withTaskGroup(of: Void.self) { group in
            for project in due { group.addTask { await self.sync(project.id) } }
        }
    }

    /// Called when the app comes to the front: refresh anything not synced in the last few seconds.
    func appDidBecomeActive() {
        Task { await syncDue(olderThan: 10) }
    }

    /// Exponential backoff after failures: interval × 2^n, capped at 10 minutes.
    private func recordResult(_ id: UUID, success: Bool) {
        if success {
            failures[id] = nil
            nextAttempt[id] = nil
        } else {
            let n = (failures[id] ?? 0) + 1
            failures[id] = n
            let base = max(AppModel.pollInterval, 30)
            nextAttempt[id] = .now.addingTimeInterval(min(base * pow(2, Double(n - 1)), 600))
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
        recentChanges[id] = nil
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
                let previous = state(of: id).board
                await apply(data, snapshot: snapshot, to: id)
                update(id) { $0.lastCommit = data.commit }
                if let previous, let current = state(of: id).board {
                    noteChanges(ChangeDetector.changes(from: previous, to: current), project: id)
                }
            }
            update(id) { $0.lastSyncAt = .now }
            states[id]?.error = nil
            recordResult(id, success: true)
        } catch {
            states[id, default: ProjectState()].error = "\(error)"
            recordResult(id, success: false)
        }
    }

    private func noteChanges(_ changes: [IssueChange], project id: UUID) {
        guard !changes.isEmpty else { return }
        let now = Date.now
        var recent = (recentChanges[id] ?? [:]).filter { now.timeIntervalSince($0.value.at) < Self.highlightDuration }
        for change in changes where recent[change.issue.id] == nil || change.kind != .reassigned {
            recent[change.issue.id] = RecentChange(kind: change.kind, at: now)
        }
        recentChanges[id] = recent
        if let project = project(id) { Notifier.shared.post(changes, project: project) }
    }

    func recentChange(_ issueID: String, in project: UUID) -> RecentChange? {
        guard let change = recentChanges[project]?[issueID],
              Date.now.timeIntervalSince(change.at) < Self.highlightDuration else { return nil }
        return change
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
