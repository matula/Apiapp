import AppKit
import SwiftUI

@main
struct ApiappApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Apiapp", id: "main") {
            ContentView()
                .environment(appDelegate.model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(model: appDelegate.model) }
    }
}

/// Owns the model, so that the last save can happen here when the app quits. A view's
/// notification handler might already be gone by then.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.live()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.saveWorkspace()
        return .terminateNow
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Request") { model.newTab() }
                .keyboardShortcut("n")
            Button("Quick Open…") { model.isQuickOpenPresented = true }
                .keyboardShortcut("k")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveActiveTab() }
                .keyboardShortcut("s")
            Divider()
            Button("Close Tab") {
                if let id = model.activeTabID { model.requestClose(id) }
            }
            .keyboardShortcut("w")
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { FindCommand.showFindBar() }
                .keyboardShortcut("f")
        }

        CommandMenu("Request") {
            Button("Send") { model.sendActiveTab() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Cancel") { model.cancelActiveTab() }
                .keyboardShortcut(".")
            Divider()
            Button("Format JSON") { model.formatActiveBody() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Go to URL") { model.urlFocusRequest += 1 }
                .keyboardShortcut("l")
            Divider()
            Button("Next Tab") { model.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
