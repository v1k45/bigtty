// Draws the bigtty app icon and writes an .icns.
//   swift scripts/make-icon.swift <out.icns>
// One big terminal window in front of two smaller ones (the herd), on a
// dark indigo squircle.
import AppKit

func hex(_ h: UInt32) -> CGColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1).cgColor
}

/// A terminal window: rounded body, title bar, traffic lights.
func window(_ ctx: CGContext, _ r: CGRect, fill: CGColor, bar: CGColor) {
    let path = CGPath(roundedRect: r, cornerWidth: r.width * 0.09, cornerHeight: r.width * 0.09, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let barHeight = r.height * 0.16
    ctx.setFillColor(bar); ctx.fill(CGRect(x: r.minX, y: r.maxY - barHeight, width: r.width, height: barHeight))
    let d = barHeight * 0.36
    for (i, color) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: r.minX + barHeight * 0.5 + CGFloat(i) * d * 1.6, y: r.maxY - barHeight / 2 - d / 2, width: d, height: d))
    }
    ctx.restoreGState()
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Squircle with a soft drop shadow (macOS icon grid: 824pt body).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(shape); ctx.setFillColor(hex(0x0E1020)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [hex(0x2B2F4A), hex(0x0E1020)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The herd behind, the big one in front.
    window(ctx, CGRect(x: 560, y: 600, width: 290, height: 220), fill: hex(0x3A3F66), bar: hex(0x4A5080))
    window(ctx, CGRect(x: 175, y: 640, width: 290, height: 200), fill: hex(0x3A3F66), bar: hex(0x4A5080))
    window(ctx, CGRect(x: 205, y: 190, width: 614, height: 520), fill: hex(0x11131F), bar: hex(0x262A40))

    // A prompt, "›_".
    ctx.setStrokeColor(hex(0x5CF29A))
    ctx.setLineWidth(50)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 300, y: 510))
    ctx.addLine(to: CGPoint(x: 408, y: 429))
    ctx.addLine(to: CGPoint(x: 300, y: 348))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 457.5, y: 348))
    ctx.addLine(to: CGPoint(x: 597, y: 348))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bigtty.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(px)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try task.run()
task.waitUntilExit()
try draw(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + ".png"))
print(out)
