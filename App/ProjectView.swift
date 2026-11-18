import BeadsKit
import SwiftUI

enum ProjectMode: String, CaseIterable, Identifiable {
    case board, list, epics, focus, graph
    var id: String { rawValue }
    var title: String {
        switch self {
        case .board: "Board"
        case .list: "List"
        case .epics: "Epics"
        case .focus: "Focus"
        case .graph: "Graph"
        }
    }
    var symbol: String {
        switch self {
        case .board: "rectangle.split.3x1"
        case .list: "list.bullet"
        case .epics: "square.stack.3d.up"
        case .focus: "scope"
        case .graph: "point.3.connected.trianglepath.dotted"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(Self.allCases.firstIndex(of: self)! + 1)")) }
}

/// Detail column for a selected project: Board / List / Epics / Focus + filters + inspector.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var selection: String?
    @State private var filter = IssueFilter()
    @State private var graphAnchor: GraphAnchor?
    @SceneStorage("projectMode") private var mode: ProjectMode = .board
    @AppStorage(SettingsKeys.humanNames) private var humanNames = ""

    var body: some View {
        let state = model.state(of: projectID)
        Group {
            if let board = state.board {
                let issues = board.filtered(filter, humans: SettingsKeys.parse(humanNames))
                withDetail(board, issues)
                    .navigationSubtitle(subtitle(board, state))
                    .searchable(text: $filter.search, placement: .toolbar, prompt: "ID, title, assignee, label")
                    .toolbar {
                        ToolbarItem { FilterMenu(filter: $filter, board: board) }
                    }
            } else if let error = state.error {
                ContentUnavailableView {
                    Label("Sync failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await model.sync(projectID) } }
                }
            } else {
                ProgressView("Fetching beads data…")
            }
        }
        .navigationTitle(model.project(projectID)?.displayName ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(ProjectMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .background {
                    // ⌘1…⌘4 switch views.
                    ForEach(ProjectMode.allCases) { m in
                        Button(m.title) { mode = m }.keyboardShortcut(m.shortcut, modifiers: .command).hidden()
                    }
                }
            }
            ToolbarItem {
                Button { Task { await model.sync(projectID) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(state.isSyncing)
                .help("Fetch the latest beads data (⌘R)")
            }
            if selection != nil {
                ToolbarItem {
                    // Esc closes the details from anywhere in the window (onKeyPress needs focus, this doesn't).
                    Button { selection = nil } label: { Label("Close Details", systemImage: "sidebar.trailing") }
                        .keyboardShortcut(.cancelAction)
                        .help("Close details (Esc)")
                }
            }
        }
        .environment(\.recentChanges, model.recentChanges[projectID] ?? [:])
        .onChange(of: projectID) { selection = nil }
        .onChange(of: model.focusRequest, initial: true) {
            // A notification click for this project: open the issue.
            guard let request = model.focusRequest, request.project == projectID else { return }
            if let issue = request.issue { selection = issue }
            model.focusRequest = nil
        }
        #if DEBUG
        // Debug-only: `-debugSelectIssue <id>` opens an issue in the inspector at launch.
        .onChange(of: state.board?.data.commit, initial: true) {
            let defaults = UserDefaults.standard
            if selection == nil, let id = defaults.string(forKey: "debugSelectIssue") { selection = id }
            if let raw = defaults.string(forKey: "debugMode"), let m = ProjectMode(rawValue: raw) { mode = m }
            if filter.search.isEmpty, let q = defaults.string(forKey: "debugSearch") { filter.search = q }
            for p in (defaults.string(forKey: "debugPriorities") ?? "").split(separator: ",").compactMap({ Int($0) }) {
                filter.priorities.insert(p)
            }
        }
        #endif
    }

    /// Banners stacked above the view. (A safeAreaInset would slide under horizontal scroll views.)
    private func content(_ board: BoardIndex, _ issues: [Issue]) -> some View {
        VStack(spacing: 0) {
            if let error = model.state(of: projectID).error { ErrorBanner(message: error) }
            if filter.activeCount > 0 || filter.showArchived {
                ActiveFiltersBar(filter: $filter, shown: issues.count, total: board.data.issues.count)
                Divider()
            }
            modeView(board, issues).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func modeView(_ board: BoardIndex, _ issues: [Issue]) -> some View {
        switch mode {
        case .board: BoardView(board: board, issues: issues, selection: $selection)
        case .list: IssueListView(board: board, issues: issues, selection: $selection)
        case .epics: EpicsView(board: board, issues: issues, selection: $selection)
        case .focus: FocusView(board: board, issues: issues, selection: $selection)
        case .graph: GraphModeView(board: board, issues: issues, selection: $selection, anchor: $graphAnchor)
        }
    }

    @ViewBuilder private func withDetail(_ board: BoardIndex, _ issues: [Issue]) -> some View {
        #if DEBUG
        // Debug-only: `-debugPlainDetail YES` shows the detail as a plain column (window snapshots can't
        // render the Liquid Glass inspector).
        if UserDefaults.standard.bool(forKey: "debugPlainDetail") {
            HStack(spacing: 0) {
                content(board, issues)
                if let id = selection, let issue = board.issuesByID[id] {
                    Divider()
                    IssueDetailView(projectID: projectID, issue: issue, board: board, selection: $selection,
                                    showInGraph: { id in graphAnchor = board.issuesByID[id]?.issueType == "epic" ? .epic(id) : .issue(id); mode = .graph })
                        .frame(width: 420)
                }
            }
        } else {
            inspectorLayout(board, issues)
        }
        #else
        inspectorLayout(board, issues)
        #endif
    }

    private func inspectorLayout(_ board: BoardIndex, _ issues: [Issue]) -> some View {
        content(board, issues)
            .inspector(isPresented: inspectorShown(board)) {
                if let id = selection, let issue = board.issuesByID[id] {
                    IssueDetailView(projectID: projectID, issue: issue, board: board, selection: $selection,
                                    showInGraph: { id in graphAnchor = board.issuesByID[id]?.issueType == "epic" ? .epic(id) : .issue(id); mode = .graph })
                        .inspectorColumnWidth(min: 320, ideal: 400, max: 640)
                }
            }
    }

    private func inspectorShown(_ board: BoardIndex) -> Binding<Bool> {
        Binding(get: { selection.map { board.issuesByID[$0] != nil } ?? false },
                set: { if !$0 { selection = nil } })
    }

    private func subtitle(_ board: BoardIndex, _ state: AppModel.ProjectState) -> String {
        var parts = ["\(board.data.issues.count) issues"]
        switch BeadsReader.support(for: board.data.schemaVersion) {
        case .supported: break
        case let .newerThanTested(v): parts.append("schema \(v) is newer than tested")
        case let .olderThanTested(v): parts.append("schema \(v) is older than tested")
        }
        if state.isSyncing { parts.append("syncing…") }
        else if let at = model.project(projectID)?.lastSyncAt { parts.append("synced \(at.relative)") }
        return parts.joined(separator: " · ")
    }
}

struct ErrorBanner: View {
    let message: String
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Refresh failed — showing the last fetched data. \(expanded ? message : "")")
                .font(.caption).textSelection(.enabled)
                .lineLimit(expanded ? nil : 1)
            Spacer()
            Button(expanded ? "Less" : "Details") { expanded.toggle() }.buttonStyle(.link).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }
}

/// Flat table of all issues (the M1 view), grouped by board column order.
struct IssueListView: View {
    let board: BoardIndex
    let issues: [Issue]
    @Binding var selection: String?
    @State private var showClosed = false
    @State private var sortOrder = [KeyPathComparator(\Issue.priority)]

    var body: some View {
        let rows = issues
            .filter { showClosed || $0.status != "closed" }
            .sorted(using: sortOrder)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("ID", value: \.id) { Text($0.id).font(.callout.monospaced()) }.width(min: 80, ideal: 110)
            TableColumn("P", value: \.priority) { PriorityBadge(priority: $0.priority) }.width(36)
            TableColumn("Type", value: \.issueType) { issue in
                Label(issue.issueType, systemImage: Style.typeSymbol(issue.issueType))
            }.width(min: 60, ideal: 90)
            TableColumn("Column") { issue in
                if let c = board.columns[issue.id] {
                    Label(c.title, systemImage: Style.columnSymbol(c)).foregroundStyle(Style.columnColor(c))
                } else {
                    Text(issue.status).foregroundStyle(.secondary)
                }
            }.width(min: 90, ideal: 110)
            TableColumn("Title", value: \.title)
            TableColumn("Assignee") { Text($0.assignee ?? "") }.width(min: 80, ideal: 140)
            TableColumn("Updated") { Text($0.updatedAt?.relative ?? "") }.width(min: 80, ideal: 110)
        }
        .toolbar {
            ToolbarItem { Toggle("Show closed", isOn: $showClosed) }
        }
    }
}
