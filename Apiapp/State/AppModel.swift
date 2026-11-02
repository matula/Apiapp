import AppKit
import Observation
import Synchronization
import SwiftUI

enum SidebarItem: Hashable {
    case saved(UUID)
    case history(UUID)
    case response(UUID)
}

enum RenameTarget: Identifiable {
    case folder(UUID)
    case request(UUID)
    case response(UUID)

    var id: UUID {
        switch self {
        case .folder(let id), .request(let id), .response(let id): id
        }
    }
}

/// A sheet's request to save a particular tab.
struct SaveTarget: Identifiable {
    var id: UUID
}

@MainActor
@Observable
final class AppModel {
    static let historyLimit = 500

    var tabs: [RequestTab] = []
    var activeTabID: UUID?
    var folders: [Folder] = []
    var savedRequests: [SavedRequest] = []
    var history: [HistoryEntry] = []
    var savedResponses: [SavedResponse] = []
    var environments: [RequestEnvironment] = []
    var activeEnvironmentID: UUID?
    /// True until everything on disk has been read in.
    private(set) var isLoading = true

    var alertMessage: String?
    var saveTarget: SaveTarget?
    var renameTarget: RenameTarget?
    var tabPendingClose: UUID?
    var isQuickOpenPresented = false
    var isEnvironmentEditorPresented = false
    /// Goes up each time ⌘L is pressed; the URL field watches it.
    var urlFocusRequest = 0

    private let store: Store
    private let vault: SecretVault
    private let runner: RequestRunner
    private let workspaceWriter: WorkspaceWriter
    @ObservationIgnored private var sendTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var workspaceSave: Task<Void, Never>?
    @ObservationIgnored private var workspaceVersion = 0

    /// Nothing is read from disk until `load()` is called.
    init(store: Store, vault: SecretVault, runner: RequestRunner = RequestRunner()) {
        self.store = store
        self.vault = vault
        self.runner = runner
        workspaceWriter = WorkspaceWriter(store: store)
    }

    /// The app as the user runs it: Keychain secrets and data in Application Support.
    static func live() -> AppModel {
        var startupProblem: String?
        let vault: SecretVault
        do {
            let storage: SecretStorage = Store.isolatedRoot == nil ? KeychainSecretStorage() : InMemorySecretStorage()
            vault = try SecretVault(storage: storage)
        } catch {
            // Carrying on with the real Keychain could overwrite secrets we failed to read.
            startupProblem = "\(error.localizedDescription) Tokens and passwords won’t be available, and new ones won’t be kept, until that’s put right and the app is reopened."
            vault = try! SecretVault(storage: InMemorySecretStorage())
        }
        let model = AppModel(store: Store(root: Store.defaultRoot), vault: vault)
        if let startupProblem { model.alertMessage = startupProblem }
        Task { await model.load() }
        return model
    }

    // MARK: Computed state

    var activeTab: RequestTab? {
        tabs.first { $0.id == activeTabID }
    }

    var activeEnvironment: RequestEnvironment? {
        environments.first { $0.id == activeEnvironmentID }
    }

    var activeSidebarItem: SidebarItem? {
        guard let tab = activeTab else { return nil }
        if let id = tab.savedRequestID { return .saved(id) }
        if let id = tab.savedResponseID { return .response(id) }
        if let id = tab.historyEntryID { return .history(id) }
        return nil
    }

    private func index(of tabID: UUID?) -> Int? {
        tabs.firstIndex { $0.id == tabID }
    }

    func draftBinding(_ tabID: UUID) -> Binding<RequestDraft> {
        Binding(
            get: { [weak self] in
                self?.tabs.first { $0.id == tabID }?.draft ?? RequestDraft()
            },
            set: { [weak self] newValue in
                self?.update(tabID) { $0.draft = newValue }
            }
        )
    }

    func update(_ tabID: UUID, _ change: (inout RequestTab) -> Void) {
        guard let index = index(of: tabID) else { return }
        let before = tabs[index]
        change(&tabs[index])
        // Pane choices and notices aren't kept in the workspace file, so they aren't worth a write.
        if tabs[index].keptStateDiffers(from: before) { scheduleWorkspaceSave() }
    }

    // MARK: Tabs

    func newTab() {
        open(RequestTab(draft: .blank()))
    }

    func select(_ tabID: UUID) {
        activeTabID = tabID
        scheduleWorkspaceSave()
    }

    func selectAdjacentTab(offset: Int) {
        guard let index = index(of: activeTabID), !tabs.isEmpty else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    /// Asks first if closing would lose edits.
    func requestClose(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tab.isDirty {
            tabPendingClose = tabID
        } else {
            close(tabID)
        }
    }

    func close(_ tabID: UUID) {
        guard let index = index(of: tabID) else { return }
        sendTasks[tabID]?.cancel()
        tabs.remove(at: index)
        if activeTabID == tabID {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { newTab() }
        attempt { try vault.remove([tabID]) }
        scheduleWorkspaceSave()
    }

    private func open(_ tab: RequestTab) {
        tabs.append(tab)
        activeTabID = tab.id
        scheduleWorkspaceSave()
    }

    func open(_ item: SidebarItem) {
        switch item {
        case .saved(let id): openSaved(id)
        case .history(let id): openHistory(id)
        case .response(let id): openSavedResponse(id)
        }
    }

    func openSaved(_ id: UUID) {
        if let tab = tabs.first(where: { $0.savedRequestID == id }) {
            select(tab.id)
        } else if let saved = savedRequests.first(where: { $0.id == id }) {
            open(RequestTab(draft: saved.request, savedRequestID: id))
        }
    }

    func openHistory(_ id: UUID) {
        if let tab = tabs.first(where: { $0.historyEntryID == id && $0.savedRequestID == nil }) {
            select(tab.id)
        } else if let entry = history.first(where: { $0.id == id }) {
            open(RequestTab(draft: entry.request, historyEntryID: id))
        }
    }

    func openSavedResponse(_ id: UUID) {
        if let tab = tabs.first(where: { $0.savedResponseID == id }) {
            select(tab.id)
        } else if let saved = savedResponses.first(where: { $0.id == id }) {
            let tab = RequestTab(draft: saved.request, savedResponseID: id)
            open(tab)
            // Getting a big body ready for the viewer takes a moment, so it's done away from
            // the main thread, and only shown if nothing else has happened to the tab since.
            let snapshot = saved.response
            Task { [weak self] in
                let display = await Task.detached(priority: .userInitiated) { ResponseDisplay(snapshot) }.value
                guard let self, let index = self.index(of: tab.id), self.tabs[index].phase == .idle else { return }
                self.tabs[index].phase = .finished(display)
            }
        }
    }

    // MARK: Sending

    func sendActiveTab() {
        guard let activeTabID else { return }
        send(activeTabID)
    }

    func cancelActiveTab() {
        guard let activeTabID else { return }
        sendTasks[activeTabID]?.cancel()
    }

    func send(_ tabID: UUID) {
        guard let index = index(of: tabID) else { return }
        if tabs[index].isSending {
            sendTasks[tabID]?.cancel()
            return
        }
        let draft = tabs[index].draft
        let variables = activeEnvironment?.resolvedValues ?? [:]
        let plan: RequestBuilder.Plan
        do {
            plan = try RequestBuilder.plan(draft, variables: variables)
        } catch {
            tabs[index].phase = .failed(error.localizedDescription)
            return
        }
        let credentialHeaders = RequestBuilder.credentialHeaderNames(for: draft, variables: variables)

        tabs[index].phase = .sending
        // Whatever comes back isn't the response that was saved, so it can be saved itself.
        tabs[index].savedResponseID = nil
        let entry = record(draft)
        // Once it's in history, closing an unsaved tab loses nothing.
        if tabs[index].savedRequestID == nil { tabs[index].baseline = draft }

        sendTasks[tabID] = Task { [weak self, runner] in
            let phase: RequestPhase
            do {
                // Upload files are read here rather than on the main thread.
                let request = try await Task.detached(priority: .userInitiated) { try RequestBuilder.assemble(plan) }.value
                try Task.checkCancellation()
                phase = .finished(try await runner.send(request, credentialHeaders: credentialHeaders))
            } catch is CancellationError {
                phase = .cancelled
            } catch let error as URLError where error.code == .cancelled {
                phase = .cancelled
            } catch {
                phase = .failed(error.localizedDescription)
            }
            self?.finish(tabID: tabID, entryID: entry.id, phase: phase)
        }
    }

    private func finish(tabID: UUID, entryID: UUID, phase: RequestPhase) {
        sendTasks[tabID] = nil
        if let index = index(of: tabID) { tabs[index].phase = phase }
        guard let index = history.firstIndex(where: { $0.id == entryID }),
              case .finished(let display) = phase else { return }
        history[index].statusCode = display.snapshot.statusCode
        attempt { try store.save(history[index]) }
    }

    @discardableResult
    private func record(_ draft: RequestDraft) -> HistoryEntry {
        let entry = HistoryEntry(request: draft)
        history.insert(entry, at: 0)
        attempt {
            try vault.set(draft.auth.secrets, for: entry.id)
            try store.save(entry)
        }
        if history.count > Self.historyLimit {
            let removed = history[Self.historyLimit...].map(\.id)
            history.removeLast(history.count - Self.historyLimit)
            attempt {
                try removed.forEach(store.delete(historyEntry:))
                try vault.remove(removed)
            }
        }
        return entry
    }

    // MARK: Editing

    func formatActiveBody() {
        guard let activeTabID else { return }
        update(activeTabID) { tab in
            do {
                tab.draft.bodyText = try JSONFormatter.format(tab.draft.bodyText)
                tab.bodyNotice = nil
            } catch {
                tab.bodyNotice = error.localizedDescription
            }
        }
    }

    // MARK: Saving requests

    /// ⌘S: updates the saved request, or asks where to keep a new one.
    func saveActiveTab() {
        guard let tab = activeTab else { return }
        guard let savedID = tab.savedRequestID else {
            saveTarget = SaveTarget(id: tab.id)
            return
        }
        guard let index = savedRequests.firstIndex(where: { $0.id == savedID }) else { return }
        savedRequests[index].request = tab.draft
        savedRequests[index].updatedAt = Date()
        write(savedRequests[index])
        update(tab.id) { $0.baseline = $0.draft }
    }

    func save(tabID: UUID, name: String, folderID: UUID?) {
        guard let tabIndex = index(of: tabID) else { return }
        var draft = tabs[tabIndex].draft
        draft.name = name
        let saved = SavedRequest(folderID: folderID, request: draft)
        savedRequests.append(saved)
        write(saved)
        update(tabID) { tab in
            tab.draft = draft
            tab.baseline = draft
            tab.savedRequestID = saved.id
            tab.historyEntryID = nil
            tab.savedResponseID = nil
        }
    }

    private func write(_ saved: SavedRequest) {
        attempt {
            try vault.set(saved.request.auth.secrets, for: saved.id)
            try store.save(saved)
        }
    }

    func requests(in folderID: UUID?) -> [SavedRequest] {
        savedRequests
            .filter { shownFolderID(of: $0) == folderID }
            .sorted { $0.request.displayName.localizedStandardCompare($1.request.displayName) == .orderedAscending }
    }

    /// A request whose folder is gone, say because folders.json couldn't be read, shows on
    /// the main list rather than nowhere. Its file keeps the folder until it's moved or saved.
    private func shownFolderID(of saved: SavedRequest) -> UUID? {
        guard let id = saved.folderID, folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func duplicate(savedRequest id: UUID) {
        guard var copy = savedRequests.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.request.name = "\(copy.request.displayName) copy"
        copy.updatedAt = Date()
        savedRequests.append(copy)
        write(copy)
    }

    func move(savedRequest id: UUID, to folderID: UUID?) {
        guard let index = savedRequests.firstIndex(where: { $0.id == id }) else { return }
        savedRequests[index].folderID = folderID
        write(savedRequests[index])
    }

    func delete(savedRequest id: UUID) {
        savedRequests.removeAll { $0.id == id }
        attempt {
            try store.delete(request: id)
            try vault.remove([id])
        }
        // The tab stays open as an unsaved request, so nothing in it is lost.
        for index in tabs.indices where tabs[index].savedRequestID == id {
            tabs[index].savedRequestID = nil
        }
        scheduleWorkspaceSave()
    }

    // MARK: Folders

    @discardableResult
    func addFolder(named name: String = "New Folder") -> Folder {
        let folder = Folder(name: name)
        folders.append(folder)
        saveFolders()
        return folder
    }

    /// Requests in the folder move to the main list rather than being deleted.
    func delete(folder id: UUID) {
        for index in savedRequests.indices where savedRequests[index].folderID == id {
            savedRequests[index].folderID = nil
            write(savedRequests[index])
        }
        folders.removeAll { $0.id == id }
        saveFolders()
    }

    private func saveFolders() {
        attempt { try store.save(folders: folders) }
    }

    // MARK: Renaming

    func currentName(of target: RenameTarget) -> String {
        switch target {
        case .folder(let id): folders.first { $0.id == id }?.name ?? ""
        case .request(let id): savedRequests.first { $0.id == id }?.request.displayName ?? ""
        case .response(let id): savedResponses.first { $0.id == id }?.name ?? ""
        }
    }

    func rename(_ target: RenameTarget, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch target {
        case .folder(let id):
            guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
            folders[index].name = name
            saveFolders()
        case .request(let id):
            guard let index = savedRequests.firstIndex(where: { $0.id == id }) else { return }
            savedRequests[index].request.name = name
            write(savedRequests[index])
            for tabIndex in tabs.indices where tabs[tabIndex].savedRequestID == id {
                tabs[tabIndex].draft.name = name
                tabs[tabIndex].baseline.name = name
            }
            scheduleWorkspaceSave()
        case .response(let id):
            guard let index = savedResponses.firstIndex(where: { $0.id == id }) else { return }
            savedResponses[index].name = name
            write(savedResponses[index])
        }
    }

    // MARK: History

    func delete(historyEntry id: UUID) {
        history.removeAll { $0.id == id }
        attempt {
            try store.delete(historyEntry: id)
            try vault.remove([id])
        }
    }

    func clearHistory() {
        let ids = history.map(\.id)
        history.removeAll()
        attempt {
            try ids.forEach(store.delete(historyEntry:))
            try vault.remove(ids)
        }
    }

    // MARK: Saved responses

    func saveActiveResponse() {
        guard let tab = activeTab, let display = tab.response else { return }
        let snapshot = display.snapshot
        let name = "\(tab.draft.displayName) · \(snapshot.statusCode)"
        let saved = SavedResponse(name: name, request: tab.draft, response: snapshot)
        savedResponses.insert(saved, at: 0)
        write(saved)
        update(tab.id) { $0.savedResponseID = saved.id }
    }

    private func write(_ saved: SavedResponse) {
        attempt {
            try vault.set(saved.request.auth.secrets, for: saved.id)
            try store.save(saved)
        }
    }

    func delete(savedResponse id: UUID) {
        savedResponses.removeAll { $0.id == id }
        attempt {
            try store.delete(response: id)
            try vault.remove([id])
        }
        for index in tabs.indices where tabs[index].savedResponseID == id {
            tabs[index].savedResponseID = nil
        }
    }

    /// Writes the response body to a file the user picks.
    func exportBody(ofSavedResponse id: UUID) {
        guard let saved = savedResponses.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = saved.response.contentType?.contains("json") == true ? "response.json" : "response.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try saved.response.body.write(to: url, options: .atomic) }
    }

    // MARK: Environments

    func selectEnvironment(_ id: UUID?) {
        activeEnvironmentID = id
        scheduleWorkspaceSave()
    }

    func updateEnvironments(_ updated: [RequestEnvironment]) {
        let previousVariables = environments.flatMap(\.variables).map(\.id)
        environments = updated
        if !updated.contains(where: { $0.id == activeEnvironmentID }) {
            activeEnvironmentID = updated.first?.id
        }
        attempt {
            let currentVariables = updated.flatMap(\.variables)
            for variable in currentVariables {
                try vault.set(variable.isSecret && !variable.value.isEmpty ? ["value": variable.value] : [:], for: variable.id)
            }
            try vault.remove(previousVariables.filter { id in !currentVariables.contains { $0.id == id } })
            try store.save(environments: updated)
        }
        scheduleWorkspaceSave()
    }

    // MARK: Loading and persistence

    /// Reads everything from disk away from the main thread, then takes it in here.
    /// Anything done in the meantime, such as opening a tab, is kept.
    func load() async {
        isLoading = true
        let store = store
        let result = await Task.detached(priority: .userInitiated) { Result { try store.load() } }.value
        switch result {
        case .success(let snapshot): take(snapshot)
        case .failure(let error): report(error.localizedDescription)
        }
        if tabs.isEmpty { newTab() }
        if activeTab == nil { activeTabID = tabs.first?.id }
        isLoading = false
    }

    private func take(_ snapshot: LibrarySnapshot) {
        folders = snapshot.folders
        savedRequests = snapshot.requests.map { saved in
            var saved = saved
            saved.request.auth.apply(secrets: vault.values(for: saved.id))
            return saved
        }
        let earlier = snapshot.history.map { entry in
            var entry = entry
            entry.request.auth.apply(secrets: vault.values(for: entry.id))
            return entry
        }
        history = (history + earlier).sorted { $0.sentAt > $1.sentAt }
        savedResponses = snapshot.responses
            .map { response in
                var response = response
                response.request.auth.apply(secrets: vault.values(for: response.id))
                return response
            }
            .sorted { $0.savedAt > $1.savedAt }
        environments = snapshot.environments?.map(restoringSecrets) ?? [Self.starterEnvironment()]
        activeEnvironmentID = snapshot.workspace.activeEnvironmentID ?? environments.first?.id
        if !environments.contains(where: { $0.id == activeEnvironmentID }) {
            activeEnvironmentID = environments.first?.id
        }
        tabs = snapshot.workspace.tabs.map(restoreTab) + tabs
        if activeTab == nil { activeTabID = snapshot.workspace.activeTabID }
        if !snapshot.unreadableFiles.isEmpty {
            let files = snapshot.unreadableFiles.joined(separator: ", ")
            report("These files couldn’t be read and were skipped: \(files). Copies ending in .broken were kept beside them.")
        }
        // The starter environment is written out only when the file is truly missing. One
        // that exists but couldn't be read is left for the user to fix.
        if snapshot.environments == nil, snapshot.isComplete { attempt { try store.save(environments: environments) } }
        // After a partial read, owners that are still on disk look as if they're gone, and
        // pruning would throw their secrets away for good.
        if snapshot.isComplete { pruneSecrets() }
    }

    private static func starterEnvironment() -> RequestEnvironment {
        RequestEnvironment(name: "Local", variables: [Variable(key: "baseUrl", value: "http://localhost:3000")])
    }

    private func restoringSecrets(in environment: RequestEnvironment) -> RequestEnvironment {
        var environment = environment
        for index in environment.variables.indices where environment.variables[index].isSecret {
            environment.variables[index].value = vault.values(for: environment.variables[index].id)["value"] ?? ""
        }
        return environment
    }

    private func restoreTab(_ state: WorkspaceState.Tab) -> RequestTab {
        var draft = state.draft
        var baseline = state.baseline
        let secrets = vault.values(for: state.id)
        draft.auth.apply(secrets: secrets)
        baseline.auth.apply(secrets: secrets)
        var savedRequestID = state.savedRequestID
        if let id = savedRequestID {
            if let saved = savedRequests.first(where: { $0.id == id }) {
                baseline = saved.request
            } else {
                savedRequestID = nil
            }
        }
        return RequestTab(
            id: state.id,
            draft: draft,
            baseline: baseline,
            savedRequestID: savedRequestID,
            historyEntryID: state.historyEntryID
        )
    }

    /// Clears out secrets that nothing refers to any more.
    private func pruneSecrets() {
        var owners = Set(savedRequests.map(\.id))
        owners.formUnion(history.map(\.id))
        owners.formUnion(savedResponses.map(\.id))
        owners.formUnion(tabs.map(\.id))
        owners.formUnion(environments.flatMap(\.variables).map(\.id))
        attempt { try vault.prune(keeping: owners) }
    }

    private func scheduleWorkspaceSave() {
        workspaceSave?.cancel()
        workspaceSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveWorkspace(inBackground: true)
        }
    }

    /// Keeps the tabs' secrets and writes the workspace file. The file holds every open
    /// body twice, so it's normally written away from the main thread. `inBackground: false`
    /// finishes the write before returning, for when the app is about to quit.
    func saveWorkspace(inBackground: Bool = false) {
        workspaceSave?.cancel()
        attempt {
            for tab in tabs { try vault.set(tab.draft.auth.secrets, for: tab.id) }
        }
        workspaceVersion += 1
        let version = workspaceVersion
        let state = WorkspaceState(
            tabs: tabs.map {
                WorkspaceState.Tab(
                    id: $0.id,
                    draft: $0.draft,
                    baseline: $0.baseline,
                    savedRequestID: $0.savedRequestID,
                    historyEntryID: $0.historyEntryID
                )
            },
            activeTabID: activeTabID,
            activeEnvironmentID: activeEnvironmentID
        )
        let writer = workspaceWriter
        if inBackground {
            Task.detached(priority: .utility) { [weak self] in
                do {
                    try writer.write(state, version: version)
                } catch {
                    await self?.report(error.localizedDescription)
                }
            }
        } else {
            attempt { try writer.write(state, version: version) }
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Shows a problem after any that's already waiting to be seen.
    private func report(_ message: String) {
        guard alertMessage?.contains(message) != true else { return }
        alertMessage = [alertMessage, message].compactMap { $0 }.joined(separator: "\n\n")
    }
}

/// Writes the workspace file from any thread. Each write carries a version, and one that
/// was queued earlier never lands over a newer one.
final class WorkspaceWriter: Sendable {
    private let store: Store
    private let lastWritten = Mutex(0)

    init(store: Store) {
        self.store = store
    }

    func write(_ state: WorkspaceState, version: Int) throws {
        try lastWritten.withLock { last in
            guard version > last else { return }
            try store.save(workspace: state)
            last = version
        }
    }
}
