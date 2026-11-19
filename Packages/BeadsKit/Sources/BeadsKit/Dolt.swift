import Foundation

public enum DoltError: Error, Sendable, CustomStringConvertible {
    case queryFailed(String)
    case malformedOutput(String)

    public var description: String {
        switch self {
        case let .queryFailed(s): "dolt query failed: \(s)"
        case let .malformedOutput(s): "Unexpected dolt output: \(s)"
        }
    }
}

/// Runs read-only SQL against a snapshot with the bundled `dolt` binary.
public struct DoltClient: Sendable {
    let env: ToolEnvironment

    public init(env: ToolEnvironment) { self.env = env }

    public func version() async throws -> String {
        let out = try await ProcessRunner.run(env.doltExecutable, ["version"], environment: env.doltEnvironment(), timeout: 30)
        guard out.status == 0 else { throw DoltError.queryFailed(out.stderrString) }
        return out.stdoutString.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// Runs several `;`-separated statements in one process; returns the raw JSON rows of each, in order.
    /// dolt prints one `{"rows": [...]}` object per statement, each on its own line.
    public func query(_ statements: [String], in database: URL) async throws -> [Data] {
        let sql = statements.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "; \n")) }.joined(separator: ";\n") + ";"
        let out = try await ProcessRunner.run(env.doltExecutable, ["sql", "-r", "json", "-q", sql],
                                              environment: env.doltEnvironment(), currentDirectory: database, timeout: 120,
                                              sandboxProfile: Self.sandboxProfile(database: database, env: env))
        guard out.status == 0 else {
            throw DoltError.queryFailed(out.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let results = try Self.splitResults(out.stdout)
        guard results.count == statements.count else {
            throw DoltError.malformedOutput("expected \(statements.count) result sets, got \(results.count)")
        }
        return results
    }

    /// The database comes from an untrusted repository, so dolt runs with no network, may write only to the
    /// snapshot and its own config root, and may read nothing under the home folder except those and itself.
    static func sandboxProfile(database: URL, env: ToolEnvironment) -> String {
        func lit(_ url: URL) -> String {
            let path = url.resolvingSymlinksInPath().path
            return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let home = URL(filePath: NSHomeDirectory())
        let db = lit(database), root = lit(env.paths.doltRoot), tool = lit(env.doltExecutable.deletingLastPathComponent())
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath \(db)) (subpath \(root)) (literal "/dev/null") (subpath "/private/var/folders"))
        (deny file-read* (subpath \(lit(home))))
        (allow file-read* (literal \(lit(home))) (subpath \(db)) (subpath \(root)) (subpath \(tool)))
        """
    }

    /// Extracts the `rows` array of each result object as standalone JSON.
    static func splitResults(_ data: Data) throws -> [Data] {
        var results: [Data] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let trimmed = line.drop(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") })
            guard !trimmed.isEmpty else { continue }
            guard let object = try JSONSerialization.jsonObject(with: Data(trimmed)) as? [String: Any] else {
                throw DoltError.malformedOutput(String(decoding: trimmed.prefix(200), as: UTF8.self))
            }
            // Empty result sets are printed as {} by some dolt versions.
            let rows = object["rows"] as? [Any] ?? []
            results.append(try JSONSerialization.data(withJSONObject: rows))
        }
        return results
    }
}
