// Renders the app icon (a cup on an indigo-to-amber squircle) at 1024 px.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
    let inset = r.insetBy(dx: 100, dy: 100)
    let path = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 0.27, green: 0.25, blue: 0.80, alpha: 1), NSColor(red: 0.96, green: 0.62, blue: 0.30, alpha: 1)])!
        .draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = cup.size
        cup.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
    }
    NSColor.systemGreen.setFill()
    NSBezierPath(ovalIn: NSRect(x: 700, y: 640, width: 120, height: 120)).fill()
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
