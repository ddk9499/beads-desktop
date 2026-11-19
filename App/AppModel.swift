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

    struct RecentChange: Hashable {
        let kind: IssueChange.Kind
        let at: Date
    }

    struct FocusRequest: Equatable {
        let project: UUID
        let issue: String?
    }

    private(set) var projects: [Project] = []
    private(set) var states: [UUID: ProjectState] = [:]
    /// Issues changed by recent refreshes, per project: issue id → (what, when). Drives card highlights.
    private(set) var recentChanges: [UUID: [String: RecentChange]] = [:]
    /// Set when something (a notification click) asks to show a project/issue; views consume and clear it.
    var focusRequest: FocusRequest?
    /// Fatal setup problem (no data folder / no bundled dolt): nothing can work.
    private(set) var setupError: String?
    /// Non-fatal: git or dolt failed their self-check; cached data is still shown.
    private(set) var toolWarning: String?

    /// How long a changed card stays highlighted.
    static let highlightDuration: TimeInterval = 10 * 60

    @ObservationIgnored private var scheduler = PollScheduler(interval: AppModel.pollInterval)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// One running sync per project; later callers await the same task (coalescing happens here, so a change
    /// set is computed and notified exactly once).
    @ObservationIgnored private var syncTasks: [UUID: Task<Void, Never>] = [:]
    /// Last successful sync per project (memory only: persisting it would rewrite projects.json on every poll).
    private(set) var lastSync: [UUID: Date] = [:]

    @ObservationIgnored private var service: SyncService?
    @ObservationIgnored private var projectsFile: ProjectsFile?
    @ObservationIgnored private(set) var env: ToolEnvironment?

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "uz.dkamaloff.beads" }

    init() {
        // Before anything async: a click on a notification may be what launched the app.
        Notifier.shared.onOpen = { [weak self] project, issue in
            self?.focusRequest = FocusRequest(project: project, issue: issue)
        }
    }

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
        } catch {
            setupError = "\(error)"
            return
        }

        // Show cached data and start refreshing right away; nothing below waits for the network.
        for project in projects {
            Task { await loadCachedThenSync(project.id) }
        }
        startPolling()
        Task { await Notifier.shared.requestAuthorizationIfNeeded() }
        if let service { await service.removeOrphans(keeping: Set(projects.map(\.id))) }
        await checkTools()
    }

    /// Self-check of git and dolt. A failure is reported but doesn't stop cached data from showing.
    private func checkTools() async {
        guard let env else { return }
        do {
            async let git = GitClient(env: env).version()
            async let dolt = DoltClient(env: env).version()
            _ = try await (git, dolt)
            toolWarning = nil
        } catch {
            toolWarning = "\(error)"
        }
    }

    // MARK: - Polling

    /// Poll interval in seconds from Settings; 0 = manual only.
    static var pollInterval: TimeInterval {
        UserDefaults.standard.object(forKey: SettingsKeys.pollSeconds) as? Double ?? 30
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = AppModel.pollInterval
                try? await Task.sleep(for: .seconds(interval > 0 ? min(interval, 15) : 15))
                guard let self else { return }
                self.scheduler.interval = AppModel.pollInterval
                self.syncDue(minAge: nil)
            }
        }
    }

    /// Starts (without waiting) syncs for projects the scheduler says are due.
    private func syncDue(minAge: TimeInterval?) {
        let busy = Set(syncTasks.keys)
        for id in scheduler.due(projects.map(\.id), now: .now, minAge: minAge, busy: busy) {
            Task { await sync(id) }
        }
    }

    /// App came to the front: refresh anything not synced in the last few seconds (not in manual mode).
    func appDidBecomeActive() {
        scheduler.interval = Self.pollInterval
        syncDue(minAge: 10)
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

    /// Removes the project from the list now; its running sync is cancelled and awaited before its
    /// data folder is deleted, so nothing is recreated afterwards.
    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        states[id] = nil
        recentChanges[id] = nil
        lastSync[id] = nil
        scheduler.forget(id)
        try? save()
        let running = syncTasks[id]
        running?.cancel()
        Task {
            await running?.value
            await service?.remove(id)
        }
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
        if state(of: id).board == nil, let (data, url) = try? await service.loadCached(project) {
            await apply(data, snapshot: url, to: id)
        }
        await sync(id)
    }

    func syncAll() async {
        await withTaskGroup(of: Void.self) { group in
            for project in projects { group.addTask { await self.sync(project.id) } }
        }
    }

    /// Syncs a project; concurrent calls for the same project share one run.
    func sync(_ id: UUID) async {
        if let running = syncTasks[id] {
            await running.value
            return
        }
        let task = Task { await performSync(id) }
        syncTasks[id] = task
        await task.value
        syncTasks[id] = nil
    }

    private func performSync(_ id: UUID) async {
        guard let service, let project = project(id) else { return }
        states[id, default: ProjectState()].isSyncing = true
        defer { states[id]?.isSyncing = false }
        do {
            switch try await service.sync(project) {
            case .unchanged:
                if state(of: id).board == nil, let (data, url) = try await service.loadCached(project) {
                    await apply(data, snapshot: url, to: id)
                }
            case let .updated(data, snapshot, refID):
                let previous = state(of: id).board
                await apply(data, snapshot: snapshot, to: id)
                update(id) {
                    $0.lastCommit = data.commit
                    $0.lastRefID = refID
                }
                if let previous, let current = state(of: id).board {
                    noteChanges(ChangeDetector.changes(from: previous, to: current), project: id)
                }
            }
            guard self.project(id) != nil else { return }
            lastSync[id] = .now
            states[id]?.error = nil
            scheduler.record(id, success: true, now: .now)
        } catch is CancellationError {
            return
        } catch ProcessError.cancelled {
            return
        } catch {
            guard self.project(id) != nil else { return }
            states[id, default: ProjectState()].error = "\(error)"
            scheduler.record(id, success: false, now: .now)
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

    private func apply(_ data: BeadsData, snapshot: URL, to id: UUID) async {
        let board = await Task.detached(priority: .userInitiated) { BoardIndex(data) }.value
        guard projects.contains(where: { $0.id == id }) else { return }
        states[id, default: ProjectState()].board = board
        states[id]?.snapshot = snapshot
    }

    // MARK: - Detail

    func detail(_ issueID: String, project id: UUID) async throws -> IssueDetail? {
        let state = state(of: id)
        guard let env, let snapshot = state.snapshot, let board = state.board else { return nil }
        return try await BeadsReader(dolt: DoltClient(env: env))
            .detail(issueID: issueID, snapshot: snapshot, tables: board.data.tables)
    }

    // MARK: - Persistence

    /// Applies a change and writes projects.json only if something actually changed.
    private func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        var copy = projects[i]
        change(&copy)
        guard copy != projects[i] else { return }
        projects[i] = copy
        try? save()
    }

    private func save() throws { try projectsFile?.save(projects) }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
