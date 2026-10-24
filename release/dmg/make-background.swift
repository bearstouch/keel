// Renders the DMG window background (660 x 400 pt) at 1x and 2x in the Light icon look (DS-09):
//   swift release/dmg/make-background.swift release/dmg
// The icon centres (180, 190) and (480, 190) must match scripts/make-dmg.sh.
import AppKit
import CoreText

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let size = NSSize(width: 660, height: 400)
let iconY: CGFloat = 190

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Inter, as the interface uses (MAC-19); registered for this process only.
for weight in ["Medium", "SemiBold"] {
    CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Sources/KeelUI/Resources/Fonts/Inter-\(weight).ttf") as CFURL, .process, nil)
}
func inter(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: "Inter-\(name)", size: size) ?? .systemFont(ofSize: size, weight: .medium) }

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The Light look's plate: white → #F3EDEC, top to bottom.
    NSGradient(starting: color(0xFFFFFF), ending: color(0xF3EDEC))!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    // Finder uses top-left coordinates; AppKit is bottom-left.
    let y = size.height - iconY
    let arrow = NSBezierPath(); arrow.lineWidth = 4; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 280, y: y)); arrow.line(to: NSPoint(x: 380, y: y))
    arrow.move(to: NSPoint(x: 362, y: y + 14)); arrow.line(to: NSPoint(x: 382, y: y)); arrow.line(to: NSPoint(x: 362, y: y - 14))
    // The Light look's mark red (#DC382D), not a warning colour.
    color(0xDC382D, 0.9).setStroke(); arrow.stroke()
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let caption = NSAttributedString(
        string: "Drag Keel to Applications to install", attributes: [.font: inter("Medium", 15), .foregroundColor: color(0x5E5A59), .paragraphStyle: style])
    caption.draw(in: NSRect(x: 0, y: 62, width: size.width, height: 24))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: "\(out)/background.png")
render(scale: 2, to: "\(out)/background@2x.png")
