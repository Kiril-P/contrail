import AppKit
import CoreVideo
import QuartzCore

/// Calls `onFrame` once per refresh of the display a view is on, and can be
/// paused completely so an idle trail costs nothing.
///
/// macOS 14+ uses `NSView.displayLink`, which follows the view across displays
/// and handles ProMotion. macOS 13 falls back to `CVDisplayLink`.
@MainActor
final class FrameDriver: NSObject {
    private weak var view: NSView?
    private let onFrame: @MainActor () -> Void
    private var link: AnyObject?            // CADisplayLink on macOS 14+
    private var cvLink: CVDisplayLink?
    private(set) var isRunning = false

    init(view: NSView, onFrame: @escaping @MainActor () -> Void) {
        self.view = view
        self.onFrame = onFrame
        super.init()
    }

    func start() {
        guard !isRunning, let view else { return }
        isRunning = true
        if #available(macOS 14.0, *) {
            if let link = link as? CADisplayLink {
                link.isPaused = false
            } else {
                let link = view.displayLink(target: self, selector: #selector(step(_:)))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        } else {
            startCVDisplayLink(for: view)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if #available(macOS 14.0, *) {
            (link as? CADisplayLink)?.isPaused = true
        }
        if let cvLink {
            CVDisplayLinkStop(cvLink)
        }
    }

    func invalidate() {
        stop()
        if #available(macOS 14.0, *) {
            (link as? CADisplayLink)?.invalidate()
        }
        link = nil
        cvLink = nil
    }

    @available(macOS 14.0, *)
    @objc private func step(_ link: CADisplayLink) {
        onFrame()
    }

    // MARK: macOS 13 fallback

    private func startCVDisplayLink(for view: NSView) {
        if cvLink == nil {
            var created: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&created)
            guard let created else { return }
            CVDisplayLinkSetOutputHandler(created) { [weak self] _, _, _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning else { return }
                        self.onFrame()
                    }
                }
                return kCVReturnSuccess
            }
            cvLink = created
        }
        guard let cvLink else { return }
        if let number = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            CVDisplayLinkSetCurrentCGDisplay(cvLink, CGDirectDisplayID(number.uint32Value))
        }
        CVDisplayLinkStart(cvLink)
    }
}
