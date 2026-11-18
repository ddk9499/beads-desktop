import BeadsKit
import SwiftUI

/// Kanban board: Backlog · Ready · In Progress · Blocked · Done (read-only).
struct BoardView: View {
    let board: BoardIndex
    /// Issues after filters/search; columns come from `board.columns`.
    let issues: [Issue]
    @Binding var selection: String?
    @AppStorage(SettingsKeys.doneWindowDays) private var doneWindowDays = 14
    @AppStorage(SettingsKeys.boardSort) private var sort: BoardSort = .priority

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(visibleColumns, id: \.column) { entry in
                    IssueColumn(title: entry.column.title, symbol: Style.columnSymbol(entry.column),
                                color: Style.columnColor(entry.column), issues: entry.issues,
                                board: board, selection: $selection) {
                        if entry.column == .done { doneWindowMenu }
                    } footer: {
                        if entry.hidden > 0 {
                            Button("\(entry.hidden) older — show all") { doneWindowDays = 0 }
                                .buttonStyle(.link).font(.caption).padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding(12)
        }
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(BoardSort.allCases) { Text($0.title).tag($0) }
                }
                .help("Card order within columns")
            }
        }
    }

    private var doneWindowMenu: some View {
        Menu {
            Picker("Closed within", selection: $doneWindowDays) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
                Text("All").tag(0)
            }
            .pickerStyle(.inline)
        } label: {
            Text(doneWindowDays == 0 ? "All" : "\(doneWindowDays)d").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show issues closed within…")
    }

    private struct Entry { let column: BoardColumn; let issues: [Issue]; let hidden: Int }

    private var visibleColumns: [Entry] {
        let byColumn = Dictionary(grouping: issues.filter { board.columns[$0.id] != nil }) { board.columns[$0.id]! }
        return BoardColumn.allCases.compactMap { column in
            var issues = byColumn[column] ?? []
            var hidden = 0
            if column == .done, doneWindowDays > 0 {
                let cutoff = Calendar.current.date(byAdding: .day, value: -doneWindowDays, to: .now) ?? .distantPast
                let recent = issues.filter { ($0.closedAt ?? $0.updatedAt ?? .distantPast) >= cutoff }
                hidden = issues.count - recent.count
                issues = recent
            }
            // Like Scotty: an empty Blocked column is hidden.
            if column == .blocked, issues.isEmpty { return nil }
            let sorted = column == .done
                ? issues.sorted { ($0.closedAt ?? $0.updatedAt ?? .distantPast) > ($1.closedAt ?? $1.updatedAt ?? .distantPast) }
                : sort.sorted(issues)
            return Entry(column: column, issues: sorted, hidden: hidden)
        }
    }
}

/// A titled column of cards, used by the Board and Focus views.
struct IssueColumn<Accessory: View, Footer: View>: View {
    let title: String
    let symbol: String
    let color: Color
    var hint: String?
    let issues: [Issue]
    let board: BoardIndex
    @Binding var selection: String?
    /// `false` when the column sits inside an outer scroll view (grouped Focus).
    var scrolls = true
    var width: CGFloat = 290
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if scrolls {
                ScrollView { cards }
            } else {
                cards
            }
        }
        .frame(width: width)
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    private var cards: some View {
        LazyVStack(spacing: 8) {
            ForEach(issues) { issue in
                CardView(issue: issue, board: board, isSelected: selection == issue.id)
                    .onTapGesture { selection = selection == issue.id ? nil : issue.id }
                    .id(issue.id)
            }
            if issues.isEmpty {
                Text("No issues").font(.caption).foregroundStyle(.tertiary).padding(.vertical, 16)
            }
            footer()
        }
        .padding(8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).font(.headline)
            Text("\(issues.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .help(hint ?? "")
    }
}

extension IssueColumn where Accessory == EmptyView, Footer == EmptyView {
    init(title: String, symbol: String, color: Color, hint: String? = nil, issues: [Issue], board: BoardIndex,
         selection: Binding<String?>, scrolls: Bool = true, width: CGFloat = 290) {
        self.init(title: title, symbol: symbol, color: color, hint: hint, issues: issues, board: board,
                  selection: selection, scrolls: scrolls, width: width, accessory: { EmptyView() }, footer: { EmptyView() })
    }
}

struct CardView: View {
    let issue: Issue
    let board: BoardIndex
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Style.typeSymbol(issue.issueType))
                    .foregroundStyle(.secondary).font(.caption)
                    .help(issue.issueType)
                Text(issue.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                OriginMark(name: issue.createdBy)
                PriorityBadge(priority: issue.priority)
            }
            Text(issue.title)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let parent = board.parent(of: issue.id) {
                Label(parent.title, systemImage: "square.stack.3d.up")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let progress = board.progress(of: issue.id) {
                ProgressView(value: Double(progress.closed), total: Double(progress.total)) {
                    Text("\(progress.closed)/\(progress.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            let blockers = board.blockers(of: issue)
            if !blockers.isEmpty, issue.status != "closed" {
                Label("Blocked by \(blockers.prefix(3).joined(separator: ", "))\(blockers.count > 3 ? "…" : "")",
                      systemImage: "exclamationmark.octagon")
                    .font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            let labels = board.labels[issue.id] ?? []
            if !labels.isEmpty || issue.assignee != nil {
                HStack(spacing: 4) {
                    ForEach(labels.prefix(3), id: \.self) { LabelChip(text: $0) }
                    if labels.count > 3 { Text("+\(labels.count - 3)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let assignee = issue.assignee {
                        Label(assignee, systemImage: "person").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(.rect)
        .opacity(issue.status == "closed" ? 0.75 : 1)
    }
}
