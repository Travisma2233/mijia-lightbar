import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 24
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
NSGradient(colors: [NSColor(red: 1.0, green: 0.80, blue: 0.30, alpha: 1), NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1)])!.draw(in: path, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()
let cfg = NSImage.SymbolConfiguration(pointSize: 460, weight: .regular).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon1024.png"))
