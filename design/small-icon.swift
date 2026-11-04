import AppKit
// Draws the simplified small-size Contrail icon: indigo squircle, white
// pointer, thick cyan contrail. Usage: swift small-icon.swift <pixels> <out.png>
let px = Int(CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let s = CGFloat(px)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Work in a 100x100 design space, y down.
ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s / 100, y: -s / 100)
let tile = CGRect(x: 9.8, y: 9.8, width: 80.4, height: 80.4)   // macOS grid ~824/1024
let squircle = CGPath(roundedRect: tile, cornerWidth: 18.5, cornerHeight: 18.5, transform: nil)
ctx.addPath(squircle); ctx.clip()
let colors = [CGColor(red: 0x24/255, green: 0x29/255, blue: 0x78/255, alpha: 1), CGColor(red: 0x0A/255, green: 0x0F/255, blue: 0x24/255, alpha: 1)]
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 50, y: 10), end: CGPoint(x: 50, y: 90), options: [])
// Contrail: thick cyan stroke with a soft halo, from lower left to the pointer.
let trail = CGMutablePath()
trail.move(to: CGPoint(x: 20, y: 78))
trail.addCurve(to: CGPoint(x: 62, y: 52), control1: CGPoint(x: 30, y: 58), control2: CGPoint(x: 50, y: 66))
let cyan = CGColor(red: 0x28/255, green: 0xDC/255, blue: 0xFF/255, alpha: 1)
ctx.setLineCap(.round)
ctx.addPath(trail); ctx.setStrokeColor(cyan.copy(alpha: 0.35)!); ctx.setLineWidth(px <= 16 ? 16 : 13); ctx.strokePath()
ctx.addPath(trail); ctx.setStrokeColor(cyan); ctx.setLineWidth(px <= 16 ? 10 : 7.5); ctx.strokePath()
// Pointer: classic arrow, tip upper left.
let p = CGMutablePath()
let pts: [CGPoint] = [CGPoint(x: 52, y: 18), CGPoint(x: 52, y: 62), CGPoint(x: 62, y: 53), CGPoint(x: 69, y: 68),
                      CGPoint(x: 76, y: 65), CGPoint(x: 69, y: 50), CGPoint(x: 82, y: 50)]
p.addLines(between: pts); p.closeSubpath()
ctx.addPath(p); ctx.setFillColor(.white); ctx.fillPath()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
