// Draws the app icon into an .iconset directory: a UPS block with a bolt, on a rounded square.
// Usage: make-icon <output.iconset>
import AppKit

func icon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // Background: the rounded square of macOS icons, with its margin.
    let inset = size * 0.1
    let square = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let background = NSBezierPath(roundedRect: square, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(
        starting: NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.42, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.22, alpha: 1))!.draw(in: background, angle: -90)

    // The UPS: a block with two terminals on top.
    let white = NSColor(calibratedWhite: 1, alpha: 0.95)
    white.setFill()
    let block = NSRect(x: size * 0.25, y: size * 0.25, width: size * 0.5, height: size * 0.42)
    NSBezierPath(roundedRect: block, xRadius: size * 0.05, yRadius: size * 0.05).fill()
    for x in [0.33, 0.57] {
        let terminal = NSRect(x: size * x, y: size * 0.67, width: size * 0.1, height: size * 0.06)
        NSBezierPath(roundedRect: terminal, xRadius: size * 0.015, yRadius: size * 0.015).fill()
    }

    // The bolt, cut out of the block in the background colour.
    NSColor(calibratedRed: 0.08, green: 0.25, blue: 0.31, alpha: 1).setFill()
    let bolt = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(0.54, 0.62), (0.40, 0.45), (0.49, 0.45), (0.46, 0.30), (0.60, 0.48), (0.51, 0.48)]
    bolt.move(to: NSPoint(x: size * points[0].0, y: size * points[0].1))
    points.dropFirst().forEach { bolt.line(to: NSPoint(x: size * $0.0, y: size * $0.1)) }
    bolt.close()
    bolt.fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try icon(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try icon(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
