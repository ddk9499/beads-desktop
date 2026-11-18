import AppKit
import BeadsKit
import SwiftUI

/// Inspector for one bead: fields, hierarchy, dependencies (clickable), long text, comments.
struct IssueDetailView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    let issue: Issue
    let board: BoardIndex
    @Binding var selection: String?

    @State private var detail: IssueDetail?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                fields
                hierarchy
                dependencies
                texts
                comments
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Reload when the issue or the snapshot changes (a sync may have updated it).
        .task(id: "\(issue.id)@\(board.data.commit)") { await load() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Style.typeSymbol(issue.issueType)).foregroundStyle(.secondary)
                Text(issue.id).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issue.id, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy ID")
                Spacer()
                PriorityBadge(priority: issue.priority)
                Button { selection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close details (Esc)")
            }
            Text(issue.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            if let column = board.columns[issue.id] {
                Label(column.title, systemImage: Style.columnSymbol(column))
                    .font(.caption).foregroundStyle(Style.columnColor(column))
            }
        }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Status", issue.status)
            row("Type", issue.issueType)
            if let assignee = issue.assignee { row("Assignee", assignee) }
            if let owner = issue.owner { row("Owner", owner) }
            GridRow {
                Text("Created by").foregroundStyle(.secondary)
                HStack(spacing: 4) { OriginMark(name: issue.createdBy); Text(issue.createdBy ?? "unknown") }
            }
            if let d = issue.createdAt { row("Created", d.relative, help: d.formatted()) }
            if let d = issue.updatedAt { row("Updated", d.relative, help: d.formatted()) }
            if let d = issue.closedAt { row("Closed", d.relative, help: d.formatted()) }
            let labels = board.labels[issue.id] ?? []
            if !labels.isEmpty {
                GridRow {
                    Text("Labels").foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) { ForEach(labels, id: \.self) { LabelChip(text: $0) } }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var hierarchy: some View {
        if let parent = board.parent(of: issue.id) {
            section("Epic") { IssueLink(issue: parent, selection: $selection) }
        }
        let children = board.children(of: issue.id)
        if !children.isEmpty, let progress = board.progress(of: issue.id) {
            section("Children · \(progress.closed)/\(progress.total) closed") {
                ProgressView(value: Double(progress.closed), total: Double(progress.total)).controlSize(.small)
                ForEach(BoardSort.priority.sorted(children)) { IssueLink(issue: $0, selection: $selection) }
            }
        }
    }

    @ViewBuilder private var dependencies: some View {
        let blockers = board.blockers(of: issue)
        if !blockers.isEmpty {
            section("Blocked by") {
                ForEach(blockers, id: \.self) { id in
                    if let target = board.issuesByID[id] {
                        IssueLink(issue: target, selection: $selection)
                    } else {
                        Text(id).font(.callout.monospaced()).foregroundStyle(.secondary).help("Not in this repository")
                    }
                }
            }
        }
        let blocking = board.blocking(issue.id).filter { $0.status != "closed" }
        if !blocking.isEmpty {
            section("Blocks") { ForEach(blocking) { IssueLink(issue: $0, selection: $selection) } }
        }
        let links = board.otherLinks(of: issue.id)
        if !links.isEmpty {
            section("Related") {
                ForEach(links, id: \.issue.id) { link in
                    HStack(spacing: 6) {
                        Text(link.type).font(.caption).foregroundStyle(.secondary).frame(minWidth: 90, alignment: .leading)
                        IssueLink(issue: link.issue, selection: $selection)
                    }
                }
            }
        }
    }

    @ViewBuilder private var texts: some View {
        if let detail {
            textSection("Description", detail.description)
            textSection("Design", detail.design)
            textSection("Acceptance criteria", detail.acceptanceCriteria)
            textSection("Notes", detail.notes)
        } else if let loadError {
            Label(loadError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var comments: some View {
        if let detail, !detail.comments.isEmpty {
            section("Comments · \(detail.comments.count)") {
                ForEach(detail.comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            OriginMark(name: comment.author)
                            Text(comment.author ?? "unknown").font(.caption.weight(.semibold))
                            if let d = comment.createdAt {
                                Text(d.relative).font(.caption).foregroundStyle(.secondary).help(d.formatted())
                            }
                        }
                        MarkdownText(source: comment.text).font(.callout)
                    }
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: Helpers

    private func row(_ title: String, _ value: String, help: String? = nil) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).help(help ?? "")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    @ViewBuilder private func textSection(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            section(title) { MarkdownText(source: text).font(.callout) }
        }
    }

    private func load() async {
        loadError = nil
        do {
            detail = try await model.detail(issue.id, project: projectID)
        } catch {
            detail = nil
            loadError = "Couldn't load details: \(error)"
        }
    }
}

/// A clickable reference to another bead in the same project.
struct IssueLink: View {
    let issue: Issue
    @Binding var selection: String?

    var body: some View {
        Button { selection = issue.id } label: {
            HStack(spacing: 6) {
                Image(systemName: issue.status == "closed" ? "checkmark.circle.fill" : Style.typeSymbol(issue.issueType))
                    .foregroundStyle(issue.status == "closed" ? Color.green : Color.secondary)
                Text(issue.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(issue.title).lineLimit(1).strikethrough(issue.status == "closed", color: .secondary)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .help(issue.title)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}
