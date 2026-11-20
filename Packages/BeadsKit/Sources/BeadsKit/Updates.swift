import Foundation
import Security

// MARK: - Versions

/// Semantic version (`1.2.3`, `1.2.3-beta.1`) with SemVer 2.0 precedence; build metadata is ignored.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
            else { return nil }
            s = s[..<dash]
        }
        let core = s.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, let a = Int(core[0]), let b = Int(core[1]), let c = Int(core[2]), a >= 0, b >= 0, c >= 0
        else { return nil }
        (major, minor, patch, prerelease) = (a, b, c, pre)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        if (l.major, l.minor, l.patch) != (r.major, r.minor, r.patch) {
            return (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
        }
        // A pre-release is lower than the release; otherwise compare identifiers left to right.
        switch (l.prerelease.isEmpty, r.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(l.prerelease, r.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true   // numeric identifiers sort before alphanumeric ones
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return l.prerelease.count < r.prerelease.count
    }
}

// MARK: - GitHub releases

public struct ReleaseAsset: Hashable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int
}

public struct AvailableRelease: Hashable, Sendable {
    public let tag: String
    public let version: SemanticVersion
    public let title: String
    public let notes: String
    public let isPrerelease: Bool
    public let page: URL?
    public let installer: ReleaseAsset
    public let checksum: ReleaseAsset?
}

public enum UpdateError: Error, Sendable, CustomStringConvertible {
    case http(Int, String)
    case notAuthorized
    case noInstaller
    case checksumMismatch
    case badChecksumFile
    case invalidDiskImage(String)
    case appMismatch(String)
    case signatureInvalid(String)
    case notWritable(String)
    case tool(String)

    public var description: String {
        switch self {
        case let .http(code, message): "GitHub answered \(code): \(message)"
        case .notAuthorized:
            "GitHub didn't return the releases (private repository?). Add a token in Settings → Updates, or log in with `gh auth login`."
        case .noInstaller: "The release has no installer (.dmg)."
        case .checksumMismatch: "The downloaded installer doesn't match its published SHA-256. Nothing was installed."
        case .badChecksumFile: "The release's .sha256 file is malformed."
        case let .invalidDiskImage(d): "The installer couldn't be opened: \(d)"
        case let .appMismatch(d): "The installer contains a different app: \(d). Nothing was installed."
        case let .signatureInvalid(d): "The new app's signature isn't valid: \(d). Nothing was installed."
        case let .notWritable(path): "Can't replace the app at \(path) (no write access). Move it to /Applications or your user folder."
        case let .tool(d): d
        }
    }
}

/// Reads releases of one repository through the GitHub REST API.
public struct GitHubReleases: Sendable {
    public let repository: String
    public let token: String?
    let session: URLSession

    public init(repository: String, token: String?, session: URLSession = .shared) {
        self.repository = repository
        self.token = token
        self.session = session
    }

    public func request(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BeadsDesktop-Updater", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The newest release above `current` that has a DMG for `appName`, or nil when up to date.
    public func newestRelease(above current: SemanticVersion, appName: String, includePrereleases: Bool) async throws -> AvailableRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30") else { return nil }
        let (data, response) = try await session.data(for: request(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 401 { throw UpdateError.notAuthorized }
        guard status == 200 else { throw UpdateError.http(status, String(decoding: data.prefix(200), as: UTF8.self)) }
        return try Self.pick(from: data, above: current, appName: appName, includePrereleases: includePrereleases)
    }

    static func pick(from data: Data, above current: SemanticVersion, appName: String,
                     includePrereleases: Bool) throws -> AvailableRelease? {
        struct Release: Decodable {
            struct Asset: Decodable { let id: Int; let name: String; let size: Int }
            let tag_name: String
            let name: String?
            let body: String?
            let draft: Bool
            let prerelease: Bool
            let html_url: String?
            let assets: [Asset]
        }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        var best: AvailableRelease?
        for r in releases where !r.draft && (includePrereleases || !r.prerelease) {
            guard let version = SemanticVersion(r.tag_name), version > current,
                  includePrereleases || !version.isPrerelease else { continue }
            let dmgName = "\(appName)-\(version).dmg"
            guard let dmg = r.assets.first(where: { $0.name == dmgName }) else { continue }
            let sum = r.assets.first { $0.name == dmgName + ".sha256" }
            let candidate = AvailableRelease(
                tag: r.tag_name, version: version, title: r.name ?? r.tag_name, notes: r.body ?? "",
                isPrerelease: r.prerelease, page: r.html_url.flatMap(URL.init(string:)),
                installer: ReleaseAsset(id: dmg.id, name: dmg.name, size: dmg.size),
                checksum: sum.map { ReleaseAsset(id: $0.id, name: $0.name, size: $0.size) })
            if best.map({ candidate.version > $0.version }) ?? true { best = candidate }
        }
        return best
    }

    /// Asset download URL (the API redirects to storage; works for private repositories with a token).
    public func assetURL(_ asset: ReleaseAsset) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/assets/\(asset.id)")!
    }

    /// Small text asset (the .sha256 file).
    public func text(of asset: ReleaseAsset) async throws -> String {
        guard asset.size < 4096 else { throw UpdateError.badChecksumFile }
        let (data, response) = try await session.data(for: request(assetURL(asset), accept: "application/octet-stream"),
                                                      delegate: StripAuthOnRedirect())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status, asset.name) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// GitHub redirects asset downloads to a pre-signed storage URL that rejects an extra Authorization header,
/// and the token must never be sent to another host anyway.
final class StripAuthOnRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        if next.url?.host() != "api.github.com" { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        return next
    }
}

// MARK: - Download with progress

/// Downloads a release asset to a temporary file, reporting progress (0…1).
public final class AssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let lock = NSLock()

    public init(progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) {
        self.progress = progress
    }

    public func start(_ request: URLRequest) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                lock.withLock { self.session = session }
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            lock.withLock { session }?.invalidateAndCancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
        lock.withLock { session }?.finishTasksAndInvalidate()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if next.url?.host() != "api.github.com" { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return finish(.failure(UpdateError.http(status, "download failed"))) }
        // The temp file is deleted when this method returns: move it somewhere we own.
        let target = FileManager.default.temporaryDirectory.appending(path: "update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            finish(.success(target))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - Verify and install

public enum UpdateInstaller {
    /// Checks a downloaded DMG and copies the app out of it into a private staging folder.
    /// Requirements: SHA-256 matches (when published), same bundle id, valid signature, same Team ID as the
    /// running app (when it has one), and the expected version.
    public static func stage(dmg: URL, expectedSHA256: String?, appName: String, bundleID: String,
                             teamID: String?, version: SemanticVersion) async throws -> URL {
        if let expectedSHA256 {
            let actual = try await sha256(dmg)
            guard actual == expectedSHA256.lowercased() else { throw UpdateError.checksumMismatch }
        }

        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appending(path: "update-mount-\(UUID().uuidString.prefix(8))")
        let staging = fm.temporaryDirectory.appending(path: "update-stage-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let attach = try await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"),
            ["attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path, dmg.path],
            environment: env, timeout: 120)
        guard attach.status == 0 else {
            try? fm.removeItem(at: mount)
            try? fm.removeItem(at: staging)
            throw UpdateError.invalidDiskImage(attach.stderrString)
        }
        // Unmount before returning (success or not): the caller quits the app right after a successful stage.
        func detach() async {
            _ = try? await ProcessRunner.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", "-force", mount.path],
                                             environment: env, timeout: 60)
            try? FileManager.default.removeItem(at: mount)
        }

        do {
            let source = mount.appending(path: "\(appName).app")
            guard fm.fileExists(atPath: source.path) else { throw UpdateError.invalidDiskImage("\(appName).app not found in the image") }
            let staged = staging.appending(path: "\(appName).app")
            let copy = try await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"), [source.path, staged.path], environment: env, timeout: 300)
            guard copy.status == 0 else { throw UpdateError.tool("Copying the new app failed: \(copy.stderrString)") }
            await detach()
            try verify(app: staged, bundleID: bundleID, teamID: teamID, version: version)
            return staged
        } catch {
            await detach()
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Bundle id, version and code signature (Team ID must match when the running app has one).
    public static func verify(app: URL, bundleID: String, teamID: String?, version: SemanticVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.appMismatch("no Info.plist")
        }
        let foundID = info["CFBundleIdentifier"] as? String ?? "?"
        guard foundID == bundleID else { throw UpdateError.appMismatch("bundle id \(foundID)") }
        let foundVersion = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
        guard foundVersion == version else {
            throw UpdateError.appMismatch("version \(info["CFBundleShortVersionString"] as? String ?? "?"), expected \(version)")
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signatureInvalid("unreadable")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else { throw UpdateError.signatureInvalid("OSStatus \(status)") }
        if let teamID {
            guard teamIdentifier(of: code) == teamID else {
                throw UpdateError.signatureInvalid("signed by another team (\(teamIdentifier(of: code) ?? "none"))")
            }
        }
    }

    /// Team ID of the running app, nil when ad-hoc signed.
    public static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func sha256(_ file: URL) async throws -> String {
        let out = try await ProcessRunner.run(URL(filePath: "/usr/bin/shasum"), ["-a", "256", file.path],
                                              environment: ["PATH": "/usr/bin:/bin"], timeout: 120)
        guard out.status == 0, let hash = out.stdoutString.split(separator: " ").first else {
            throw UpdateError.tool("shasum failed")
        }
        return String(hash).lowercased()
    }

    /// Parses `<hex>  <file>` from a .sha256 asset.
    public static func parseChecksum(_ text: String) throws -> String {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first,
              first.count == 64, first.allSatisfy(\.isHexDigit) else { throw UpdateError.badChecksumFile }
        return first.lowercased()
    }

    /// Replaces the installed app with `staged` after this process exits, then relaunches it.
    /// A small shell script does the swap (keeping the old copy until the new one is in place).
    public static func scheduleReplace(installed: URL, with staged: URL, pid: Int32) throws {
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: installed.path) else {
            throw UpdateError.notWritable(installed.path)
        }
        let script = FileManager.default.temporaryDirectory.appending(path: "beads-update-\(UUID().uuidString.prefix(8)).sh")
        try Data(swapScript.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Paths go in as argv, never into the script text.
        process.arguments = [script.path, String(pid), staged.path, installed.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static let swapScript = """
    #!/bin/sh
    # BeadsDesktop updater: $1 = pid to wait for, $2 = staged new .app, $3 = installed .app
    pid="$1"; new="$2"; target="$3"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -gt 600 ] && exit 1
      sleep 0.1
    done
    tmp="${target%.app}.updating.app"
    old="${target%.app}.previous.app"
    rm -rf "$tmp" "$old"
    ditto "$new" "$tmp" || { rm -rf "$tmp"; open "$target"; exit 1; }
    if mv "$target" "$old"; then
      if mv "$tmp" "$target"; then rm -rf "$old"; else mv "$old" "$target"; rm -rf "$tmp"; fi
    else
      rm -rf "$tmp"
    fi
    rm -rf "$(dirname "$new")"
    open "$target"
    rm -f "$0"
    """
}

// MARK: - Token

/// Where the GitHub token for (private) release checks comes from: Keychain first, then the gh CLI.
public enum GitHubToken {
    static let service = "GitHub token for updates"

    public static func resolve(bundleID: String) async -> String? {
        if let stored = keychainToken(bundleID: bundleID) { return stored }
        return await ghToken()
    }

    public static func keychainToken(bundleID: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: bundleID, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Stores (or with nil/empty, removes) the token in the login keychain.
    public static func setKeychainToken(_ token: String?, bundleID: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: bundleID]
        SecItemDelete(base as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// `gh auth token` of the user's GitHub CLI, if installed and logged in.
    static func ghToken() async -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            let env = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": NSHomeDirectory()]
            guard let out = try? await ProcessRunner.run(URL(filePath: path), ["auth", "token", "--hostname", "github.com"],
                                                         environment: env, timeout: 15), out.status == 0 else { continue }
            let token = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return nil
    }
}
