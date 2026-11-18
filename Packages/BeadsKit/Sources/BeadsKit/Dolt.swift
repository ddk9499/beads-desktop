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
                                              environment: env.doltEnvironment(), currentDirectory: database, timeout: 120)
        guard out.status == 0 else {
            throw DoltError.queryFailed(out.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let results = try Self.splitResults(out.stdout)
        guard results.count == statements.count else {
            throw DoltError.malformedOutput("expected \(statements.count) result sets, got \(results.count)")
        }
        return results
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
