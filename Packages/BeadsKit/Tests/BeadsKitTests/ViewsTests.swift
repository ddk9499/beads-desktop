import Foundation
import Testing
@testable import BeadsKit

@Suite struct ViewsTests {
    static func issue(_ id: String, _ status: String = "open", priority: Int = 2, type: String = "task",
                      assignee: String? = nil, createdBy: String? = nil, title: String? = nil,
                      closed: String? = nil) -> BeadsKit.Issue {
        var json: [String: Any] = ["id": id, "title": title ?? id, "status": status, "priority": priority, "issue_type": type]
        if let assignee { json["assignee"] = assignee }
        if let createdBy { json["created_by"] = createdBy }
        if let closed { json["closed_at"] = closed }
        return try! BeadsReader.decoder().decode(BeadsKit.Issue.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func label(_ id: String, _ label: String) -> Label {
        try! JSONDecoder().decode(Label.self, from: JSONSerialization.data(withJSONObject: ["issue_id": id, "label": label]))
    }

    static func board(_ issues: [BeadsKit.Issue], labels: [Label] = [], deps: [Dependency] = []) -> BoardIndex {
        BoardIndex(BeadsData(commit: "c", schemaVersion: 66, issues: issues, dependencies: deps, labels: labels,
                             customStatuses: [], readyIDs: [], blockedIDs: []))
    }

    // MARK: Filters

    @Test func facetsAreOrWithinAndAcross() {
        let b = Self.board([Self.issue("a", priority: 0, type: "bug"), Self.issue("b", priority: 1, type: "task"),
                            Self.issue("c", priority: 0, type: "task")])
        var f = IssueFilter()
        f.priorities = [0, 1]
        #expect(b.filtered(f, humans: []).map(\.id) == ["a", "b", "c"])
        f.types = ["task"]
        #expect(b.filtered(f, humans: []).map(\.id) == ["b", "c"])
        #expect(f.activeCount == 3)
    }

    @Test func searchMatchesIdTitleAssigneeLabels() {
        let b = Self.board([Self.issue("bd-1", title: "Fix Login"), Self.issue("bd-2", assignee: "Alice"),
                            Self.issue("bd-3"), Self.issue("xx-9")],
                           labels: [Self.label("bd-3", "frontend")])
        var f = IssueFilter()
        for (q, expected) in [("login", ["bd-1"]), ("alice", ["bd-2"]), ("FRONT", ["bd-3"]), ("xx-", ["xx-9"]), ("  ", ["bd-1", "bd-2", "bd-3", "xx-9"])] {
            f.search = q
            #expect(b.filtered(f, humans: []).map(\.id) == expected, "query \(q)")
        }
    }

    @Test func unassignedAndOriginFacets() {
        let b = Self.board([Self.issue("a", assignee: "bob", createdBy: "doston"), Self.issue("b", assignee: "  ", createdBy: "bee"),
                            Self.issue("c", createdBy: nil)])
        #expect(b.assigneeOptions == ["", "bob"])
        var f = IssueFilter()
        f.assignees = [IssueFilter.unassigned]
        #expect(b.filtered(f, humans: []).map(\.id) == ["b", "c"])
        f = IssueFilter()
        f.origins = [.human]
        #expect(b.filtered(f, humans: ["doston"]).map(\.id) == ["a"])
    }

    @Test func archivedHiddenByDefaultAndNotALabelOption() {
        let b = Self.board([Self.issue("a"), Self.issue("b")],
                           labels: [Self.label("a", "archived"), Self.label("b", "ui")])
        var f = IssueFilter()
        #expect(b.filtered(f, humans: []).map(\.id) == ["b"])
        f.showArchived = true
        #expect(b.filtered(f, humans: []).count == 2)
        #expect(b.labelOptions == ["ui"])
    }

    // MARK: Focus

    @Test func focusColumns() {
        let issues = [
            Self.issue("wip", "in_progress"), Self.issue("hook", "hooked"),
            Self.issue("p0", priority: 0), Self.issue("p3", priority: 3),
            Self.issue("blocked", priority: 0), Self.issue("blocker", priority: 3),
            Self.issue("old", "closed", closed: "2026-01-01 00:00:00"), Self.issue("new", "closed", closed: "2026-02-01 00:00:00"),
        ]
        let b = Self.board(issues, deps: [BoardTests.dep("blocked", "blocker", "blocks")])
        let focus = FocusModel(board: b, issues: issues, groupByAssignee: false, showRecent: true)
        let g = try! #require(focus.groups.first)
        #expect(Set(g.inFlight.map(\.id)) == ["wip", "hook"])
        #expect(g.blocked.map(\.id) == ["blocked"])
        #expect(g.nextUp.map(\.id) == ["p0"])   // P0/P1, open, not blocked
        #expect(g.recent.map(\.id) == ["new", "old"])
        #expect(FocusModel(board: b, issues: issues, groupByAssignee: false, showRecent: false).groups[0].recent.isEmpty)
    }

    @Test func focusGroupsByAssigneeActiveFirst() {
        let issues = [Self.issue("a", priority: 0, assignee: "zed"), Self.issue("b", "in_progress", assignee: "amy"),
                      Self.issue("c", "in_progress"), Self.issue("d", priority: 1, assignee: "bob")]
        let focus = FocusModel(board: Self.board(issues), issues: issues, groupByAssignee: true, showRecent: false)
        // Active (in flight/blocked) groups first: amy, then unassigned; then the rest by name.
        #expect(focus.groups.map(\.id) == ["amy", "", "bob", "zed"])
    }

    // MARK: Epics

    @Test func epicsOrderAndHideClosed() {
        let issues = [Self.issue("e3", "closed", priority: 0, type: "epic"), Self.issue("e2", priority: 2, type: "epic"),
                      Self.issue("e1", priority: 1, type: "epic"), Self.issue("t", type: "task")]
        let b = Self.board(issues)
        #expect(b.epics(among: issues, hideClosed: false).map(\.id) == ["e1", "e2", "e3"])
        #expect(b.epics(among: issues, hideClosed: true).map(\.id) == ["e1", "e2"])
    }
}
