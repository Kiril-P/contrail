import AppKit
import ContrailCore
import SwiftUI

/// Renders a synthetic trail to a PNG without touching the real cursor.
///
///     Contrail.app/Contents/MacOS/Contrail --snapshot out.png [--preset cyan] [--matte] [--width 7] [--opacity 1] [--glow 0.7] [--taper N] [--speed N] [--ripples] [--click-size N] [--background light|dark]
///     Contrail.app/Contents/MacOS/Contrail --snapshot-presets out.png
///     Contrail.app/Contents/MacOS/Contrail --snapshot-ui out.png
///
/// Used to produce README images and to eyeball shader changes.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested(store: SettingsStore) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot-ui"), index + 1 < args.count {
            let ok = renderUI(store: store, to: URL(fileURLWithPath: args[index + 1]))
            exit(ok ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--snapshot-presets"), index + 1 < args.count {
            exit(renderPresetSheet(to: URL(fileURLWithPath: args[index + 1])) ? 0 : 1)
        }
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[index + 1])
        var settings = TrailSettings.default
        if let p = args.firstIndex(of: "--preset"), p + 1 < args.count { settings.presetID = args[p + 1] }
        settings.highContrast = args.contains("--matte")
        func number(_ flag: String) -> Double? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        }
        if let width = number("--width") { settings.width = width }
        if let opacity = number("--opacity") { settings.opacity = opacity }
        if let glow = number("--glow") { settings.glow = glow }
        let background = args.firstIndex(of: "--background").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? (settings.highContrast ? "light" : "dark")
        if let taper = number("--taper") { settings.taper = taper }
        if let size = number("--click-size") { settings.clickSize = size }
        sampleRipples = args.contains("--ripples")
        let speed = number("--speed")
        let ok = render(settings: settings.clamped(), background: background, speed: speed, to: output)
        exit(ok ? 0 : 1)
    }

    /// Writes the popover and Settings window layouts side by side (the live
    /// Metal preview isn't captured). For checking layout without a screenshot.
    static func renderUI(store: SettingsStore, to url: URL) -> Bool {
        let glyphs = HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 18) {
                    ForEach([true, false], id: \.self) { enabled in
                        Image(nsImage: MenuBarIcon.image(enabled: enabled))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 72, height: 72)
                            .foregroundStyle(dark ? Color.white : Color.black)
                    }
                }
                .padding(12)
                .background(dark ? Color(white: 0.15) : Color(white: 0.92))
            }
        }
        let content = HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                MenuPopover(store: store, openSettings: {})
                    .background(Color(nsColor: .windowBackgroundColor))
                glyphs
            }
            SettingsView(store: store)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .padding(24)
        .background(Color.gray.opacity(0.3))
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// A slow, steady drag at `speed` points per second, sampled at 120 Hz with
    /// a 60 Hz mouse, through the real engine and settings. Slow motion makes
    /// very short segments, which the fast flick never exercises.
    static func slowTrail(size: CGSize, settings: TrailSettings, speed: Double) -> [TrailSegment] {
        var engine = TrailEngine()
        // Start near the left edge and stop before the head leaves the canvas.
        let seconds = min(3, Double(size.width) * 0.8 / max(speed, 1))
        let frames = max(Int(seconds * 120), 2)
        var position = CGPoint(x: size.width * 0.1, y: size.height * 0.4)
        for frame in 0..<frames {
            if frame % 2 == 0 {
                position.x += speed / 60
                position.y += speed / 60 * 0.3
            }
            engine.update(cursor: position, now: Double(frame) / 120, settings: settings)
        }
        return TrailGeometry.segments(for: engine.visiblePoints(length: settings.length), settings: settings)
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

    static func render(settings: TrailSettings, background: String, speed: Double? = nil, to url: URL) -> Bool {
        guard let image = renderImage(settings: settings, background: background, size: CGSize(width: 640, height: 300), speed: speed) else { return false }
        return write(image, to: url)
    }

    /// All nine presets in a 3×3 grid on a dark background.
    static func renderPresetSheet(to url: URL) -> Bool {
        let cell = CGSize(width: 300, height: 130)
        let scale = 2
        let columns = 3
        let rows = (ColorPreset.all.count + columns - 1) / columns
        let width = Int(cell.width) * columns * scale
        let height = Int(cell.height) * rows * scale
        guard let canvas = makeContext(width: width, height: height) else { return false }
        canvas.setFillColor(darkBackground)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, preset) in ColorPreset.all.enumerated() {
            var settings = TrailSettings.default
            settings.presetID = preset.id
            guard let image = renderImage(settings: settings, background: nil, size: cell) else { return false }
            let column = index % columns
            let row = rows - 1 - index / columns
            canvas.draw(image, in: CGRect(x: column * image.width, y: row * image.height, width: image.width, height: image.height))
        }
        guard let image = canvas.makeImage() else { return false }
        return write(image, to: url)
    }

    private static let darkBackground = CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    }

    /// Renders the sample trail at 2×. `background` is "light", "dark", or nil
    /// for a transparent image.
    /// Set by `--ripples`: also draw three click rings at different ages.
    private static var sampleRipples = false

    static func renderImage(settings: TrailSettings, background: String?, size: CGSize, speed: Double? = nil) -> CGImage? {
        guard let renderer = TrailRenderer.shared else { return nil }
        let scale: CGFloat = 2
        let segments = speed.map { slowTrail(size: size, settings: settings, speed: $0) }
            ?? sampleTrail(size: size, settings: settings)
        var frame = TrailFrame(segments: segments)
        if sampleRipples {
            var system = RippleSystem()
            let now = 10.0
            let samples: [(x: Double, age: Double, primary: Bool)] = [(0.25, 0.12, true), (0.5, 0.35, true), (0.75, 0.6, false)]
            for sample in samples {
                let center = CGPoint(x: size.width * sample.x, y: size.height * 0.3)
                system.add(at: center, time: now - sample.age * RippleSystem.duration, color: settings.rippleColor(primary: sample.primary))
            }
            frame.ripples = system.instances(now: now, size: settings.clickSize)
        }
        let uniforms = TrailUniforms(viewSize: size, origin: .zero, scale: scale, settings: settings)
        guard let texture = renderer.renderOffscreen(
            frame, uniforms: uniforms, width: Int(size.width * scale), height: Int(size.height * scale)
        ) else { return nil }

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        // Texture row 0 is the top row, which is also how CGImage stores rows.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let trail = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: colorSpace, bitmapInfo: info)?.makeImage(),
              let canvas = makeContext(width: width, height: height) else { return nil }
        if let background {
            canvas.setFillColor(background == "light" ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : darkBackground)
            canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        canvas.draw(trail, in: CGRect(x: 0, y: 0, width: width, height: height))
        return canvas.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
