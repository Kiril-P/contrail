import AppKit
import Combine
import ContrailCore

/// Owns the overlay panels and drives the trail and click ripples.
///
/// While the cursor moves, each screen's display link samples the cursor and
/// redraws. Once the trail and any ripples have faded, every display link is
/// paused and only lightweight mouse monitors remain, so an idle trail costs
/// ~0 CPU. No permissions are required: mouse event monitoring and
/// `NSEvent.mouseLocation` are not protected by TCC.
@MainActor
final class TrailController {
    private struct ScreenOverlay {
        let panel: OverlayPanel
        let view: TrailLayerView
        let driver: FrameDriver
    }

    private let store: SettingsStore
    private var engine = TrailEngine()
    private var ripples = RippleSystem()
    private var particles = ParticleSystem()
    private var overlays: [ScreenOverlay] = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    private var frameContent = TrailFrame.empty
    private var lastUpdate: CFTimeInterval = 0
    private var isActive = false
    /// When the trail last became empty.
    private var emptySince: CFTimeInterval?
    /// Where the cursor was when the display links last paused. A click wakes
    /// the links for its ripple; until the cursor actually moves away from
    /// here, the trail isn't fed, so a click alone never leaves a dot.
    private var restingCursor: CGPoint?

    init(store: SettingsStore) {
        self.store = store
    }

    func start() {
        rebuildOverlays()
        installMonitors()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetTrail() }
        })

        store.$settings
            .map(\.isEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setEnabled(enabled)
            }
            .store(in: &cancellables)
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            for overlay in overlays { overlay.panel.orderFrontRegardless() }
            restingCursor = NSEvent.mouseLocation
            // @Published emits before the new value is stored, so pass it on.
            wake(enabled: true)
        } else {
            sleep()
            resetTrail()
            ripples.removeAll()
            particles.removeAll()
            frameContent = .empty
            for overlay in overlays {
                // Hide rather than draw a clear frame: drawing can block on a
                // display in standby.
                overlay.view.hideStaleContent()
                overlay.panel.orderOut(nil)
            }
        }
    }

    // MARK: Overlays

    private func rebuildOverlays() {
        for overlay in overlays {
            overlay.driver.invalidate()
            overlay.panel.orderOut(nil)
        }
        overlays.removeAll()
        isActive = false
        resetTrail()

        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = TrailLayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            let driver = FrameDriver(view: view) { [weak self, weak view] in
                guard let self, let view else { return }
                self.frame(for: view)
            }
            overlays.append(ScreenOverlay(panel: panel, view: view, driver: driver))
            if store.settings.isEnabled {
                panel.orderFrontRegardless()
            }
        }
        if store.settings.isEnabled {
            wake()
        }
    }

    // MARK: Activity

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.wake() }
            return event
        }) {
            monitors.append(local)
        }
        // Global only: clicks in Contrail's own popover and Settings window
        // shouldn't ripple, and global monitors never see this app's events.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            let primary = event.type == .leftMouseDown && !event.modifierFlags.contains(.control)
            // For global events there's no window, so this is already in
            // screen coordinates: where the click happened, even if the
            // cursor has moved on by the time this runs.
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.click(at: location, primary: primary) }
        }) {
            monitors.append(global)
        }
    }

    private func click(at location: CGPoint, primary: Bool) {
        let settings = store.settings
        guard settings.isEnabled, settings.clickRipples else { return }
        ripples.add(at: location, time: CACurrentMediaTime(), color: settings.rippleColor(primary: primary))
        wake()
    }

    /// Starts every display link if the trail is enabled and currently idle.
    private func wake(enabled: Bool? = nil) {
        guard enabled ?? store.settings.isEnabled, !isActive else { return }
        isActive = true
        emptySince = nil
        for overlay in overlays { overlay.driver.start() }
    }

    /// Clears the trail and treats the cursor's current position as "at
    /// rest", so the next frame doesn't turn a still cursor into a dot.
    private func resetTrail() {
        engine.reset()
        restingCursor = NSEvent.mouseLocation
    }

    private func sleep() {
        isActive = false
        restingCursor = NSEvent.mouseLocation
        for overlay in overlays { overlay.driver.stop() }
    }

    // MARK: Frame

    private func frame(for view: TrailLayerView) {
        let settings = store.settings
        let now = CACurrentMediaTime()

        // Several displays tick independently; update the model at most once
        // per ~1 ms and let every display draw the latest state.
        if now - lastUpdate > 0.001 {
            let dt = now - lastUpdate
            lastUpdate = now
            let cursor = NSEvent.mouseLocation
            // After a reset (sleep, wake, enable, screen change), don't start
            // a trail until the cursor actually moves; a click alone only
            // shows its ripple.
            if !(engine.isEmpty && cursor == restingCursor) {
                restingCursor = nil
                engine.update(cursor: cursor, now: now, settings: settings)
            }
            let points = engine.visiblePoints(length: settings.length)
            particles.update(head: engine.samples.last?.point, dt: dt, settings: settings)
            ripples.prune(now: now)
            frameContent = TrailFrame(
                segments: TrailGeometry.segments(for: points, settings: settings),
                ripples: ripples.instances(
                    now: now,
                    size: settings.clickSize,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ),
                particles: particles.instances(settings: settings)
            )
        }

        guard let overlay = overlays.first(where: { $0.view === view }) else { return }
        let frame = overlay.panel.frame
        // The trail's wide glow reaches ~4× its width beyond the core; a
        // ripple's reaches ~40 pt beyond its ring.
        let trailRect = frame.insetBy(dx: -CGFloat(settings.width * 4.5 + 12), dy: -CGFloat(settings.width * 4.5 + 12))
        let rippleRect = frame.insetBy(dx: -RippleSystem.glowReach, dy: -RippleSystem.glowReach)
        let onScreen = TrailFrame(
            segments: frameContent.segments.filter { $0.bounds.intersects(trailRect) },
            ripples: frameContent.ripples.filter { $0.bounds.intersects(rippleRect) },
            particles: frameContent.particles.filter { $0.bounds.intersects(frame) }
        )
        view.render(onScreen, origin: frame.origin, settings: settings)

        guard engine.isEmpty && ripples.isEmpty && particles.isEmpty else {
            emptySince = nil
            return
        }
        let emptyFor = now - (emptySince ?? now)
        if emptySince == nil { emptySince = now }

        // Screens normally clear themselves on their next tick. If one hasn't
        // after 0.1 s, its display link has probably stopped (standby,
        // mirroring): hide its stale content instead of drawing, so nothing
        // here can block on the GPU, and let it redraw on the next wake.
        if emptyFor > 0.1 {
            for other in overlays where !other.view.isClear {
                other.view.hideStaleContent()
            }
        }
        if overlays.allSatisfy(\.view.isClear) {
            sleep()
            resetTrail()
        }
    }
}
