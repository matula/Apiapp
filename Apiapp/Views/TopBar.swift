import SwiftUI

/// The row of open-request pills, the environment menu and Save.
struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(model.tabs) { tab in
                            TabPill(tab: tab, isActive: tab.id == model.activeTabID)
                                .id(tab.id)
                        }
                        IconButton(systemName: "plus", size: 30, help: "New request") {
                            model.newTab()
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: model.activeTabID, initial: true) {
                    proxy.scrollTo(model.activeTabID)
                }
            }

            EnvironmentMenu()
            Button("Save") { model.saveActiveTab() }
                .buttonStyle(OutlineButtonStyle(height: 30, cornerRadius: 15, horizontalPadding: 14))
                .help("Save this request (⌘S)")
        }
    }
}

private struct TabPill: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.select(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Text(tab.draft.method.rawValue)
                        .font(Theme.methodTag)
                        .foregroundStyle(Theme.color(for: tab.draft.method))
                    Text(tab.draft.displayName)
                        .font(isActive ? Theme.bodySemibold : Theme.body)
                        .foregroundStyle(isActive ? Theme.ink : Theme.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 170, alignment: .leading)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive || isHovering || tab.isDirty {
                Button {
                    model.requestClose(tab.id)
                } label: {
                    Group {
                        if tab.isDirty && !isHovering {
                            Circle().fill(Theme.secondary).frame(width: 7, height: 7)
                        } else {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.isDirty ? "Unsaved changes. Close tab" : "Close tab")
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(isActive ? Theme.track : (isHovering ? Theme.hover : .clear), in: Capsule())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close") { model.requestClose(tab.id) }
        }
    }
}

private struct EnvironmentMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.selectEnvironment(nil)
            } label: {
                checkmarked("No Environment", isSelected: model.activeEnvironmentID == nil)
            }
            if !model.environments.isEmpty { Divider() }
            ForEach(model.environments) { environment in
                Button {
                    model.selectEnvironment(environment.id)
                } label: {
                    checkmarked(environment.name, isSelected: environment.id == model.activeEnvironmentID)
                }
            }
            Divider()
            Button("Manage Environments…") { model.isEnvironmentEditorPresented = true }
        } label: {
            HStack(spacing: 6) {
                Text(model.activeEnvironment?.name ?? "No Environment")
                Chevron()
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(OutlineButtonStyle(height: 30, cornerRadius: 15, horizontalPadding: 12))
        .fixedSize()
        .accessibilityLabel("Environment")
    }

    @ViewBuilder private func checkmarked(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// The method dropdown, URL field and Send button.
struct URLBar: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab
    @FocusState private var isURLFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                MethodMenu(tab: tab)
                Rectangle().fill(Theme.divider).frame(width: 1, height: 36)
                TextField("https://api.example.com/v1/users", text: urlBinding)
                    .textFieldStyle(.plain)
                    .font(Theme.urlMono)
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                    .focused($isURLFocused)
                    .padding(.horizontal, 12)
                    .onSubmit { model.send(tab.id) }
                    .accessibilityLabel("Request URL")
            }
            .frame(height: 38)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.urlBorder))

            Button {
                model.send(tab.id)
            } label: {
                HStack(spacing: 8) {
                    Text(tab.isSending ? "Cancel" : "Send")
                        .font(Theme.bodySemibold)
                    if !tab.isSending {
                        Text("⌘↩").font(.system(size: 12))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .frame(minWidth: 96)
                .background(tab.isSending ? Theme.secondary : Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.isSending ? "Cancel" : "Send")
        }
        .onChange(of: model.urlFocusRequest) { isURLFocused = true }
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { tab.draft.url },
            set: { url in model.update(tab.id) { $0.draft.setURL(url) } }
        )
    }
}

private struct MethodMenu: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab

    var body: some View {
        Menu {
            ForEach(HTTPMethod.allCases) { method in
                Button(method.rawValue) {
                    model.update(tab.id) { $0.draft.method = method }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(tab.draft.method.rawValue)
                    .font(Theme.bodySemibold)
                    .foregroundStyle(Theme.color(for: tab.draft.method))
                Chevron()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Method: \(tab.draft.method.rawValue)")
    }
}
