import Foundation
import Testing
@testable import BeadsKit

@Suite struct RemoteURLTests {
    @Test(arguments: [
        "git@github.com:octo-org/private-beads.git",
        "git@github.com:octo-org/private-beads",
        "ssh://git@github.com/octo-org/private-beads.git",
        "git+ssh://git@github.com/octo-org/private-beads.git",
        "https://github.com/octo-org/private-beads",
        "https://github.com/octo-org/private-beads.git",
        "github.com/octo-org/private-beads",
        "octo-org/private-beads",
        "  git@github.com:octo-org/private-beads.git\n",
    ])
    func normalizesToSSH(_ input: String) throws {
        let url = try RemoteURL.parse(input)
        #expect(url.gitURL == "ssh://git@github.com/octo-org/private-beads.git")
        #expect(url.description == "octo-org/private-beads")
    }

    @Test func keepsCustomPortAndUser() throws {
        let url = try RemoteURL.parse("ssh://gitea@git.example.com:2222/team/proj.git")
        #expect(url.gitURL == "ssh://gitea@git.example.com:2222/team/proj.git")
        #expect(url.description == "git.example.com/team/proj")
    }

    @Test(arguments: [
        "", "just-a-word", "ftp://github.com/a/b", "github.com/a/b/c/d",
        "git@github.com:-oProxyCommand=evil/x", "git@github.com:a/b;rm", "ddk9499/..", "git@-host:a/b",
    ])
    func rejects(_ input: String) {
        #expect(throws: RemoteURL.ParseError.self) { try RemoteURL.parse(input) }
    }
}

@Suite struct GitParsingTests {
    @Test func parsesTree() throws {
        let raw = [
            "100644 blob c6cf3de5e936c366d2ed58167cbf8c99d01c7fe2 1577964\t35h6ef7ctklkh9kdgb9rcep3oe34qgrj.darc",
            "100644 blob 1754b404a1b0952f6b0e0e3b68ab9f400c0798fc     255\tmanifest",
        ].joined(separator: "\0") + "\0"
        let entries = try GitClient.parseTree(Data(raw.utf8))
        #expect(entries.map(\.name) == ["35h6ef7ctklkh9kdgb9rcep3oe34qgrj.darc", "manifest"])
        #expect(entries[0].size == 1_577_964)
    }

    @Test(arguments: [
        "040000 tree c6cf3de5e936c366d2ed58167cbf8c99d01c7fe2 -\tsubdir",
        "100644 blob c6cf3de5e936c366d2ed58167cbf8c99d01c7fe2 10\t../escape",
        "120000 blob c6cf3de5e936c366d2ed58167cbf8c99d01c7fe2 10\tlink",
        "100644 blob c6cf3de5e936c366d2ed58167cbf8c99d01c7fe2 10\t.hidden",
    ])
    func rejectsUnsafeEntries(_ line: String) {
        let raw = line + "\0" + "100644 blob 1754b404a1b0952f6b0e0e3b68ab9f400c0798fc 255\tmanifest\0"
        #expect(throws: RemoteError.self) { try GitClient.parseTree(Data(raw.utf8)) }
    }

    @Test func requiresManifest() {
        let raw = "100644 blob 1754b404a1b0952f6b0e0e3b68ab9f400c0798fc 255\tabc\0"
        #expect(throws: RemoteError.self) { try GitClient.parseTree(Data(raw.utf8)) }
    }

    @Test(arguments: [
        ("ERROR: Repository not found.\nfatal: Could not read from remote repository.", RemoteError.repositoryNotFound),
        ("git@github.com: Permission denied (publickey).", RemoteError.authenticationFailed(detail: "git@github.com: Permission denied (publickey).")),
        ("Host key verification failed.", RemoteError.hostKeyMismatch(detail: "Host key verification failed.")),
        ("xcrun: error: invalid active developer path", RemoteError.gitUnavailable),
    ])
    func classifiesErrors(_ stderr: String, _ expected: RemoteError) {
        #expect(RemoteError.classify(stderr: stderr, command: "ls-remote") == expected)
    }
}

@Suite struct EnvironmentTests {
    let paths = AppPaths(root: URL(filePath: "/Users/x/Library/Application Support/uz.dkamaloff.beads"),
                         sshControlDir: URL(filePath: "/tmp/beads-501"))

    @Test func controlPathDiffersPerKey() {
        let env = ToolEnvironment(paths: paths, doltExecutable: URL(filePath: "/x/dolt"))
        let a = env.sshOptions(SSHIdentity(privateKeyPath: "/Users/x/.ssh/id_ed25519"))
        let b = env.sshOptions(SSHIdentity(privateKeyPath: "/Users/x/.ssh/github_other"))
        let pathA = a.first { $0.hasPrefix("ControlPath=") }
        let pathB = b.first { $0.hasPrefix("ControlPath=") }
        #expect(pathA != nil && pathA != pathB)
        // Unix socket limit is 104 bytes; ssh appends a ~17 char temp suffix while creating the master.
        #expect((pathA!.count - "ControlPath=".count - 2 + 40 + 17) < 104)
    }

    @Test func gitSSHCommandQuotesPathsWithSpaces() {
        let env = ToolEnvironment(paths: paths, doltExecutable: URL(filePath: "/x/dolt"))
        let cmd = env.gitEnvironment(SSHIdentity(privateKeyPath: "/Users/x/my keys/id"))["GIT_SSH_COMMAND"]!
        #expect(cmd.contains("'/Users/x/my keys/id'"))
        #expect(cmd.contains(#"UserKnownHostsFile="/Users/x/Library/Application Support/uz.dkamaloff.beads/known_hosts""#))
        #expect(cmd.contains("'BatchMode=yes'"))
    }

    @Test func gitEnvironmentIsolatesUserConfig() {
        let env = ToolEnvironment(paths: paths, doltExecutable: URL(filePath: "/x/dolt")).gitEnvironment(.init(privateKeyPath: nil))
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
    }
}

@Suite struct DoltOutputTests {
    @Test func splitsResultSets() throws {
        let out = """
        {"rows": [{"v":64}]}
        {"rows": [{"id":"bd-1","title":"A\\nB"},{"id":"bd-2"}]}
        {}

        """
        let sets = try DoltClient.splitResults(Data(out.utf8))
        #expect(sets.count == 3)
        let rows = try JSONSerialization.jsonObject(with: sets[1]) as! [[String: Any]]
        #expect(rows.count == 2)
        #expect((try JSONSerialization.jsonObject(with: sets[2]) as! [Any]).isEmpty)
    }

    @Test func decodesIssueWithMissingNullColumns() throws {
        let json = #"[{"id":"bd-ciouf","title":"T","status":"in_progress","priority":2,"issue_type":"bug","assignee":"beads/polecats/quartz","created_at":"2026-02-03 14:24:16","updated_at":"2026-02-10 06:08:03.123456","pinned":0}]"#
        let issue = try BeadsReader.decoder().decode([BeadsKit.Issue].self, from: Data(json.utf8))[0]
        #expect(issue.closedAt == nil)
        #expect(issue.owner == nil)
        #expect(issue.pinned == false)
        #expect(issue.createdAt == ISO8601DateFormatter().date(from: "2026-02-03T14:24:16Z"))
    }

    @Test func schemaSupport() {
        #expect(BeadsReader.support(for: 64) == .supported)
        #expect(BeadsReader.support(for: 70) == .newerThanTested(70))
        #expect(BeadsReader.support(for: 10) == .olderThanTested(10))
    }

    @Test func issueIDValidation() {
        #expect(BeadsReader.isSafeIssueID("spk-ywt.1"))
        #expect(!BeadsReader.isSafeIssueID("x' OR 1=1 --"))
    }
}
