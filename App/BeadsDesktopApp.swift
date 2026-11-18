import BeadsKit
import SwiftUI

@main
struct BeadsDesktopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh All") {
                    Task { for p in model.projects { await model.sync(p.id) } }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.projects) { project in
                    ProjectRow(project: project, state: model.state(of: project.id)).tag(project.id)
                        .contextMenu {
                            Button("Refresh") { Task { await model.sync(project.id) } }
                            Button("Remove", role: .destructive) { model.removeProject(project.id) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button { showingAdd = true } label: { Label("Add Project", systemImage: "plus") }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.setupError ?? model.toolStatus)
                    .font(.caption2).foregroundStyle(model.setupError == nil ? Color.secondary : Color.red)
                    .lineLimit(3).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let id = selection, model.projects.contains(where: { $0.id == id }) {
                ProjectView(projectID: id)
            } else {
                ContentUnavailableView("No project selected", systemImage: "square.stack.3d.up",
                                       description: Text("Add a GitHub repository that has beads data."))
            }
        }
        .sheet(isPresented: $showingAdd) { AddProjectSheet { selection = $0 } }
    }
}

struct ProjectRow: View {
    let project: Project
    let state: AppModel.ProjectState

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(project.displayName)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if case .syncing = state { ProgressView().controlSize(.small) }
            if case .failed = state { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }

    private var subtitle: String {
        switch state {
        case .idle: "Not synced"
        case .syncing: "Syncing…"
        case let .loaded(data, _): "\(data.issues.count) issues · \(data.readyIDs.count) ready"
        case .failed: "Sync failed"
        }
    }
}
