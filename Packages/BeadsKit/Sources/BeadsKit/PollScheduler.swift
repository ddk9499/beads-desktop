import Foundation

/// Decides which projects to refresh and when; pure state, time is passed in (testable).
public struct PollScheduler: Sendable {
    /// Seconds between checks; 0 = manual only.
    public var interval: TimeInterval
    /// Backoff cap after repeated failures.
    public static let maxBackoff: TimeInterval = 600

    private var lastSync: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    private var nextAttempt: [UUID: Date] = [:]

    public init(interval: TimeInterval) { self.interval = interval }

    public var isManual: Bool { interval <= 0 }

    public func lastSync(of id: UUID) -> Date? { lastSync[id] }

    /// Projects due for an automatic refresh: last sync older than `minAge` (default: the interval) and not
    /// in failure backoff. Nothing is due in manual mode.
    public func due(_ ids: [UUID], now: Date, minAge: TimeInterval? = nil, busy: Set<UUID> = []) -> [UUID] {
        guard !isManual else { return [] }
        let age = minAge ?? interval
        return ids.filter { id in
            !busy.contains(id)
                && (nextAttempt[id].map { $0 <= now } ?? true)
                && (lastSync[id].map { now.timeIntervalSince($0) >= age - 1 } ?? true)
        }
    }

    /// After a failure the next automatic attempt waits interval × 2^(n-1), at least 30 s, at most 10 min.
    public mutating func record(_ id: UUID, success: Bool, now: Date) {
        if success {
            lastSync[id] = now
            failures[id] = nil
            nextAttempt[id] = nil
        } else {
            let n = (failures[id] ?? 0) + 1
            failures[id] = n
            let base = max(interval, 30)
            nextAttempt[id] = now.addingTimeInterval(min(base * pow(2, Double(n - 1)), Self.maxBackoff))
        }
    }

    public func retryAt(_ id: UUID) -> Date? { nextAttempt[id] }

    public mutating func forget(_ id: UUID) {
        lastSync[id] = nil
        failures[id] = nil
        nextAttempt[id] = nil
    }
}

/// Inline markdown for untrusted bead text: emphasis, code and http(s) links only.
public enum SafeMarkdown {
    public static let allowedSchemes: Set<String> = ["https", "http"]

    public static func attributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var text = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        for run in text.runs {
            guard let url = run.link else { continue }
            if !isAllowed(url) { text[run.range].link = nil }
        }
        return text
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return false }
        return url.host() != nil
    }
}
