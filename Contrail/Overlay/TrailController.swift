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
    /// Where the current mouse press started, and whether it has moved far
    /// enough to count as a drag (so a jittery click never highlights).
    private var pressPoint: CGPoint?
    private var pressIsDrag = false
    /// Whether the hold key (if any) was down on the previous model update.
    private var wasHolding = true
    /// Notices a game capturing the mouse; while captured (and "Turn off in
    /// games" is on), nothing is drawn and clicks don't ripple.
    private var capture = CursorCapture()
    /// Screen frames, cached: mouse events can arrive hundreds of times a
    /// second, and `NSScreen.screens` builds new objects on every call.
    private var screenFrames: [CGRect] = []
    /// Captured, and that's allowed to turn things off: "Turn off in games"
    /// is on, and the user hasn't forced the trail on here (an "Always on"
    /// rule, or the switch or shortcut).
    private var isCaptured: Bool {
        capture.isCaptured && store.settings.offInGames && !activation.decision.isForcedOn && !captureOverridden
    }
    /// The switch or shortcut turned the trail on: the user wants it here,
    /// captured mouse or not, until another app comes to the front.
    private var captureOverridden = false

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
            MainActor.assumeIsolated {
                self?.resetTrail()
                self?.capture.reset()
            }
        })
        // Another app in front starts with a free mouse. (Not Contrail's own
        // popover or Settings: the app underneath may still have it.)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.capture.reset()
                self?.captureOverridden = false
            }
        })
        activation.didToggle = { [weak self] in
            guard let self, self.activation.isOn else { return }
            self.captureOverridden = true
        }

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
        screenFrames = NSScreen.screens.map(\.frame)
        capture.reset()
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
            // Global events have no window: this is the screen position.
            let location = event.locationInWindow
            let delta = CGVector(dx: event.deltaX, dy: event.deltaY)
            let time = event.timestamp
            // Tablets in absolute mode report deltas unrelated to position.
            let tablet = event.subtype == .tabletPoint
            MainActor.assumeIsolated {
                if tablet {
                    self?.capture.forgetPosition()
                } else {
                    self?.watchCapture(location: location, delta: delta, time: time)
                }
                self?.moved(flags: flags)
            }
        }) {
            monitors.append(global)
        }
        // Presses inside Contrail's own windows (popover, Settings) never
        // count as drags, and clear any press state left from outside.
        // A release inside Contrail's own windows (press started outside)
        // still ends the gesture, even while drawing is paused.
        let ownReleases: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: ownReleases, handler: { [weak self] event in
            if NSEvent.pressedMouseButtons & ~(1 << event.buttonNumber) == 0 {
                MainActor.assumeIsolated { self?.release(at: NSEvent.mouseLocation) }
            }
            return event
        }) {
            monitors.append(local)
        }
        let ownClicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: ownClicks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.clearPress() }
            return event
        }) {
            monitors.append(local)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                // Movement over Contrail's own windows isn't fed to the
                // capture check; don't compare across it.
                self?.capture.forgetPosition()
                self?.moved(flags: flags)
            }
            return event
        }) {
            monitors.append(local)
        }
        // Global only: clicks in Contrail's own popover and Settings window
        // shouldn't ripple, and global monitors never see this app's events.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            let flags = event.modifierFlags
            let pressLocation = event.locationInWindow
            // Another button already down means this press joins a drag in
            // progress rather than starting a new one.
            let otherButtons = NSEvent.pressedMouseButtons & ~(1 << event.buttonNumber)
            let primary = event.type == .leftMouseDown && !flags.contains(.control)
            // For global events there's no window, so this is already in
            // screen coordinates: where the press happened, even if the
            // cursor has moved on by the time this runs.
            MainActor.assumeIsolated {
                guard otherButtons == 0 else { return }
                self?.pressed(at: pressLocation)
                self?.press(at: pressLocation, primary: primary, flags: flags)
            }
        }) {
            monitors.append(global)
        }
        let releases: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: releases, handler: { [weak self] event in
            let location = event.locationInWindow
            let otherButtons = NSEvent.pressedMouseButtons & ~(1 << event.buttonNumber)
            MainActor.assumeIsolated {
                // The gesture ends when the last button comes up.
                if otherButtons == 0 { self?.release(at: location) }
            }
        }) {
            monitors.append(global)
        }
    }

    /// Feeds the capture detector; when a capture starts (and is allowed to
    /// turn things off), clears whatever is showing.
    private func watchCapture(location: CGPoint, delta: CGVector, time: Double) {
        guard store.settings.offInGames else { return }
        let atEdge = screenFrames.contains { f in
            f.insetBy(dx: -1, dy: -1).contains(location)
                && (location.x <= f.minX + 1 || location.x >= f.maxX - 2
                    || location.y <= f.minY + 1 || location.y >= f.maxY - 2)
        }
        guard capture.moved(location: location, delta: delta, time: time, atScreenEdge: atEdge),
              isCaptured else { return }
        resetTrail()
        ripples.removeAll()
        clearPress()
        // Draw one empty frame, then the links pause as usual.
        wake()
    }

    /// Mouse movement wakes the trail, unless a hold key is required and up.
    /// Mouse events carry the modifier state, so no keyboard monitoring (and
    /// no permission) is needed.
    private func moved(flags: NSEvent.ModifierFlags) {
        // A held ring always wakes, so it can follow or be released.
        guard !isCaptured else { return }
        guard ripples.isHolding || store.settings.holdModifier.isSatisfied(by: flags) else { return }
        wake()
    }

    private func pressed(at location: CGPoint) {
        pressPoint = location
        pressIsDrag = false
    }

    private func clearPress() {
        pressPoint = nil
        pressIsDrag = false
    }

    /// True while a mouse button is held and the cursor has moved at least
    /// 4 pt from where the press began. `pressedMouseButtons` needs no
    /// permission.
    private func isDragging(cursor: CGPoint, settings: TrailSettings) -> Bool {
        // Presses inside Contrail's own windows aren't seen (global monitor),
        // so they never start a drag.
        guard NSEvent.pressedMouseButtons != 0, let start = pressPoint else {
            pressPoint = nil
            pressIsDrag = false
            return false
        }
        if !pressIsDrag, hypot(cursor.x - start.x, cursor.y - start.y) >= 4 {
            pressIsDrag = true
        }
        return settings.pressEffects && pressIsDrag
    }

    /// A button went down: a ring appears at the cursor and stays on it
    /// until the button comes up (see `release(at:)`).
    private func press(at location: CGPoint, primary: Bool, flags: NSEvent.ModifierFlags) {
        let settings = store.settings
        guard activation.isOn, settings.pressEffects, !isCaptured,
              settings.holdModifier.isSatisfied(by: flags) else { return }
        ripples.press(at: location, time: CACurrentMediaTime(), color: settings.rippleColor(primary: primary))
        // The cursor may have moved while the trail slept or drained (hold
        // key up, or trail off); a click alone shouldn't start a trail here.
        if engine.isAwaitingStroke {
            restingCursor = NSEvent.mouseLocation
        }
        wake()
    }

    /// The last button came up: the held ring ripples out from here.
    private func release(at location: CGPoint) {
        guard ripples.isHolding else { return }
        ripples.release(at: location, time: CACurrentMediaTime(),
                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
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
        // Links only wake for movement or clicks with the hold key down (or
        // for enable/rebuild, which set the resting cursor themselves), so a
        // wake is never a fresh key press on a still cursor.
        wasHolding = true
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
            let dragging = isDragging(cursor: cursor, settings: settings)
            // A captured mouse (first-person game) draws nothing, like a
            // hold key that's up.
            let holding = settings.holdModifier.isSatisfied(by: NSEvent.modifierFlags) && !isCaptured
            if holding && !wasHolding {
                // Pressing the hold key starts a trail only once the cursor
                // moves, even if the old one is still draining.
                restingCursor = cursor
            }
            wasHolding = holding
            if !holding || (engine.isAwaitingStroke && cursor == restingCursor) {
                // Hold key up, or the cursor hasn't moved since the trail was
                // reset or the key went down: record nothing, but keep time
                // moving so whatever is still visible drains away.
                engine.drain(now: now, settings: settings)
            } else {
                restingCursor = nil
                engine.update(cursor: cursor, now: now, settings: settings,
                              dragging: dragging)
            }
            let points = engine.visiblePoints(length: settings.length)
            // No head while the hold key is up or on a stroke's first sample,
            // so particles never stream across movement the trail didn't draw.
            let head = engine.samples.last
            let particleHead = holding && head?.startsStroke == false ? head?.point : nil
            particles.update(head: particleHead, dt: dt, settings: settings)
            // The held ring rides on the cursor, turning the drag color once
            // the press becomes a drag. If the release happened where the
            // global monitor can't see it (Contrail's own windows), let go here.
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if ripples.isHolding {
                // Let go when the button is up (also covers releases the
                // global monitor can't see) or the hold key was released.
                if NSEvent.pressedMouseButtons == 0 || !holding {
                    ripples.release(at: cursor, time: now, reduceMotion: reduceMotion)
                } else {
                    ripples.move(to: cursor, time: now, dragColor: dragging ? settings.dragColor : nil)
                }
            }
            ripples.prune(now: now)
            frameContent = TrailFrame(
                segments: TrailGeometry.segments(for: points, settings: settings),
                ripples: ripples.instances(now: now, size: settings.clickSize, reduceMotion: reduceMotion),
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

        // A button held still: once its ring has settled the picture stops
        // changing, so pause drawing and keep that frame on screen. Moving
        // (drag monitor) or letting go (mouse-up monitors) wakes us again.
        // Letting go of a hold key sends no event; the still ring simply
        // releases on the next move or mouse-up.
        if engine.isEmpty && particles.isEmpty && ripples.isSettled(now: now) {
            sleep()
            return
        }
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
