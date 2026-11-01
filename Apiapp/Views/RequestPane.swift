import SwiftUI

/// Params, Headers, Auth and Body.
struct RequestPane: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab

    private var draft: Binding<RequestDraft> { model.draftBinding(tab.id) }

    private var enabledHeaders: Int {
        tab.draft.headers.filter { $0.isEnabled && !$0.key.isEmpty }.count
    }

    private var enabledParams: Int {
        tab.draft.params.filter { $0.isEnabled && !$0.key.isEmpty }.count
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                SegmentedBar(selection: paneBinding, items: [
                    .init(value: .params, title: enabledParams > 0 ? "Params \(enabledParams)" : "Params"),
                    .init(value: .headers, title: enabledHeaders > 0 ? "Headers \(enabledHeaders)" : "Headers"),
                    .init(value: .auth, title: tab.draft.auth.kind == .none ? "Auth" : "Auth •"),
                    .init(value: .body, title: "Body"),
                ])
                Spacer()
                if tab.requestPane == .body {
                    BodyTypeMenu(tab: tab)
                    if tab.draft.bodyType == .json {
                        Button("Format JSON") { model.formatActiveBody() }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(tab.draft.bodyText.isEmpty)
                    }
                }
            }

            switch tab.requestPane {
            case .params:
                KeyValueEditor(rows: paramsBinding, keyPlaceholder: "Query key")
            case .headers:
                KeyValueEditor(rows: draft.headers, keyPlaceholder: "Header")
            case .auth:
                AuthEditor(auth: draft.auth)
            case .body:
                BodyEditor(tab: tab, draft: draft)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var paneBinding: Binding<RequestPaneKind> {
        Binding(
            get: { tab.requestPane },
            set: { pane in model.update(tab.id) { $0.requestPane = pane } }
        )
    }

    private var paramsBinding: Binding<[KeyValue]> {
        Binding(
            get: { draft.wrappedValue.params },
            set: { rows in model.update(tab.id) { $0.draft.setParams(rows) } }
        )
    }
}

private struct BodyTypeMenu: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab

    var body: some View {
        Menu {
            ForEach(BodyType.allCases) { type in
                Button {
                    model.update(tab.id) { tab in
                        tab.draft.setBodyType(type)
                        tab.bodyNotice = nil
                    }
                } label: {
                    if type == tab.draft.bodyType {
                        Label(type.label, systemImage: "checkmark")
                    } else {
                        Text(type.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(tab.draft.bodyType.label)
                Chevron()
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(OutlineButtonStyle())
        .fixedSize()
        .accessibilityLabel("Body type")
    }
}

private struct BodyEditor: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab
    let draft: Binding<RequestDraft>

    var body: some View {
        switch tab.draft.bodyType {
        case .json, .raw:
            PaneFrame {
                ContentTypeStrip(tab: tab)
                if let notice = tab.bodyNotice {
                    NoticeStrip(message: notice) {
                        model.update(tab.id) { $0.bodyNotice = nil }
                    }
                }
                CodeEditor(text: draft.bodyText, language: tab.draft.bodyType == .json ? .json : .plain)
                    .id(tab.id)
            }
        case .form:
            VStack(spacing: 8) {
                PaneFrame { ContentTypeStrip(tab: tab) }.frame(height: 30)
                KeyValueEditor(rows: draft.formFields)
            }
        case .multipart:
            VStack(spacing: 8) {
                PaneFrame { ContentTypeStrip(tab: tab) }.frame(height: 30)
                MultipartEditor(fields: draft.multipartFields)
            }
        case .none:
            PaneFrame {
                Text("This request has no body.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Shows the Content-Type that goes with the body, and lets you drop or restore it.
private struct ContentTypeStrip: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab

    var body: some View {
        HStack(spacing: 8) {
            if let header = tab.draft.contentType, header.isEnabled {
                Text("\(header.key): \(header.value)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if tab.draft.isContentTypeAutomatic {
                    Text("Set automatically")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Theme.track, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", help: "Remove Content-Type header") {
                    model.update(tab.id) { $0.draft.removeContentType() }
                }
            } else {
                Text("No Content-Type header")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Button("Add") {
                    model.update(tab.id) { $0.draft.addAutomaticContentType() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// A one-line problem report above the editor, such as a JSON syntax error.
private struct NoticeStrip: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.failureColors.text)
                .lineLimit(2)
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", help: "Dismiss", action: onDismiss)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 30)
        .background(Theme.failureColors.background)
    }
}
