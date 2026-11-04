import AppKit
import ContrailCore
import QuartzCore

/// An NSView backed by a transparent CAMetalLayer that draws trail segments.
@MainActor
final class TrailLayerView: NSView {
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// True when the last frame drawn was empty, so another clear is unnecessary.
    private(set) var isClear = true
    /// After `hideStaleContent()`, the number of new frames still to present
    /// before the layer is shown again.
    private var framesUntilShown = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        TrailRenderer.shared?.configure(layer)
        return layer
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// Renders segments given in global coordinates whose origin maps to this
    /// view's bottom-left corner at `origin`.
    func render(_ segments: [TrailSegment], origin: CGPoint, settings: TrailSettings) {
        guard let renderer = TrailRenderer.shared else { return }
        if segments.isEmpty && isClear { return }
        let scale = metalLayer.contentsScale
        let uniforms = TrailUniforms(viewSize: bounds.size, origin: origin, scale: scale, settings: settings)
        if renderer.draw(segments, uniforms: uniforms, into: metalLayer) {
            isClear = segments.isEmpty
            if metalLayer.isHidden {
                // Presentation is asynchronous, so the first new frame may not
                // be on screen yet when this returns. Frames present in order,
                // so once the second one is submitted the first has replaced
                // the stale content and showing the layer can't flash it.
                framesUntilShown -= 1
                if framesUntilShown <= 0 {
                    setLayerHidden(false)
                }
            }
        }
    }

    /// Hides whatever this view last presented without asking the GPU for a
    /// drawable, which can block for up to a second on a display that isn't
    /// presenting (standby, mirroring). The next successful draw shows it again.
    func hideStaleContent() {
        guard !isClear else { return }
        setLayerHidden(true)
        framesUntilShown = 2
        isClear = true
    }

    private func setLayerHidden(_ hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.isHidden = hidden
        CATransaction.commit()
    }
}
