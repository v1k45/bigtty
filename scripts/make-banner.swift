// Draws the README banner, light and dark: the app icon, the name and the
// tagline.
//   swift scripts/make-banner.swift <out-dir>   → banner-dark.png, banner-light.png
import AppKit

func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

func banner(dark: Bool, icon: NSImage) -> NSBitmapImageRep {
    let width = 2560, height = 720
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    let card = NSBezierPath(roundedRect: bounds, xRadius: 48, yRadius: 48)
    card.addClip()
    let top = dark ? hex(0x2B2F4A) : hex(0xF4F5FA)
    let bottom = dark ? hex(0x0E1020) : hex(0xE3E6F2)
    NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: -90)
    // A soft green glow behind the icon, from the prompt's color.
    let glow = NSGradient(colors: [hex(0x5CF29A, dark ? 0.16 : 0.22), hex(0x5CF29A, 0)])!
    glow.draw(fromCenter: NSPoint(x: 560, y: 360), radius: 0, toCenter: NSPoint(x: 560, y: 360), radius: 520, options: [])

    icon.draw(in: NSRect(x: 300, y: 100, width: 520, height: 520))

    let name = NSAttributedString(string: "bigtty", attributes: [
        .font: NSFont.systemFont(ofSize: 230, weight: .heavy),
        .foregroundColor: dark ? NSColor.white : hex(0x161827),
        .kern: -6,
    ])
    name.draw(at: NSPoint(x: 900, y: 330))
    let tagline = NSAttributedString(string: "A native Mac home for your terminal agents.", attributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .medium),
        .foregroundColor: dark ? hex(0xB4B9D6) : hex(0x4A4F6A),
    ])
    tagline.draw(at: NSPoint(x: 910, y: 225))
    let prompt = NSAttributedString(string: "›_ herdr · Ghostty · browser · files", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 44, weight: .semibold),
        .foregroundColor: dark ? hex(0x5CF29A) : hex(0x1E9E5A),
    ])
    prompt.draw(at: NSPoint(x: 912, y: 140))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs"
let icon = NSImage(contentsOfFile: "Resources/AppIcon.png")!
for dark in [true, false] {
    let path = "\(dir)/banner-\(dark ? "dark" : "light").png"
    try banner(dark: dark, icon: icon).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print(path)
}
