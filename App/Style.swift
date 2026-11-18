import BeadsKit
import SwiftUI

enum Style {
    static func priorityColor(_ p: Int) -> Color {
        switch p {
        case 0: .red
        case 1: .orange
        case 2: .yellow
        case 3: .blue
        default: .gray
        }
    }

    static func typeSymbol(_ type: String) -> String {
        switch type {
        case "bug": "ladybug"
        case "feature": "sparkles"
        case "epic": "square.stack.3d.up"
        case "chore": "wrench.adjustable"
        case "decision": "signpost.right"
        case "spike": "flask"
        case "story": "book"
        case "milestone": "flag"
        case "gate": "lock"
        default: "checkmark.square"
        }
    }

    static func columnColor(_ c: BoardColumn) -> Color {
        switch c {
        case .backlog: .gray
        case .ready: .blue
        case .inProgress: .orange
        case .blocked: .red
        case .done: .green
        }
    }

    static func columnSymbol(_ c: BoardColumn) -> String {
        switch c {
        case .backlog: "tray"
        case .ready: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.octagon"
        case .done: "checkmark.circle.fill"
        }
    }
}

struct PriorityBadge: View {
    let priority: Int
    var body: some View {
        Text("P\(priority)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Style.priorityColor(priority).opacity(0.18), in: .capsule)
            .foregroundStyle(Style.priorityColor(priority))
    }
}

struct LabelChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }
}

struct OriginMark: View {
    let name: String?
    @AppStorage(SettingsKeys.humanNames) private var humanNames = ""

    var body: some View {
        let origin = Origin.of(name, humans: SettingsKeys.parse(humanNames))
        Text(origin == .human ? "👤" : "🤖")
            .font(.caption2)
            .help(origin == .human ? "Human · \(name ?? "unknown")" : "Agent · \(name ?? "unknown")")
    }
}

enum SettingsKeys {
    static let humanNames = "humanNames"
    static let doneWindowDays = "doneWindowDays"
    static let boardSort = "boardSort"
    static let pollSeconds = "pollSeconds"

    static func parse(_ raw: String) -> Set<String> {
        Set(raw.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

extension Date {
    var relative: String { formatted(.relative(presentation: .named)) }
}
