import SwiftUI

struct ResponsePane: View {
    @Environment(AppModel.self) private var model
    let tab: RequestTab

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                summary
                Spacer(minLength: 0)
                if let display = tab.response {
                    SegmentedBar(selection: paneBinding, items: [
                        .init(value: .body, title: "Body"),
                        .init(value: .headers, title: "Headers \(display.snapshot.headers.count)"),
                    ])
                    Button("Save response") { model.saveActiveResponse() }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(tab.savedResponseID != nil)
                }
            }
            .frame(minHeight: 28)

            PaneFrame {
                if let display = tab.response, !display.snapshot.redirects.isEmpty {
                    RedirectStrip(snapshot: display.snapshot)
                }
                content
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var summary: some View {
        switch tab.phase {
        case .idle:
            Text("Response")
                .font(Theme.bodySemibold)
                .foregroundStyle(Theme.secondary)
        case .sending:
            ProgressView().controlSize(.small)
            Text("Sending…")
                .font(Theme.body)
                .foregroundStyle(Theme.secondary)
        case .finished(let display):
            let colors = Theme.statusColors(for: display.snapshot.statusCode)
            StatusPill(text: "\(display.snapshot.statusCode) \(display.snapshot.reason)", background: colors.background, foreground: colors.text)
            Text(Formatting.duration(display.snapshot.duration))
                .font(Theme.body)
                .foregroundStyle(Theme.secondary)
            Text(Formatting.size(display.snapshot.body.count))
                .font(Theme.body)
                .foregroundStyle(Theme.secondary)
        case .failed:
            StatusPill(text: "Failed", background: Theme.failureColors.background, foreground: Theme.failureColors.text)
        case .cancelled:
            StatusPill(text: "Cancelled", background: Theme.track, foreground: Theme.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab.phase {
        case .idle:
            PlaceholderText(tab.savedResponseID == nil ? "Send a request to see the response here." : "Opening the saved response…")
        case .sending:
            PlaceholderText("Waiting for the server…")
        case .cancelled:
            PlaceholderText("This request was cancelled.")
        case .failed(let message):
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .finished(let display):
            if tab.responsePane == .headers {
                CodeEditor(text: .constant(display.headersText), language: .headers, isEditable: false)
                    .id("\(tab.id)-headers")
            } else if display.isBinary {
                PlaceholderText("Binary data (\(Formatting.size(display.snapshot.body.count))). Save the response to keep it.")
            } else if display.bodyText.isEmpty {
                PlaceholderText("The response has no body.")
            } else {
                CodeEditor(text: .constant(display.bodyText), language: display.language, isEditable: false)
                    .id("\(tab.id)-body")
            }
        }
    }

    private var paneBinding: Binding<ResponsePaneKind> {
        Binding(
            get: { tab.responsePane },
            set: { pane in model.update(tab.id) { $0.responsePane = pane } }
        )
    }
}

/// Says where a redirected request ended up, since the URL field still shows where it started.
private struct RedirectStrip: View {
    let snapshot: ResponseSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Text(snapshot.redirectSummary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(snapshot.url)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

private struct StatusPill: View {
    var text: String
    var background: Color
    var foreground: Color

    var body: some View {
        Text(text)
            .font(Theme.bodySemibold)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

private struct PlaceholderText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.body)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
