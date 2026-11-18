import Foundation

public enum SyncOutcome: Sendable {
    /// Remote ref did not move; the existing snapshot is current.
    case unchanged(commit: String)
    /// A new snapshot was fetched and read.
    case updated(BeadsData, snapshot: URL)
}

/// Brings a project's local snapshot up to date with `refs/dolt/data` on its remote.
/// Calls for the same project are coalesced; different projects sync concurrently.
public actor SyncService {
    public let env: ToolEnvironment
    public let git: GitClient
    public let reader: BeadsReader
    private var inFlight: [UUID: Task<SyncOutcome, any Error>] = [:]

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

    private func performSync(_ project: Project) async throws -> SyncOutcome {
        let store = store(for: project)
        guard let remoteCommit = try await git.remoteDataRef(project.remote, identity: project.identity) else {
            throw RemoteError.noBeadsData
        }
        if remoteCommit == project.lastCommit, store.hasSnapshot(remoteCommit) {
            return .unchanged(commit: remoteCommit)
        }

        try await git.ensureBareRepo(at: store.bareRepo)
        let fetched = try await git.fetchDataRef(project.remote, identity: project.identity, into: store.bareRepo)
        let snapshot = try await store.materialize(commit: fetched, git: git)
        let data = try await reader.read(snapshot: snapshot, commit: fetched)

        store.removeSnapshots(except: fetched)
        await git.prune(store.bareRepo)
        return .updated(data, snapshot: snapshot)
    }
}
