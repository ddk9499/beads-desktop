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

    /// Limits for data from an untrusted remote (a real beads database is a few MB to a few hundred MB).
    public static let maxFiles = 10_000
    public static let maxTotalBytes: Int = 4 * 1_073_741_824

    /// Writes the files of `commit` from the bare repo into a fresh snapshot directory.
    /// Dolt table files are named by their content hash, so a file with the same name and size in `previous`
    /// is identical: it is cloned (APFS copy-on-write, instant, no extra space). The rest is extracted
    /// with a single git process.
    public func materialize(commit: String, previous: String? = nil, git: GitClient) async throws -> URL {
        let target = snapshotURL(commit)
        if hasSnapshot(commit) { return target }

        let fm = FileManager.default
        let entries = try await git.listTree(commit: commit, in: bareRepo)
        try Self.checkLimits(entries)

        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let staging = snapshotsDir.appending(path: ".tmp-\(commit)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let noms = staging.appending(path: ".dolt/noms", directoryHint: .isDirectory)
        try fm.createDirectory(at: noms, withIntermediateDirectories: true)

        do {
            let previousNoms = previous.flatMap { hasSnapshot($0) ? snapshotURL($0).appending(path: ".dolt/noms") : nil }
            var toExtract: [String] = []
            for entry in entries {
                if entry.name != "manifest", let previousNoms,
                   Self.size(of: previousNoms.appending(path: entry.name)) == entry.size,
                   clonefile(previousNoms.appending(path: entry.name).path, noms.appending(path: entry.name).path, 0) == 0 {
                    continue
                }
                toExtract.append(entry.name)
            }
            try await git.extract(toExtract, commit: commit, from: bareRepo, into: noms,
                                  indexFile: staging.appending(path: "index"))
            try? fm.removeItem(at: staging.appending(path: "index"))
            for entry in entries where Self.size(of: noms.appending(path: entry.name)) != entry.size {
                throw RemoteError.unexpectedTreeEntry("\(entry.name): size mismatch")
            }
            try Self.validateManifest(Data(contentsOf: noms.appending(path: "manifest")))
            try Data(Self.repoState.utf8).write(to: staging.appending(path: ".dolt/repo_state.json"))
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return target
    }

    static func checkLimits(_ entries: [TreeEntry]) throws {
        guard entries.count <= maxFiles else { throw RemoteError.tooLarge("\(entries.count) files, limit \(maxFiles)") }
        let total = entries.reduce(0) { $0 + $1.size }
        guard total <= maxTotalBytes else {
            throw RemoteError.tooLarge("\(total / 1_048_576) MB, limit \(maxTotalBytes / 1_048_576) MB")
        }
    }

    /// Dolt manifest: `<version>:<format>:<lock>:<root>:<gcgen>:<file>:<chunks>:…`. Only what the bundled dolt reads.
    static let supportedManifest = (version: "5", format: "__DOLT__")

    static func validateManifest(_ data: Data) throws {
        let fields = String(decoding: data.prefix(256), as: UTF8.self).split(separator: ":", maxSplits: 2)
        guard fields.count >= 2 else { throw RemoteError.unsupportedStorage("unreadable manifest") }
        guard fields[0] == supportedManifest.version, fields[1] == supportedManifest.format else {
            throw RemoteError.unsupportedStorage("manifest \(fields[0].prefix(8)):\(fields[1].prefix(16))")
        }
    }

    static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
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
