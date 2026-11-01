import AppKit
import SwiftUI

/// A table with one empty row at the bottom. Typing in that row turns it into a real
/// row and adds a new empty one below. Both kinds share one `ForEach`, so the row keeps
/// its identity through the change and the cursor stays where it was.
struct GrowingRows<Row: Identifiable & Sendable, RowView: View>: View where Row.ID: Sendable {
    @Binding var rows: [Row]
    var isEmpty: (Row) -> Bool
    var makeRow: () -> Row
    var rowView: (Binding<Row>, (() -> Void)?) -> RowView
    @State private var blank: Row

    init(
        rows: Binding<[Row]>,
        isEmpty: @escaping (Row) -> Bool,
        makeRow: @escaping () -> Row,
        @ViewBuilder rowView: @escaping (Binding<Row>, (() -> Void)?) -> RowView
    ) {
        _rows = rows
        self.isEmpty = isEmpty
        self.makeRow = makeRow
        self.rowView = rowView
        _blank = State(initialValue: makeRow())
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows + [blank]) { row in
                    let id = row.id
                    let isReal = rows.contains { $0.id == id }
                    rowView(binding(for: id), isReal ? { rows.removeAll { $0.id == id } } : nil)
                    if isReal { Divider().overlay(Theme.hairline) }
                }
            }
        }
    }

    private func binding(for id: Row.ID) -> Binding<Row> {
        Binding(
            get: { rows.first { $0.id == id } ?? blank },
            set: { newValue in
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    rows[index] = newValue
                } else if isEmpty(newValue) {
                    blank = newValue
                } else {
                    rows.append(newValue)
                    blank = makeRow()
                }
            }
        )
    }
}

/// Params, headers and form fields.
struct KeyValueEditor: View {
    @Binding var rows: [KeyValue]
    var keyPlaceholder = "Key"
    var valuePlaceholder = "Value"

    var body: some View {
        PaneFrame {
            GrowingRows(rows: $rows, isEmpty: { $0.key.isEmpty && $0.value.isEmpty }, makeRow: { KeyValue() }) { row, onRemove in
                KeyValueRow(row: row, keyPlaceholder: keyPlaceholder, valuePlaceholder: valuePlaceholder, onRemove: onRemove)
            }
        }
    }
}

private struct KeyValueRow: View {
    @Binding var row: KeyValue
    var keyPlaceholder: String
    var valuePlaceholder: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Include", isOn: $row.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(onRemove == nil)
                .opacity(onRemove == nil ? 0 : 1)
            CellField(placeholder: keyPlaceholder, text: $row.key)
            CellField(placeholder: valuePlaceholder, text: $row.value)
            RemoveRowButton(action: onRemove)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .opacity(row.isEnabled ? 1 : 0.5)
    }
}

/// A borderless monospaced field, for use inside table rows.
struct CellField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .foregroundStyle(Theme.ink)
            .autocorrectionDisabled()
            .frame(maxWidth: .infinity)
    }
}

/// Keeps its space when there's nothing to remove, so the columns stay lined up.
struct RemoveRowButton: View {
    var action: (() -> Void)?

    var body: some View {
        if let action {
            IconButton(systemName: "xmark", help: "Remove row", action: action)
        } else {
            Color.clear.frame(width: 20, height: 20)
        }
    }
}

/// Multipart rows, which can each be text or a file.
struct MultipartEditor: View {
    @Binding var fields: [MultipartField]

    var body: some View {
        PaneFrame {
            GrowingRows(rows: $fields, isEmpty: { $0.key.isEmpty && $0.value.isEmpty }, makeRow: { MultipartField() }) { field, onRemove in
                MultipartRow(field: field, onRemove: onRemove)
            }
        }
    }
}

private struct MultipartRow: View {
    @Binding var field: MultipartField
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Include", isOn: $field.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(onRemove == nil)
                .opacity(onRemove == nil ? 0 : 1)
            CellField(placeholder: "Key", text: $field.key)
            Picker("Kind", selection: $field.kind) {
                Text("Text").tag(MultipartField.Kind.text)
                Text("File").tag(MultipartField.Kind.file)
            }
            .labelsHidden()
            .fixedSize()
            if field.kind == .text {
                CellField(placeholder: "Value", text: $field.value)
            } else {
                Button(field.value.isEmpty ? "Choose File…" : (field.value as NSString).lastPathComponent) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { field.value = url.path }
                }
                .buttonStyle(OutlineButtonStyle(height: 24, cornerRadius: 6))
                .help(field.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            RemoveRowButton(action: onRemove)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .opacity(field.isEnabled ? 1 : 0.5)
    }
}
