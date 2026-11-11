public import SwiftUI
import Foundation

extension A2UICatalog {
    /// The A2UI 1.0 basic catalog, rendered natively: all eighteen components. It also answers
    /// to the v0.9 and v0.9.1 basic catalog ids, for agents that haven't moved to 1.0.
    public static var basic: A2UICatalog {
        var c = A2UICatalog(id: A2UIVersion.basicCatalogID)
        c.aliases = A2UIVersion.basicCatalogIDs.subtracting([A2UIVersion.basicCatalogID])
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
        c.register("ChoicePicker") { A2UIChoicePickerView(context: $0) }
        c.register("DateTimeInput") { A2UIDateTimeInputView(context: $0) }
        c.register("Tabs") { A2UITabsView(context: $0) }
        c.register("Modal") { A2UIModalView(context: $0) }
        c.register("Video") { A2UIVideoView(context: $0) }
        c.register("AudioPlayer") { A2UIAudioPlayerView(context: $0) }
        for schema in A2UIComponentSchema.basicSubset { c.describe(schema) }
        return c
    }
}

// MARK: - Content

struct A2UITextView: View {
    let context: A2UIComponentContext

    var body: some View {
        let blocks = A2UIMarkdown.blocks(context.string("text") ?? "")
        let caption = context.string("variant") == "caption"
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(block.text)
                    .font(block.level > 0 ? Self.headingFont(block.level) : (caption ? .caption : legacyFont))
                    .foregroundStyle(caption && block.level == 0 ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(block.level > 0 || isLegacyHeading ? .isHeader : [])
            }
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title.bold()
        case 3: .title2.bold()
        case 4: .title3.weight(.semibold)
        default: .headline
        }
    }

    /// v0.9 agents send `variant: "h1"`…`"h5"`; 1.0 uses Markdown headings instead.
    private var isLegacyHeading: Bool { context.string("variant")?.hasPrefix("h") == true }

    private var legacyFont: Font {
        switch context.string("variant") {
        case "h1": Self.headingFont(1)
        case "h2": Self.headingFont(2)
        case "h3": Self.headingFont(3)
        case "h4": Self.headingFont(4)
        case "h5": Self.headingFont(5)
        default: .body
        }
    }
}

/// Markdown for Text: `#` headings and paragraphs, with inline styles inside each.
enum A2UIMarkdown {
    struct Block {
        var level: Int
        var text: AttributedString
    }

    static func blocks(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [Substring] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Block(level: 0, text: inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush()
                blocks.append(Block(level: hashes, text: inline(String(line.dropFirst(hashes + 1)))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        if blocks.isEmpty { blocks.append(Block(level: 0, text: AttributedString(""))) }
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
        let value = context.value("name")
        // `{"svgPath": …}` icons aren't drawn yet; show a neutral symbol in their place.
        let name = value?.stringValue
        Image(systemName: name.map(Self.symbol(for:)) ?? "square.dashed")
            .frame(minWidth: 24, minHeight: 24)   // one size, so icons in a list line up
            .accessibilityLabel(name ?? "")
    }

    /// The A2UI 1.0 icon names, mapped to SF Symbols. Anything else passes through as a
    /// symbol name, so an app's own agent can use SF Symbols directly.
    static let symbols: [String: String] = [
        "accountCircle": "person.crop.circle", "add": "plus", "arrowBack": "chevron.left",
        "arrowForward": "chevron.right", "attachFile": "paperclip", "calendarToday": "calendar",
        "call": "phone", "camera": "camera", "check": "checkmark", "close": "xmark", "delete": "trash",
        "download": "square.and.arrow.down", "edit": "pencil", "event": "calendar",
        "error": "exclamationmark.circle", "fastForward": "forward.fill", "favorite": "heart.fill",
        "favoriteOff": "heart", "folder": "folder", "help": "questionmark.circle", "home": "house",
        "info": "info.circle", "locationOn": "mappin.and.ellipse", "lock": "lock", "lockOpen": "lock.open",
        "mail": "envelope", "menu": "line.3.horizontal", "moreVert": "ellipsis.vertical",
        "moreHoriz": "ellipsis", "notificationsOff": "bell.slash", "notifications": "bell",
        "pause": "pause.fill", "payment": "creditcard", "person": "person", "phone": "phone",
        "photo": "photo", "play": "play.fill", "print": "printer", "refresh": "arrow.clockwise",
        "rewind": "backward.fill", "search": "magnifyingglass", "send": "paperplane",
        "settings": "gearshape", "share": "square.and.arrow.up", "shoppingCart": "cart",
        "skipNext": "forward.end.fill", "skipPrevious": "backward.end.fill", "star": "star.fill",
        "starHalf": "star.leadinghalf.filled", "starOff": "star", "stop": "stop.fill",
        "upload": "square.and.arrow.up", "visibility": "eye", "visibilityOff": "eye.slash",
        "volumeDown": "speaker.wave.1", "volumeMute": "speaker", "volumeOff": "speaker.slash",
        "volumeUp": "speaker.wave.3", "warning": "exclamationmark.triangle",
        // v0.9 names that agents still send.
        "remove": "minus", "email": "envelope", "location": "mappin", "place": "mappin",
        "calendar": "calendar",
    ]

    static func symbol(for name: String) -> String { symbols[name] ?? name }
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
            // `weight` works like flex-grow: weighted children share the free space.
            if let weight = child.component?["weight"]?.doubleValue, weight > 0 {
                context.render(child)
                    .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
                    .layoutPriority(weight)
            } else {
                context.render(child)
            }
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
        .disabled(!context.failingChecks.isEmpty)
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
        let prompt = context.string("placeholder") ?? label
        let variant = context.string("variant") ?? "shortText"
        let isNumber = variant == "number"
        let text = context.binding("value", default: "", get: { $0.displayString }, set: { text -> JSONValue in
            if isNumber, let n = Double(text) { return .number(n) }
            return .string(text)
        })
        let failures = context.failingChecks
        VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty { Text(label).font(.subheadline) }
            Group {
                switch variant {
                case "obscured":
                    SecureField(label, text: text, prompt: Text(prompt))
                case "longText":
                    TextField(label, text: text, prompt: Text(prompt), axis: .vertical).lineLimit(3...8)
                default:
                    TextField(label, text: text, prompt: Text(prompt))
                        #if os(iOS)
                        .keyboardType(isNumber ? .decimalPad : .default)
                        #endif
                }
            }
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
            A2UICheckMessages(failures: failures, hasValue: !(context.string("value") ?? "").isEmpty)
        }
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
        let value = context.binding("value", default: lower, get: { $0.doubleValue }, set: { .number($0) })
        VStack(alignment: .leading, spacing: 4) {
            if let label = context.string("label") { Text(label).font(.subheadline) }
            if let steps = context.double("steps"), steps >= 1 {
                Slider(value: value, in: lower...upper, step: (upper - lower) / steps)
                    .accessibilityLabel(context.string("label") ?? "")
            } else {
                Slider(value: value, in: lower...upper)
                    .accessibilityLabel(context.string("label") ?? "")
            }
        }
    }
}

/// The messages of an input's failing `@checks`, shown under it once the user has typed something.
struct A2UICheckMessages: View {
    let failures: [A2UICheckFailure]
    let hasValue: Bool

    var body: some View {
        if hasValue {
            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                if let message = failure.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(failure.severity == "error" ? Color.red : Color.secondary)
                }
            }
        }
    }
}
