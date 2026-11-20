import Foundation

/// Filesystem locations used by the app. Everything is keyed by bundle id, never by the display name,
/// so renaming the app keeps user data.
public struct AppPaths: Sendable {
    /// `~/Library/Application Support/<bundle id>`
    public let root: URL
    /// Short directory for ssh ControlMaster sockets (Unix socket paths are limited to 104 bytes).
    public let sshControlDir: URL

    public init(root: URL, sshControlDir: URL) {
        self.root = root
        self.sshControlDir = sshControlDir
    }

    public static func standard(bundleID: String) throws -> AppPaths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return AppPaths(
            root: support.appending(path: bundleID, directoryHint: .isDirectory),
            // Per app (bundle id) so the release and debug apps never share ssh master connections.
            sshControlDir: URL(filePath: "/tmp/beads-\(ToolEnvironment.shortTag(bundleID))-\(getuid())", directoryHint: .isDirectory)
        )
    }

    public var projectsDir: URL { root.appending(path: "projects", directoryHint: .isDirectory) }
    public var projectsFile: URL { root.appending(path: "projects.json") }
    public var doltRoot: URL { root.appending(path: "dolt-root", directoryHint: .isDirectory) }
    public var knownHostsFile: URL { root.appending(path: "known_hosts") }

    public func projectDir(_ id: UUID) -> URL {
        projectsDir.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    /// Creates directories and the files that must exist before any git/ssh/dolt call.
    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sshControlDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The control dir lives in /tmp: refuse to use it if someone else owns it.
        let attrs = try fm.attributesOfItem(atPath: sshControlDir.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: sshControlDir.path])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshControlDir.path)

        try KnownHosts.github.write(to: knownHostsFile, atomically: true, encoding: .utf8)

        // dolt keeps its global config under DOLT_ROOT_PATH. Disable usage metrics (eventsapi.dolthub.com)
        // and the "newer version available" check (which calls GitHub) before dolt ever runs.
        let doltConfigDir = doltRoot.appending(path: ".dolt", directoryHint: .isDirectory)
        try fm.createDirectory(at: doltConfigDir, withIntermediateDirectories: true)
        let config = doltConfigDir.appending(path: "config_global.json")
        try Data(#"{"metrics.disabled":"true","versioncheck.disabled":"true"}"#.utf8).write(to: config, options: .atomic)
    }
}

/// Host keys published by GitHub (`gh api meta --jq .ssh_keys`), pinned so first contact never prompts.
/// Fingerprints (SHA256): ED25519 +DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU,
/// ECDSA p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM, RSA uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s.
public enum KnownHosts {
    /// Hosts whose keys are pinned below; for them nothing else is trusted.
    public static func isPinned(_ host: String) -> Bool { host.lowercased() == "github.com" }

    public static let github = """
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
    @revoked github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==

    """
}

/// How to authenticate one project over SSH.
public struct SSHIdentity: Hashable, Codable, Sendable {
    /// Absolute path to the private key; `nil` = let ssh use its defaults (agent / ~/.ssh/config).
    public var privateKeyPath: String?

    public init(privateKeyPath: String?) { self.privateKeyPath = privateKeyPath }
}

/// Builds the process environment shared by every git/ssh invocation.
public struct ToolEnvironment: Sendable {
    public let paths: AppPaths
    public let gitExecutable: URL
    public let sshExecutable: URL
    public let doltExecutable: URL

    public init(paths: AppPaths, gitExecutable: URL = URL(filePath: "/usr/bin/git"),
                sshExecutable: URL = URL(filePath: "/usr/bin/ssh"), doltExecutable: URL) {
        self.paths = paths
        self.gitExecutable = gitExecutable
        self.sshExecutable = sshExecutable
        self.doltExecutable = doltExecutable
    }

    /// ssh options as argv (used directly for `ssh -T`, and joined into GIT_SSH_COMMAND for git).
    /// - Parameter host: the server being contacted. For hosts we pin (github.com) only the pinned keys are trusted.
    public func sshOptions(_ identity: SSHIdentity, host: String = "github.com") -> [String] {
        // For pinned hosts, ~/.ssh/known_hosts (which may still hold GitHub's RSA key leaked in 2023) and the
        // global file are not consulted; other hosts use the pinned file plus the user's known_hosts.
        let knownHosts = KnownHosts.isPinned(host)
            ? "UserKnownHostsFile=\"\(paths.knownHostsFile.path)\""
            : "UserKnownHostsFile=\"\(paths.knownHostsFile.path)\" \"\(NSHomeDirectory())/.ssh/known_hosts\""
        var opts = [
            "-o", "BatchMode=yes",                       // never prompt (passphrase, host key, password)
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=yes",
            // ssh splits this list on spaces; each path is quoted ("Application Support" has a space).
            "-o", knownHosts,
            "-o", KnownHosts.isPinned(host) ? "GlobalKnownHostsFile=/dev/null" : "GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts",
            // Detect dead connections (sleep, network change) instead of hanging.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            // %C hashes host/port/user but NOT the key: without the identity tag, two projects using different
            // keys for github.com would share one master connection and silently act as the wrong account.
            "-o", "ControlPath=\(paths.sshControlDir.path)/\(Self.identityTag(identity))-%C",
            "-o", "ControlPersist=300",
        ]
        if let key = identity.privateKeyPath {
            // An explicit key must fully determine the account: ignore ~/.ssh/config, whose IdentityFile entries
            // ssh would otherwise also offer (and GitHub accepts the first key it knows -> wrong account).
            opts = ["-F", "/dev/null"] + opts + ["-o", "IdentitiesOnly=yes", "-i", key]
        }
        return opts
    }

    public func gitEnvironment(_ identity: SSHIdentity, host: String = "github.com") -> [String: String] {
        // GIT_SSH_COMMAND is evaluated by a shell: quote every token.
        let command = ([sshExecutable.path] + sshOptions(identity, host: host)).map(Self.shellQuote).joined(separator: " ")
        var env = baseEnvironment()
        env["GIT_SSH_COMMAND"] = command
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CONFIG_NOSYSTEM"] = "1"     // no system credential helpers / hooks
        env["GIT_CONFIG_GLOBAL"] = "/dev/null" // user's global config must not change behavior
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }

    public func doltEnvironment() -> [String: String] {
        var env = baseEnvironment()
        env["DOLT_ROOT_PATH"] = paths.doltRoot.path
        env["DOLT_DISABLE_VERSION_CHECKS"] = "1"
        return env
    }

    func baseEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        // Keep access to the user's ssh-agent (launchd provides it to GUI apps too).
        if let sock = inherited["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = sock }
        if let tmp = inherited["TMPDIR"] { env["TMPDIR"] = tmp }
        return env
    }

    /// Short stable tag for an identity (8 hex chars of FNV-1a over the key path).
    static func identityTag(_ identity: SSHIdentity) -> String {
        shortTag(identity.privateKeyPath ?? "default")
    }

    /// 8 hex chars of FNV-1a; collision resistance is not a security property here (paths only).
    static func shortTag(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a 64
        for byte in input.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
