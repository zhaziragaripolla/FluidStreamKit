public import SwiftUI
import Foundation

extension A2UICatalog {
    /// The A2UI v0.9.1 basic catalog, rendered natively.
    ///
    /// Covered so far: Text, Image, Icon, Row, Column, List, Card, Divider, Button, TextField,
    /// CheckBox and Slider. Tabs, Modal, ChoicePicker, DateTimeInput, Video and AudioPlayer come
    /// next (RFC-005 rollout step 3); until then they render through the fallback.
    public static var basic: A2UICatalog {
        var c = A2UICatalog(id: "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json")
        c.register("Text") { A2UITextView(context: $0) }
        c.register("Image") { A2UIImageView(context: $0) }
        c.register("Icon") { A2UIIconView(context: $0) }
        c.register("Row") { A2UIStackView(context: $0, axis: .horizontal) }
        c.register("Column") { A2UIStackView(context: $0, axis: .vertical) }
        c.register("List") { A2UIListView(context: $0) }
        c.register("Card") { A2UICardView(context: $0) }
        c.register("Divider") { A2UIDividerView(context: $0) }
        c.register("Button") { A2UIButtonView(context: $0) }
        c.register("TextField") { A2UITextFieldView(context: $0) }
        c.register("CheckBox") { A2UICheckBoxView(context: $0) }
        c.register("Slider") { A2UISliderView(context: $0) }
        for schema in A2UIComponentSchema.basicSubset { c.describe(schema) }
        return c
    }
}

// MARK: - Content

struct A2UITextView: View {
    let context: A2UIComponentContext

    var body: some View {
        let raw = context.string("text") ?? ""
        let attributed = (try? AttributedString(
            markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(raw)
        Text(attributed)
            .font(font)
            .foregroundStyle(context.string("variant") == "caption" ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(isHeading ? .isHeader : [])
    }

    private var isHeading: Bool { context.string("variant")?.hasPrefix("h") == true }

    private var font: Font {
        switch context.string("variant") {
        case "h1": .largeTitle.bold()
        case "h2": .title.bold()
        case "h3": .title2.bold()
        case "h4": .title3.weight(.semibold)
        case "h5": .headline
        case "caption": .caption
        default: .body
        }
    }
}

struct A2UIImageView: View {
    let context: A2UIComponentContext

    var body: some View {
        let variant = context.string("variant") ?? "mediumFeature"
        let fill = context.string("fit") == "cover" || context.string("fit") == "fill"
        AsyncImage(url: context.url("url")) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: Self.width(variant), height: Self.height(variant))
        .frame(maxWidth: Self.width(variant) == nil ? .infinity : nil)
        .clipShape(variant == "avatar" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: variant == "icon" ? 4 : 10)))
        .accessibilityLabel(context.string("description") ?? "")
        .accessibilityHidden(context.string("description") == nil)
    }

    static func width(_ variant: String) -> CGFloat? {
        switch variant {
        case "icon": 24
        case "avatar": 40
        case "smallFeature": 80
        default: nil
        }
    }

    static func height(_ variant: String) -> CGFloat {
        switch variant {
        case "icon": 24
        case "avatar": 40
        case "smallFeature": 80
        case "largeFeature": 280
        case "header": 200
        default: 160
        }
    }
}

struct A2UIIconView: View {
    let context: A2UIComponentContext

    var body: some View {
        Image(systemName: Self.symbol(for: context.string("name") ?? ""))
            .frame(minWidth: 24, minHeight: 24)   // one size, so icons in a list line up
            .accessibilityLabel(context.string("name") ?? "")
    }

    /// A2UI icon names are Material-style; map the common ones to SF Symbols, and pass anything
    /// else through as a symbol name.
    static func symbol(for name: String) -> String {
        let map: [String: String] = [
            "check": "checkmark", "close": "xmark", "add": "plus", "remove": "minus",
            "search": "magnifyingglass", "mail": "envelope", "email": "envelope", "phone": "phone",
            "home": "house", "settings": "gearshape", "person": "person", "favorite": "heart",
            "star": "star", "share": "square.and.arrow.up", "delete": "trash", "edit": "pencil",
            "info": "info.circle", "warning": "exclamationmark.triangle", "error": "exclamationmark.circle",
            "calendar": "calendar", "event": "calendar", "location": "mappin", "place": "mappin",
            "send": "paperplane", "play": "play.fill", "pause": "pause.fill", "arrowBack": "chevron.left",
            "arrowForward": "chevron.right", "menu": "line.3.horizontal", "shoppingCart": "cart",
            "lock": "lock", "notifications": "bell", "camera": "camera", "photo": "photo",
            "upload": "square.and.arrow.up", "download": "square.and.arrow.down", "help": "questionmark.circle",
        ]
        return map[name] ?? name
    }
}

// MARK: - Layout

struct A2UIStackView: View {
    let context: A2UIComponentContext
    let axis: Axis

    var body: some View {
        let justify = context.string("justify") ?? "start"
        let between = justify == "spaceBetween" || justify == "spaceAround" || justify == "spaceEvenly"
        let content = ForEach(Array(context.children.enumerated()), id: \.element.id) { index, child in
            if between, index > 0 { Spacer(minLength: 8) }
            context.render(child)
        }
        Group {
            if axis == .horizontal {
                HStack(alignment: verticalAlignment, spacing: 8) { content }
            } else {
                VStack(alignment: horizontalAlignment, spacing: 8) { content }
            }
        }
        .frame(maxWidth: axis == .vertical || between ? .infinity : nil, alignment: frameAlignment(justify))
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch context.string("align") {
        case "center": .center
        case "end": .trailing
        default: .leading
        }
    }

    private var verticalAlignment: VerticalAlignment {
        switch context.string("align") {
        case "start": .top
        case "end": .bottom
        default: .center
        }
    }

    private func frameAlignment(_ justify: String) -> Alignment {
        switch (axis, justify) {
        case (.horizontal, "center"): .center
        case (.horizontal, "end"): .trailing
        case (.vertical, _): Alignment(horizontal: horizontalAlignment, vertical: .center)
        default: .leading
        }
    }
}

struct A2UIListView: View {
    let context: A2UIComponentContext

    var body: some View {
        if context.string("direction") == "horizontal" {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) { rows }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 8) { rows }
        }
    }

    private var rows: some View {
        ForEach(context.children) { context.render($0) }
    }
}

struct A2UICardView: View {
    let context: A2UIComponentContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(context.children) { context.render($0) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
    }
}

struct A2UIDividerView: View {
    let context: A2UIComponentContext

    var body: some View {
        if context.string("axis") == "vertical" {
            Divider().frame(maxHeight: .infinity)
        } else {
            Divider()
        }
    }
}

// MARK: - Input

struct A2UIButtonView: View {
    let context: A2UIComponentContext

    var body: some View {
        let button = Button(action: context.performAction) {
            ForEach(context.children) { context.render($0) }
        }
        switch context.string("variant") {
        case "primary": button.buttonStyle(.borderedProminent)
        case "borderless": button.buttonStyle(.borderless)
        default: button.buttonStyle(.bordered)
        }
    }
}

struct A2UITextFieldView: View {
    let context: A2UIComponentContext

    var body: some View {
        let label = context.string("label") ?? ""
        let variant = context.string("variant") ?? "shortText"
        let isNumber = variant == "number"
        let text = context.binding("value", default: "", get: { $0.displayString }, set: { text -> JSONValue in
            if isNumber, let n = Double(text) { return .number(n) }
            return .string(text)
        })
        VStack(alignment: .leading, spacing: 4) {
            switch variant {
            case "obscured":
                SecureField(label, text: text)
            case "longText":
                TextField(label, text: text, axis: .vertical).lineLimit(3...8)
            default:
                TextField(label, text: text)
                    #if os(iOS)
                    .keyboardType(isNumber ? .decimalPad : .default)
                    #endif
            }
        }
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(label)
    }
}

struct A2UICheckBoxView: View {
    let context: A2UIComponentContext

    var body: some View {
        Toggle(context.string("label") ?? "",
               isOn: context.binding("value", default: false, get: { $0.boolValue }, set: { .bool($0) }))
    }
}

struct A2UISliderView: View {
    let context: A2UIComponentContext

    var body: some View {
        let lower = context.double("min") ?? 0
        let upper = max(context.double("max") ?? 100, lower + 1)
        VStack(alignment: .leading, spacing: 4) {
            if let label = context.string("label") { Text(label).font(.subheadline) }
            Slider(value: context.binding("value", default: lower, get: { $0.doubleValue }, set: { .number($0) }),
                   in: lower...upper)
                .accessibilityLabel(context.string("label") ?? "")
        }
    }
}
