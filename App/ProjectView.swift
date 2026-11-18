import BeadsKit
import SwiftUI

/// M0/M1 verification view: a plain table of issues. The real Board/Epics/Focus come in M2–M3.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var selectedIssue: String?
    @State private var detail: IssueDetail?
    @State private var showClosed = false

    var body: some View {
        switch model.state(of: projectID) {
        case .idle, .syncing:
            ProgressView("Fetching beads data…")
        case let .failed(message):
            ContentUnavailableView {
                Label("Sync failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Retry") { Task { await model.sync(projectID) } }
            }
        case let .loaded(data, _):
            table(data)
                .inspector(isPresented: .constant(selectedIssue != nil)) { inspector(data) }
                .toolbar {
                    Toggle("Show closed", isOn: $showClosed)
                    Button { Task { await model.sync(projectID) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .navigationSubtitle(subtitle(data))
                .task(id: selectedIssue) { await loadDetail() }
        }
    }

    private func table(_ data: BeadsData) -> some View {
        let rows = data.issues
            .filter { showClosed || $0.status != "closed" }
            .sorted { ($0.priority, $0.updatedAt ?? .distantPast) < ($1.priority, $1.updatedAt ?? .distantPast) }
        return Table(rows, selection: $selectedIssue) {
            TableColumn("ID", value: \.id).width(min: 80, ideal: 100)
            TableColumn("P") { Text("P\($0.priority)") }.width(32)
            TableColumn("Type", value: \.issueType).width(min: 50, ideal: 60)
            TableColumn("Status") { issue in
                Text(column(for: issue, in: data)).foregroundStyle(issue.status == "closed" ? .secondary : .primary)
            }.width(min: 80, ideal: 100)
            TableColumn("Title", value: \.title)
            TableColumn("Assignee") { Text($0.assignee ?? "") }.width(min: 80, ideal: 140)
        }
    }

    /// Board column per the MVP plan (Backlog · Ready · In Progress · Blocked · Done).
    private func column(for issue: Issue, in data: BeadsData) -> String {
        if issue.status == "closed" { return "Done" }
        if issue.status == "deferred" { return "Backlog" }
        if data.blockedIDs.contains(issue.id) { return "Blocked" }
        if issue.status == "in_progress" { return "In Progress" }
        if data.readyIDs.contains(issue.id) { return "Ready" }
        return issue.status
    }

    @ViewBuilder private func inspector(_ data: BeadsData) -> some View {
        if let id = selectedIssue, let issue = data.issues.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(issue.title).font(.title3.bold()).textSelection(.enabled)
                    Text("\(issue.id) · \(issue.issueType) · P\(issue.priority) · \(issue.status)")
                        .font(.caption).foregroundStyle(.secondary)
                    let labels = data.labels(of: id)
                    if !labels.isEmpty { Text(labels.joined(separator: "  ·  ")).font(.caption) }
                    let children = data.children(of: id)
                    if !children.isEmpty {
                        let done = children.filter { c in data.issues.first { $0.id == c }?.status == "closed" }.count
                        ProgressView(value: Double(done), total: Double(children.count)) {
                            Text("\(done)/\(children.count) children closed").font(.caption)
                        }
                    }
                    if let detail {
                        // Untrusted text from the repo: plain text only (no HTML/markdown links rendering yet).
                        section("Description", detail.description)
                        section("Design", detail.design)
                        section("Acceptance criteria", detail.acceptanceCriteria)
                        section("Notes", detail.notes)
                        if !detail.comments.isEmpty {
                            Text("Comments").font(.headline)
                            ForEach(detail.comments) { c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.author ?? "unknown").font(.caption.bold())
                                    Text(c.text).textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .inspectorColumnWidth(min: 280, ideal: 360)
        }
    }

    @ViewBuilder private func section(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            Text(title).font(.headline)
            Text(verbatim: text).textSelection(.enabled)
        }
    }

    private func loadDetail() async {
        detail = nil
        guard let id = selectedIssue else { return }
        detail = try? await model.detail(id, project: projectID)
    }

    private func subtitle(_ data: BeadsData) -> String {
        let schema = switch BeadsReader.support(for: data.schemaVersion) {
        case .supported: "schema \(data.schemaVersion)"
        case let .newerThanTested(v): "schema \(v) (newer than tested)"
        case let .olderThanTested(v): "schema \(v) (older than tested)"
        }
        return "\(data.issues.count) issues · \(schema) · \(data.commit.prefix(8))"
    }
}

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdded: (UUID) -> Void

    @State private var address = ""
    @State private var keyPath: String?
    @State private var account: String?
    @State private var error: String?
    @State private var busy = false
    private let keys = SSHProbe.availableKeys()

    var body: some View {
        Form {
            TextField("Repository", text: $address, prompt: Text("git@github.com:owner/repo.git"))
            Picker("SSH key", selection: $keyPath) {
                Text("Default (ssh config / agent)").tag(String?.none)
                ForEach(keys, id: \.path) { Text($0.lastPathComponent).tag(Optional($0.path)) }
            }
            .onChange(of: keyPath) { account = nil }
            HStack {
                Button("Check key") {
                    Task {
                        busy = true
                        let host = (try? RemoteURL.parse(address).host) ?? "github.com"
                        account = await model.whoAmI(host: host, keyPath: keyPath)
                        busy = false
                    }
                }
                if let account { Text("Signs in as: \(account)").font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            let project = try await model.addProject(address: address, keyPath: keyPath)
                            onAdded(project.id)
                            dismiss()
                        } catch { self.error = "\(error)" }
                    }
                }
                .disabled(address.isEmpty)
            }
        }
    }
}
