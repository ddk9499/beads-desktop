import Foundation

/// A git remote reachable over SSH, normalized from whatever the user pasted.
///
/// Accepted inputs:
/// - `git@github.com:owner/repo(.git)`
/// - `ssh://git@github.com[:port]/owner/repo(.git)`
/// - `https://github.com/owner/repo(.git)` / `github.com/owner/repo` (converted to SSH)
/// - `owner/repo` (assumed github.com)
public struct RemoteURL: Hashable, Codable, Sendable, CustomStringConvertible {
    public let user: String
    public let host: String
    public let port: Int?
    public let owner: String
    public let repo: String

    public init(user: String = "git", host: String, port: Int? = nil, owner: String, repo: String) {
        self.user = user
        self.host = host
        self.port = port
        self.owner = owner
        self.repo = repo
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unrecognized(String)
        case invalidComponent(String)

        public var description: String {
            switch self {
            case .empty: "Empty repository address"
            case let .unrecognized(s): "Unrecognized repository address: \(s)"
            case let .invalidComponent(s): "Invalid characters in repository address: \(s)"
            }
        }
    }

    public static func parse(_ raw: String) throws(ParseError) -> RemoteURL {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw .empty }

        var user = "git"
        var host: String
        var port: Int?
        var path: String

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(), input.contains("://") {
            guard let h = url.host(percentEncoded: false), !h.isEmpty else { throw .unrecognized(input) }
            switch scheme {
            case "ssh", "git+ssh":
                if let u = url.user(percentEncoded: false), !u.isEmpty { user = u }
                port = url.port
            case "https", "http", "git+https":
                break // converted to SSH; port of the HTTP endpoint is irrelevant
            default:
                throw .unrecognized(input)
            }
            host = h
            path = url.path(percentEncoded: false)
        } else if let colon = input.firstIndex(of: ":"), input[..<colon].contains("@") || input[..<colon].contains(".") {
            // scp-like: [user@]host:owner/repo
            let left = String(input[..<colon])
            path = String(input[input.index(after: colon)...])
            if let at = left.firstIndex(of: "@") {
                user = String(left[..<at])
                host = String(left[left.index(after: at)...])
            } else {
                host = left
            }
        } else {
            let parts = input.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            switch parts.count {
            case 2: host = "github.com"; path = input
            case 3 where parts[0].contains("."): host = parts[0]; path = parts[1...].joined(separator: "/")
            default: throw .unrecognized(input)
            }
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2 else { throw .unrecognized(input) }
        var repo = segments[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let owner = segments[0]

        for part in [user, owner, repo] where !Self.isSafeComponent(part) {
            throw .invalidComponent(part)
        }
        guard Self.isSafeHost(host) else { throw .invalidComponent(host) }
        return RemoteURL(user: user, host: host.lowercased(), port: port, owner: owner, repo: repo)
    }

    /// Form passed to `git` (always ssh:// so a port can be expressed and nothing is parsed as an option).
    public var gitURL: String {
        let portPart = port.map { ":\($0)" } ?? ""
        return "ssh://\(user)@\(host)\(portPart)/\(owner)/\(repo).git"
    }

    /// Short form for display.
    public var description: String { host == "github.com" ? "\(owner)/\(repo)" : "\(host)/\(owner)/\(repo)" }

    public var webURL: URL? { URL(string: "https://\(host)/\(owner)/\(repo)") }

    // Conservative allow-lists: these strings reach argv of git/ssh.
    static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.hasPrefix(".")
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
            && s.allSatisfy(\.isASCII)
    }

    static func isSafeHost(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}
