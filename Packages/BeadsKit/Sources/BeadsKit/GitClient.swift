import Foundation

/// The ref where beads (Dolt) keeps its database on a git remote.
public let beadsDataRef = "refs/dolt/data"

public enum RemoteError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `/usr/bin/git` is the Xcode Command Line Tools shim and they are not installed.
    case gitUnavailable
    case authenticationFailed(detail: String)
    /// GitHub answers "Repository not found" both for missing repos and for repos the key's account can't see.
    case repositoryNotFound
    case hostKeyMismatch(detail: String)
    case keyNotLoaded(detail: String)
    case keyFileMissing(path: String)
    case network(detail: String)
    case noBeadsData
    case unexpectedTreeEntry(String)
    case gitFailed(command: String, detail: String)

    public var description: String {
        switch self {
        case .gitUnavailable:
            "git is not available. Install Xcode Command Line Tools: xcode-select --install"
        case let .authenticationFailed(d):
            "SSH authentication failed. Check that the selected key is added to your GitHub account.\n\(d)"
        case .repositoryNotFound:
            "Repository not found, or the selected SSH key's account has no access to it."
        case let .hostKeyMismatch(d):
            "SSH host key verification failed.\n\(d)"
        case let .keyNotLoaded(d):
            "The SSH key needs a passphrase. Load it once with: ssh-add --apple-use-keychain <key>\n\(d)"
        case let .keyFileMissing(path):
            "SSH key not found or not readable: \(path)"
        case let .network(d):
            "Network error.\n\(d)"
        case .noBeadsData:
            "This repository has no beads data (refs/dolt/data). Run `bd dolt push` in a beads workspace first."
        case let .unexpectedTreeEntry(name):
            "Unexpected file in beads data: \(name)"
        case let .gitFailed(cmd, d):
            "git \(cmd) failed.\n\(d)"
        }
    }

    /// Maps git/ssh stderr to a user-facing error.
    static func classify(stderr: String, command: String) -> RemoteError {
        let s = stderr.lowercased()
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("xcrun: error") || s.contains("no developer tools were found") || s.contains("invalid active developer path") {
            return .gitUnavailable
        }
        if s.contains("repository not found") { return .repositoryNotFound }
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") {
            return .hostKeyMismatch(detail: detail)
        }
        if s.contains("incorrect passphrase") || s.contains("enter passphrase") || s.contains("load key") {
            return .keyNotLoaded(detail: detail)
        }
        if s.contains("permission denied (publickey") { return .authenticationFailed(detail: detail) }
        if s.contains("could not resolve hostname") || s.contains("connection timed out")
            || s.contains("operation timed out") || s.contains("network is unreachable") || s.contains("connection refused") {
            return .network(detail: detail)
        }
        return .gitFailed(command: command, detail: detail)
    }
}

/// One file of the Dolt store inside `refs/dolt/data`.
public struct TreeEntry: Sendable, Equatable {
    public let objectID: String
    public let name: String
    public let size: Int
}

/// Thin wrapper over the system git for the few plumbing commands we need.
public struct GitClient: Sendable {
    let env: ToolEnvironment

    public init(env: ToolEnvironment) { self.env = env }

    private func git(_ args: [String], identity: SSHIdentity, in dir: URL? = nil,
                     stdoutFile: URL? = nil, timeout: Double = 120) async throws -> ProcessOutput {
        if let key = identity.privateKeyPath, !FileManager.default.isReadableFile(atPath: key) {
            throw RemoteError.keyFileMissing(path: key)
        }
        let out = try await ProcessRunner.run(env.gitExecutable, args, environment: env.gitEnvironment(identity),
                                              currentDirectory: dir, stdoutFile: stdoutFile, timeout: timeout)
        guard out.status == 0 else {
            throw RemoteError.classify(stderr: out.stderrString, command: args.first ?? "")
        }
        return out
    }

    /// Checks that git actually works (not just the CLT shim).
    public func version() async throws -> String {
        try await git(["--version"], identity: SSHIdentity(privateKeyPath: nil), timeout: 15)
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Current object id of `refs/dolt/data`, or `nil` when the repo has none.
    public func remoteDataRef(_ remote: RemoteURL, identity: SSHIdentity) async throws -> String? {
        let out = try await git(["ls-remote", "--", remote.gitURL, beadsDataRef], identity: identity, timeout: 60)
        for line in out.stdoutString.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            if cols.count == 2, cols[1] == beadsDataRef, Self.isObjectID(String(cols[0])) { return String(cols[0]) }
        }
        return nil
    }

    public func ensureBareRepo(at dir: URL) async throws {
        if FileManager.default.fileExists(atPath: dir.appending(path: "HEAD").path) { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await git(["init", "--bare", "--quiet", dir.path], identity: SSHIdentity(privateKeyPath: nil))
    }

    /// Fetches only the latest commit of `refs/dolt/data` and returns its object id.
    public func fetchDataRef(_ remote: RemoteURL, identity: SSHIdentity, into bareRepo: URL) async throws -> String {
        _ = try await git(["--git-dir", bareRepo.path, "fetch", "--quiet", "--no-tags", "--depth=1", "--force",
                           "--", remote.gitURL, "+\(beadsDataRef):\(beadsDataRef)"],
                          identity: identity, timeout: 600)
        let sha = try await git(["--git-dir", bareRepo.path, "rev-parse", "--verify", "\(beadsDataRef)^{commit}"],
                                identity: identity).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isObjectID(sha) else { throw RemoteError.gitFailed(command: "rev-parse", detail: sha) }
        return sha
    }

    /// Lists the flat tree of a commit. Data comes from the network, so names are validated strictly.
    public func listTree(commit: String, in bareRepo: URL) async throws -> [TreeEntry] {
        let out = try await git(["--git-dir", bareRepo.path, "ls-tree", "-z", "--long", commit],
                                identity: SSHIdentity(privateKeyPath: nil))
        return try Self.parseTree(out.stdout)
    }

    public func writeBlob(_ objectID: String, in bareRepo: URL, to file: URL) async throws {
        guard Self.isObjectID(objectID) else { throw RemoteError.unexpectedTreeEntry(objectID) }
        _ = try await git(["--git-dir", bareRepo.path, "cat-file", "blob", objectID],
                          identity: SSHIdentity(privateKeyPath: nil), stdoutFile: file, timeout: 600)
    }

    /// Drops objects no longer reachable after a forced ref update (each fetch replaces the whole store).
    public func prune(_ bareRepo: URL) async {
        _ = try? await git(["--git-dir", bareRepo.path, "gc", "--quiet", "--prune=now"],
                           identity: SSHIdentity(privateKeyPath: nil), timeout: 300)
    }

    // MARK: - Parsing

    static func isObjectID(_ s: String) -> Bool {
        (s.count == 40 || s.count == 64) && s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// Dolt store files: `manifest`, `LOCK`-less table files named by base32 hashes, optional `.darc` suffix.
    static func isSafeStoreFileName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && !s.hasPrefix(".") && !s.contains("/")
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// `ls-tree -z --long` lines: `<mode> SP <type> SP <object> SP+ <size> TAB <name> NUL`.
    static func parseTree(_ data: Data) throws -> [TreeEntry] {
        var entries: [TreeEntry] = []
        for record in data.split(separator: 0) where !record.isEmpty {
            let line = String(decoding: record, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { throw RemoteError.unexpectedTreeEntry(line) }
            let meta = line[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            let name = String(line[line.index(after: tab)...])
            guard meta.count == 4, meta[1] == "blob", meta[0] == "100644" || meta[0] == "100755",
                  isObjectID(String(meta[2])), let size = Int(meta[3]), isSafeStoreFileName(name)
            else { throw RemoteError.unexpectedTreeEntry(line) }
            entries.append(TreeEntry(objectID: String(meta[2]), name: name, size: size))
        }
        guard entries.contains(where: { $0.name == "manifest" }) else { throw RemoteError.unexpectedTreeEntry("manifest is missing") }
        return entries
    }
}
