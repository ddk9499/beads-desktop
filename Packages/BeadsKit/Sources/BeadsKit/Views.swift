import Foundation

/// Facet filters + free-text search, with Scotty's semantics (`lib/filters.ts`):
/// OR within a facet, AND across facets; search matches id, title, assignee and labels.
public struct IssueFilter: Equatable, Sendable {
    /// Facet value for issues without an assignee.
    public static let unassigned = ""
    /// `archived` is treated as state (hidden by default), not as a label facet.
    public static let archivedLabel = "archived"

    public var statuses: Set<String> = []
    public var types: Set<String> = []
    public var priorities: Set<Int> = []
    public var origins: Set<Origin> = []
    public var assignees: Set<String> = []
    public var labels: Set<String> = []
    public var search = ""
    public var showArchived = false

    public init() {}

    /// Number of active facet selections (search excluded).
    public var activeCount: Int {
        statuses.count + types.count + priorities.count + origins.count + assignees.count + labels.count
    }

    public var isEmpty: Bool { activeCount == 0 && search.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(_ issue: Issue, labels issueLabels: [String], humans: Set<String>) -> Bool {
        if !showArchived, issueLabels.contains(Self.archivedLabel) { return false }
        if !statuses.isEmpty, !statuses.contains(issue.status) { return false }
        if !types.isEmpty, !types.contains(issue.issueType) { return false }
        if !priorities.isEmpty, !priorities.contains(issue.priority) { return false }
        if !origins.isEmpty, !origins.contains(Origin.of(issue.createdBy, humans: humans)) { return false }
        if !assignees.isEmpty, !assignees.contains(Self.assigneeKey(issue)) { return false }
        if !labels.isEmpty, !issueLabels.contains(where: labels.contains) { return false }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let hit = issue.id.lowercased().contains(query)
                || issue.title.lowercased().contains(query)
                || (issue.assignee ?? "").lowercased().contains(query)
                || issueLabels.contains { $0.lowercased().contains(query) }
            if !hit { return false }
        }
        return true
    }

    public static func assigneeKey(_ issue: Issue) -> String {
        issue.assignee?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? unassigned
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension BoardIndex {
    public func filtered(_ filter: IssueFilter, humans: Set<String>) -> [Issue] {
        data.issues.filter { filter.matches($0, labels: labels[$0.id] ?? [], humans: humans) }
    }

}

// MARK: - Focus

/// "What's happening now" view, as in Scotty's Focus: In flight · Blocked · Next up (+ recently finished).
public struct FocusModel: Sendable {
    public static let recentLimit = 7

    public struct Group: Identifiable, Sendable {
        /// Assignee key (`IssueFilter.unassigned` for none), or "*" when ungrouped.
        public let id: String
        public let inFlight: [Issue]
        public let blocked: [Issue]
        public let nextUp: [Issue]
        public let recent: [Issue]

        public var isActive: Bool { !inFlight.isEmpty || !blocked.isEmpty }
        public var isEmpty: Bool { inFlight.isEmpty && blocked.isEmpty && nextUp.isEmpty && recent.isEmpty }
    }

    public let groups: [Group]

    public init(board: BoardIndex, issues: [Issue], groupByAssignee: Bool, showRecent: Bool) {
        let inFlight = issues.filter { $0.status == "in_progress" || $0.status == "hooked" }
        let blocked = issues.filter { $0.status != "closed" && $0.status != "deferred" && board.isBlocked($0) }
        let nextUp = issues.filter { $0.status == "open" && $0.priority <= 1 && !board.isBlocked($0) }
        let recent = showRecent
            ? issues.filter { $0.status == "closed" }
                .sorted { ($0.closedAt ?? $0.updatedAt ?? .distantPast) > ($1.closedAt ?? $1.updatedAt ?? .distantPast) }
            : []

        func build(_ id: String, _ keep: (Issue) -> Bool) -> Group {
            Group(id: id,
                  inFlight: BoardSort.priority.sorted(inFlight.filter(keep)),
                  blocked: BoardSort.priority.sorted(blocked.filter(keep)),
                  nextUp: BoardSort.priority.sorted(nextUp.filter(keep)),
                  recent: Array(recent.filter(keep).prefix(Self.recentLimit)))
        }

        guard groupByAssignee else {
            groups = [build("*") { _ in true }]
            return
        }
        let keys = Set((inFlight + blocked + nextUp + recent).map(IssueFilter.assigneeKey))
        groups = keys.map { key in build(key) { IssueFilter.assigneeKey($0) == key } }
            .filter { !$0.isEmpty }
            // Active people first, then by name; "No assignee" sorts last among equals.
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                if (a.id == IssueFilter.unassigned) != (b.id == IssueFilter.unassigned) { return b.id == IssueFilter.unassigned }
                return a.id.localizedStandardCompare(b.id) == .orderedAscending
            }
    }
}

// MARK: - Epics

extension BoardIndex {
    /// Epics in Scotty's order: open before closed, then priority, then id.
    public func epics(among issues: [Issue], hideClosed: Bool) -> [Issue] {
        issues
            .filter { $0.issueType == "epic" && !(hideClosed && $0.status == "closed") }
            .sorted { a, b in
                let ac = a.status == "closed", bc = b.status == "closed"
                if ac != bc { return !ac }
                if a.priority != b.priority { return a.priority < b.priority }
                return a.id < b.id
            }
    }

    /// Children for the epics list: open before closed, then priority/id.
    public func sortedChildren(of id: String, hideClosed: Bool) -> [Issue] {
        children(of: id)
            .filter { !(hideClosed && $0.status == "closed") }
            .sorted { a, b in
                let ac = a.status == "closed", bc = b.status == "closed"
                if ac != bc { return !ac }
                if a.priority != b.priority { return a.priority < b.priority }
                return a.id < b.id
            }
    }
}
