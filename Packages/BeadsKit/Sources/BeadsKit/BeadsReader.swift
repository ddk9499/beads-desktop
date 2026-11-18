import Foundation

/// Reads beads tables from a materialized snapshot. Talks SQL to beads' schema directly, so the
/// schema version is checked and reported (beads has had 64 migrations so far).
public struct BeadsReader: Sendable {
    /// Schema versions this reader was written and tested against.
    public static let testedSchemaVersions = 60...66

    public enum SchemaSupport: Sendable, Equatable {
        case supported
        /// Newer than tested: reading continues best-effort, the UI should show a notice.
        case newerThanTested(Int)
        case olderThanTested(Int)
    }

    let dolt: DoltClient

    public init(dolt: DoltClient) { self.dolt = dolt }

    public static func support(for version: Int) -> SchemaSupport {
        if testedSchemaVersions.contains(version) { return .supported }
        return version > testedSchemaVersions.upperBound ? .newerThanTested(version) : .olderThanTested(version)
    }

    /// Board columns we want from `issues`, if the snapshot's schema has them.
    static let issueColumns = ["id", "title", "status", "priority", "issue_type", "assignee", "owner", "created_by",
                               "created_at", "updated_at", "closed_at", "pinned"]

    public func read(snapshot: URL, commit: String) async throws -> BeadsData {
        // Pass 1: discover the schema. Columns come and go between beads versions
        // (e.g. schema 66 dropped issues.deleted_at), so the main query is built from what exists.
        let probe = try await dolt.query([
            "SELECT COALESCE(MAX(version), 0) AS v FROM schema_migrations",
            "SELECT LOWER(column_name) AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'issues'",
            "SELECT LOWER(table_name) AS c FROM information_schema.tables WHERE table_schema = DATABASE()",
        ], in: snapshot)
        let decoder = Self.decoder()
        struct Version: Decodable { let v: Int }
        struct Name: Decodable { let c: String }
        struct IDRow: Decodable { let id: String }

        let version = try decoder.decode([Version].self, from: probe[0]).first?.v ?? 0
        let columns = Set(try decoder.decode([Name].self, from: probe[1]).map(\.c))
        let tables = Set(try decoder.decode([Name].self, from: probe[2]).map(\.c))
        guard columns.contains("id"), tables.contains("issues") else {
            throw DoltError.malformedOutput("snapshot has no beads issues table")
        }

        // Pass 2: the data.
        let select = Self.issueColumns.filter(columns.contains).joined(separator: ", ")
        var filters = ["1 = 1"]
        if columns.contains("deleted_at") { filters.append("deleted_at IS NULL") }
        if columns.contains("ephemeral") { filters.append("COALESCE(ephemeral, 0) = 0") }
        if columns.contains("is_template") { filters.append("COALESCE(is_template, 0) = 0") }

        let empty = "SELECT 1 AS skip FROM dual WHERE 1 = 0"
        let results = try await dolt.query([
            "SELECT \(select) FROM issues WHERE \(filters.joined(separator: " AND "))",
            tables.contains("dependencies") ? """
                SELECT issue_id, depends_on_issue_id, type FROM dependencies
                WHERE depends_on_issue_id IS NOT NULL AND depends_on_issue_id <> ''
                """ : empty,
            tables.contains("labels") ? "SELECT issue_id, label FROM labels" : empty,
            tables.contains("custom_statuses") ? "SELECT name, category FROM custom_statuses" : empty,
            tables.contains("ready_issues") ? "SELECT id FROM ready_issues" : empty,
            tables.contains("blocked_issues") ? "SELECT id FROM blocked_issues" : empty,
        ], in: snapshot)

        let issues = try decoder.decode([Issue].self, from: results[0])
        let issueIDs = Set(issues.map(\.id))
        return BeadsData(
            commit: commit,
            schemaVersion: version,
            issues: issues,
            dependencies: try Self.decodeIfRows([Dependency].self, results[1], decoder),
            labels: try Self.decodeIfRows([Label].self, results[2], decoder),
            customStatuses: try Self.decodeIfRows([CustomStatus].self, results[3], decoder),
            readyIDs: Set(try Self.decodeIfRows([IDRow].self, results[4], decoder).map(\.id)).intersection(issueIDs),
            blockedIDs: Set(try Self.decodeIfRows([IDRow].self, results[5], decoder).map(\.id)).intersection(issueIDs)
        )
    }

    private static func decodeIfRows<T: Decodable & RangeReplaceableCollection>(_ type: T.Type, _ data: Data,
                                                                                  _ decoder: JSONDecoder) throws -> T {
        data == Data("[]".utf8) ? T() : try decoder.decode(T.self, from: data)
    }

    public func detail(issueID: String, snapshot: URL) async throws -> IssueDetail {
        // ids come from the data itself; still never splice anything but a validated literal into SQL.
        guard Self.isSafeIssueID(issueID) else { throw DoltError.queryFailed("invalid issue id") }
        let literal = "'\(issueID)'"
        let results = try await dolt.query([
            "SELECT description, design, acceptance_criteria, notes FROM issues WHERE id = \(literal)",
            "SELECT id, author, text, created_at FROM comments WHERE issue_id = \(literal) ORDER BY created_at, id",
        ], in: snapshot)
        struct Texts: Decodable {
            let description: String?
            let design: String?
            let acceptance_criteria: String?
            let notes: String?
        }
        let decoder = Self.decoder()
        let texts = try decoder.decode([Texts].self, from: results[0]).first
        return IssueDetail(
            description: texts?.description ?? "",
            design: texts?.design ?? "",
            acceptanceCriteria: texts?.acceptance_criteria ?? "",
            notes: texts?.notes ?? "",
            comments: try decoder.decode([Comment].self, from: results[1])
        )
    }

    static func isSafeIssueID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// dolt prints DATETIME as `yyyy-MM-dd HH:mm:ss[.ffffff]`; beads stores UTC.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(raw)"))
        }
        return decoder
    }

    static func parseDate(_ raw: String) -> Date? {
        let main = raw.split(separator: ".").first.map(String.init) ?? raw
        let parts = main.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" || $0 == "T" }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(identifier: "UTC")
        (comps.year, comps.month, comps.day, comps.hour, comps.minute, comps.second) =
            (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
        return comps.date
    }
}
