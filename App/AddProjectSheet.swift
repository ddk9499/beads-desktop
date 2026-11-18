import BeadsKit
import SwiftUI

/// Add a repository: address → key → check (account + beads data) → add.
struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdded: (UUID) -> Void

    @State private var address = ""
    @State private var keyPath: String?
    @State private var check: AppModel.AccessCheck?
    @State private var checking = false
    @State private var error: String?
    private let keys = SSHProbe.availableKeys()

    private var parsed: Result<RemoteURL, RemoteURL.ParseError>? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do { return .success(try RemoteURL.parse(trimmed)) } catch { return .failure(error) }
    }

    private var hasData: Bool {
        if case .success(.some) = check?.data { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Repository", text: $address, prompt: Text("git@github.com:owner/repo.git"))
                        .onSubmit { Task { await runCheck() } }
                    switch parsed {
                    case let .success(remote):
                        Text(remote.gitURL).font(.caption.monospaced()).foregroundStyle(.secondary)
                    case let .failure(err):
                        Text(err.description).font(.caption).foregroundStyle(.red)
                    case nil:
                        Text("SSH or HTTPS address, or owner/repo for GitHub").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("SSH key", selection: $keyPath) {
                        Text("Default (~/.ssh/config, agent)").tag(String?.none)
                        ForEach(keys, id: \.path) { Text($0.lastPathComponent).tag(Optional($0.path)) }
                    }
                } footer: {
                    Text("With several GitHub accounts on this Mac, pick the key of the account that can see the repository.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Access") {
                    if checking {
                        HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                    } else if let check {
                        CheckRow(result: check.account.map { "Signs in as \($0)" })
                        CheckRow(result: check.data.flatMap { sha in
                            sha.map { .success("beads data found (\($0.prefix(8)))") } ?? .failure(RemoteError.noBeadsData)
                        })
                    } else {
                        Button("Check access") { Task { await runCheck() } }
                            .disabled(parsedRemote == nil)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520)
        .onChange(of: address) { check = nil }
        .onChange(of: keyPath) { check = nil }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(parsedRemote == nil || checking || (check != nil && !hasData))
                    .help(check == nil ? "Adds without checking; you can also check access first" : "")
            }
        }
    }

    private var parsedRemote: RemoteURL? {
        if case let .success(remote) = parsed { return remote }
        return nil
    }

    private func runCheck() async {
        guard parsedRemote != nil else { return }
        checking = true
        defer { checking = false }
        error = nil
        do { check = try await model.checkAccess(address: address, keyPath: keyPath) }
        catch { self.error = "\(error)" }
    }

    private func add() {
        Task {
            do {
                let project = try await model.addProject(address: address, keyPath: keyPath)
                onAdded(project.id)
                dismiss()
            } catch { self.error = "\(error)" }
        }
    }
}

private struct CheckRow: View {
    let result: Result<String, Error>

    var body: some View {
        switch result {
        case let .success(text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failure(error):
            Label { Text(verbatim: String(describing: error)).textSelection(.enabled) } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            .font(.callout)
        }
    }
}
