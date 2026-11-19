import Foundation

/// Board columns, matching Scotty (`lib/board-columns.ts`) so both tools agree on where a bead sits.
public enum BoardColumn: String, CaseIterable, Identifiable, Sendable {
    case backlog, ready, inProgress, blocked, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .backlog: "Backlog"
        case .ready: "Ready"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }
}

/// Precomputed lookups over one `BeadsData` snapshot (built once per sync, O(n) total).
public struct BoardIndex: Sendable {
    /// Dependency types that hold a bead back (beads' BLOCKING_DEP_TYPES).
    public static let blockingTypes: Set<String> = ["blocks", "parent-child", "conditional-blocks", "waits-for"]

    public let data: BeadsData
    public let issuesByID: [String: Issue]
    /// Outgoing edges: what this issue depends on.
    public let dependencies: [String: [Dependency]]
    /// Incoming edges: who depends on this issue.
    public let dependents: [String: [Dependency]]
    public let labels: [String: [String]]
    public let customCategories: [String: String]
    public let columns: [String: BoardColumn]
    /// Filter facet options, computed once from ALL issues (so picking one value doesn't hide the others).
    public let statusOptions: [String]
    public let typeOptions: [String]
    public let labelOptions: [String]
    /// Sorted assignees, with `IssueFilter.unassigned` first when some issue has none.
    public let assigneeOptions: [String]

    public init(_ data: BeadsData) {
        self.data = data
        issuesByID = Dictionary(data.issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        dependencies = Dictionary(grouping: data.dependencies, by: \.issueID)
        dependents = Dictionary(grouping: data.dependencies, by: \.dependsOnID)
        labels = Dictionary(grouping: data.labels, by: \.issueID).mapValues { $0.map(\.label).sorted() }
        customCategories = Dictionary(data.customStatuses.compactMap { s in s.category.map { (s.name, $0.lowercased()) } },
                                      uniquingKeysWith: { a, _ in a })

        var columns: [String: BoardColumn] = [:]
        let partial = BoardIndex.Partial(issuesByID: issuesByID, dependencies: dependencies)
        for issue in data.issues {
            if let column = BoardIndex.column(for: issue, blocked: partial.isBlocked(issue), customCategories: customCategories) {
                columns[issue.id] = column
            }
        }
        self.columns = columns

        statusOptions = Set(data.issues.map(\.status)).sorted()
        typeOptions = Set(data.issues.map(\.issueType)).sorted()
        labelOptions = Set(data.labels.map(\.label)).subtracting([IssueFilter.archivedLabel]).sorted()
        let keys = Set(data.issues.map(IssueFilter.assigneeKey))
        let named = keys.subtracting([IssueFilter.unassigned]).sorted()
        assigneeOptions = keys.contains(IssueFilter.unassigned) ? [IssueFilter.unassigned] + named : named
    }

    // MARK: - Queries

    public func issues(in column: BoardColumn) -> [Issue] {
        data.issues.filter { columns[$0.id] == column }
    }

    /// Unresolved blockers worth naming on a card. `parent-child` is excluded: it points at the bead's own epic.
    public func blockers(of issue: Issue) -> [String] {
        Partial(issuesByID: issuesByID, dependencies: dependencies).blockers(of: issue)
    }

    public func isBlocked(_ issue: Issue) -> Bool {
        Partial(issuesByID: issuesByID, dependencies: dependencies).isBlocked(issue)
    }

    /// The epic this issue belongs to (`parent-child` edge from child to parent).
    public func parent(of id: String) -> Issue? {
        dependencies[id]?.first { $0.type == Dependency.parentChild }.flatMap { issuesByID[$0.dependsOnID] }
    }

    public func children(of id: String) -> [Issue] {
        (dependents[id] ?? []).filter { $0.type == Dependency.parentChild }.compactMap { issuesByID[$0.issueID] }
    }

    /// Closed / total children, `nil` when the issue has no children.
    public func progress(of id: String) -> (closed: Int, total: Int)? {
        let kids = children(of: id)
        guard !kids.isEmpty else { return nil }
        return (kids.filter { $0.status == "closed" }.count, kids.count)
    }

    /// Issues that this one blocks (incoming non-hierarchy blocking edges).
    public func blocking(_ id: String) -> [Issue] {
        (dependents[id] ?? [])
            .filter { $0.type != Dependency.parentChild && Self.blockingTypes.contains($0.type) }
            .compactMap { issuesByID[$0.issueID] }
    }

    /// Non-blocking links in both directions (`related`, `discovered-from`, …), with their type.
    public func otherLinks(of id: String) -> [(type: String, issue: Issue)] {
        let out = (dependencies[id] ?? []).filter { !Self.blockingTypes.contains($0.type) }
            .compactMap { d in issuesByID[d.dependsOnID].map { (d.type, $0) } }
        let incoming = (dependents[id] ?? []).filter { !Self.blockingTypes.contains($0.type) }
            .compactMap { d in issuesByID[d.issueID].map { ("\(d.type) (from)", $0) } }
        return out + incoming
    }

    // MARK: - Column rules

    static func column(for issue: Issue, blocked: Bool, customCategories: [String: String]) -> BoardColumn? {
        switch issue.status {
        case "deferred": return .backlog
        case "closed": return .done
        case "in_progress", "hooked": return .inProgress
        case "blocked": return .blocked
        case "open": return blocked ? .blocked : .ready
        default:
            // Custom statuses: beads categories (bd statuses) decide.
            switch customCategories[issue.status] {
            case "active": return blocked ? .blocked : .ready
            case "wip": return .inProgress
            case "done": return .done
            case "frozen": return .backlog
            default: return nil
            }
        }
    }

    /// The bits of the index needed to compute blocked-ness, usable during init.
    struct Partial {
        let issuesByID: [String: Issue]
        let dependencies: [String: [Dependency]]

        func blockers(of issue: Issue) -> [String] {
            (dependencies[issue.id] ?? [])
                .filter { $0.type != Dependency.parentChild && BoardIndex.blockingTypes.contains($0.type) }
                // A missing target (other rig, external) counts as open, like Scotty.
                .filter { (issuesByID[$0.dependsOnID]?.status ?? "open") != "closed" }
                .map(\.dependsOnID)
        }

        func isBlocked(_ issue: Issue) -> Bool {
            if issue.status == "blocked" { return true }
            guard issue.status != "closed", issue.status != "deferred" else { return false }
            return !blockers(of: issue).isEmpty
        }
    }
}

public enum BoardSort: String, CaseIterable, Identifiable, Sendable {
    case priority, updated
    public var id: String { rawValue }
    public var title: String { self == .priority ? "Priority" : "Recently updated" }

    public func sorted(_ issues: [Issue]) -> [Issue] {
        issues.sorted { a, b in
            let ua = a.updatedAt ?? a.createdAt ?? .distantPast
            let ub = b.updatedAt ?? b.createdAt ?? .distantPast
            switch self {
            case .priority:
                if a.priority != b.priority { return a.priority < b.priority }
                if ua != ub { return ua > ub }
            case .updated:
                if ua != ub { return ua > ub }
                if a.priority != b.priority { return a.priority < b.priority }
            }
            return a.id < b.id
        }
    }
}

/// Who created a bead. beads has no human/agent flag; anyone on the user's allowlist is a human (Scotty's rule).
public enum Origin: Sendable, Comparable {
    case human, agent

    public static func of(_ name: String?, humans: Set<String>) -> Origin {
        guard let name, humans.contains(name) else { return .agent }
        return .human
    }
}
