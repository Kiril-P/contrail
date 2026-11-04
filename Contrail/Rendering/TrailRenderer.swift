import ContrailCore
import Metal
import QuartzCore
import simd

/// Matches `Uniforms` in `TrailShader` (128 bytes).
struct TrailUniforms {
    var viewSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var width: Float
    var glow: Float
    var opacity: Float
    var pixel: Float
    var highContrast: Float
    var stopCount: Float
    var style: Float
    var pad1: Float = 0
    var stop0: SIMD4<Float>
    var stop1: SIMD4<Float>
    var stop2: SIMD4<Float>
    var stop3: SIMD4<Float>
    var dragColor: SIMD4<Float>

    init(viewSize: CGSize, origin: CGPoint, scale: CGFloat, settings: TrailSettings) {
        self.viewSize = SIMD2(Float(viewSize.width), Float(viewSize.height))
        self.origin = SIMD2(Float(origin.x), Float(origin.y))
        self.width = Float(settings.width)
        self.glow = Float(settings.glow)
        self.opacity = Float(settings.opacity)
        self.pixel = Float(1 / max(scale, 1))
        self.highContrast = settings.highContrast ? 1 : 0
        self.style = Float(TrailStyle.allCases.firstIndex(of: settings.style) ?? 0)
        let stops = settings.preset.stops.map(\.simd)
        self.stopCount = Float(stops.count)
        self.stop0 = stops[0]
        self.stop1 = stops.count > 1 ? stops[1] : stops[0]
        self.stop2 = stops.count > 2 ? stops[2] : stops[0]
        self.stop3 = stops.count > 3 ? stops[3] : stops[0]
        self.dragColor = settings.dragColor.simd
    }
}

/// Everything drawn in one frame, in global points.
struct TrailFrame {
    var segments: [TrailSegment] = []
    var ripples: [RippleInstance] = []
    var particles: [ParticleInstance] = []

    static let empty = TrailFrame()

    var isEmpty: Bool { segments.isEmpty && ripples.isEmpty && particles.isEmpty }
}

/// Shared Metal state: one device, queue and pipeline for every overlay and
/// preview view.
@MainActor
final class TrailRenderer {
    static let shared: TrailRenderer? = TrailRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let ripplePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: TrailShader.source, options: nil)
            // Every shape blends with MAX so overlaps merge instead of stacking.
            func makePipeline(_ label: String, vertex: String, fragment: String) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = label
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = .bgra8Unorm
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .max
                attachment.alphaBlendOperation = .max
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            self.pipeline = try makePipeline("Contrail trail", vertex: "trail_vertex", fragment: "trail_fragment")
            self.ripplePipeline = try makePipeline("Contrail ripples", vertex: "ripple_vertex", fragment: "ripple_fragment")
            self.particlePipeline = try makePipeline("Contrail particles", vertex: "particle_vertex", fragment: "particle_fragment")
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

    /// Draws `frame` (in global points) into `layer`. An empty frame clears it. Returns false when nothing could be submitted (no drawable), so the
    /// caller can try again next frame.
    ///
    /// With `inTransaction`, the frame is presented as part of the current Core
    /// Animation transaction (the layer must have `presentsWithTransaction`
    /// set), so other layer changes in that transaction appear with it.
    @discardableResult
    func draw(_ frame: TrailFrame, uniforms: TrailUniforms, into layer: CAMetalLayer, inTransaction: Bool = false) -> Bool {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return false }
        encode(frame, uniforms: uniforms, target: drawable.texture, commandBuffer: commandBuffer)
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
    func renderOffscreen(_ frame: TrailFrame, uniforms: TrailUniforms, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        encode(frame, uniforms: uniforms, target: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func encode(_ frame: TrailFrame, uniforms: TrailUniforms, target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TrailUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TrailUniforms>.stride, index: 1)
        drawInstances(frame.segments, pipeline: pipeline, encoder: encoder)
        drawInstances(frame.particles, pipeline: particlePipeline, encoder: encoder)
        drawInstances(frame.ripples, pipeline: ripplePipeline, encoder: encoder)
        encoder.endEncoding()
    }

    /// One instanced quad per element of `instances`, bound at buffer index 0.
    private func drawInstances<T>(_ instances: [T], pipeline: MTLRenderPipelineState, encoder: MTLRenderCommandEncoder) {
        guard !instances.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        let byteCount = instances.count * MemoryLayout<T>.stride
        instances.withUnsafeBytes { bytes in
            if byteCount <= 4096 {
                encoder.setVertexBytes(bytes.baseAddress!, length: byteCount, index: 0)
            } else if let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: byteCount, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}
