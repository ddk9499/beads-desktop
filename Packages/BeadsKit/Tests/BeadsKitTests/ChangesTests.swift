import Foundation
import Testing
@testable import BeadsKit

@Suite struct ChangesTests {
    typealias V = ViewsTests

    @Test func detectsLifecycleChanges() {
        let old = V.board([V.issue("a"), V.issue("b", "in_progress"), V.issue("c", "closed"), V.issue("d"),
                           V.issue("blocked"), V.issue("blocker")],
                          deps: [BoardTests.dep("blocked", "blocker", "blocks")])
        let new = V.board([V.issue("a", "in_progress"), V.issue("b", "closed"), V.issue("c"), V.issue("d", assignee: "bee"),
                           V.issue("blocked"), V.issue("blocker", "closed"), V.issue("e")],
                          deps: [BoardTests.dep("blocked", "blocker", "blocks")])
        let changes = ChangeDetector.changes(from: old, to: new)
        let byID = Dictionary(grouping: changes, by: \.issue.id).mapValues { $0.map(\.kind) }
        #expect(byID["a"] == [.moved])
        #expect(byID["b"] == [.closed])
        #expect(byID["blocker"] == [.closed])
        #expect(byID["c"] == [.reopened])
        #expect(byID["d"] == [.reassigned])
        #expect(byID["blocked"] == [.unblocked])
        #expect(byID["e"] == [.created])
        // Most interesting first.
        #expect(changes.first?.kind == .closed)
        #expect(changes.first { $0.issue.id == "a" }?.summary == "Ready → In Progress · a a")
    }

    @Test func noChangesForIdenticalSnapshots() {
        let b = V.board([V.issue("a"), V.issue("b", "closed")])
        #expect(ChangeDetector.changes(from: b, to: b).isEmpty)
    }

    @Test func becameBlocked() {
        let old = V.board([V.issue("x"), V.issue("y")])
        let new = V.board([V.issue("x"), V.issue("y")], deps: [BoardTests.dep("x", "y", "blocks")])
        #expect(ChangeDetector.changes(from: old, to: new).map(\.kind) == [.becameBlocked])
    }
}
