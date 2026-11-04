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
    private let activation: ActivationController
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
    /// Whether the hold key (if any) was down on the previous model update.
    private var wasHolding = true

    init(store: SettingsStore, activation: ActivationController) {
        self.store = store
        self.activation = activation
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

        activation.$decision
            .map(\.isOn)
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
            if activation.isOn {
                panel.orderFrontRegardless()
            }
        }
        if activation.isOn {
            wake()
        }
    }

    // MARK: Activity

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.moved(flags: flags) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.moved(flags: flags) }
            return event
        }) {
            monitors.append(local)
        }
        // Global only: clicks in Contrail's own popover and Settings window
        // shouldn't ripple, and global monitors never see this app's events.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            let flags = event.modifierFlags
            let primary = event.type == .leftMouseDown && !flags.contains(.control)
            // For global events there's no window, so this is already in
            // screen coordinates: where the click happened, even if the
            // cursor has moved on by the time this runs.
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.click(at: location, primary: primary, flags: flags) }
        }) {
            monitors.append(global)
        }
    }

    /// Mouse movement wakes the trail, unless a hold key is required and up.
    /// Mouse events carry the modifier state, so no keyboard monitoring (and
    /// no permission) is needed.
    private func moved(flags: NSEvent.ModifierFlags) {
        guard store.settings.holdModifier.isSatisfied(by: flags) else { return }
        wake()
    }

    private func click(at location: CGPoint, primary: Bool, flags: NSEvent.ModifierFlags) {
        let settings = store.settings
        guard activation.isOn, settings.clickRipples, settings.holdModifier.isSatisfied(by: flags) else { return }
        ripples.add(at: location, time: CACurrentMediaTime(), color: settings.rippleColor(primary: primary))
        // The cursor may have moved while the trail slept or drained (hold
        // key up, or trail off); a click alone shouldn't start a trail here.
        if engine.isAwaitingStroke {
            restingCursor = NSEvent.mouseLocation
        }
        wake()
    }

    /// Starts every display link if the trail is enabled and currently idle.
    private func wake(enabled: Bool? = nil) {
        guard enabled ?? activation.isOn, !isActive else { return }
        isActive = true
        emptySince = nil
        for overlay in overlays { overlay.driver.start() }
    }

    /// Clears the trail and treats the cursor's current position as "at
    /// rest", so the next frame doesn't turn a still cursor into a dot.
    private func resetTrail() {
        engine.reset()
        particles.removeAll()
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
            // With a hold key set, record the cursor only while it's down;
            // otherwise let the trail drain away. After a reset (sleep, wake,
            // enable, screen change), don't start a trail until the cursor
            // actually moves; a click alone only shows its ripple.
            let holding = settings.holdModifier.isSatisfied(by: NSEvent.modifierFlags)
            if holding && !wasHolding {
                // Pressing the hold key starts a trail only once the cursor
                // moves, even if the old one is still draining.
                restingCursor = cursor
            }
            wasHolding = holding
            if !holding {
                engine.drain(now: now, settings: settings)
            } else if !(engine.isAwaitingStroke && cursor == restingCursor) {
                restingCursor = nil
                engine.update(cursor: cursor, now: now, settings: settings)
            }
            let points = engine.visiblePoints(length: settings.length)
            // No head while the hold key is up or on a stroke's first sample,
            // so particles never stream across movement the trail didn't draw.
            let head = engine.samples.last
            let particleHead = holding && head?.startsStroke == false ? head?.point : nil
            particles.update(head: particleHead, dt: dt, settings: settings)
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
