import AppKit
import ContrailCore
import QuartzCore

/// An NSView backed by a transparent CAMetalLayer that draws trail segments.
@MainActor
final class TrailLayerView: NSView {
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// True when the last frame drawn was empty, so another clear is unnecessary.
    private(set) var isClear = true

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

    /// Renders a frame given in global coordinates whose origin maps to this
    /// view's bottom-left corner at `origin`.
    func render(_ frame: TrailFrame, origin: CGPoint, settings: TrailSettings) {
        guard let renderer = TrailRenderer.shared else { return }
        if frame.isEmpty && isClear { return }
        let scale = metalLayer.contentsScale
        let uniforms = TrailUniforms(viewSize: bounds.size, origin: origin, scale: scale, settings: settings)
        guard metalLayer.isHidden else {
            if renderer.draw(frame, uniforms: uniforms, into: metalLayer) {
                isClear = frame.isEmpty
            }
            return
        }

        // Showing a hidden layer: present the fresh frame inside the same Core
        // Animation transaction that unhides the layer, so the stale content
        // underneath can never appear, however busy the GPU is.
        metalLayer.presentsWithTransaction = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if renderer.draw(frame, uniforms: uniforms, into: metalLayer, inTransaction: true) {
            isClear = frame.isEmpty
            metalLayer.isHidden = false
        }
        CATransaction.commit()
        metalLayer.presentsWithTransaction = false
    }

    /// Hides whatever this view last presented without asking the GPU for a
    /// drawable, which can block for up to a second on a display that isn't
    /// presenting (standby, mirroring). The next successful draw shows it again.
    func hideStaleContent() {
        guard !isClear else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.isHidden = true
        CATransaction.commit()
        isClear = true
    }
}
