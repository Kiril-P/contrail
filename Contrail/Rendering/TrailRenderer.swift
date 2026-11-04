import ContrailCore
import Metal
import QuartzCore
import simd

/// Matches `Uniforms` in `TrailShader` (112 bytes).
struct TrailUniforms {
    var viewSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var width: Float
    var glow: Float
    var opacity: Float
    var pixel: Float
    var highContrast: Float
    var stopCount: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var stop0: SIMD4<Float>
    var stop1: SIMD4<Float>
    var stop2: SIMD4<Float>
    var stop3: SIMD4<Float>

    init(viewSize: CGSize, origin: CGPoint, scale: CGFloat, settings: TrailSettings) {
        self.viewSize = SIMD2(Float(viewSize.width), Float(viewSize.height))
        self.origin = SIMD2(Float(origin.x), Float(origin.y))
        self.width = Float(settings.width)
        self.glow = Float(settings.glow)
        self.opacity = Float(settings.opacity)
        self.pixel = Float(1 / max(scale, 1))
        self.highContrast = settings.highContrast ? 1 : 0
        let stops = settings.preset.stops.map(\.simd)
        self.stopCount = Float(stops.count)
        self.stop0 = stops[0]
        self.stop1 = stops.count > 1 ? stops[1] : stops[0]
        self.stop2 = stops.count > 2 ? stops[2] : stops[0]
        self.stop3 = stops.count > 3 ? stops[3] : stops[0]
    }
}

/// Shared Metal state: one device, queue and pipeline for every overlay and
/// preview view.
@MainActor
final class TrailRenderer {
    static let shared: TrailRenderer? = TrailRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: TrailShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Contrail trail"
            descriptor.vertexFunction = library.makeFunction(name: "trail_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "trail_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .max
            attachment.alphaBlendOperation = .max
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Contrail: failed to build Metal pipeline: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = CGColor.clear
        layer.maximumDrawableCount = 3
    }

    /// Draws `segments` (in global points) into `layer`. An empty array clears
    /// it. Returns false when nothing could be submitted (no drawable), so the
    /// caller can try again next frame.
    ///
    /// With `inTransaction`, the frame is presented as part of the current Core
    /// Animation transaction (the layer must have `presentsWithTransaction`
    /// set), so other layer changes in that transaction appear with it.
    @discardableResult
    func draw(_ segments: [TrailSegment], uniforms: TrailUniforms, into layer: CAMetalLayer, inTransaction: Bool = false) -> Bool {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return false }
        encode(segments, uniforms: uniforms, target: drawable.texture, commandBuffer: commandBuffer)
        if inTransaction {
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        return true
    }

    /// Renders into an offscreen texture and waits for the GPU. Used for
    /// snapshots (README images, visual checks).
    func renderOffscreen(_ segments: [TrailSegment], uniforms: TrailUniforms, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        encode(segments, uniforms: uniforms, target: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func encode(_ segments: [TrailSegment], uniforms: TrailUniforms, target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !segments.isEmpty {
            var uniforms = uniforms
            encoder.setRenderPipelineState(pipeline)
            let byteCount = segments.count * MemoryLayout<TrailSegment>.stride
            segments.withUnsafeBytes { bytes in
                if byteCount <= 4096 {
                    encoder.setVertexBytes(bytes.baseAddress!, length: byteCount, index: 0)
                } else if let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: byteCount, options: .storageModeShared) {
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                }
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TrailUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TrailUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segments.count)
        }
        encoder.endEncoding()
    }
}
