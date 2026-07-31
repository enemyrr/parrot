import AppKit

/// The bird, once, for everywhere it appears — the menu bar and the About pane.
///
/// Inlined as SVG source rather than an asset: keeping it here means the
/// executable has no resource bundle to install alongside it, which is what
/// makes `parrot` a single file you can drop on `$PATH`.
enum ParrotGlyph {
    static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    /// `template: true` lets the menu bar tint it for light/dark and for the
    /// highlighted state; the About pane wants it tinted too, so it is the
    /// default rather than the exception.
    static func image(size: CGFloat, template: Bool = true) -> NSImage? {
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = template
        return image
    }
}
