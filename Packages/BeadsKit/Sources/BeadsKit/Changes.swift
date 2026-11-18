import Foundation

/// What happened to one bead between two snapshots.
public struct IssueChange: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case created
        case closed
        case reopened
        /// Was blocked, now is not (and still open).
        case unblocked
        case becameBlocked
        /// Moved between board columns for another reason (e.g. picked up: Ready → In Progress).
        case moved
        case reassigned
    }

    public let kind: Kind
    public let issue: Issue
    public let from: BoardColumn?
    public let to: BoardColumn?
    public let previousAssignee: String?

    public var id: String { "\(kind.rawValue):\(issue.id)" }
}

public enum ChangeDetector {
    /// Compares two snapshots of the same project. Order: most interesting first.
    public static func changes(from old: BoardIndex, to new: BoardIndex) -> [IssueChange] {
        var result: [IssueChange] = []
        for issue in new.data.issues {
            let toColumn = new.columns[issue.id]
            guard let before = old.issuesByID[issue.id] else {
                result.append(IssueChange(kind: .created, issue: issue, from: nil, to: toColumn, previousAssignee: nil))
                continue
            }
            let fromColumn = old.columns[issue.id]
            let wasClosed = before.status == "closed", isClosed = issue.status == "closed"
            let kind: IssueChange.Kind?
            if !wasClosed && isClosed {
                kind = .closed
            } else if wasClosed && !isClosed {
                kind = .reopened
            } else if fromColumn == .blocked && toColumn != .blocked && !isClosed {
                kind = .unblocked
            } else if fromColumn != .blocked && toColumn == .blocked {
                kind = .becameBlocked
            } else if fromColumn != toColumn {
                kind = .moved
            } else {
                kind = nil
            }
            if let kind {
                result.append(IssueChange(kind: kind, issue: issue, from: fromColumn, to: toColumn, previousAssignee: nil))
            }
            if (before.assignee ?? "") != (issue.assignee ?? "") {
                result.append(IssueChange(kind: .reassigned, issue: issue, from: fromColumn, to: toColumn,
                                          previousAssignee: before.assignee))
            }
        }
        let rank: [IssueChange.Kind: Int] = [.closed: 0, .unblocked: 1, .created: 2, .becameBlocked: 3,
                                             .reopened: 4, .moved: 5, .reassigned: 6]
        return result.sorted { (rank[$0.kind]!, $0.issue.id) < (rank[$1.kind]!, $1.issue.id) }
    }
}

extension IssueChange {
    /// Short human-readable line, e.g. "Closed · bd-12 Fix login".
    public var summary: String {
        let what: String = switch kind {
        case .created: "New"
        case .closed: "Closed"
        case .reopened: "Reopened"
        case .unblocked: "Unblocked"
        case .becameBlocked: "Blocked"
        case .moved: "\(from?.title ?? "—") → \(to?.title ?? "—")"
        case .reassigned: "Assigned to \(issue.assignee ?? "nobody")"
        }
        return "\(what) · \(issue.id) \(issue.title)"
    }
}
