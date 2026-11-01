import SwiftUI

struct AuthEditor: View {
    @Binding var auth: AuthConfig

    var body: some View {
        PaneFrame {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AuthRow("Type") {
                        Picker("Type", selection: $auth.kind) {
                            ForEach(AuthConfig.Kind.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    switch auth.kind {
                    case .none:
                        Text("This request doesn’t send any credentials.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.secondary)
                    case .bearer:
                        AuthRow("Token") { SecretField(placeholder: "Token or {{variable}}", text: $auth.token) }
                        storageNote
                    case .basic:
                        AuthRow("Username") { PlainField(placeholder: "Username", text: $auth.username) }
                        AuthRow("Password") { SecretField(placeholder: "Password or {{variable}}", text: $auth.password) }
                        storageNote
                    case .apiKey:
                        AuthRow("Name") { PlainField(placeholder: "X-API-Key", text: $auth.apiKeyName) }
                        AuthRow("Value") { SecretField(placeholder: "Key or {{variable}}", text: $auth.apiKeyValue) }
                        AuthRow("Add to") {
                            Picker("Add to", selection: $auth.apiKeyPlacement) {
                                ForEach(AuthConfig.Placement.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        storageNote
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var storageNote: some View {
        Text("Kept in your Keychain, not in saved files.")
            .font(Theme.caption)
            .foregroundStyle(Theme.secondary)
            .padding(.leading, 86)
    }
}

private struct AuthRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(Theme.secondary)
                .frame(width: 76, alignment: .leading)
            content
        }
    }
}

private struct PlainField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(maxWidth: 420, minHeight: 28)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder))
    }
}

/// Hidden by default, with an eye button to show what's in it.
private struct SecretField: View {
    var placeholder: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .autocorrectionDisabled()

            IconButton(systemName: isRevealed ? "eye.slash" : "eye", size: 24, help: isRevealed ? "Hide" : "Show") {
                isRevealed.toggle()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxWidth: 420, minHeight: 28)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder))
    }
}
