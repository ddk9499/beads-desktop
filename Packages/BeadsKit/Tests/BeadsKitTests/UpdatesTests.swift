import Foundation
import Testing
@testable import BeadsKit

@Suite struct SemanticVersionTests {
    @Test(arguments: [("v0.1.0", "0.1.0"), ("1.2.3", "1.2.3"), ("v1.2.3-beta.1", "1.2.3-beta.1"), ("1.0.0+build.5", "1.0.0")])
    func parses(_ raw: String, _ expected: String) {
        #expect(SemanticVersion(raw)?.description == expected)
    }

    @Test(arguments: ["", "1.2", "1.2.3.4", "a.b.c", "1.2.3-", "1.2.3-be ta", "-1.0.0", "1.2.3-a..b"])
    func rejects(_ raw: String) {
        #expect(SemanticVersion(raw) == nil)
    }

    /// SemVer 2.0 §11 example ordering.
    @Test func precedence() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0", "10.0.0"]
            .map { SemanticVersion($0)! }
        for (a, b) in zip(ordered, ordered.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
        #expect(SemanticVersion("v0.1.0") == SemanticVersion("0.1.0"))
    }
}

@Suite struct ReleasePickTests {
    static let json = """
    [
      {"tag_name":"v0.3.0","name":"Draft","draft":true,"prerelease":false,"assets":[{"id":9,"name":"BeadsDesktop-0.3.0.dmg","size":1}]},
      {"tag_name":"v0.2.1-beta.1","name":"Beta","draft":false,"prerelease":true,"body":"b","assets":[{"id":7,"name":"BeadsDesktop-0.2.1-beta.1.dmg","size":1}]},
      {"tag_name":"v0.2.0","name":"BeadsDesktop 0.2.0","draft":false,"prerelease":false,"body":"notes","html_url":"https://github.com/o/r/releases/tag/v0.2.0",
       "assets":[{"id":5,"name":"BeadsDesktop-0.2.0.dmg","size":100},{"id":6,"name":"BeadsDesktop-0.2.0.dmg.sha256","size":90}]},
      {"tag_name":"v0.1.5","name":"no dmg","draft":false,"prerelease":false,"assets":[]},
      {"tag_name":"not-a-version","draft":false,"prerelease":false,"assets":[]},
      {"tag_name":"v0.1.0","draft":false,"prerelease":false,"assets":[{"id":1,"name":"BeadsDesktop-0.1.0.dmg","size":1}]}
    ]
    """

    @Test func picksNewestStableWithInstaller() throws {
        let r = try #require(try GitHubReleases.pick(from: Data(Self.json.utf8), above: SemanticVersion("0.1.0")!,
                                                     appName: "BeadsDesktop", includePrereleases: false))
        #expect(r.version.description == "0.2.0")
        #expect(r.installer.id == 5)
        #expect(r.checksum?.id == 6)
        #expect(r.notes == "notes")
    }

    @Test func prereleasesOnlyWhenAsked() throws {
        let r = try GitHubReleases.pick(from: Data(Self.json.utf8), above: SemanticVersion("0.1.0")!,
                                        appName: "BeadsDesktop", includePrereleases: true)
        #expect(r?.version.description == "0.2.1-beta.1")
    }

    @Test func upToDate() throws {
        #expect(try GitHubReleases.pick(from: Data(Self.json.utf8), above: SemanticVersion("0.2.0")!,
                                        appName: "BeadsDesktop", includePrereleases: false) == nil)
    }

    @Test func checksumParsing() throws {
        let hex = String(repeating: "ab", count: 32)
        #expect(try UpdateInstaller.parseChecksum("\(hex)  BeadsDesktop-0.1.0.dmg\n") == hex)
        #expect(throws: UpdateError.self) { try UpdateInstaller.parseChecksum("nope") }
    }
}

/// The installer must refuse anything that isn't the same, intact, correctly versioned app.
@Suite(.serialized) struct UpdateVerifyTests {
    /// A minimal ad-hoc signed app bundle.
    static func makeApp(bundleID: String = "uz.example.app", version: String = "1.2.3") throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "bk-verify-\(UUID().uuidString.prefix(8))")
        let app = root.appending(path: "Test.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appending(path: "Contents/MacOS/Test").path)
        try Data("hello".utf8).write(to: app.appending(path: "Contents/Resources/data.txt"))
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        _ = try Offline.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return (app, root)
    }

    @Test func acceptsMatchingApp() throws {
        let (app, root) = try Self.makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        try UpdateInstaller.verify(app: app, bundleID: "uz.example.app", teamID: nil, version: SemanticVersion("1.2.3")!)
    }

    @Test func rejectsOtherBundleIDAndVersion() throws {
        let (app, root) = try Self.makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.verify(app: app, bundleID: "uz.dkamaloff.beads", teamID: nil, version: SemanticVersion("1.2.3")!)
        }
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.verify(app: app, bundleID: "uz.example.app", teamID: nil, version: SemanticVersion("1.2.4")!)
        }
    }

    @Test func rejectsWrongTeam() throws {
        let (app, root) = try Self.makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        // Ad-hoc signed app has no Team ID; a running app with a team must not accept it.
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.verify(app: app, bundleID: "uz.example.app", teamID: "ABCDE12345", version: SemanticVersion("1.2.3")!)
        }
    }

    @Test func rejectsTamperedApp() throws {
        let (app, root) = try Self.makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("evil".utf8).write(to: app.appending(path: "Contents/Resources/data.txt"))
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.verify(app: app, bundleID: "uz.example.app", teamID: nil, version: SemanticVersion("1.2.3")!)
        }
    }
}
