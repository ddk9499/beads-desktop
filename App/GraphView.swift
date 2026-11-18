import BeadsKit
import SwiftUI
import WebKit

/// What the graph is built around.
enum GraphAnchor: Hashable {
    case epic(String)
    case issue(String)

    var id: String {
        switch self {
        case let .epic(id), let .issue(id): id
        }
    }
}

/// Graph mode: pick an epic or an issue's neighborhood; click a node to open it in the inspector.
struct GraphModeView: View {
    let board: BoardIndex
    let issues: [Issue]
    @Binding var selection: String?
    @Binding var anchor: GraphAnchor?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let epics = board.epics(among: issues, hideClosed: true)
        let effective = anchor ?? selection.map(GraphAnchor.issue) ?? epics.first.map { .epic($0.id) }
        let scope: GraphScope? = switch effective {
        case let .epic(id): GraphScope.epic(id, in: board)
        case let .issue(id): GraphScope.neighborhood(of: id, in: board)
        case nil: nil
        }

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: Binding(get: { effective }, set: { anchor = $0 })) {
                    if let id = selection, board.issuesByID[id] != nil {
                        Text("Blockers & dependents of \(id)").tag(Optional(GraphAnchor.issue(id)))
                    }
                    if case let .issue(id) = effective, id != selection {
                        Text("Blockers & dependents of \(id)").tag(Optional(GraphAnchor.issue(id)))
                    }
                    Section("Epics") {
                        ForEach(epics) { epic in
                            Text("\(epic.id) · \(String(epic.title.prefix(60)))").tag(Optional(GraphAnchor.epic(epic.id)))
                        }
                    }
                }
                .frame(maxWidth: 520)
                if let selection, case let .epic(epicID) = effective, selection != epicID {
                    Button("Neighborhood of \(selection)") { anchor = .issue(selection) }
                        .help("Show blockers and dependents of the selected issue")
                }
                Spacer()
                if let scope {
                    Text("\(scope.nodes.count) issues · \(scope.edges.count) links\(scope.truncated > 0 ? " · \(scope.truncated) not shown" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GraphLegend()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let scope {
                GraphWebView(scope: scope, board: board, selection: $selection, dark: colorScheme == .dark)
            } else {
                ContentUnavailableView("Nothing to graph", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Select an issue or pick an epic."))
            }
        }
    }
}

private struct GraphLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legend("blocks", color: .red, dash: [])
            legend("parent → child", color: .secondary, dash: [4, 3])
            legend("related", color: .secondary, dash: [1, 3])
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func legend(_ title: String, color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: .init(x: 0, y: 4)); p.addLine(to: .init(x: 18, y: 4)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dash))
                .frame(width: 18, height: 8)
            Text(title)
        }
    }
}

/// WKWebView hosting `Resources/Graph/graph.html` (Cytoscape + dagre, fully local).
struct GraphWebView: NSViewRepresentable {
    let scope: GraphScope
    let board: BoardIndex
    @Binding var selection: String?
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "select")
        controller.add(context.coordinator, name: "ready")
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        if let page = Bundle.main.url(forResource: "graph", withExtension: "html", subdirectory: "Graph") {
            context.coordinator.pageURL = page
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.render(payload())
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private func payload() -> Payload {
        let nodes = scope.nodes.map { issue in
            Payload.Node(id: issue.id, title: issue.title, status: issue.status, type: issue.issueType,
                         column: board.columns[issue.id]?.rawValue ?? "", inside: scope.insideIDs.contains(issue.id))
        }
        let edges = scope.edges.map { Payload.Edge(id: $0.id, source: $0.source, target: $0.target, type: $0.type) }
        // Relayout only when the graph itself changed (not on selection/theme changes).
        var hasher = Hasher()
        hasher.combine(scope.anchorID)
        for n in nodes { hasher.combine(n.id); hasher.combine(n.column); hasher.combine(n.status) }
        for e in edges { hasher.combine(e.id) }
        return Payload(key: String(hasher.finalize()), anchor: scope.anchorID, selected: selection ?? "",
                       dark: dark, nodes: nodes, edges: edges)
    }

    struct Payload: Encodable, Equatable {
        struct Node: Encodable, Equatable {
            let id, title, status, type, column: String
            let inside: Bool
        }
        struct Edge: Encodable, Equatable { let id, source, target, type: String }
        let key, anchor, selected: String
        let dark: Bool
        let nodes: [Node]
        let edges: [Edge]
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var selection: Binding<String?>
        weak var webView: WKWebView?
        var pageURL: URL?
        private var isReady = false
        private var pending: Payload?
        private var lastSent: Payload?

        init(selection: Binding<String?>) { self.selection = selection }

        func render(_ payload: Payload) {
            guard payload != lastSent else { return }
            pending = payload
            flush()
        }

        private func flush() {
            guard isReady, let payload = pending, let webView,
                  let json = try? String(decoding: JSONEncoder().encode(payload), as: UTF8.self) else { return }
            pending = nil
            lastSent = payload
            // Passed as an argument, never spliced into the script source.
            webView.callAsyncJavaScript("return render(payload)", arguments: ["payload": json], in: nil, in: .page) { result in
                #if DEBUG
                switch result {
                case let .failure(error):
                    FileHandle.standardError.write(Data("[graph] render failed: \(error)\n".utf8))
                case let .success(value):
                    FileHandle.standardError.write(Data("[graph] rendered \(String(describing: value))\n".utf8))
                    // Debug-only: `-debugGraphSnapshot <png>` captures the web view after rendering.
                    if let path = UserDefaults.standard.string(forKey: "debugGraphSnapshot") {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1))
                            webView.takeSnapshot(with: nil) { image, _ in
                                guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                                      let png = rep.representation(using: .png, properties: [:]) else { return }
                                try? png.write(to: URL(filePath: path))
                            }
                        }
                    }
                }
                #endif
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                isReady = true
                flush()
            case "select":
                guard let id = message.body as? String else { return }
                selection.wrappedValue = id.isEmpty ? nil : id
            default:
                break
            }
        }

        /// Only our bundled page may load; anything else (links, redirects) is refused.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, let pageURL, url.isFileURL,
                  url.standardizedFileURL.path == pageURL.standardizedFileURL.path else { return .cancel }
            return .allow
        }
    }
}
