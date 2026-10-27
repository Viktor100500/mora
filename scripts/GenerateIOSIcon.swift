import AppKit
import Foundation

// The iPhone icon reuses the Mac leaf, drawn full-bleed: iOS applies its own mask.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let pixels = 1024
// App Store icons must be opaque: draw into a context without alpha.
let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let p = CGFloat(pixels)
let gradient = NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.51, blue: 0.41, alpha: 1), ending: NSColor(srgbRed: 0.11, green: 0.31, blue: 0.23, alpha: 1))!
gradient.draw(in: NSRect(x: 0, y: 0, width: p, height: p), angle: -55)
// Map the Mac icon's inner square (6%–94%) onto the whole canvas.
let transform = NSAffineTransform()
transform.scale(by: 1 / 0.88)
transform.translateX(by: -p * 0.06, yBy: -p * 0.06)
transform.concat()
let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: p * 0.30, y: p * 0.31))
leaf.curve(to: NSPoint(x: p * 0.74, y: p * 0.73), controlPoint1: NSPoint(x: p * 0.18, y: p * 0.68), controlPoint2: NSPoint(x: p * 0.54, y: p * 0.78))
leaf.curve(to: NSPoint(x: p * 0.30, y: p * 0.31), controlPoint1: NSPoint(x: p * 0.80, y: p * 0.42), controlPoint2: NSPoint(x: p * 0.61, y: p * 0.21))
NSColor(srgbRed: 0.93, green: 0.95, blue: 0.87, alpha: 1).setFill(); leaf.fill()
let stem = NSBezierPath(); stem.move(to: NSPoint(x: p * 0.28, y: p * 0.27)); stem.curve(to: NSPoint(x: p * 0.63, y: p * 0.62), controlPoint1: NSPoint(x: p * 0.43, y: p * 0.43), controlPoint2: NSPoint(x: p * 0.53, y: p * 0.50)); stem.lineWidth = p * 0.027; stem.lineCapStyle = .round
NSColor(srgbRed: 0.20, green: 0.43, blue: 0.34, alpha: 1).setStroke(); stem.stroke()
NSGraphicsContext.restoreGraphicsState()
try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: output)
