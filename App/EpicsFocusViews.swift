import BeadsKit
import SwiftUI

/// Epics with progress (closed ÷ children); expand to see children.
struct EpicsView: View {
    let board: BoardIndex
    let issues: [Issue]
    @Binding var selection: String?
    @AppStorage("epicsHideClosed") private var hideClosed = true
    @State private var expanded: Set<String> = []

    var body: some View {
        let epics = board.epics(among: issues, hideClosed: hideClosed)
        let allEpics = board.epics(among: issues, hideClosed: false).count
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("\(epics.count)\(hideClosed && allEpics != epics.count ? " of \(allEpics)" : "") epics · progress = closed ÷ children")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                ForEach(epics) { epic in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Button {
                                if expanded.contains(epic.id) { expanded.remove(epic.id) } else { expanded.insert(epic.id) }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(expanded.contains(epic.id) ? 90 : 0))
                                    .frame(width: 16, height: 16)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .help(expanded.contains(epic.id) ? "Hide children" : "Show children")
                            EpicRow(epic: epic, board: board)
                                .contentShape(.rect)
                                .onTapGesture { toggleSelection(epic.id) }
                        }
                        .padding(10)
                        .background(rowBackground(epic.id), in: .rect(cornerRadius: 8))

                        if expanded.contains(epic.id) {
                            let children = board.sortedChildren(of: epic.id, hideClosed: hideClosed)
                            VStack(alignment: .leading, spacing: 2) {
                                if children.isEmpty {
                                    Text(hideClosed ? "No open children" : "No children")
                                        .font(.caption).foregroundStyle(.secondary).padding(6)
                                }
                                ForEach(children) { child in
                                    ChildRow(issue: child, board: board)
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(rowBackground(child.id), in: .rect(cornerRadius: 6))
                                        .contentShape(.rect)
                                        .onTapGesture { toggleSelection(child.id) }
                                }
                            }
                            .padding(.leading, 34).padding(.top, 4).padding(.bottom, 6)
                        }
                    }
                }
            }
            .padding(12)
        }
        .overlay {
            if epics.isEmpty { ContentUnavailableView("No epics", systemImage: "square.stack.3d.up") }
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $hideClosed) { Label("Hide closed", systemImage: "eye.slash") }
                    .help("Hide closed epics and closed children")
            }
        }
    }

    private func toggleSelection(_ id: String) { selection = selection == id ? nil : id }

    private func rowBackground(_ id: String) -> Color {
        selection == id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)
    }
}

private struct EpicRow: View {
    let epic: Issue
    let board: BoardIndex

    var body: some View {
        let progress = board.progress(of: epic.id)
        HStack(spacing: 10) {
            Image(systemName: epic.status == "closed" ? "checkmark.circle.fill" : "square.stack.3d.up")
                .foregroundStyle(epic.status == "closed" ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(epic.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    PriorityBadge(priority: epic.priority)
                    if let column = board.columns[epic.id] {
                        Text(column.title).font(.caption).foregroundStyle(Style.columnColor(column))
                    }
                }
                Text(epic.title).lineLimit(2).strikethrough(epic.status == "closed", color: .secondary)
            }
            Spacer()
            if let progress {
                let pct = Int((Double(progress.closed) / Double(progress.total) * 100).rounded())
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(progress.closed)/\(progress.total) · \(pct)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    ProgressView(value: Double(progress.closed), total: Double(progress.total))
                        .frame(width: 140).controlSize(.small)
                }
            } else {
                Text("no children").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ChildRow: View {
    let issue: Issue
    let board: BoardIndex

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: issue.status == "closed" ? "checkmark.circle.fill" : Style.typeSymbol(issue.issueType))
                .foregroundStyle(issue.status == "closed" ? Color.green : Color.secondary)
            Text(issue.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(issue.title).lineLimit(1).strikethrough(issue.status == "closed", color: .secondary)
            Spacer()
            if let assignee = issue.assignee { Text(assignee).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let column = board.columns[issue.id] {
                Image(systemName: Style.columnSymbol(column)).foregroundStyle(Style.columnColor(column)).help(column.title)
            }
            PriorityBadge(priority: issue.priority)
        }
    }
}

/// In flight · Blocked · Next up (+ recently finished), optionally per assignee.
struct FocusView: View {
    let board: BoardIndex
    let issues: [Issue]
    @Binding var selection: String?
    @AppStorage("focusGroupByAssignee") private var groupByAssignee = false
    @AppStorage("focusShowRecent") private var showRecent = false

    var body: some View {
        let model = FocusModel(board: board, issues: issues, groupByAssignee: groupByAssignee, showRecent: showRecent)
        Group {
            if groupByAssignee {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(group.id == IssueFilter.unassigned ? "No assignee" : group.id, systemImage: "person")
                                    .font(.headline)
                                columns(group, scrolls: false)
                            }
                            .padding(12)
                            Divider()
                        }
                    }
                }
            } else if let group = model.groups.first {
                ScrollView(.horizontal) { columns(group, scrolls: true).padding(12) }
            }
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $groupByAssignee) { Label("Group by assignee", systemImage: "person.2") }
                    .help("Group by assignee")
            }
            ToolbarItem {
                Toggle(isOn: $showRecent) { Label("Recently finished", systemImage: "checkmark.circle") }
                    .help("Show the last \(FocusModel.recentLimit) closed issues")
            }
        }
    }

    private func columns(_ group: FocusModel.Group, scrolls: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IssueColumn(title: "In flight", symbol: Style.columnSymbol(.inProgress), color: Style.columnColor(.inProgress),
                        hint: "in progress or hooked", issues: group.inFlight, board: board, selection: $selection, scrolls: scrolls)
            IssueColumn(title: "Blocked", symbol: Style.columnSymbol(.blocked), color: Style.columnColor(.blocked),
                        hint: "waiting on a dependency or marked blocked", issues: group.blocked, board: board,
                        selection: $selection, scrolls: scrolls)
            IssueColumn(title: "Next up", symbol: "arrow.right.circle", color: .blue,
                        hint: "ready · P0/P1", issues: group.nextUp, board: board, selection: $selection, scrolls: scrolls)
            if showRecent {
                IssueColumn(title: "Recently finished", symbol: Style.columnSymbol(.done), color: Style.columnColor(.done),
                            hint: "last \(FocusModel.recentLimit) closed", issues: group.recent, board: board,
                            selection: $selection, scrolls: scrolls)
            }
        }
    }
}

// MARK: - Filters UI

/// Toolbar menu with all facets; checkmarks show active values.
struct FilterMenu: View {
    @Binding var filter: IssueFilter
    let board: BoardIndex

    var body: some View {
        Menu {
            facet("Status", board.statusOptions, \.statuses) { $0 }
            facet("Type", board.typeOptions, \.types) { $0 }
            facet("Priority", [0, 1, 2, 3, 4], \.priorities) { "P\($0)" }
            facet("Origin", [Origin.human, .agent], \.origins) { $0 == .human ? "👤 Human" : "🤖 Agent" }
            facet("Assignee", board.assigneeOptions, \.assignees) { $0.isEmpty ? "Unassigned" : $0 }
            if !board.labelOptions.isEmpty {
                facet("Label", board.labelOptions, \.labels) { $0 }
            }
            Divider()
            Toggle("Show archived", isOn: $filter.showArchived)
            Button("Clear filters") {
                let search = filter.search
                filter = IssueFilter()
                filter.search = search
            }
            .disabled(filter.activeCount == 0 && !filter.showArchived)
        } label: {
            Label(filter.activeCount == 0 ? "Filter" : "Filter (\(filter.activeCount))",
                  systemImage: filter.activeCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter issues")
    }

    private func facet<T: Hashable>(_ title: String, _ options: [T], _ key: WritableKeyPath<IssueFilter, Set<T>>,
                                    name: @escaping (T) -> String) -> some View {
        let selected = filter[keyPath: key]
        return Menu(selected.isEmpty ? title : "\(title) (\(selected.count))") {
            ForEach(options, id: \.self) { option in
                Toggle(name(option), isOn: Binding(
                    get: { filter[keyPath: key].contains(option) },
                    set: { on in
                        if on { filter[keyPath: key].insert(option) } else { filter[keyPath: key].remove(option) }
                    }))
            }
        }
    }
}

/// Removable chips for active facets, shown under the toolbar.
struct ActiveFiltersBar: View {
    @Binding var filter: IssueFilter
    let shown: Int
    let total: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("\(shown) of \(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                chips(\.statuses) { "status: \($0)" }
                chips(\.types) { "type: \($0)" }
                chips(\.priorities) { "P\($0)" }
                chips(\.origins) { $0 == .human ? "👤 human" : "🤖 agent" }
                chips(\.assignees) { $0.isEmpty ? "unassigned" : "@\($0)" }
                chips(\.labels) { "#\($0)" }
                if filter.showArchived { chip("archived shown") { filter.showArchived = false } }
                Button("Clear") {
                    let search = filter.search
                    filter = IssueFilter()
                    filter.search = search
                }
                .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func chips<T: Hashable & Comparable>(_ key: WritableKeyPath<IssueFilter, Set<T>>, name: @escaping (T) -> String) -> some View {
        ForEach(filter[keyPath: key].sorted(), id: \.self) { value in
            chip(name(value)) { filter[keyPath: key].remove(value) }
        }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.caption2)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
