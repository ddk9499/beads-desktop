import Foundation
import Testing
@testable import BeadsKit

/// Network tests against real repositories. Enabled only when these are set:
///   BEADS_IT_DOLT     path to a dolt binary (e.g. Vendor/dolt/dolt)
///   BEADS_IT_SSH_KEY  private key that GitHub accepts
///   BEADS_IT_PRIVATE  optional private repo with beads data, e.g. git@github.com:octo-org/private-beads.git
enum IT {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["BEADS_IT_DOLT"] != nil && env["BEADS_IT_SSH_KEY"] != nil }

    static func makeEnv() throws -> (ToolEnvironment, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "beadskit-it-\(UUID().uuidString.prefix(8))")
        let control = URL(filePath: "/tmp/bk-it-\(getuid())")
        let paths = AppPaths(root: root, sshControlDir: control)
        try paths.prepare()
        return (ToolEnvironment(paths: paths, doltExecutable: URL(filePath: env["BEADS_IT_DOLT"]!)), root)
    }

    static var identity: SSHIdentity { SSHIdentity(privateKeyPath: env["BEADS_IT_SSH_KEY"]) }
}

@Suite(.enabled(if: IT.enabled), .serialized) struct IntegrationTests {
    @Test func toolsAreAvailable() async throws {
        let (env, root) = try IT.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await GitClient(env: env).version().hasPrefix("git version"))
        #expect(try await DoltClient(env: env).version().hasPrefix("dolt version"))
    }

    @Test func syncsPublicBeadsRepo() async throws {
        let (env, root) = try IT.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SyncService(env: env)
        var project = Project(remote: try RemoteURL.parse("gastownhall/beads"), identity: IT.identity)

        let clock = ContinuousClock()
        let start = clock.now
        guard case let .updated(data, snapshot, _) = try await service.sync(project) else {
            Testing.Issue.record("expected first sync to fetch"); return
        }
        print("first sync: \(clock.now - start), issues: \(data.issues.count), schema: \(data.schemaVersion)")
        #expect(data.issues.count > 1000)
        #expect(BoardIndex(data).columns.values.contains(.ready))
        #expect(data.dependencies.contains { $0.type == Dependency.parentChild })
        #expect(BeadsReader.support(for: data.schemaVersion) == .supported)

        // Detail of an issue that has comments.
        let reader = BeadsReader(dolt: DoltClient(env: env))
        if let withComments = data.issues.first(where: { $0.status == "closed" }) {
            _ = try await reader.detail(issueID: withComments.id, snapshot: snapshot, tables: data.tables)
        }

        project.lastCommit = data.commit
        let second = clock.now
        guard case let .unchanged(commit) = try await service.sync(project) else {
            Testing.Issue.record("expected unchanged on second sync"); return
        }
        print("no-change sync: \(clock.now - second)")
        #expect(commit == data.commit)

        let cached = try await service.loadCached(project)
        #expect(cached?.0.issues.count == data.issues.count)
    }

    @Test(.enabled(if: IT.env["BEADS_IT_PRIVATE"] != nil))
    func syncsPrivateRepoAndReportsAccount() async throws {
        let (env, root) = try IT.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = try RemoteURL.parse(IT.env["BEADS_IT_PRIVATE"]!)

        let account = try await SSHProbe(env: env).account(host: remote.host, identity: IT.identity)
        print("ssh key authenticates as: \(account)")

        let service = SyncService(env: env)
        guard case let .updated(data, snapshot, _) = try await service.sync(Project(remote: remote, identity: IT.identity)) else {
            Testing.Issue.record("expected fetch"); return
        }
        #expect(!data.issues.isEmpty)
        let epic = try #require(data.issues.first { $0.issueType == "epic" })
        #expect(!BoardIndex(data).children(of: epic.id).isEmpty)
        let detail = try await BeadsReader(dolt: DoltClient(env: env)).detail(issueID: epic.id, snapshot: snapshot, tables: data.tables)
        print("epic \(epic.id) comments: \(detail.comments.map(\.text))")
    }

    @Test func missingKeyFileIsReportedClearly() async throws {
        let (env, root) = try IT.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: RemoteError.keyFileMissing(path: "/nonexistent/key")) {
            _ = try await GitClient(env: env).remoteDataRef(try RemoteURL.parse("gastownhall/beads"),
                                                            identity: SSHIdentity(privateKeyPath: "/nonexistent/key"))
        }
    }

    /// A real key that GitHub doesn't know must fail, even though ~/.ssh/config has a working default key.
    @Test(.enabled(if: IT.env["BEADS_IT_PRIVATE"] != nil && IT.env["BEADS_IT_OTHER_KEY"] != nil))
    func explicitKeyIsNotSilentlyReplacedByConfigKey() async throws {
        let (env, root) = try IT.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = SSHIdentity(privateKeyPath: IT.env["BEADS_IT_OTHER_KEY"]!)
        do {
            _ = try await GitClient(env: env).remoteDataRef(try RemoteURL.parse(IT.env["BEADS_IT_PRIVATE"]!), identity: other)
            Testing.Issue.record("expected access to be denied")
        } catch let error as RemoteError {
            print("other key -> \(error)")
            switch error {
            case .authenticationFailed, .repositoryNotFound, .keyNotLoaded: break
            default: Testing.Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test func repoWithoutBeadsData() async throws {
        let (env, root) = try IT.makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let sha = try await GitClient(env: env).remoteDataRef(try RemoteURL.parse("brendan-appstart/bead-me-up-scotty"),
                                                              identity: IT.identity)
        #expect(sha == nil)
    }
}
