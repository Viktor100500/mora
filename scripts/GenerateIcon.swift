import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (size, scale) in sizes {
    let pixels = size * scale
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    let p = CGFloat(pixels)
    let rect = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
    let background = NSBezierPath(roundedRect: rect, xRadius: p * 0.20, yRadius: p * 0.20)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.51, blue: 0.41, alpha: 1), ending: NSColor(srgbRed: 0.11, green: 0.31, blue: 0.23, alpha: 1))!
    gradient.draw(in: background, angle: -55)
    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: p * 0.30, y: p * 0.31))
    leaf.curve(to: NSPoint(x: p * 0.74, y: p * 0.73), controlPoint1: NSPoint(x: p * 0.18, y: p * 0.68), controlPoint2: NSPoint(x: p * 0.54, y: p * 0.78))
    leaf.curve(to: NSPoint(x: p * 0.30, y: p * 0.31), controlPoint1: NSPoint(x: p * 0.80, y: p * 0.42), controlPoint2: NSPoint(x: p * 0.61, y: p * 0.21))
    NSColor(srgbRed: 0.93, green: 0.95, blue: 0.87, alpha: 1).setFill(); leaf.fill()
    let stem = NSBezierPath(); stem.move(to: NSPoint(x: p * 0.28, y: p * 0.27)); stem.curve(to: NSPoint(x: p * 0.63, y: p * 0.62), controlPoint1: NSPoint(x: p * 0.43, y: p * 0.43), controlPoint2: NSPoint(x: p * 0.53, y: p * 0.50)); stem.lineWidth = p * 0.027; stem.lineCapStyle = .round
    NSColor(srgbRed: 0.20, green: 0.43, blue: 0.34, alpha: 1).setStroke(); stem.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data = representation.representation(using: .png, properties: [:])!
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try data.write(to: directory.appendingPathComponent(name))
}

func bigEndian(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
// An ICNS container can embed the native PNG representations directly.
let entries = [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")]
var payload = Data()
for (type, filename) in entries {
    let png = try Data(contentsOf: directory.appendingPathComponent(filename))
    payload.append(type.data(using: .ascii)!); payload.append(bigEndian(UInt32(png.count + 8))); payload.append(png)
}
var icon = "icns".data(using: .ascii)!
icon.append(bigEndian(UInt32(payload.count + 8))); icon.append(payload)
try icon.write(to: directory.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
