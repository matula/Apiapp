import SwiftUI

/// The two-to-four-way switch used for Params / Headers / Auth / Body and Body / Headers.
struct SegmentedBar<Value: Hashable>: View {
    struct Item: Identifiable {
        var value: Value
        var title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    var items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.title)
                        .font(isSelected ? Theme.bodySemibold : Theme.body)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.thumb)
                                    .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A white button with a thin border, as used for Save, Format JSON and Save response.
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var cornerRadius: CGFloat = 8
    var horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        OutlineLabel(configuration: configuration, height: height, cornerRadius: cornerRadius, horizontalPadding: horizontalPadding)
    }

    private struct OutlineLabel: View {
        let configuration: Configuration
        let height: CGFloat
        let cornerRadius: CGFloat
        let horizontalPadding: CGFloat
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(isHovering || configuration.isPressed ? Theme.hover : Theme.window, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.controlBorder))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovering = $0 }
        }
    }
}

/// A small × or + with a comfortable hit area.
struct IconButton: View {
    var systemName: String
    var size: CGFloat = 20
    var help: String
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: size, height: size)
                .background(isHovering ? Theme.track : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The little chevron that follows a dropdown's label.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.secondary)
    }
}

/// The thin rounded frame around editors and tables.
struct PaneFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // No clipShape: SwiftUI splits clipped content into separate layers around an
        // AppKit view, which hides whatever sits beside the text editor.
        VStack(spacing: 0) { content }
            .padding(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.editor, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
    }
}

/// The line between the request and response. Drag it to change their sizes.
struct PaneDivider: View {
    @Binding var height: Double
    var range: ClosedRange<Double>
    @State private var startHeight: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startHeight ?? height
                                startHeight = start
                                height = min(max(start + value.translation.height, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startHeight = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}
