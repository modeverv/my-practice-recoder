import AppKit
import Foundation

// Original vector artwork, rendered at every macOS icon scale without external tools.
// Keep this source as the editable master; no generated-image service is required.
func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func drawIcon(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize,
        pixelsHigh: pixelSize, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "PracticeRecorder.Icon", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not allocate icon bitmap"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let scale = CGFloat(pixelSize) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()

    let tile = rounded(NSRect(x: 58, y: 58, width: 908, height: 908), radius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0x000E1A, 0.34)
    shadow.shadowBlurRadius = 27; shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.set(); color(0x102F43).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x1E5363), color(0x0D263E), color(0x101C32)])!
        .draw(in: tile, angle: -65)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: color(0x70F1D1, 0.17), ending: color(0x70F1D1, 0))!
        .draw(fromCenter: NSPoint(x: 242, y: 850), radius: 0,
              toCenter: NSPoint(x: 242, y: 850), radius: 710, options: [])
    NSGraphicsContext.restoreGraphicsState()
    let rim = rounded(NSRect(x: 60, y: 60, width: 904, height: 904), radius: 202)
    color(0xFFFFFF, 0.12).setStroke(); rim.lineWidth = 3; rim.stroke()

    // A familiar video camera outline, with its lens also reading as the REC mark.
    let body = rounded(NSRect(x: 220, y: 402, width: 434, height: 326), radius: 72)
    color(0xF6FAFF).setStroke(); body.lineWidth = 38; body.stroke()
    let prism = NSBezierPath()
    prism.move(to: NSPoint(x: 654, y: 606))
    prism.line(to: NSPoint(x: 791, y: 690))
    prism.curve(to: NSPoint(x: 822, y: 673), controlPoint1: NSPoint(x: 808, y: 701), controlPoint2: NSPoint(x: 822, y: 690))
    prism.line(to: NSPoint(x: 822, y: 457))
    prism.curve(to: NSPoint(x: 791, y: 440), controlPoint1: NSPoint(x: 822, y: 439), controlPoint2: NSPoint(x: 808, y: 430))
    prism.line(to: NSPoint(x: 654, y: 524))
    prism.close()
    color(0xF6FAFF).setFill(); prism.fill()
    let record = NSBezierPath(ovalIn: NSRect(x: 342, y: 474, width: 182, height: 182))
    NSGradient(starting: color(0xFF6D60), ending: color(0xF12D45))!
        .draw(in: record, angle: -90)
    color(0xFFFFFF, 0.23).setFill()
    NSBezierPath(ovalIn: NSRect(x: 379, y: 603, width: 58, height: 14)).fill()

    // Symmetric waveform: recognizable even at Dock sizes, separate from the camera.
    let heights: [CGFloat] = [38, 86, 142, 198, 142, 86, 38]
    for (index, height) in heights.enumerated() {
        let bar = rounded(NSRect(x: 295 + CGFloat(index) * 68, y: 267 - height / 2,
                                 width: 26, height: height), radius: 13)
        color(0x78E6CF).setFill(); bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PracticeRecorder.Icon", code: 2)
    }
    return png
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift scripts/make-icon.swift ICONSET_DIRECTORY MASTER_PNG\n", stderr)
    exit(1)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let master = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 1 ? "" : "@2x"
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try drawIcon(pixelSize: points * multiplier).write(to: iconset.appendingPathComponent(filename), options: .atomic)
    }
}
try drawIcon(pixelSize: 1024).write(to: master, options: .atomic)
print("Rendered original camera/REC/waveform icon: \(master.path)")
