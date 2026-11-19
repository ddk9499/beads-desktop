import Foundation

public struct Project: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var remote: RemoteURL
    public var identity: SSHIdentity
    /// Optional user-facing name; defaults to `owner/repo`.
    public var customName: String?
    /// Commit of `refs/dolt/data` that the current snapshot was built from.
    public var lastCommit: String?
    /// Raw id of the ref when it was fetched (differs from `lastCommit` for annotated tags).
    public var lastRefID: String?
    public let addedAt: Date

    public init(id: UUID = UUID(), remote: RemoteURL, identity: SSHIdentity, customName: String? = nil) {
        self.id = id
        self.remote = remote
        self.identity = identity
        self.customName = customName
        self.addedAt = .now
    }

    public var displayName: String { customName?.isEmpty == false ? customName! : remote.description }
}

/// Persists the project list as JSON in Application Support.
public struct ProjectsFile: Sendable {
    let url: URL

    public init(url: URL) { self.url = url }

    struct Payload: Codable {
        var version = 1
        var projects: [Project]
    }

    public func load() throws -> [Project] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Payload.self, from: Data(contentsOf: url)).projects
    }

    public func save(_ projects: [Project]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Payload(projects: projects)).write(to: url, options: .atomic)
    }
}

/// Helpers for the "Add project" flow.
public struct SSHProbe: Sendable {
    let env: ToolEnvironment

    public init(env: ToolEnvironment) { self.env = env }

    /// Private keys in ~/.ssh that have a matching `.pub` next to them.
    public static func availableKeys(sshDir: URL = URL(filePath: NSHomeDirectory()).appending(path: ".ssh")) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: sshDir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "pub" }
            .map { $0.deletingPathExtension() }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Which account the key logs in as, e.g. GitHub's "Hi <login>! You've successfully authenticated".
    /// Matters when one machine has keys for several GitHub accounts.
    public func account(host: String, user: String = "git", identity: SSHIdentity) async throws -> String {
        let out = try await ProcessRunner.run(
            env.sshExecutable, env.sshOptions(identity, host: host) + ["-T", "--", "\(user)@\(host)"],
            environment: env.gitEnvironment(identity, host: host), timeout: 30
        )
        let text = out.stderrString + out.stdoutString
        if let range = text.range(of: #"Hi ([A-Za-z0-9_.-]+)!"#, options: .regularExpression) {
            return String(text[range].dropFirst(3).dropLast())
        }
        throw RemoteError.classify(stderr: text, command: "ssh")
    }
}
