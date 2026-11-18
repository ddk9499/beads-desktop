import Foundation
import Testing
@testable import BeadsKit

@Suite struct GraphScopeTests {
    typealias V = ViewsTests
    static func dep(_ a: String, _ b: String, _ t: String) -> Dependency { BoardTests.dep(a, b, t) }

    /// epic ─┬─ a ── a1        x blocks a; b blocks y; z unrelated
    ///       └─ b
    static var board: BoardIndex {
        V.board([V.issue("epic", type: "epic"), V.issue("a"), V.issue("a1"), V.issue("b"),
                 V.issue("x"), V.issue("y"), V.issue("z")],
                deps: [dep("a", "epic", "parent-child"), dep("b", "epic", "parent-child"), dep("a1", "a", "parent-child"),
                       dep("a", "x", "blocks"), dep("y", "b", "blocks")])
    }

    @Test func epicScopeIsDescendantsPlusOneHop() {
        let scope = GraphScope.epic("epic", in: Self.board)
        #expect(scope.insideIDs == ["epic", "a", "a1", "b"])
        #expect(Set(scope.nodes.map(\.id)) == ["epic", "a", "a1", "b", "x", "y"])
        #expect(scope.nodes.first?.id == "epic")
        // Edges point prerequisite -> dependent and parent -> child.
        #expect(scope.edges.contains(.init(source: "x", target: "a", type: "blocks")))
        #expect(scope.edges.contains(.init(source: "epic", target: "a", type: "parent-child")))
        #expect(!scope.edges.contains { $0.source == "z" || $0.target == "z" })
    }

    @Test func neighborhoodFollowsActiveChainsOnly() {
        // c <- d <- e (blocks chain), f closed blocker of d, g related to d
        let b = V.board([V.issue("c"), V.issue("d"), V.issue("e"), V.issue("f", "closed"), V.issue("g"), V.issue("p", type: "epic")],
                        deps: [Self.dep("d", "c", "blocks"), Self.dep("e", "d", "waits-for"), Self.dep("d", "f", "blocks"),
                               Self.dep("d", "g", "related"), Self.dep("d", "p", "parent-child")])
        let scope = GraphScope.neighborhood(of: "d", in: b)
        #expect(scope.insideIDs == ["c", "d", "e"])
        #expect(Set(scope.nodes.map(\.id)) == ["c", "d", "e", "p"])   // parent as context; closed f and related g left out
        #expect(scope.anchorID == "d")
    }

    @Test func unknownAnchorIsEmpty() {
        #expect(GraphScope.epic("nope", in: Self.board).nodes.isEmpty)
        #expect(GraphScope.neighborhood(of: "nope", in: Self.board).nodes.isEmpty)
    }

    @Test func capKeepsAnchorAndReportsTruncation() {
        var issues = [V.issue("epic", type: "epic")]
        var deps: [Dependency] = []
        for i in 0..<(GraphScope.maxNodes + 10) {
            issues.append(V.issue("t\(i)"))
            deps.append(Self.dep("t\(i)", "epic", "parent-child"))
        }
        let scope = GraphScope.epic("epic", in: V.board(issues, deps: deps))
        #expect(scope.nodes.count == GraphScope.maxNodes)
        #expect(scope.nodes.first?.id == "epic")
        #expect(scope.truncated == 11)
    }
}
