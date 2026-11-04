import AppKit
import ContrailCore

/// Renders a synthetic trail to a PNG without touching the real cursor.
///
///     Contrail.app/Contents/MacOS/Contrail --snapshot out.png [--preset cyan] [--matte] [--background light|dark]
///
/// Used to produce README images and to eyeball shader changes.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[index + 1])
        var settings = TrailSettings.default
        if let p = args.firstIndex(of: "--preset"), p + 1 < args.count { settings.presetID = args[p + 1] }
        settings.highContrast = args.contains("--matte")
        let background = args.firstIndex(of: "--background").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? (settings.highContrast ? "light" : "dark")
        let ok = render(settings: settings.clamped(), background: background, to: output)
        exit(ok ? 0 : 1)
    }

    /// A smooth S-curve sampled the way the engine would see a fast mouse flick.
    static func sampleTrail(size: CGSize, settings: TrailSettings) -> [TrailSegment] {
        var engine = TrailEngine()
        var flick = settings
        flick.length = 0.6
        let frames = 54
        for i in 0...frames {
            let t = Double(i) / Double(frames)
            let x = size.width * (0.12 + 0.76 * t)
            let y = size.height * (0.5 + 0.28 * sin(t * .pi * 2.2))
            engine.update(cursor: CGPoint(x: x, y: y), now: t * 0.6, settings: flick)
        }
        return TrailGeometry.segments(for: engine.visiblePoints(length: flick.length), settings: settings)
    }

    static func render(settings: TrailSettings, background: String, to url: URL) -> Bool {
        guard let renderer = TrailRenderer.shared else { return false }
        let size = CGSize(width: 640, height: 300)
        let scale: CGFloat = 2
        let segments = sampleTrail(size: size, settings: settings)
        let uniforms = TrailUniforms(viewSize: size, origin: .zero, scale: scale, settings: settings)
        guard let texture = renderer.renderOffscreen(
            segments, uniforms: uniforms, width: Int(size.width * scale), height: Int(size.height * scale)
        ) else { return false }

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let trail = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: colorSpace, bitmapInfo: info)?.makeImage(),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace, bitmapInfo: info) else { return false }
        let bg = background == "light" ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                                       : CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        canvas.setFillColor(bg)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Metal textures are top-left origin; flip into CoreGraphics space.
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        canvas.draw(trail, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = canvas.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url) } catch { return false }
        return true
    }
}
