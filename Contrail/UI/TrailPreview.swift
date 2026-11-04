import AppKit
import ContrailCore
import SwiftUI

/// A live preview that runs the real engine and Metal renderer on a synthetic
/// figure-eight path, so what you see in the menu is exactly what the overlay
/// draws.
struct TrailPreview: NSViewRepresentable {
    @ObservedObject var store: SettingsStore

    func makeNSView(context: Context) -> PreviewTrailView {
        PreviewTrailView(settings: store.settings)
    }

    func updateNSView(_ view: PreviewTrailView, context: Context) {
        view.settings = store.settings
    }
}

@MainActor
final class PreviewTrailView: NSView {
    var settings: TrailSettings {
        didSet {
            guard oldValue != settings else { return }
            if reduceMotion { renderStill() }
        }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private let trailView = TrailLayerView(frame: .zero)
    private var engine = TrailEngine()
    private var ripples = RippleSystem()
    private var particles = ParticleSystem()
    private var lastStep: Double?
    private var previousLoop = 0.0
    private var driver: FrameDriver?
    private var startTime = CACurrentMediaTime()
    private var occlusionObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?

    init(settings: TrailSettings) {
        self.settings = settings
        super.init(frame: .zero)
        trailView.autoresizingMask = [.width, .height]
        addSubview(trailView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        trailView.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
        }
        guard let window else {
            driver?.invalidate()
            driver = nil
            return
        }
        if driver == nil {
            driver = FrameDriver(view: trailView) { [weak self] in self?.step() }
        }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        }
        updateRunning()
    }

    private func updateRunning() {
        guard let window, let driver else { return }
        if reduceMotion {
            driver.stop()
            renderStill()
        } else if window.isVisible && window.occlusionState.contains(.visible) {
            engine.reset()
            particles.removeAll()
            // Restart the acted-out gesture cleanly: a release mark may have
            // passed while the preview was hidden.
            ripples.removeAll()
            previousLoop = ((CACurrentMediaTime() - startTime) * 1.1).truncatingRemainder(dividingBy: 2 * .pi)
            lastStep = nil
            driver.start()
        } else {
            driver.stop()
        }
    }

    /// A smooth figure-eight that sweeps the width of the preview.
    private func cursorPosition(at time: Double) -> CGPoint {
        let size = bounds.size
        let t = time * 1.1
        let x = size.width / 2 + (size.width / 2 - 24) * sin(t)
        let y = size.height / 2 + (size.height / 2 - 14) * sin(2 * t) * 0.9
        return CGPoint(x: x, y: y)
    }

    /// With Reduce Motion on, show one still trail (and, with clicks & drags
    /// on, one still ring) instead of animating.
    private func renderStill() {
        guard bounds.width > 0 else { return }
        var frame = SnapshotRenderer.sampleFrame(size: bounds.size, settings: settings)
        if settings.pressEffects {
            var still = RippleSystem()
            still.add(at: CGPoint(x: bounds.width * 0.82, y: bounds.height * 0.5), time: 0, color: settings.rippleColor(primary: true))
            frame.ripples = still.instances(now: RippleSystem.duration * 0.3, size: previewRippleSize, reduceMotion: true)
        }
        trailView.render(frame, origin: .zero, settings: settings)
    }

    /// The full 24–128 pt range scaled to fit the preview, so every step of
    /// the Size slider is visible.
    private var previewRippleSize: Double {
        settings.clickSize / TrailSettings.clickSizeRange.upperBound * Double(bounds.height) * 1.1
    }

    private func step() {
        guard bounds.width > 0 else { return }
        let now = CACurrentMediaTime()
        let cursor = cursorPosition(at: now - startTime)
        // With clicks & drags on, act out the gesture on every loop: a quick
        // left click, a quick right click, then press, drag and release.
        let loop = ((now - startTime) * 1.1).truncatingRemainder(dividingBy: 2 * .pi)
        let effects = settings.pressEffects
        let dragging = effects && loop > 3.6 && loop < 5.4
        engine.update(cursor: cursor, now: now, settings: settings, dragging: dragging)
        let segments = TrailGeometry.segments(for: engine.visiblePoints(length: settings.length), settings: settings)
        particles.update(head: engine.samples.last?.point, dt: now - (lastStep ?? now), settings: settings)
        lastStep = now

        ripples.prune(now: now)
        if effects {
            func crossed(_ mark: Double) -> Bool { previousLoop < mark && loop >= mark }
            if crossed(1.2) || crossed(2.5) {
                ripples.press(at: cursor, time: now, color: settings.rippleColor(primary: crossed(1.2)))
            }
            if crossed(1.32) || crossed(2.62) || crossed(5.4) {
                ripples.release(at: cursor, time: now)
            }
            if crossed(3.4) {
                ripples.press(at: cursor, time: now, color: settings.rippleColor(primary: true))
            }
            ripples.move(to: cursor, time: now, dragColor: dragging ? settings.dragColor : nil)
        } else {
            ripples.removeAll()
        }
        previousLoop = loop
        let frame = TrailFrame(
            segments: segments,
            ripples: ripples.instances(now: now, size: previewRippleSize),
            particles: particles.instances(settings: settings)
        )
        trailView.render(frame, origin: .zero, settings: settings)
    }
}
