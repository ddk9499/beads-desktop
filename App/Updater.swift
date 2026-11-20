import AppKit
import BeadsKit
import Observation
import SwiftUI

/// Checks GitHub Releases for a newer version, downloads and verifies it, swaps the app and relaunches.
@MainActor @Observable
final class UpdateController {
    static let shared = UpdateController()

    /// Repository whose releases carry `BeadsDesktop-<version>.dmg` (see scripts/release.sh).
    static let repository = "ddk9499/beads-desktop"
    static let appName = "BeadsDesktop"
    /// The installable (release) app; the Debug app has its own bundle id and never installs updates.
    static let releaseBundleID = "uz.dkamaloff.beads"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableRelease)
        case downloading(AvailableRelease, received: Int64, total: Int64)
        case installing(AvailableRelease)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?

    static var currentVersion: SemanticVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
    }

    static var canInstall: Bool { Bundle.main.bundleIdentifier == releaseBundleID }

    /// Test hook: `open --env BEADS_UPDATE_TEST_AUTOINSTALL=1 <app>` installs a found update without the click
    /// and logs each phase to stderr (used to test the whole flow end to end).
    static let testAutoInstall = ProcessInfo.processInfo.environment["BEADS_UPDATE_TEST_AUTOINSTALL"] == "1"

    private func log(_ message: String) {
        if Self.testAutoInstall { FileHandle.standardError.write(Data("[updater] \(message)\n".utf8)) }
    }

    static var automaticChecks: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.autoUpdateCheck) as? Bool ?? true
    }

    // MARK: Checking

    /// At launch: quiet check (only a found update is shown). Release app only.
    func checkAtLaunch() {
        guard Self.canInstall, Self.automaticChecks else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(userInitiated: false)
        }
    }

    /// From the menu / Settings: always shows the result.
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        if case .downloading = phase { return showWindow() }
        if case .installing = phase { return showWindow() }
        guard let current = Self.currentVersion else { return }
        phase = .checking
        if userInitiated { showWindow() }
        do {
            let token = await GitHubToken.resolve(bundleID: Self.releaseBundleID)
            let releases = GitHubReleases(repository: Self.repository, token: token)
            let includePre = UserDefaults.standard.bool(forKey: SettingsKeys.includePrereleases)
            let found = try await releases.newestRelease(above: current, appName: Self.appName, includePrereleases: includePre)
            log("current \(current), found \(found?.version.description ?? "nothing newer"), token: \(token == nil ? "no" : "yes")")
            if let found, userInitiated || UserDefaults.standard.string(forKey: SettingsKeys.skippedVersion) != found.version.description {
                phase = .available(found)
                showWindow()
                if Self.testAutoInstall { install(found) }
            } else {
                phase = .upToDate
                if !userInitiated { phase = .idle }
            }
        } catch {
            log("check failed: \(error)")
            phase = .failed("\(error)")
            if !userInitiated { phase = .idle } // quiet at launch; the user can check again from the menu
        }
    }

    // MARK: Install

    func skip(_ release: AvailableRelease) {
        UserDefaults.standard.set(release.version.description, forKey: SettingsKeys.skippedVersion)
        closeWindow()
    }

    func install(_ release: AvailableRelease) {
        guard Self.canInstall else {
            phase = .failed("Updates are installed only by the release app (\(Self.releaseBundleID)). This is \(Bundle.main.bundleIdentifier ?? "?").")
            return
        }
        task = Task { await download(release) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        closeWindow()
    }

    private func download(_ release: AvailableRelease) async {
        phase = .downloading(release, received: 0, total: Int64(release.installer.size))
        do {
            let token = await GitHubToken.resolve(bundleID: Self.releaseBundleID)
            let releases = GitHubReleases(repository: Self.repository, token: token)
            var expected: String?
            if let checksum = release.checksum {
                expected = try UpdateInstaller.parseChecksum(try await releases.text(of: checksum))
            }

            var request = releases.request(releases.assetURL(release.installer), accept: "application/octet-stream")
            request.timeoutInterval = 120
            let downloader = AssetDownload { received, total in
                Task { @MainActor in
                    guard case .downloading = UpdateController.shared.phase else { return }
                    UpdateController.shared.phase = .downloading(release, received: received,
                                                                 total: total > 0 ? total : Int64(release.installer.size))
                }
            }
            log("downloading \(release.installer.name), sha256 published: \(expected != nil)")
            let dmg = try await downloader.start(request)
            log("downloaded \((try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? 0) bytes")
            try Task.checkCancellation()

            phase = .installing(release)
            let staged: URL
            do {
                staged = try await UpdateInstaller.stage(
                    dmg: dmg, expectedSHA256: expected, appName: Self.appName, bundleID: Self.releaseBundleID,
                    teamID: UpdateInstaller.currentTeamID(), version: release.version)
                try? FileManager.default.removeItem(at: dmg)
            } catch {
                try? FileManager.default.removeItem(at: dmg)
                throw error
            }
            log("verified and staged at \(staged.path); replacing \(Bundle.main.bundleURL.path) and relaunching")
            try UpdateInstaller.scheduleReplace(installed: Bundle.main.bundleURL, with: staged,
                                                pid: ProcessInfo.processInfo.processIdentifier)
            NSApp.terminate(nil)
        } catch is CancellationError {
            phase = .idle
        } catch {
            log("install failed: \(error)")
            phase = .failed("\(error)")
        }
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: UpdateView().environment(self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Software Update"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 360))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func closeWindow() {
        window?.close()
    }
}

private struct UpdateView: View {
    @Environment(UpdateController.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            content
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    private var current: String { UpdateController.currentVersion?.description ?? "?" }

    private var headline: String {
        switch updater.phase {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "BeadsDesktop is up to date"
        case let .available(r): "BeadsDesktop \(r.version) is available"
        case let .downloading(r, _, _): "Downloading BeadsDesktop \(r.version)…"
        case let .installing(r): "Installing BeadsDesktop \(r.version)…"
        case .failed: "Update failed"
        }
    }

    private var subtitle: String {
        switch updater.phase {
        case let .available(r): "You have \(current).\(r.isPrerelease ? " This is a pre-release." : "")"
        case .installing: "Verifying the download. The app will restart."
        default: "Current version: \(current)"
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case let .available(r):
            ScrollView {
                MarkdownText(source: r.notes.isEmpty ? "No release notes." : r.notes).font(.callout)
                    .padding(10)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            if !UpdateController.canInstall {
                Label("This debug build can't install updates; use the release app.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case let .downloading(_, received, total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(Int(Double(received) / Double(max(total, 1)) * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .installing:
            ProgressView().progressViewStyle(.linear)
        case .upToDate:
            EmptyView()
        case let .failed(message):
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch updater.phase {
            case let .available(r):
                Button("Skip This Version") { updater.skip(r) }
                if let page = r.page { Link("Release Page", destination: page) }
                Spacer()
                Button("Later") { updater.closeWindow() }.keyboardShortcut(.cancelAction)
                Button("Install & Relaunch") { updater.install(r) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!UpdateController.canInstall)
            case .downloading:
                Spacer()
                Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction)
            case .installing:
                Spacer()
            default:
                Spacer()
                Button("Check Again") { updater.checkNow() }
                Button("OK") { updater.closeWindow() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Settings → Updates.
struct UpdateSettingsSection: View {
    @AppStorage(SettingsKeys.autoUpdateCheck) private var autoCheck = true
    @AppStorage(SettingsKeys.includePrereleases) private var includePrereleases = false
    @State private var token = ""
    @State private var hasStoredToken = GitHubToken.keychainToken(bundleID: UpdateController.releaseBundleID) != nil

    var body: some View {
        Section {
            Toggle("Check for updates at launch", isOn: $autoCheck)
            Toggle("Include pre-releases", isOn: $includePrereleases)
            HStack {
                SecureField(hasStoredToken ? "Token saved in Keychain" : "GitHub token (optional)", text: $token)
                Button(hasStoredToken && token.isEmpty ? "Remove" : "Save") {
                    GitHubToken.setKeychainToken(token.isEmpty ? nil : token, bundleID: UpdateController.releaseBundleID)
                    hasStoredToken = !token.isEmpty
                    token = ""
                }
                .disabled(token.isEmpty && !hasStoredToken)
            }
            Button("Check Now") { UpdateController.shared.checkNow() }
        } header: {
            Text("Updates")
        } footer: {
            Text("Releases come from github.com/\(UpdateController.repository). For a private repository a token with read access is needed: the one saved here (Keychain), otherwise `gh auth token` is used. Downloads are verified (SHA-256, bundle id, signature and Team ID) before the app is replaced.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
