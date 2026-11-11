public import SwiftUI
import Foundation

extension A2UICatalog {
    /// The basic catalog plus FluidStreamKit's own components. Today that adds `Table`, which
    /// A2UI's basic catalog doesn't define. It has its own catalog id, so an agent can tell
    /// the two apart.
    public static var fluid: A2UICatalog {
        var c = A2UICatalog(id: "https://github.com/zhaziragaripolla/FluidStreamKit/catalogs/fluid/1", including: .basic)
        c.register(A2UIComponentSchema.table) { A2UITableView(context: $0) }
        return c
    }
}

extension A2UIComponentSchema {
    /// A data-driven table. A FluidStreamKit extension, not part of A2UI's basic catalog.
    public static let table = A2UIComponentSchema(
        name: "Table",
        description: "A table of text cells, one row per item of a data array. FluidStreamKit extension.",
        properties: [
            .init("columns", .array, required: true,
                  "[{\"title\": \"Price\", \"path\": \"price\", \"align\": \"end\"}]. path is relative to each row"),
            .init("rows", .array, required: true, "Bind with {\"@path\": \"/items\"} to an array of objects"),
        ],
        fallback: .init(components: [["id": "root", "component": "Column", "children": []]]))
}

// MARK: - ChoicePicker

/// Selection logic for ChoicePicker, kept apart from the view so it can be tested.
enum A2UIChoice {
    struct Option: Hashable {
        let label: String
        let value: String
    }

    /// Options from `[{"label", "value"}]`. Labels may be bindings, so `resolve` reads them.
    static func options(from value: JSONValue?, resolve: (JSONValue?) -> JSONValue? = { $0 }) -> [Option] {
        (value?.arrayValue ?? []).compactMap { item in
            if let s = item.stringValue { return Option(label: s, value: s) }
            guard let v = item["value"]?.displayString, !v.isEmpty else { return nil }
            return Option(label: resolve(item["label"])?.displayString ?? v, value: v)
        }
    }

    /// The selected values. A2UI stores them as an array of strings; a single string is accepted too.
    static func selection(from value: JSONValue?) -> [String] {
        if let s = value?.stringValue { return [s] }
        return (value?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// The selection after the user taps `value`.
    static func toggling(_ value: String, in selection: [String], exclusive: Bool) -> [String] {
        if exclusive { return [value] }
        if selection.contains(value) { return selection.filter { $0 != value } }
        return selection + [value]
    }
}

struct A2UIChoicePickerView: View {
    let context: A2UIComponentContext
    @State private var filter = ""

    var body: some View {
        let all = A2UIChoice.options(from: context.value("options"), resolve: context.resolve)
        let options = filter.isEmpty ? all : all.filter { $0.label.localizedCaseInsensitiveContains(filter) }
        // 1.0 default: one choice.
        let exclusive = context.string("variant") != "multipleSelection"
        let chips = context.string("displayStyle") == "chips"
        let selection = context.binding(
            "value", default: [String](), get: { A2UIChoice.selection(from: $0) },
            set: { .array($0.map(JSONValue.string)) })
        VStack(alignment: .leading, spacing: 6) {
            if let label = context.string("label") { Text(label).font(.subheadline) }
            if context.bool("filterable") == true {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            }
            if chips {
                FlowRow(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        let isOn = selection.wrappedValue.contains(option.value)
                        Button(option.label) {
                            selection.wrappedValue = A2UIChoice.toggling(option.value, in: selection.wrappedValue, exclusive: exclusive)
                        }
                        .buttonStyle(.bordered)
                        .tint(isOn ? .accentColor : .secondary)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            } else {
                ForEach(options, id: \.self) { option in
                    let isOn = selection.wrappedValue.contains(option.value)
                    Button {
                        selection.wrappedValue = A2UIChoice.toggling(option.value, in: selection.wrappedValue, exclusive: exclusive)
                    } label: {
                        Label(option.label, systemImage: exclusive
                              ? (isOn ? "largecircle.fill.circle" : "circle")
                              : (isOn ? "checkmark.square.fill" : "square"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            A2UICheckMessages(failures: context.failingChecks, hasValue: !selection.wrappedValue.isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(context.string("label") ?? "")
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (origins, maxWidth, y + rowHeight)
    }
}

// MARK: - DateTimeInput

/// Date parsing and formatting for DateTimeInput. Values travel as ISO 8601 strings.
enum A2UIDateValue {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()) { return date }
        return nil
    }

    /// A date-only value is written as `yyyy-MM-dd`; anything with a time as a full timestamp.
    static func format(_ date: Date, includesTime: Bool) -> String {
        includesTime
            ? date.formatted(.iso8601)
            : date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }
}

struct A2UIDateTimeInputView: View {
    let context: A2UIComponentContext

    var body: some View {
        // 1.0 defaults both to false; with neither enabled, ask for a date.
        let showsTime = context.bool("enableTime") ?? false
        let showsDate = context.bool("enableDate") ?? !showsTime
        let date = context.binding(
            "value", default: Date(), get: { $0.stringValue.flatMap(A2UIDateValue.parse) },
            set: { .string(A2UIDateValue.format($0, includesTime: showsTime)) })
        let lower = context.string("min").flatMap(A2UIDateValue.parse) ?? .distantPast
        let upper = max(context.string("max").flatMap(A2UIDateValue.parse) ?? .distantFuture, lower)
        DatePicker(context.string("label") ?? "", selection: date, in: lower...upper, displayedComponents: components(showsDate, showsTime))
            .environment(\.timeZone, showsTime ? .current : .gmt)
    }

    private func components(_ date: Bool, _ time: Bool) -> DatePickerComponents {
        switch (date, time) {
        case (true, true): [.date, .hourAndMinute]
        case (false, true): [.hourAndMinute]
        default: [.date]
        }
    }
}

// MARK: - Table

/// Turns a Table component's properties into cells, kept apart from the view so it can be tested.
enum A2UITable {
    struct Column: Hashable {
        let title: String
        let path: String
        let alignsEnd: Bool
    }

    static func columns(from value: JSONValue?) -> [Column] {
        (value?.arrayValue ?? []).compactMap { item in
            guard let path = item["path"]?.stringValue else { return nil }
            return Column(title: item["title"]?.displayString ?? path, path: path, alignsEnd: item["align"]?.stringValue == "end")
        }
    }

    /// One array of cell texts per row, capped so a huge data array can't flood the screen.
    static func cells(rows: JSONValue?, columns: [Column], maxRows: Int = 200) -> [[String]] {
        (rows?.arrayValue ?? []).prefix(maxRows).map { row in
            columns.map { column in
                JSONPointer.resolve(column.path, in: .root).flatMap { row.value(at: $0) }?.displayString ?? ""
            }
        }
    }
}

struct A2UITableView: View {
    let context: A2UIComponentContext

    var body: some View {
        let columns = A2UITable.columns(from: context.value("columns"))
        let rows = A2UITable.cells(rows: context.value("rows"), columns: columns)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                ForEach(columns, id: \.self) { column in
                    Text(column.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(column.alignsEnd ? .trailing : .leading)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, text in
                        Text(text)
                            .font(index == 0 ? .subheadline.weight(.semibold) : .subheadline)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
