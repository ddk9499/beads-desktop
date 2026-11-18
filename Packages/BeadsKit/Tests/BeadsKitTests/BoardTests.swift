import Foundation
import Testing
@testable import BeadsKit

@Suite struct BoardTests {
    static func issue(_ id: String, _ status: String, priority: Int = 2, type: String = "task", updated: String? = nil) -> BeadsKit.Issue {
        var json: [String: Any] = ["id": id, "title": id, "status": status, "priority": priority, "issue_type": type]
        if let updated { json["updated_at"] = updated }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! BeadsReader.decoder().decode(BeadsKit.Issue.self, from: data)
    }

    static func dep(_ from: String, _ to: String, _ type: String) -> Dependency {
        let data = try! JSONSerialization.data(withJSONObject: ["issue_id": from, "depends_on_issue_id": to, "type": type])
        return try! JSONDecoder().decode(Dependency.self, from: data)
    }

    static func board(_ issues: [BeadsKit.Issue], _ deps: [Dependency] = [], custom: [CustomStatus] = []) -> BoardIndex {
        BoardIndex(BeadsData(commit: "c", schemaVersion: 66, issues: issues, dependencies: deps, labels: [],
                             customStatuses: custom, readyIDs: [], blockedIDs: []))
    }

    @Test func builtInStatusesMapLikeScotty() {
        let b = Self.board([
            Self.issue("a", "deferred"), Self.issue("b", "open"), Self.issue("c", "in_progress"),
            Self.issue("d", "hooked"), Self.issue("e", "blocked"), Self.issue("f", "closed"), Self.issue("g", "pinned"),
        ])
        #expect(b.columns["a"] == .backlog)
        #expect(b.columns["b"] == .ready)
        #expect(b.columns["c"] == .inProgress)
        #expect(b.columns["d"] == .inProgress)
        #expect(b.columns["e"] == .blocked)
        #expect(b.columns["f"] == .done)
        #expect(b.columns["g"] == nil)
        #expect(b.unplacedCount == 1)
    }

    @Test func openWithOpenBlockerIsBlocked() {
        let b = Self.board([Self.issue("x", "open"), Self.issue("blocker", "in_progress")],
                           [Self.dep("x", "blocker", "blocks")])
        #expect(b.columns["x"] == .blocked)
        #expect(b.blockers(of: b.issuesByID["x"]!) == ["blocker"])
        #expect(b.blocking("blocker").map(\.id) == ["x"])
    }

    @Test func closedBlockerDoesNotBlock() {
        let b = Self.board([Self.issue("x", "open"), Self.issue("blocker", "closed")], [Self.dep("x", "blocker", "blocks")])
        #expect(b.columns["x"] == .ready)
    }

    @Test func missingBlockerCountsAsOpen() {
        let b = Self.board([Self.issue("x", "open")], [Self.dep("x", "other-rig-1", "waits-for")])
        #expect(b.columns["x"] == .blocked)
    }

    @Test func parentChildIsHierarchyNotBlocker() {
        let b = Self.board([Self.issue("epic", "open", type: "epic"), Self.issue("kid", "open"), Self.issue("kid2", "closed")],
                           [Self.dep("kid", "epic", "parent-child"), Self.dep("kid2", "epic", "parent-child")])
        #expect(b.columns["kid"] == .ready)
        #expect(b.parent(of: "kid")?.id == "epic")
        #expect(Set(b.children(of: "epic").map(\.id)) == ["kid", "kid2"])
        #expect(b.progress(of: "epic")! == (1, 2))
        #expect(b.progress(of: "kid") == nil)
    }

    @Test func relatedLinksAreNotBlocking() {
        let b = Self.board([Self.issue("x", "open"), Self.issue("y", "open")], [Self.dep("x", "y", "related")])
        #expect(b.columns["x"] == .ready)
        #expect(b.otherLinks(of: "x").map(\.issue.id) == ["y"])
        #expect(b.otherLinks(of: "y").map(\.type) == ["related (from)"])
    }

    @Test func customStatusesUseCategories() {
        let custom = [CustomStatus(name: "in_review", category: "active"), CustomStatus(name: "qa", category: "wip"),
                      CustomStatus(name: "shipped", category: "done"), CustomStatus(name: "on_hold", category: "frozen"),
                      CustomStatus(name: "legacy", category: nil)]
        let b = Self.board(["in_review", "qa", "shipped", "on_hold", "legacy"].map { Self.issue($0, $0) }, custom: custom)
        #expect(b.columns["in_review"] == .ready)
        #expect(b.columns["qa"] == .inProgress)
        #expect(b.columns["shipped"] == .done)
        #expect(b.columns["on_hold"] == .backlog)
        #expect(b.columns["legacy"] == nil)
    }

    @Test func sortModes() {
        let issues = [Self.issue("a", "open", priority: 2, updated: "2026-01-03 00:00:00"),
                      Self.issue("b", "open", priority: 0, updated: "2026-01-01 00:00:00"),
                      Self.issue("c", "open", priority: 2, updated: "2026-01-02 00:00:00")]
        #expect(BoardSort.priority.sorted(issues).map(\.id) == ["b", "a", "c"])
        #expect(BoardSort.updated.sorted(issues).map(\.id) == ["a", "c", "b"])
    }

    @Test func origin() {
        #expect(Origin.of("doston", humans: ["doston"]) == .human)
        #expect(Origin.of("bee", humans: ["doston"]) == .agent)
        #expect(Origin.of(nil, humans: ["doston"]) == .agent)
    }
}
