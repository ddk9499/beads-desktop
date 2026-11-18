import BeadsKit
import SwiftUI
import UserNotifications

/// Owns the model and starts it at launch, independent of windows: refresh and notifications keep running
/// when the window is closed or when macOS restores the app without one.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before launch finishes to receive the click that launched the app.
        Notifier.shared.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
        Task { await model.start() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.appDidBecomeActive() }
        }
    }
}

@main
struct BeadsDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh All") { Task { await delegate.model.syncAll() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("selectedProject") private var selectionRaw: String?
    @State private var showingAdd = false

    private var selection: Binding<UUID?> {
        Binding(get: { selectionRaw.flatMap(UUID.init(uuidString:)) }, set: { selectionRaw = $0?.uuidString })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("Projects") {
                    ForEach(model.projects) { project in
                        ProjectRow(project: project, state: model.state(of: project.id)).tag(project.id)
                            .contextMenu {
                                Button("Refresh") { Task { await model.sync(project.id) } }
                                if let url = project.remote.webURL {
                                    Link("Open on \(project.remote.host)", destination: url)
                                }
                                Divider()
                                Button("Remove", role: .destructive) { model.removeProject(project.id) }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .toolbar {
                Button { showingAdd = true } label: { Label("Add Project", systemImage: "plus") }
                    .help("Add a repository")
            }
            .safeAreaInset(edge: .bottom) {
                if let setupError = model.setupError {
                    Text(setupError).font(.caption2).foregroundStyle(.red).lineLimit(4)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .overlay {
                if model.projects.isEmpty, model.setupError == nil {
                    Button("Add a repository…") { showingAdd = true }.buttonStyle(.link)
                }
            }
        } detail: {
            if let id = selection.wrappedValue, model.project(id) != nil {
                ProjectView(projectID: id).id(id)
            } else {
                ContentUnavailableView("No project selected", systemImage: "square.stack.3d.up",
                                       description: Text("Add a GitHub repository that has beads data."))
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddProjectSheet { selection.wrappedValue = $0 }
        }
        .onChange(of: model.focusRequest) {
            // Notification click: switch to its project; ProjectView then opens the issue.
            if let request = model.focusRequest, model.project(request.project) != nil {
                selection.wrappedValue = request.project
            }
        }
        #if DEBUG
        // Debug-only: `-debugSelectProject owner/repo` selects a project at launch (for screenshots/UI checks).
        .onChange(of: model.projects.count, initial: true) {
            if let name = UserDefaults.standard.string(forKey: "debugSelectProject"),
               let project = model.projects.first(where: { $0.remote.description == name }) {
                selection.wrappedValue = project.id
            }
        }
        #endif
    }
}

struct ProjectRow: View {
    let project: Project
    let state: AppModel.ProjectState

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if state.isSyncing {
                ProgressView().controlSize(.small)
            } else if state.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(state.error ?? "")
            }
        }
    }

    private var subtitle: String {
        guard let board = state.board else { return state.isSyncing ? "Syncing…" : (state.error != nil ? "Sync failed" : "Not synced") }
        let inProgress = board.columns.values.filter { $0 == .inProgress }.count
        let ready = board.columns.values.filter { $0 == .ready }.count
        return "\(inProgress) in progress · \(ready) ready"
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKeys.humanNames) private var humanNames = ""
    @AppStorage(SettingsKeys.pollSeconds) private var pollSeconds = 30.0
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                Picker("Check for changes", selection: $pollSeconds) {
                    Text("Every 15 seconds").tag(15.0)
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 5 minutes").tag(300.0)
                    Text("Only manually (⌘R)").tag(0.0)
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("Each check is one lightweight `git ls-remote` per project; data is downloaded only when it changed. Projects that fail are retried less often (up to every 10 minutes).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(IssueChange.Kind.allCases, id: \.self) { kind in
                    NotificationToggle(kind: kind)
                }
                NotificationPermissionRow(status: $notificationStatus)
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Shown when a background refresh finds changes. While the app is in front, changed cards are highlighted instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Human names", text: $humanNames, prompt: Text("doston, Doston Kamalov"), axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Attribution")
            } footer: {
                Text("beads doesn't record whether a human or an agent created a bead. Names listed here (comma-separated, as they appear in created_by / comment author) are shown as 👤; everyone else as 🤖.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .task { notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }
}

private struct NotificationToggle: View {
    let kind: IssueChange.Kind
    @AppStorage private var isOn: Bool

    init(kind: IssueChange.Kind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: NotificationPrefs.defaults[kind] ?? false, NotificationPrefs.key(kind))
    }

    var body: some View { Toggle(NotificationPrefs.label(kind), isOn: $isOn) }
}

/// Shows whether macOS allows notifications and offers the right next step.
private struct NotificationPermissionRow: View {
    @Binding var status: UNAuthorizationStatus

    var body: some View {
        switch status {
        case .authorized, .provisional:
            Label("macOS allows notifications from this app", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            HStack {
                Label("Not allowed yet", systemImage: "bell.badge")
                Spacer()
                Button("Allow Notifications…") {
                    Task {
                        await Notifier.shared.requestAuthorization()
                        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS has notifications turned off for this app", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Text("macOS won't ask again once denied. Turn them on in System Settings → Notifications. If the app isn't listed there, the build isn't signed with a stable identity (see README → Signing).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                if let error = Notifier.shared.authorizationError {
                    Text(error).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}
