import SwiftUI

/// Names a new saved request and picks where it goes.
struct SaveRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tabID: UUID

    @State private var name = ""
    @State private var folderID: UUID?
    @State private var isAddingFolder = false
    @State private var newFolderName = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        model.save(tabID: tabID, name: trimmedName, folderID: folderID)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Request").font(.headline)

            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .labelsHidden()
                    .onSubmit(save)
            }
            LabeledContent("Save to") {
                HStack {
                    Picker("Save to", selection: $folderID) {
                        Text("Main List").tag(UUID?.none)
                        if !model.folders.isEmpty { Divider() }
                        ForEach(model.folders) { folder in
                            Text(folder.name).tag(UUID?.some(folder.id))
                        }
                    }
                    .labelsHidden()
                    Button("New Folder…") { isAddingFolder = true }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = model.tabs.first { $0.id == tabID }?.draft.displayName ?? ""
        }
        .alert("New Folder", isPresented: $isAddingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { folderID = model.addFolder(named: name).id }
                newFolderName = ""
            }
        }
    }
}

/// Renames a folder, saved request or saved response.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: RenameTarget
    @State private var name = ""

    private func rename() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.rename(target, to: name)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename").font(.headline)
            TextField("Name", text: $name)
                .labelsHidden()
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = model.currentName(of: target) }
    }
}

/// ⌘K: jump to any saved request or history entry by typing.
struct QuickOpenSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    private struct Result: Identifiable {
        var item: SidebarItem
        var request: RequestDraft
        var detail: String
        var id: SidebarItem { item }
    }

    private static let limit = 40

    private var results: [Result] {
        let saved = model.savedRequests.map { Result(item: .saved($0.id), request: $0.request, detail: "Saved") }
        let history = model.history.map { entry in
            Result(item: .history(entry.id), request: entry.request, detail: Formatting.age(since: entry.sentAt))
        }
        let all = saved + history
        let matches = query.isEmpty ? all : all.filter { result in
            result.request.displayName.localizedCaseInsensitiveContains(query)
                || result.request.url.localizedCaseInsensitiveContains(query)
                || result.request.method.rawValue.localizedCaseInsensitiveContains(query)
        }
        return Array(matches.prefix(Self.limit))
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField("Find a request", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .autocorrectionDisabled()
                .focused($isFieldFocused)
                .padding(14)
                .onSubmit { open(results) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { result in
                            Button {
                                model.open(result.item)
                                dismiss()
                            } label: {
                                RequestRow(method: result.request.method, title: result.request.displayName, trailing: result.detail)
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .background(isHighlighted(result, in: results) ? Theme.track : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) {
                    if results.indices.contains(highlighted) { proxy.scrollTo(results[highlighted].id) }
                }
            }
            .frame(height: 320)
            .overlay {
                if results.isEmpty {
                    Text(query.isEmpty ? "Saved and sent requests will show up here." : "No matches")
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(width: 520)
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onExitCommand { dismiss() }
    }

    private func isHighlighted(_ result: Result, in results: [Result]) -> Bool {
        results.indices.contains(highlighted) && results[highlighted].id == result.id
    }

    private func open(_ results: [Result]) {
        guard results.indices.contains(highlighted) else { return }
        model.open(results[highlighted].item)
        dismiss()
    }
}

/// Edits environments and their variables, applied when Done is pressed.
struct EnvironmentEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var environments: [RequestEnvironment] = []
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(environments) { environment in
                            Text(environment.name).tag(environment.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    Divider()
                    HStack(spacing: 2) {
                        IconButton(systemName: "plus", size: 24, help: "Add environment") {
                            let environment = RequestEnvironment(name: "New Environment")
                            environments.append(environment)
                            selectedID = environment.id
                        }
                        IconButton(systemName: "minus", size: 24, help: "Delete environment") {
                            environments.removeAll { $0.id == selectedID }
                            selectedID = environments.first?.id
                        }
                        .disabled(selectedID == nil)
                        Spacer()
                    }
                    .padding(6)
                }
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)

                detail.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Use a variable anywhere as {{name}}. Secret values stay in your Keychain.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    model.updateEnvironments(environments)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 460)
        .onAppear {
            environments = model.environments
            selectedID = model.activeEnvironmentID ?? environments.first?.id
        }
    }

    @ViewBuilder private var detail: some View {
        if let index = environments.firstIndex(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Environment name", text: $environments[index].name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                PaneFrame {
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 14, height: 1)
                        columnTitle("Name")
                        columnTitle("Value")
                        Text("Secret").frame(width: 44)
                        Color.clear.frame(width: 20, height: 1)
                    }
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    Divider().overlay(Theme.hairline)
                    GrowingRows(
                        rows: $environments[index].variables,
                        isEmpty: { $0.key.isEmpty && $0.value.isEmpty },
                        makeRow: { Variable() }
                    ) { variable, onRemove in
                        VariableRow(variable: variable, onRemove: onRemove)
                    }
                    .id(environments[index].id)
                }
            }
            .padding(14)
        } else {
            Text("Add an environment to get started.")
                .font(Theme.body)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VariableRow: View {
    @Binding var variable: Variable
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Include", isOn: $variable.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(onRemove == nil)
                .opacity(onRemove == nil ? 0 : 1)
            CellField(placeholder: "name", text: $variable.key)
            Group {
                if variable.isSecret {
                    SecureField("value", text: $variable.value)
                        .textFieldStyle(.plain)
                        .font(Theme.mono)
                } else {
                    CellField(placeholder: "value", text: $variable.value)
                }
            }
            .frame(maxWidth: .infinity)
            Toggle("Secret", isOn: $variable.isSecret)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 44)
            RemoveRowButton(action: onRemove)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .opacity(variable.isEnabled ? 1 : 0.5)
    }
}
