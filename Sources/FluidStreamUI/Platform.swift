#if canImport(UIKit)
public import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
public import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#endif

public extension NSAttributedString.Key {
    /// Marks which streamed block a range belongs to. Value: `StreamBlockAttribute.rawValue`.
    static let fluidBlock = NSAttributedString.Key("FluidStream.block")
    /// The language of a code fence, when one was given (e.g. "swift").
    static let fluidCodeLanguage = NSAttributedString.Key("FluidStream.codeLanguage")
}

public enum StreamBlockAttribute: String, Sendable {
    case thinking, code, toolCall
}

extension PlatformFont {
    /// The same font with the bold and/or italic traits added. Returns `self` if the system
    /// has no such variant.
    func adding(bold: Bool, italic: Bool) -> PlatformFont {
        guard bold || italic else { return self }
        #if canImport(UIKit)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
        #endif
    }

    func scaled(by factor: CGFloat) -> PlatformFont {
        withSize(pointSize * factor)
    }
}

/// Visual styling for a streamed document.
public struct StreamTheme {
    public var bodyFont: PlatformFont
    public var codeFont: PlatformFont
    public var toolCallFont: PlatformFont
    /// Size multipliers for `#`, `##` and `###` headings.
    public var headingScales: [CGFloat]
    public var textColor: PlatformColor
    public var secondaryTextColor: PlatformColor
    public var linkColor: PlatformColor
    public var codeBackgroundColor: PlatformColor
    public var inlineCodeBackgroundColor: PlatformColor
    public var paragraphSpacing: CGFloat
    public var listIndent: CGFloat

    public init(
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        toolCallFont: PlatformFont,
        headingScales: [CGFloat] = [1.5, 1.3, 1.15],
        textColor: PlatformColor,
        secondaryTextColor: PlatformColor,
        linkColor: PlatformColor,
        codeBackgroundColor: PlatformColor,
        inlineCodeBackgroundColor: PlatformColor,
        paragraphSpacing: CGFloat = 8,
        listIndent: CGFloat = 18
    ) {
        precondition(headingScales.count == 3)
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.toolCallFont = toolCallFont
        self.headingScales = headingScales
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.linkColor = linkColor
        self.codeBackgroundColor = codeBackgroundColor
        self.inlineCodeBackgroundColor = inlineCodeBackgroundColor
        self.paragraphSpacing = paragraphSpacing
        self.listIndent = listIndent
    }

    /// The same theme with every font scaled by `factor`, used to follow Dynamic Type relative to
    /// the body size the theme was built with.
    public func scaled(by factor: CGFloat) -> StreamTheme {
        var copy = self
        copy.bodyFont = bodyFont.scaled(by: factor)
        copy.codeFont = codeFont.scaled(by: factor)
        copy.toolCallFont = toolCallFont.scaled(by: factor)
        return copy
    }

    /// System fonts and semantic colors, so light and dark mode adapt automatically.
    public static func standard() -> StreamTheme {
        let body = PlatformFont.preferredFont(forTextStyle: .body)
        #if canImport(UIKit)
        return StreamTheme(
            bodyFont: body,
            codeFont: .monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular),
            toolCallFont: .monospacedSystemFont(ofSize: body.pointSize * 0.8, weight: .regular),
            textColor: .label,
            secondaryTextColor: .secondaryLabel,
            linkColor: .link,
            codeBackgroundColor: .secondarySystemBackground,
            inlineCodeBackgroundColor: .tertiarySystemFill
        )
        #else
        return StreamTheme(
            bodyFont: body,
            codeFont: .monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular),
            toolCallFont: .monospacedSystemFont(ofSize: body.pointSize * 0.8, weight: .regular),
            textColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            linkColor: .linkColor,
            codeBackgroundColor: .controlBackgroundColor,
            inlineCodeBackgroundColor: .quaternaryLabelColor
        )
        #endif
    }
}
