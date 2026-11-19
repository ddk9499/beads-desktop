import Foundation

/// Board-level view of a bead. Large text fields live in `IssueDetail` and are loaded on demand.
public struct Issue: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let status: String
    public let priority: Int
    public let issueType: String
    public let assignee: String?
    public let owner: String?
    public let createdBy: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let closedAt: Date?
    public let pinned: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority, assignee, owner, pinned
        case issueType = "issue_type", createdBy = "created_by"
        case createdAt = "created_at", updatedAt = "updated_at", closedAt = "closed_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 2
        issueType = try c.decodeIfPresent(String.self, forKey: .issueType) ?? "task"
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee).nilIfEmpty
        owner = try c.decodeIfPresent(String.self, forKey: .owner).nilIfEmpty
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy).nilIfEmpty
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        pinned = (try c.decodeIfPresent(Int.self, forKey: .pinned) ?? 0) != 0
    }
}

public struct Dependency: Hashable, Codable, Sendable {
    /// The dependent issue (for `parent-child`: the child).
    public let issueID: String
    /// What it depends on (for `parent-child`: the parent; for `blocks`: the blocker).
    public let dependsOnID: String
    public let type: String

    enum CodingKeys: String, CodingKey {
        case issueID = "issue_id", dependsOnID = "depends_on_issue_id", type
    }

    public static let parentChild = "parent-child"
    public static let blocks = "blocks"
}

public struct Label: Hashable, Codable, Sendable {
    public let issueID: String
    public let label: String

    enum CodingKeys: String, CodingKey { case issueID = "issue_id", label }
}

public struct CustomStatus: Hashable, Codable, Sendable {
    public let name: String
    public let category: String?
}

public struct Comment: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let author: String?
    public let text: String
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey { case id, author, text, createdAt = "created_at" }
}

public struct IssueDetail: Hashable, Sendable {
    public let description: String
    public let design: String
    public let acceptanceCriteria: String
    public let notes: String
    public let comments: [Comment]
}

/// Everything the board needs, read from one snapshot.
public struct BeadsData: Sendable {
    public let commit: String
    public let schemaVersion: Int
    public let issues: [Issue]
    public let dependencies: [Dependency]
    public let labels: [Label]
    public let customStatuses: [CustomStatus]
    /// Which known beads tables exist (all verified to be base tables, not views).
    public let tables: Set<String>
    /// Rows that failed to decode and were skipped.
    public let skippedRows: Int

    public init(commit: String, schemaVersion: Int, issues: [Issue], dependencies: [Dependency], labels: [Label],
                customStatuses: [CustomStatus], tables: Set<String> = [], skippedRows: Int = 0) {
        self.commit = commit
        self.schemaVersion = schemaVersion
        self.issues = issues
        self.dependencies = dependencies
        self.labels = labels
        self.customStatuses = customStatuses
        self.tables = tables
        self.skippedRows = skippedRows
    }
}

extension Optional where Wrapped == String {
    var nilIfEmpty: String? { self.flatMap(\.nilIfEmpty) }
}
