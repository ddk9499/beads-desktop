import Foundation
import SwiftUI

/// Renders bead text (untrusted, from the repo) as inline markdown: emphasis, code, http(s) links.
/// No HTML, no images, no custom URL schemes. Block structure (lists, headings) is kept as plain lines.
struct MarkdownText: View {
    let source: String

    var body: some View {
        Text(Self.render(source))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func render(_ source: String) -> AttributedString {
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
            let scheme = url.scheme?.lowercased()
            if scheme != "https" && scheme != "http" { text[run.range].link = nil }
        }
        return text
    }
}
