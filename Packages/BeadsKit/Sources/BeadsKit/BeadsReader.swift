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

    /// beads tables this reader touches. The database comes from the remote and is untrusted: any of these
    /// that is a VIEW (arbitrary SQL that dolt would execute on SELECT) makes the snapshot unreadable.
    static let knownTables: Set<String> = ["issues", "dependencies", "labels", "custom_statuses", "comments", "schema_migrations"]

    public enum ReadError: Error, Sendable, Equatable, CustomStringConvertible {
        case noIssuesTable
        case viewsInPlaceOfTables([String])

        public var description: String {
            switch self {
            case .noIssuesTable: "This snapshot has no beads `issues` table."
            case let .viewsInPlaceOfTables(names):
                "Refusing to read: beads tables are replaced by SQL views (\(names.joined(separator: ", "))). "
                    + "Views would run code from the repository."
            }
        }
    }

    public func read(snapshot: URL, commit: String) async throws -> BeadsData {
        // Pass 1: discover the schema (only information_schema, which can't be redefined by the database).
        // Columns come and go between beads versions (e.g. schema 66 dropped issues.deleted_at).
        let probe = try await dolt.query([
            "SELECT LOWER(table_name) AS c, table_type AS t FROM information_schema.tables WHERE table_schema = DATABASE()",
            "SELECT LOWER(column_name) AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'issues'",
        ], in: snapshot)
        let decoder = Self.decoder()
        struct TableRow: Decodable { let c: String; let t: String }
        struct Name: Decodable { let c: String }
        struct Version: Decodable { let v: Int }

        let tableRows = try decoder.decode([TableRow].self, from: probe[0])
        let views = tableRows.filter { Self.knownTables.contains($0.c) && $0.t.uppercased() != "BASE TABLE" }.map(\.c)
        guard views.isEmpty else { throw ReadError.viewsInPlaceOfTables(views.sorted()) }
        let tables = Set(tableRows.map(\.c)).intersection(Self.knownTables)
        let columns = Set(try decoder.decode([Name].self, from: probe[1]).map(\.c))
        guard tables.contains("issues"), columns.contains("id") else { throw ReadError.noIssuesTable }

        // Pass 2: the data, from base tables only.
        let select = Self.issueColumns.filter(columns.contains).joined(separator: ", ")
        var filters = ["1 = 1"]
        if columns.contains("deleted_at") { filters.append("deleted_at IS NULL") }
        if columns.contains("ephemeral") { filters.append("COALESCE(ephemeral, 0) = 0") }
        if columns.contains("is_template") { filters.append("COALESCE(is_template, 0) = 0") }

        let empty = "SELECT 1 AS skip FROM dual WHERE 1 = 0"
        let results = try await dolt.query([
            tables.contains("schema_migrations") ? "SELECT COALESCE(MAX(version), 0) AS v FROM schema_migrations" : empty,
            "SELECT \(select) FROM issues WHERE \(filters.joined(separator: " AND "))",
            tables.contains("dependencies") ? """
                SELECT issue_id, depends_on_issue_id, type FROM dependencies
                WHERE depends_on_issue_id IS NOT NULL AND depends_on_issue_id <> ''
                """ : empty,
            tables.contains("labels") ? "SELECT issue_id, label FROM labels" : empty,
            tables.contains("custom_statuses") ? "SELECT name, category FROM custom_statuses" : empty,
        ], in: snapshot)

        // Lossy: one malformed row must not take down the whole board.
        let issues = try Self.lossy(Issue.self, results[1], decoder)
        let deps = try Self.lossy(Dependency.self, results[2], decoder)
        let labels = try Self.lossy(Label.self, results[3], decoder)
        let statuses = try Self.lossy(CustomStatus.self, results[4], decoder)
        return BeadsData(
            commit: commit,
            schemaVersion: (try? decoder.decode([Version].self, from: results[0]).first?.v) ?? 0,
            issues: issues.rows,
            dependencies: deps.rows,
            labels: labels.rows,
            customStatuses: statuses.rows,
            tables: tables,
            skippedRows: issues.skipped + deps.skipped + labels.skipped + statuses.skipped
        )
    }

    /// Decodes rows one by one, dropping (and counting) the ones that don't decode.
    static func lossy<T: Decodable>(_ type: T.Type, _ data: Data, _ decoder: JSONDecoder) throws -> (rows: [T], skipped: Int) {
        let decoded = try decoder.decode([LossyRow<T>].self, from: data)
        let rows = decoded.compactMap(\.value)
        return (rows, decoded.count - rows.count)
    }

    public func detail(issueID: String, snapshot: URL, tables: Set<String>) async throws -> IssueDetail {
        // ids come from the data itself; still never splice anything but a validated literal into SQL.
        guard Self.isSafeIssueID(issueID) else { throw DoltError.queryFailed("invalid issue id") }
        let literal = "'\(issueID)'"
        let results = try await dolt.query([
            "SELECT description, design, acceptance_criteria, notes FROM issues WHERE id = \(literal)",
            tables.contains("comments")
                ? "SELECT id, author, text, created_at FROM comments WHERE issue_id = \(literal) ORDER BY created_at, id"
                : "SELECT 1 AS skip FROM dual WHERE 1 = 0",
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
            comments: try Self.lossy(Comment.self, results[1], decoder).rows
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

/// A row that decodes to `nil` instead of failing the whole array.
struct LossyRow<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
