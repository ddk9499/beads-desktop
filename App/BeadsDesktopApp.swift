import BeadsKit
import SwiftUI

@main
struct BeadsDesktopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if DEBUG
                    DebugSnapshot.scheduleIfRequested()
                    #endif
                    await model.start()
                }
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh All") { Task { await model.syncAll() } }
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

    var body: some View {
        Form {
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
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
