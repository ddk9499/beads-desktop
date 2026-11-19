import Foundation
import Testing
@testable import BeadsKit

/// Tests that need local tools (git, the pinned dolt from `scripts/fetch-dolt.sh`) but no network.
enum Offline {
    /// `Vendor/dolt/dolt` of this repository, or `BEADS_IT_DOLT`.
    static var doltURL: URL? {
        if let path = ProcessInfo.processInfo.environment["BEADS_IT_DOLT"] { return URL(filePath: path) }
        let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
        let url = repo.appending(path: "Vendor/dolt/dolt")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    static var hasDolt: Bool { doltURL != nil }

    static func makeEnv() throws -> (ToolEnvironment, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "beadskit-offline-\(UUID().uuidString.prefix(8))")
        let paths = AppPaths(root: root, sshControlDir: URL(filePath: "/tmp/bk-off-\(getuid())"))
        try paths.prepare()
        return (ToolEnvironment(paths: paths, doltExecutable: doltURL ?? URL(filePath: "/usr/bin/false")), root)
    }

    /// Copies the committed schema-66 fixture into a fresh Dolt database dir (dolt writes a LOCK file into it).
    static func fixtureDatabase(in root: URL) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "noms", withExtension: nil, subdirectory: "Fixtures/schema66"))
        let db = root.appending(path: "db")
        try FileManager.default.createDirectory(at: db.appending(path: ".dolt"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: db.appending(path: ".dolt/noms"))
        try Data(SnapshotStore.repoState.utf8).write(to: db.appending(path: ".dolt/repo_state.json"))
        return db
    }

    static func run(_ exe: String, _ args: [String], in dir: URL? = nil, stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM": "1",
                         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                         "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
                         "DOLT_ROOT_PATH": FileManager.default.temporaryDirectory.appending(path: "bk-dolt-root").path,
                         "DOLT_DISABLE_VERSION_CHECKS": "1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try inPipe.fileHandleForWriting.close()
        } else {
            try p.run()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite(.enabled(if: Offline.hasDolt), .serialized) struct ReaderFixtureTests {
    @Test func readsSchema66Fixture() async throws {
        let (env, root) = try Offline.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Offline.fixtureDatabase(in: root)
        let data = try await BeadsReader(dolt: DoltClient(env: env)).read(snapshot: db, commit: "fixture")
        #expect(data.schemaVersion == 66)
        #expect(data.issues.count == 6)
        #expect(data.skippedRows == 0)
        #expect(data.tables.isSuperset(of: ["issues", "comments", "dependencies", "labels"]))
        let board = BoardIndex(data)
        #expect(board.children(of: "spk-ywt").map(\.id) == ["spk-ywt.1"])
        #expect(board.columns["spk-v6u"] == .inProgress)

        let detail = try await BeadsReader(dolt: DoltClient(env: env)).detail(issueID: "spk-ywt", snapshot: db, tables: data.tables)
        #expect(!detail.comments.isEmpty)
    }

    /// A repository that replaces `issues` with a VIEW would make dolt run its SQL: refuse instead.
    @Test func refusesViewsInPlaceOfTables() async throws {
        let (env, root) = try Offline.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Offline.fixtureDatabase(in: root)
        _ = try Offline.run(env.doltExecutable.path, ["sql", "-q",
            "RENAME TABLE issues TO issues_real; CREATE VIEW issues AS SELECT * FROM issues_real"], in: db)
        await #expect(throws: BeadsReader.ReadError.viewsInPlaceOfTables(["issues"])) {
            _ = try await BeadsReader(dolt: DoltClient(env: env)).read(snapshot: db, commit: "evil")
        }
    }

    /// dolt runs sandboxed: no reading of files under the home folder outside the snapshot.
    @Test func doltCannotReadHomeFiles() async throws {
        let (env, root) = try Offline.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Offline.fixtureDatabase(in: root)
        let secret = URL(filePath: NSHomeDirectory()).appending(path: ".beadskit-sandbox-probe-\(getpid())")
        try Data("secret".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        let rows = try await DoltClient(env: env).query(["SELECT LOAD_FILE('\(secret.path)') AS f"], in: db)
        #expect(!String(decoding: rows[0], as: UTF8.self).contains("secret"))
    }
}

@Suite(.serialized) struct SnapshotStoreTests {
    /// Builds a bare repo whose `refs/dolt/data` commit has the given flat files.
    static func bareRepo(files: [String: String], in root: URL, subdir: Bool = false) throws -> (URL, String) {
        let bare = root.appending(path: "data.git")
        _ = try Offline.run("/usr/bin/git", ["init", "--bare", "--quiet", bare.path])
        var tree = ""
        for (name, content) in files.sorted(by: { $0.key < $1.key }) {
            let oid = try Offline.run("/usr/bin/git", ["--git-dir", bare.path, "hash-object", "-w", "--stdin"], stdin: content)
            tree += "100644 blob \(oid)\t\(name)\n"
        }
        if subdir {
            let inner = try Offline.run("/usr/bin/git", ["--git-dir", bare.path, "mktree"], stdin: tree)
            tree += "040000 tree \(inner)\tsub\n"
        }
        let treeID = try Offline.run("/usr/bin/git", ["--git-dir", bare.path, "mktree"], stdin: tree)
        let commit = try Offline.run("/usr/bin/git", ["--git-dir", bare.path, "commit-tree", treeID, "-m", "x"])
        _ = try Offline.run("/usr/bin/git", ["--git-dir", bare.path, "update-ref", beadsDataRef, commit])
        return (bare, commit)
    }

    static let manifest = "5:__DOLT__:lock:root:00000000000000000000000000000000:aaaa:1"

    @Test func materializesAndReusesUnchangedFiles() async throws {
        let (env, root) = try Offline.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(projectDir: root.appending(path: "p"))
        try FileManager.default.createDirectory(at: store.projectDir, withIntermediateDirectories: true)

        let (bare1, c1) = try Self.bareRepo(files: ["manifest": Self.manifest, "aaaa": "table-a", "bbbb.darc": "table-b"],
                                            in: store.projectDir)
        #expect(bare1.path == store.bareRepo.path)
        let git = GitClient(env: env)
        let s1 = try await store.materialize(commit: c1, git: git)
        #expect(try String(contentsOf: s1.appending(path: ".dolt/noms/aaaa"), encoding: .utf8) == "table-a")
        #expect(FileManager.default.fileExists(atPath: s1.appending(path: ".dolt/repo_state.json").path))

        // Second commit: one new table, one kept; the kept one may be cloned from the previous snapshot.
        let (_, c2) = try Self.bareRepo(files: ["manifest": Self.manifest + "x", "aaaa": "table-a", "cccc": "table-c"],
                                        in: store.projectDir)
        let s2 = try await store.materialize(commit: c2, previous: c1, git: git)
        #expect(try String(contentsOf: s2.appending(path: ".dolt/noms/aaaa"), encoding: .utf8) == "table-a")
        #expect(try String(contentsOf: s2.appending(path: ".dolt/noms/cccc"), encoding: .utf8) == "table-c")
        #expect(!FileManager.default.fileExists(atPath: s2.appending(path: ".dolt/noms/bbbb.darc").path))

        store.removeSnapshots(except: [c2])
        #expect(!store.hasSnapshot(c1))
        #expect(store.hasSnapshot(c2))
    }

    @Test func rejectsUnknownManifestFormat() async throws {
        let (env, root) = try Offline.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(projectDir: root.appending(path: "p"))
        try FileManager.default.createDirectory(at: store.projectDir, withIntermediateDirectories: true)
        let (_, c) = try Self.bareRepo(files: ["manifest": "6:__DOLT_NEXT__:x"], in: store.projectDir)
        await #expect(throws: RemoteError.self) { _ = try await store.materialize(commit: c, git: GitClient(env: env)) }
        // Nothing half-written is left behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.projectDir.appending(path: "snapshots").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func subdirectoryIsUnsupportedStorage() async throws {
        let (env, root) = try Offline.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(projectDir: root.appending(path: "p"))
        try FileManager.default.createDirectory(at: store.projectDir, withIntermediateDirectories: true)
        let (_, c) = try Self.bareRepo(files: ["manifest": Self.manifest], in: store.projectDir, subdir: true)
        do {
            _ = try await store.materialize(commit: c, git: GitClient(env: env))
            Testing.Issue.record("expected unsupportedStorage")
        } catch let RemoteError.unsupportedStorage(detail) {
            #expect(detail.contains("tree"))
        }
    }

    @Test func limits() {
        let big = [TreeEntry(objectID: String(repeating: "a", count: 40), name: "x", size: SnapshotStore.maxTotalBytes + 1)]
        #expect(throws: RemoteError.self) { try SnapshotStore.checkLimits(big) }
        let many = (0...SnapshotStore.maxFiles).map { TreeEntry(objectID: String(repeating: "a", count: 40), name: "f\($0)", size: 1) }
        #expect(throws: RemoteError.self) { try SnapshotStore.checkLimits(many) }
    }
}

@Suite struct ProcessRunnerTests {
    let env = ["PATH": "/usr/bin:/bin"]

    @Test func timeoutKills() async {
        await #expect(throws: ProcessError.self) {
            _ = try await ProcessRunner.run(URL(filePath: "/bin/sleep"), ["10"], environment: env, timeout: 0.5)
        }
    }

    @Test func outputLimitKills() async {
        do {
            _ = try await ProcessRunner.run(URL(filePath: "/usr/bin/yes"), [], environment: env, timeout: 20, outputLimit: 1_048_576)
            Testing.Issue.record("expected outputTooLarge")
        } catch ProcessError.outputTooLarge {
        } catch {
            Testing.Issue.record("unexpected \(error)")
        }
    }

    @Test func cancellationKills() async {
        let task = Task { try await ProcessRunner.run(URL(filePath: "/bin/sleep"), ["10"], environment: env, timeout: 30) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let started = ContinuousClock.now
        let result = await task.result
        #expect(ContinuousClock.now - started < .seconds(3))
        if case .success = result { Testing.Issue.record("expected cancellation") }
    }

    @Test func sandboxProfileBlocksWritesOutsideAllowedPaths() async throws {
        let profile = "(version 1)(allow default)(deny file-write* (subpath \"/private/tmp/bk-sandbox-deny\"))"
        try? FileManager.default.createDirectory(atPath: "/private/tmp/bk-sandbox-deny", withIntermediateDirectories: true)
        let out = try await ProcessRunner.run(URL(filePath: "/usr/bin/touch"), ["/private/tmp/bk-sandbox-deny/x"],
                                              environment: env, sandboxProfile: profile)
        #expect(out.status != 0)
    }
}

@Suite struct PollSchedulerTests {
    let a = UUID(), b = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func manualModeNeverDue() {
        let s = PollScheduler(interval: 0)
        #expect(s.due([a, b], now: t0).isEmpty)
        #expect(s.due([a], now: t0, minAge: 10).isEmpty)
    }

    @Test func dueAfterInterval() {
        var s = PollScheduler(interval: 30)
        #expect(s.due([a, b], now: t0) == [a, b])
        s.record(a, success: true, now: t0)
        #expect(s.due([a, b], now: t0.addingTimeInterval(10)) == [b])
        #expect(s.due([a, b], now: t0.addingTimeInterval(30), busy: [b]) == [a])
    }

    @Test func exponentialBackoffCapped() {
        var s = PollScheduler(interval: 30)
        s.record(a, success: false, now: t0)
        #expect(s.retryAt(a) == t0.addingTimeInterval(30))
        s.record(a, success: false, now: t0)
        #expect(s.retryAt(a) == t0.addingTimeInterval(60))
        for _ in 0..<10 { s.record(a, success: false, now: t0) }
        #expect(s.retryAt(a) == t0.addingTimeInterval(PollScheduler.maxBackoff))
        #expect(s.due([a], now: t0.addingTimeInterval(599)).isEmpty)
        s.record(a, success: true, now: t0)
        #expect(s.retryAt(a) == nil)
    }
}

@Suite struct SafeMarkdownTests {
    @Test(arguments: [
        ("[x](https://example.com)", true), ("[x](http://example.com)", true),
        ("[x](file:///etc/passwd)", false), ("[x](javascript:alert(1))", false),
        ("[x](x-apple.systempreferences:foo)", false), ("[x](ssh://host)", false), ("<https://ok.example>", true),
    ])
    func linkSchemes(_ source: String, _ keepsLink: Bool) {
        let text = SafeMarkdown.attributed(source)
        #expect(text.runs.contains { $0.link != nil } == keepsLink, "\(source)")
    }

    @Test func emphasisAndPlainText() {
        let text = SafeMarkdown.attributed("**bold** and `code`\nnext line")
        #expect(String(text.characters) == "bold and code\nnext line")
    }
}
