import Foundation

/// A drawable slice of the dependency graph (the whole graph of a real project has thousands of nodes).
public struct GraphScope: Sendable, Equatable {
    public struct Edge: Hashable, Sendable {
        /// Prerequisite / parent.
        public let source: String
        /// Dependent / child.
        public let target: String
        public let type: String

        public var id: String { "\(source)->\(target):\(type)" }
    }

    public let nodes: [Issue]
    public let edges: [Edge]
    /// Nodes that belong to the scope proper (vs. one-hop context around it).
    public let insideIDs: Set<String>
    /// The issue/epic the scope was built around.
    public let anchorID: String

    /// Hard cap so a huge epic can't freeze the web view; the rest is reported as truncated.
    public static let maxNodes = 400
    public let truncated: Int

    /// Scotty's epic scope: the epic, every recursive parent-child descendant, plus one hop of
    /// external dependency context in either direction.
    public static func epic(_ epicID: String, in board: BoardIndex) -> GraphScope {
        guard board.issuesByID[epicID] != nil else { return .empty(epicID) }
        var inside: Set<String> = [epicID]
        var pending = [epicID]
        while let id = pending.popLast() {
            for child in board.children(of: id).map(\.id) where inside.insert(child).inserted {
                pending.append(child)
            }
        }
        var outside: Set<String> = []
        for id in inside {
            for dep in board.dependencies[id] ?? [] where !inside.contains(dep.dependsOnID) && board.issuesByID[dep.dependsOnID] != nil {
                outside.insert(dep.dependsOnID)
            }
            for dep in board.dependents[id] ?? [] where !inside.contains(dep.issueID) {
                outside.insert(dep.issueID)
            }
        }
        return build(anchor: epicID, inside: inside, outside: outside, board: board)
    }

    /// Scotty's neighborhood: the full chains of *active* blockers upstream and dependents downstream,
    /// plus the issue's parent and direct children as hierarchy context.
    public static func neighborhood(of id: String, in board: BoardIndex) -> GraphScope {
        guard let focus = board.issuesByID[id] else { return .empty(id) }
        let active: (Dependency) -> Bool = {
            BoardIndex.blockingTypes.contains($0.type) && $0.type != Dependency.parentChild
        }
        func isOpen(_ id: String) -> Bool { board.issuesByID[id].map { $0.status != "closed" } ?? false }

        func walk(_ next: (String) -> [String]) -> Set<String> {
            var seen: Set<String> = [id]
            var pending = [id]
            while let current = pending.popLast() {
                for n in next(current) where isOpen(n) && seen.insert(n).inserted { pending.append(n) }
            }
            return seen
        }
        let up = walk { cur in (board.dependencies[cur] ?? []).filter(active).map(\.dependsOnID) }
        let down = walk { cur in (board.dependents[cur] ?? []).filter(active).map(\.issueID) }
        var inside = up.union(down)
        inside.insert(focus.id)
        var context: Set<String> = []
        if let parent = board.parent(of: id) { context.insert(parent.id) }
        for child in board.children(of: id) { context.insert(child.id) }
        return build(anchor: id, inside: inside, outside: context.subtracting(inside), board: board)
    }

    static func build(anchor: String, inside: Set<String>, outside: Set<String>, board: BoardIndex) -> GraphScope {
        // Deterministic order; the anchor and inside nodes win when capping.
        let ordered = [anchor] + inside.subtracting([anchor]).sorted() + outside.sorted()
        let kept = Array(ordered.prefix(maxNodes))
        let keptSet = Set(kept)
        var edges: Set<Edge> = []
        for id in kept {
            for dep in board.dependencies[id] ?? [] where keptSet.contains(dep.dependsOnID) {
                // Records are dependent -> prerequisite; draw prerequisite -> dependent (and parent -> child).
                edges.insert(Edge(source: dep.dependsOnID, target: id, type: dep.type))
            }
        }
        return GraphScope(
            nodes: kept.compactMap { board.issuesByID[$0] },
            edges: edges.sorted { $0.id < $1.id },
            insideIDs: inside.intersection(keptSet),
            anchorID: anchor,
            truncated: ordered.count - kept.count
        )
    }

    static func empty(_ anchor: String) -> GraphScope {
        GraphScope(nodes: [], edges: [], insideIDs: [], anchorID: anchor, truncated: 0)
    }
}
