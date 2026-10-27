import Metal
import QuartzCore

/// Draws the visualizer on the graphics chip: last frame flows into this one (feedback trails in 16-bit color,
/// so fades are smooth), then it's shown on screen with a soft glow. Works at full screen resolution.
final class VizRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let feed: MTLRenderPipelineState
    private let show: MTLRenderPipelineState
    private var targets: [MTLTexture] = []
    private var current = 0
    let outputFormat: MTLPixelFormat

    /// GPU time of the most recent frames, in milliseconds (for the smoothness governor and tests).
    private(set) var gpuMs: [Double] = []
    private let lock = NSLock()

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), outputFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.outputFormat = outputFormat
        do {
            let lib = try device.makeLibrary(source: VizShaders.source, options: nil)
            func pipe(_ frag: String, _ fmt: MTLPixelFormat) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: "vizVertex")
                d.fragmentFunction = lib.makeFunction(name: frag)
                d.colorAttachments[0].pixelFormat = fmt
                return try device.makeRenderPipelineState(descriptor: d)
            }
            feed = try pipe("vizFeed", .rgba16Float)
            show = try pipe("vizShow", outputFormat)
        } catch {
            print("Visualizer shaders didn't compile:", error)
            return nil
        }
    }

    var size: (Int, Int) { targets.first.map { ($0.width, $0.height) } ?? (0, 0) }

    private func ensureTargets(_ w: Int, _ h: Int) {
        if let t = targets.first, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        targets = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        current = 0
        // start from black
        if let cb = queue.makeCommandBuffer() {
            for t in targets {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = t
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rp.colorAttachments[0].storeAction = .store
                cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            }
            cb.commit()
        }
    }

    /// Draws one frame. `width`/`height` is the drawing size for the trails (may be below screen size
    /// if the governor stepped it down); the result is shown into `output` at its own size.
    func draw(engine: VizEngine, width: Int, height: Int, output: MTLTexture, present: (MTLCommandBuffer) -> Void = { _ in },
              completion: (() -> Void)? = nil) {
        ensureTargets(max(16, width), max(16, height))
        guard targets.count == 2, let cb = queue.makeCommandBuffer() else { return }
        var u = engine.uniforms(width: targets[0].width, height: targets[0].height)
        var music = engine.shown.map { min($0, 1.25) } + engine.wave      // 48 bands + 128 waveform samples
        let src = targets[current], dst = targets[1 - current]

        let rp1 = MTLRenderPassDescriptor()
        rp1.colorAttachments[0].texture = dst
        rp1.colorAttachments[0].loadAction = .dontCare
        rp1.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp1) {
            enc.setRenderPipelineState(feed)
            enc.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentBytes(&music, length: music.count * MemoryLayout<Float>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        let rp2 = MTLRenderPassDescriptor()
        rp2.colorAttachments[0].texture = output
        rp2.colorAttachments[0].loadAction = .dontCare
        rp2.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp2) {
            enc.setRenderPipelineState(show)
            enc.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
            enc.setFragmentTexture(dst, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        present(cb)
        cb.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if let self, ms > 0 {
                self.lock.lock()
                self.gpuMs.append(ms)
                if self.gpuMs.count > 120 { self.gpuMs.removeFirst() }
                self.lock.unlock()
            }
            completion?()
        }
        cb.commit()
        current = 1 - current
    }

    func recentGpuMs() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return gpuMs
    }

    func resetTimes() { lock.lock(); gpuMs.removeAll(); lock.unlock() }

    /// For tests: an offscreen picture to draw into.
    func makeOutput(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: outputFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// For tests: copies a picture into memory the CPU can read (BGRA bytes).
    func readBack(_ t: MTLTexture) -> [UInt8] {
        let bpr = t.width * 4
        guard let buf = device.makeBuffer(length: bpr * t.height, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * t.height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let p = buf.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: p, count: bpr * t.height))
    }
}
