import Foundation

/// On-disk layout of one project:
/// ```
/// <project>/data.git/              bare repo holding only refs/dolt/data
/// <project>/snapshots/<commit>/    a Dolt database dir (.dolt/noms/* + repo_state.json)
/// ```
/// Snapshots are built in a temp dir and renamed into place, so readers never see a half-written store.
/// They stay writable: dolt takes a LOCK file inside `noms/` even for reads.
public struct SnapshotStore: Sendable {
    public let projectDir: URL

    public init(projectDir: URL) { self.projectDir = projectDir }

    public var bareRepo: URL { projectDir.appending(path: "data.git", directoryHint: .isDirectory) }
    var snapshotsDir: URL { projectDir.appending(path: "snapshots", directoryHint: .isDirectory) }

    public func snapshotURL(_ commit: String) -> URL {
        snapshotsDir.appending(path: commit, directoryHint: .isDirectory)
    }

    public func hasSnapshot(_ commit: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(commit).appending(path: ".dolt/noms/manifest").path)
    }

    /// Writes the files of `commit` from the bare repo into a fresh snapshot directory.
    public func materialize(commit: String, git: GitClient) async throws -> URL {
        let target = snapshotURL(commit)
        if hasSnapshot(commit) { return target }

        let fm = FileManager.default
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let staging = snapshotsDir.appending(path: ".tmp-\(commit)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let noms = staging.appending(path: ".dolt/noms", directoryHint: .isDirectory)
        try fm.createDirectory(at: noms, withIntermediateDirectories: true)

        do {
            let entries = try await git.listTree(commit: commit, in: bareRepo)
            for entry in entries {
                let file = noms.appending(path: entry.name)
                try await git.writeBlob(entry.objectID, in: bareRepo, to: file)
                let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
                guard size == entry.size else { throw RemoteError.unexpectedTreeEntry("\(entry.name): size mismatch") }
            }
            try Data(Self.repoState.utf8).write(to: staging.appending(path: ".dolt/repo_state.json"))
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return target
    }

    /// Removes every snapshot not in `keep` (and stale staging dirs).
    public func removeSnapshots(except keep: Set<String>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil,
                                                      options: []) else { return }
        for item in items where !keep.contains(item.lastPathComponent) {
            try? fm.removeItem(at: item)
        }
    }

    /// Minimal Dolt repo state for a single local `main` branch with no remotes.
    static let repoState = #"{"head":"refs/heads/main","remotes":{},"backups":{},"branches":{}}"#
}
