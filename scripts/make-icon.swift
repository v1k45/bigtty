// Draws the GhostHerdr app icon and writes an .icns.
//   swift scripts/make-icon.swift <out.icns>
// A ghost with a terminal prompt for a face, two smaller ghosts behind it
// (the herd), on a dark indigo squircle.
import AppKit

func ghost(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
    let r = w / 2
    // Rounded head, straight sides, three scallops along the bottom.
    let base = y + h * 0.13
    path.move(to: CGPoint(x: x, y: base))
    path.addLine(to: CGPoint(x: x, y: y + h - r))
    path.addArc(center: CGPoint(x: x + r, y: y + h - r), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: x + w, y: base))
    // Rounded scallops hanging down, meeting in small upward notches.
    let bumps = 3
    let step = w / CGFloat(bumps)
    for i in 0..<bumps {
        let right = x + w - CGFloat(i) * step
        let left = right - step
        path.addCurve(to: CGPoint(x: left, y: base),
                      control1: CGPoint(x: right - step * 0.05, y: y - h * 0.02),
                      control2: CGPoint(x: left + step * 0.05, y: y - h * 0.02))
    }
    path.closeSubpath()
    return path
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
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.08, blue: 0.14, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.20, green: 0.19, blue: 0.40, alpha: 1).cgColor,
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.14, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A faint glow behind the lead ghost.
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.48, green: 0.55, blue: 1.0, alpha: 0.35).cgColor,
        NSColor(srgbRed: 0.48, green: 0.55, blue: 1.0, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 540, y: 500), startRadius: 0, endCenter: CGPoint(x: 540, y: 500), endRadius: 420, options: [])

    // The herd: two smaller ghosts behind.
    for (rect, alpha) in [(CGRect(x: 210, y: 300, width: 220, height: 280), 0.28), (CGRect(x: 640, y: 330, width: 190, height: 240), 0.22)] {
        ctx.addPath(ghost(in: rect))
        ctx.setFillColor(NSColor(srgbRed: 0.72, green: 0.76, blue: 1.0, alpha: alpha).cgColor)
        ctx.fillPath()
    }

    // The lead ghost.
    let lead = CGRect(x: 330, y: 250, width: 360, height: 470)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.addPath(ghost(in: lead))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(ghost(in: lead))
    ctx.clip()
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).cgColor,
        NSColor(srgbRed: 0.84, green: 0.87, blue: 1.0, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 720), end: CGPoint(x: 512, y: 250), options: [])
    ctx.restoreGState()

    // Its face: a prompt, "›_".
    let accent = NSColor(srgbRed: 0.33, green: 0.40, blue: 0.95, alpha: 1).cgColor
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 420, y: 555))
    ctx.addLine(to: CGPoint(x: 485, y: 505))
    ctx.addLine(to: CGPoint(x: 420, y: 455))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 520, y: 450))
    ctx.addLine(to: CGPoint(x: 600, y: 450))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GhostHerdr.iconset")
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
