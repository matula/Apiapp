import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 380)
        } detail: {
            if let tab = model.activeTab {
                MainPane(tab: tab, isSidebarHidden: columnVisibility == .detailOnly)
            } else if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .sheet(item: $model.saveTarget) { target in
            SaveRequestSheet(tabID: target.id)
        }
        .sheet(item: $model.renameTarget) { target in
            RenameSheet(target: target)
        }
        .sheet(isPresented: $model.isQuickOpenPresented) {
            QuickOpenSheet()
        }
        .sheet(isPresented: $model.isEnvironmentEditorPresented) {
            EnvironmentEditorSheet()
        }
        .alert("Save your changes?", isPresented: closeAlertBinding) {
            Button("Save") {
                if let id = model.tabPendingClose { saveThenClose(id) }
            }
            Button("Don’t Save", role: .destructive) {
                if let id = model.tabPendingClose { model.close(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closing this tab loses edits you haven’t saved.")
        }
        .alert("Something went wrong", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private func saveThenClose(_ id: UUID) {
        model.select(id)
        if model.activeTab?.savedRequestID != nil {
            model.saveActiveTab()
            model.close(id)
        } else {
            // A new request needs a name first, so the tab stays open for that.
            model.saveActiveTab()
        }
    }

    private var closeAlertBinding: Binding<Bool> {
        Binding(
            get: { model.tabPendingClose != nil },
            set: { if !$0 { model.tabPendingClose = nil } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}

/// The right-hand side: tabs, URL, request and response.
private struct MainPane: View {
    private static let minimumRequestHeight = 150.0
    private static let minimumResponseHeight = 170.0
    /// Room taken by the top bar and URL row.
    private static let chromeHeight = 120.0
    /// Clears the traffic lights and sidebar button, which float here when the sidebar is hidden.
    private static let leadingInsetWithoutSidebar = 150.0

    let tab: RequestTab
    let isSidebarHidden: Bool
    @AppStorage("requestPaneHeight") private var requestHeight = 296.0

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.height - Self.chromeHeight
            let maximum = max(Self.minimumRequestHeight, available - Self.minimumResponseHeight)
            VStack(spacing: 0) {
                TopBar()
                    .padding(.top, 10)
                    .padding(.leading, isSidebarHidden ? Self.leadingInsetWithoutSidebar : 12)
                    .padding(.trailing, 16)
                URLBar(tab: tab)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                RequestPane(tab: tab)
                    .frame(height: min(requestHeight, maximum))
                PaneDivider(height: $requestHeight, range: Self.minimumRequestHeight...maximum)
                ResponsePane(tab: tab)
            }
        }
        .background(Theme.window)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .title)
    }
}
