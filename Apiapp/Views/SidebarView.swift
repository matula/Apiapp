import SwiftUI

/// Saved requests in folders or on the main list, saved responses, and history.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var expandedFolders: Set<UUID> = []
    @State private var requestToDelete: SavedRequest?
    @State private var responseToDelete: SavedResponse?
    @State private var isClearingHistory = false
    /// Refreshes the ages shown on history rows.
    @State private var now = Date()

    private var isSearching: Bool { !search.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search requests", text: $search)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder))
                .padding(.horizontal, 10)

            List {
                savedSection
                if !filteredResponses.isEmpty { responsesSection }
                historySection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
        .confirmationDialog(
            "Delete “\(requestToDelete?.request.displayName ?? "")”?",
            isPresented: Binding(get: { requestToDelete != nil }, set: { if !$0 { requestToDelete = nil } }),
            presenting: requestToDelete
        ) { request in
            Button("Delete", role: .destructive) { model.delete(savedRequest: request.id) }
        } message: { _ in
            Text("The file for this saved request is removed. History isn’t affected.")
        }
        .confirmationDialog(
            "Delete “\(responseToDelete?.name ?? "")”?",
            isPresented: Binding(get: { responseToDelete != nil }, set: { if !$0 { responseToDelete = nil } }),
            presenting: responseToDelete
        ) { response in
            Button("Delete", role: .destructive) { model.delete(savedResponse: response.id) }
        } message: { _ in
            Text("The file for this saved response is removed.")
        }
        .confirmationDialog("Clear history?", isPresented: $isClearingHistory) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Every entry and its file is removed. Saved requests and responses aren’t affected.")
        }
    }

    /// A clickable row, marked while its request is the active tab. This draws its own
    /// selection, the soft grey from the design, rather than the system's accent colour.
    private func row<Menu: View>(
        _ item: SidebarItem,
        method: HTTPMethod,
        title: String,
        trailing: String? = nil,
        @ViewBuilder menu: () -> Menu
    ) -> some View {
        let isSelected = model.activeSidebarItem == item
        return Button {
            model.open(item)
        } label: {
            RequestRow(method: method, title: title, trailing: trailing, isSelected: isSelected)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu(menuItems: menu)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    // MARK: Saved

    private var savedSection: some View {
        Section {
            ForEach(filteredRequests(in: nil)) { saved in
                savedRow(saved)
            }
            ForEach(model.folders) { folder in
                let requests = filteredRequests(in: folder.id)
                if !isSearching || !requests.isEmpty {
                    DisclosureGroup(isExpanded: isExpandedBinding(folder.id)) {
                        ForEach(requests) { saved in
                            savedRow(saved)
                        }
                    } label: {
                        folderLabel(folder)
                    }
                }
            }
        } header: {
            HStack {
                Text("Saved")
                Spacer()
                IconButton(systemName: "plus", help: "New folder") {
                    let folder = model.addFolder()
                    expandedFolders.insert(folder.id)
                    model.renameTarget = .folder(folder.id)
                }
            }
            .padding(.trailing, 6)
        }
    }

    private func folderLabel(_ folder: Folder) -> some View {
        Label {
            Text(folder.name).font(.system(size: 13, weight: .medium))
        } icon: {
            Image(systemName: "folder").foregroundStyle(Theme.secondary)
        }
        .contextMenu {
            Button("Rename…") { model.renameTarget = .folder(folder.id) }
            Divider()
            Button("Delete Folder", role: .destructive) { model.delete(folder: folder.id) }
        }
    }

    private func savedRow(_ saved: SavedRequest) -> some View {
        row(.saved(saved.id), method: saved.request.method, title: saved.request.displayName) {
            Button("Rename…") { model.renameTarget = .request(saved.id) }
            Button("Duplicate") { model.duplicate(savedRequest: saved.id) }
            Menu("Move To") {
                Button("Main List") { model.move(savedRequest: saved.id, to: nil) }
                    .disabled(saved.folderID == nil)
                ForEach(model.folders) { folder in
                    Button(folder.name) { model.move(savedRequest: saved.id, to: folder.id) }
                        .disabled(saved.folderID == folder.id)
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { requestToDelete = saved }
        }
    }

    private func isExpandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { isSearching || expandedFolders.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolders.insert(id)
                } else {
                    expandedFolders.remove(id)
                }
            }
        )
    }

    private func filteredRequests(in folderID: UUID?) -> [SavedRequest] {
        model.requests(in: folderID).filter { matches($0.request) }
    }

    // MARK: Responses

    private var filteredResponses: [SavedResponse] {
        model.savedResponses.filter { !isSearching || matches($0.request) || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var responsesSection: some View {
        Section("Responses") {
            ForEach(filteredResponses) { saved in
                row(.response(saved.id), method: saved.request.method, title: saved.name) {
                    Button("Rename…") { model.renameTarget = .response(saved.id) }
                    Button("Export Body…") { model.exportBody(ofSavedResponse: saved.id) }
                    Divider()
                    Button("Delete…", role: .destructive) { responseToDelete = saved }
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            ForEach(model.history.filter { matches($0.request) }) { entry in
                row(
                    .history(entry.id),
                    method: entry.request.method,
                    title: entry.request.shortPath.isEmpty ? entry.request.url : entry.request.shortPath,
                    trailing: Formatting.age(since: entry.sentAt, now: now)
                ) {
                    Button("Delete", role: .destructive) { model.delete(historyEntry: entry.id) }
                }
            }
        } header: {
            HStack {
                Text("History")
                Spacer()
                if !model.history.isEmpty {
                    Button("Clear…") { isClearingHistory = true }
                        .buttonStyle(.plain)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.trailing, 6)
        }
    }

    private func matches(_ request: RequestDraft) -> Bool {
        guard isSearching else { return true }
        return request.displayName.localizedCaseInsensitiveContains(search)
            || request.url.localizedCaseInsensitiveContains(search)
            || request.method.rawValue.localizedCaseInsensitiveContains(search)
    }
}

struct RequestRow: View {
    var method: HTTPMethod
    var title: String
    var trailing: String?
    var isSelected = false

    var body: some View {
        HStack(spacing: 8) {
            Text(method.rawValue)
                .font(Theme.methodTag)
                .foregroundStyle(Theme.color(for: method))
                .frame(width: 44, alignment: .leading)
            Text(title)
                .font(isSelected ? Theme.bodySemibold : Theme.body)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let trailing {
                Spacer(minLength: 4)
                Text(trailing)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}
