import AppKit

/// Liquid Glass dla pływającej warstwy sterowania (pasek, karty,
/// pigułka) -- nigdy dla treści (HIG liquid-glass.md: „Don't use Liquid
/// Glass in the content layer”). macOS 26+: NSGlassEffectView; starsze:
/// NSVisualEffectView. „Ogranicz przezroczystość” obsługuje system.
func makeGlass(around content: NSView, cornerRadius: CGFloat) -> NSView {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }
    let effect = NSVisualEffectView()
    effect.material = .headerView
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = cornerRadius
    effect.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        content.topAnchor.constraint(equalTo: effect.topAnchor),
        content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    return effect
}
