import BeadsKit
import SwiftUI

/// Kanban board: Backlog · Ready · In Progress · Blocked · Done (read-only).
struct BoardView: View {
    let board: BoardIndex
    @Binding var selection: String?
    @AppStorage(SettingsKeys.doneWindowDays) private var doneWindowDays = 14
    @AppStorage(SettingsKeys.boardSort) private var sort: BoardSort = .priority

    var body: some View {
        let columns = visibleColumns
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns, id: \.column) { entry in
                    ColumnView(column: entry.column, issues: entry.issues, hiddenCount: entry.hidden,
                               board: board, selection: $selection, doneWindowDays: $doneWindowDays)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.automatic)
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(BoardSort.allCases) { Text($0.title).tag($0) }
                }
                .help("Card order within columns")
            }
        }
    }

    private struct Entry { let column: BoardColumn; let issues: [Issue]; let hidden: Int }

    private var visibleColumns: [Entry] {
        BoardColumn.allCases.compactMap { column in
            var issues = board.issues(in: column)
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

private struct ColumnView: View {
    let column: BoardColumn
    let issues: [Issue]
    let hiddenCount: Int
    let board: BoardIndex
    @Binding var selection: String?
    @Binding var doneWindowDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(issues) { issue in
                        CardView(issue: issue, board: board, isSelected: selection == issue.id)
                            .onTapGesture { selection = selection == issue.id ? nil : issue.id }
                            .id(issue.id)
                    }
                    if issues.isEmpty {
                        Text("No issues").font(.caption).foregroundStyle(.tertiary).padding(.top, 24)
                    }
                    if hiddenCount > 0 {
                        Button("\(hiddenCount) older — show all") { doneWindowDays = 0 }
                            .buttonStyle(.link).font(.caption).padding(.vertical, 6)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: Style.columnSymbol(column)).foregroundStyle(Style.columnColor(column))
            Text(column.title).font(.headline)
            Text("\(issues.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if column == .done {
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
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
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
