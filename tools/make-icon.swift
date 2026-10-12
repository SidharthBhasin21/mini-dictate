// Draws the MiniDictate app icon and writes an .iconset folder.
// Usage: swift tools/make-icon.swift <output.iconset>   (tools/make-icon.sh wraps this and builds the .icns)
import AppKit

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024

    // macOS icon shape: an 824-point rounded square centred on a 1024-point canvas.
    let tile = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186 * scale, yRadius: 186 * scale)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 22 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(red: 0.11, green: 0.11, blue: 0.10, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(red: 0.20, green: 0.20, blue: 0.19, alpha: 1),
               ending: NSColor(red: 0.08, green: 0.08, blue: 0.07, alpha: 1))!.draw(in: shape, angle: -90)

    // A voice waveform: rounded bars, mirrored around the centre line.
    let heights: [CGFloat] = [150, 300, 470, 250, 400, 210, 110]
    let barWidth = 58 * scale, gap = 38 * scale
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (CGFloat(pixels) - total) / 2
    NSColor.white.setFill()
    for height in heights {
        let bar = NSRect(x: x, y: CGFloat(pixels) / 2 - height * scale / 2, width: barWidth, height: height * scale)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
