import BeadsKit
import SwiftUI

/// Renders bead text (untrusted, from the repo) as inline markdown via `SafeMarkdown`:
/// emphasis, code, http(s) links. No HTML, no images, no custom URL schemes.
struct MarkdownText: View {
    let source: String

    var body: some View {
        Text(SafeMarkdown.attributed(source))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
