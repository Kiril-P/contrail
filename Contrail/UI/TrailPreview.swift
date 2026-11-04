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
    private var driver: FrameDriver?
    private var startTime = CACurrentMediaTime()
    private var occlusionObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?

    init(settings: TrailSettings) {
        self.settings = settings
        super.init(frame: .zero)
        trailView.autoresizingMask = [.width, .height]
        addSubview(trailView)
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        }
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
        guard let window else {
            driver?.invalidate()
            driver = nil
            return
        }
        if driver == nil {
            driver = FrameDriver(view: trailView) { [weak self] in self?.step() }
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

    /// With Reduce Motion on, show one still trail instead of animating.
    private func renderStill() {
        guard bounds.width > 0 else { return }
        let segments = SnapshotRenderer.sampleTrail(size: bounds.size, settings: settings)
        trailView.render(segments, origin: .zero, settings: settings)
    }

    private func step() {
        guard bounds.width > 0 else { return }
        let now = CACurrentMediaTime()
        engine.update(cursor: cursorPosition(at: now - startTime), now: now, settings: settings)
        let segments = TrailGeometry.segments(for: engine.visiblePoints(length: settings.length), settings: settings)
        trailView.render(segments, origin: .zero, settings: settings)
    }
}
