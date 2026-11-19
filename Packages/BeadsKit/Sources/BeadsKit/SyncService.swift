import Foundation

public enum SyncOutcome: Sendable {
    /// Remote ref did not move; the existing snapshot is current.
    case unchanged(commit: String)
    /// A new snapshot was fetched and read. `refID` is the raw id `ls-remote` reported (a tag object id when
    /// the ref points to an annotated tag), `data.commit` the commit it resolves to.
    case updated(BeadsData, snapshot: URL, refID: String)
}

/// Brings a project's local snapshot up to date with `refs/dolt/data` on its remote.
/// Calls for the same project are coalesced; different projects sync concurrently.
public actor SyncService {
    public let env: ToolEnvironment
    public let git: GitClient
    public let reader: BeadsReader
    private var inFlight: [UUID: Task<SyncOutcome, any Error>] = [:]
    private var updatesSinceGC: [UUID: Int] = [:]
    /// Run `git gc` on a project's bare repo every this many updates (it's slow on big stores).
    static let gcEvery = 10

    public init(env: ToolEnvironment) {
        self.env = env
        self.git = GitClient(env: env)
        self.reader = BeadsReader(dolt: DoltClient(env: env))
    }

    public func store(for project: Project) -> SnapshotStore {
        SnapshotStore(projectDir: env.paths.projectDir(project.id))
    }

    /// Reads the snapshot already on disk (no network). `nil` if there is none yet.
    public func loadCached(_ project: Project) async throws -> (BeadsData, URL)? {
        guard let commit = project.lastCommit else { return nil }
        let store = store(for: project)
        guard store.hasSnapshot(commit) else { return nil }
        let url = store.snapshotURL(commit)
        return (try await reader.read(snapshot: url, commit: commit), url)
    }

    public func sync(_ project: Project) async throws -> SyncOutcome {
        if let running = inFlight[project.id] { return try await running.value }
        let task = Task { try await self.performSync(project) }
        inFlight[project.id] = task
        defer { inFlight[project.id] = nil }
        return try await task.value
    }

    /// Cancels a running sync of the project (if any) and waits until it has stopped touching its files.
    public func cancel(_ projectID: UUID) async {
        guard let task = inFlight[projectID] else { return }
        task.cancel()
        _ = try? await task.value
    }

    /// Stops any sync of the project and deletes everything stored for it.
    public func remove(_ projectID: UUID) async {
        await cancel(projectID)
        updatesSinceGC[projectID] = nil
        try? FileManager.default.removeItem(at: env.paths.projectDir(projectID))
    }

    /// Deletes data directories of projects that are no longer in the list (e.g. removed mid-sync by an older build).
    public func removeOrphans(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: env.paths.projectsDir, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !ids.contains(id), inFlight[id] == nil else { continue }
            try? fm.removeItem(at: dir)
        }
    }

    private func performSync(_ project: Project) async throws -> SyncOutcome {
        let store = store(for: project)
        guard let remoteRef = try await git.remoteDataRef(project.remote, identity: project.identity) else {
            throw RemoteError.noBeadsData
        }
        if let commit = project.lastCommit, remoteRef == (project.lastRefID ?? commit), store.hasSnapshot(commit) {
            return .unchanged(commit: commit)
        }
        try Task.checkCancellation()

        try await git.ensureBareRepo(at: store.bareRepo)
        let fetched = try await git.fetchDataRef(project.remote, identity: project.identity, into: store.bareRepo)
        try Task.checkCancellation()
        let snapshot = try await store.materialize(commit: fetched, previous: project.lastCommit, git: git)
        let data = try await reader.read(snapshot: snapshot, commit: fetched)

        // Keep the previous snapshot one more round: the UI may still be reading it (issue detail queries).
        store.removeSnapshots(except: Set([fetched, project.lastCommit].compactMap { $0 }))
        let count = (updatesSinceGC[project.id] ?? 0) + 1
        if count >= Self.gcEvery {
            await git.prune(store.bareRepo)
            updatesSinceGC[project.id] = 0
        } else {
            updatesSinceGC[project.id] = count
        }
        return .updated(data, snapshot: snapshot, refID: remoteRef)
    }
}
