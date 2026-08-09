//
//  DepthPointCloudView.swift
//  arvos
//
//  High-performance ARKit depth point cloud visualization using Metal
//  Renders depth buffer directly as 3D points
//

import SwiftUI
import MetalKit
import ARKit
import simd

// MARK: - SwiftUI Wrapper

struct DepthPointCloudView: UIViewRepresentable {
    let depthSample: DepthVisualizationSample?

    func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.delegate = context.coordinator
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 20 // Reduced from 30 for performance

        if let device = metalView.device {
            context.coordinator.setupMetal(device: device, view: metalView)
        }

        return metalView
    }

    func updateUIView(_ metalView: MTKView, context: Context) {
        context.coordinator.updateDepthSample(depthSample)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var depthState: MTLDepthStencilState?
        private var computePipelineState: MTLComputePipelineState?

        private var depthSample: DepthVisualizationSample?
        private var depthTexture: MTLTexture?
        private var confidenceTexture: MTLTexture?

        // Particle accumulation buffer
        private var particleBuffer: MTLBuffer?
        private var currentParticleIndex: Int = 0
        private let maxParticles: Int = 100_000 // Reduced from 500k for performance

        // Camera movement tracking for 3D scanning
        private var lastCameraTransform: simd_float4x4?
        private let minMovementThreshold: Float = 0.05 // 5cm movement required

        private var rotation: Float = 0
        private var vertexCount: Int = 0

        // MARK: - Setup

        func setupMetal(device: MTLDevice, view: MTKView) {
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            // Create shader library
            guard let library = device.makeDefaultLibrary() else {
                return
            }

            // Create compute pipeline for accumulation
            do {
                let computeFunction = library.makeFunction(name: "accumulateDepthPoints")
                computePipelineState = try device.makeComputePipelineState(function: computeFunction!)
            } catch {
            }

            // Create render pipeline for simple point cloud (matches Apple's approach)
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "simplePointCloudVertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "simplePointCloudFragment")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            do {
                pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
            }

            // Create depth state
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

            // Create particle buffer
            let particleSize = MemoryLayout<SIMD4<Float>>.stride * 2 // position(xyz+pad) + color(rgb+confidence)
            let bufferSize = maxParticles * particleSize
            particleBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        }

        // MARK: - Update Sample

        func updateDepthSample(_ sample: DepthVisualizationSample?) {
            guard let sample = sample, let device = device else { return }

            // Create Metal textures immediately and DON'T store the sample
            // This prevents ARFrame retention issues
            createTexturesFromDepthSample(device: device, sample: sample)

            // Store only the metadata we need, not the CVPixelBuffers
            self.depthSample = sample
        }

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle resize
        }

        private var frameCount = 0

        func draw(in view: MTKView) {
            guard let commandQueue = commandQueue,
                  let pipelineState = pipelineState,
                  let depthState = depthState,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let depthSample = depthSample,
                  let depthTexture = depthTexture else {
                if frameCount % 30 == 0 {
                }
                frameCount += 1
                return
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setDepthStencilState(depthState)

            // Create custom projection matrix for millimeter coordinates (like Apple's sample)
            let aspect = Float(view.bounds.width / view.bounds.height)
            let projectionMatrix = makePerspectiveMatrix(fovyRadians: Float.pi / 2.0,
                                                         aspect: aspect,
                                                         nearZ: 10.0,    // 10mm
                                                         farZ: 8000.0)   // 8000mm (8m)

            // Camera orientation: rotate because camera stream is rotated clockwise
            var orientationMatrix = simd_float4x4(1.0)
            orientationMatrix.columns.0 = [0, -1, 0, 0]
            orientationMatrix.columns.1 = [-1, 0, 0, 0]
            orientationMatrix.columns.2 = [0, 0, 1, 0]
            orientationMatrix.columns.3 = [0, 0, 0, 1]

            // Translation: Push point cloud away from camera to see depth (like Apple's sample)
            var translationMatrix = simd_float4x4(1.0)
            translationMatrix.columns.0 = [1, 0, 0, 0]
            translationMatrix.columns.1 = [0, 1, 0, 0]
            translationMatrix.columns.2 = [0, 0, 1, 0]
            translationMatrix.columns.3 = [0, 0, -300, 1] // Move back 300mm to see depth

            // Static tilt to see 3D structure better (no rotation)
            let angle: Float = 0.2 // ~11 degrees tilt down
            let rotationX = makeRotationMatrixX(angle)

            let viewProjectionMatrix = projectionMatrix * rotationX * translationMatrix * orientationMatrix

            struct PointCloudUniforms {
                var viewProjectionMatrix: simd_float4x4
                var fx: Float
                var fy: Float
                var cx: Float
                var cy: Float
                var depthResolution: SIMD2<Float>
                var pointSize: Float
                var confidenceThreshold: Int32
            }

            // Scale intrinsics from full camera resolution to depth resolution
            // This is CRITICAL - Apple's sample does this too!
            let K = depthSample.intrinsics
            let cameraResolution = SIMD2<Float>(1920, 1440) // Full camera resolution
            let depthResolution = SIMD2<Float>(Float(depthTexture.width), Float(depthTexture.height))
            let scaleRes = cameraResolution / depthResolution

            var uniforms = PointCloudUniforms(
                viewProjectionMatrix: viewProjectionMatrix,
                fx: K[0][0] / scaleRes.x,
                fy: K[1][1] / scaleRes.y,
                cx: K[2][0] / scaleRes.x,
                cy: K[2][1] / scaleRes.y,
                depthResolution: depthResolution,
                pointSize: 6.0, // Smaller points
                confidenceThreshold: 0
            )

            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 0)
            renderEncoder.setVertexTexture(depthTexture, index: 0)
            if let confidenceTexture = confidenceTexture {
                renderEncoder.setVertexTexture(confidenceTexture, index: 1)
            }

            // Draw ALL depth pixels as points (current frame only)
            let vertexCount = Int(depthTexture.width * depthTexture.height)
            renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertexCount)

            frameCount += 1
            if frameCount % 30 == 0 {

                // Sample some depth values
                let depthData = depthSample.depthMap
                CVPixelBufferLockBaseAddress(depthData, .readOnly)
                if let baseAddress = CVPixelBufferGetBaseAddress(depthData) {
                    let depthPtr = baseAddress.assumingMemoryBound(to: Float.self)
                    var validCount = 0
                    var minD: Float = 1000
                    var maxD: Float = 0
                    for i in 0..<min(100, Int(depthTexture.width * depthTexture.height)) {
                        let d = depthPtr[i] * 1000 // Convert to mm
                        if d > 0 {
                            validCount += 1
                            minD = min(minD, d)
                            maxD = max(maxD, d)
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(depthData, .readOnly)
            }

            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Texture Creation

        private func createTexturesFromDepthSample(device: MTLDevice, sample: DepthVisualizationSample) {
            let width = sample.width
            let height = sample.height
            vertexCount = width * height

            // Create depth texture from CVPixelBuffer
            let depthBuffer = sample.depthMap

            CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: width,
                height: height,
                mipmapped: false
            )
            depthDescriptor.usage = [.shaderRead]

            guard let texture = device.makeTexture(descriptor: depthDescriptor) else {
                return
            }

            // Copy depth data from CVPixelBuffer to Metal texture
            if let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: bytesPerRow
                )

                // DEBUG: Sample some depth values to verify they're reasonable
                let depthPtr = baseAddress.assumingMemoryBound(to: Float.self)
                var minDepth: Float = 100000
                var maxDepth: Float = 0
                var validPoints = 0
                for i in 0..<min(100, width * height) {
                    let depth = depthPtr[i] * 1000 // Convert to mm
                    if depth > 0 {
                        minDepth = min(minDepth, depth)
                        maxDepth = max(maxDepth, depth)
                        validPoints += 1
                    }
                }
            }

            self.depthTexture = texture

            // Create confidence texture if available
            if let confidenceBuffer = sample.confidenceMap {
                CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly) }

                let confidenceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r8Uint,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                confidenceDescriptor.usage = [.shaderRead]

                guard let confTexture = device.makeTexture(descriptor: confidenceDescriptor) else {
                    return
                }

                if let confAddress = CVPixelBufferGetBaseAddress(confidenceBuffer) {
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceBuffer)
                    confTexture.replace(
                        region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: confAddress,
                        bytesPerRow: bytesPerRow
                    )
                }

                self.confidenceTexture = confTexture
            }
        }

        // MARK: - Matrix Math

        private func makePerspectiveMatrix(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
            let yProj: Float = 1.0 / tanf(fovyRadians * 0.5)
            let xProj: Float = yProj / aspect
            let zProj: Float = farZ / (farZ - nearZ)

            return simd_float4x4(
                SIMD4<Float>(xProj, 0, 0, 0),
                SIMD4<Float>(0, yProj, 0, 0),
                SIMD4<Float>(0, 0, zProj, 1.0),
                SIMD4<Float>(0, 0, -zProj * nearZ, 0)
            )
        }

        private func makeRotationMatrix(_ angle: Float) -> simd_float4x4 {
            // Rotation around Y axis
            let cos = cosf(angle)
            let sin = sinf(angle)
            return simd_float4x4(
                SIMD4<Float>(cos, 0, sin, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sin, 0, cos, 0),
                SIMD4<Float>(0, 0, 0, 1)
            )
        }

        private func makeRotationMatrixX(_ angle: Float) -> simd_float4x4 {
            // Rotation around X axis
            let cos = cosf(angle)
            let sin = sinf(angle)
            return simd_float4x4(
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, cos, -sin, 0),
                SIMD4<Float>(0, sin, cos, 0),
                SIMD4<Float>(0, 0, 0, 1)
            )
        }

        // MARK: - Helpers

        private func distance(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
            let dx = a.x - b.x
            let dy = a.y - b.y
            let dz = a.z - b.z
            return sqrtf(dx*dx + dy*dy + dz*dz)
        }

        private func makeOrbitViewMatrix(rotation: Float, distance: Float) -> simd_float4x4 {
            // Orbital camera that rotates around the accumulated point cloud
            let eye = SIMD3<Float>(
                sinf(rotation) * distance,
                0.0,
                cosf(rotation) * distance
            )
            let center = SIMD3<Float>(0, 0, 0) // Look at world origin
            let up = SIMD3<Float>(0, 1, 0) // Y-up for world space

            let z = normalize(eye - center)
            let x = normalize(cross(up, z))
            let y = cross(z, x)

            return simd_float4x4(
                SIMD4<Float>(x.x, y.x, z.x, 0),
                SIMD4<Float>(x.y, y.y, z.y, 0),
                SIMD4<Float>(x.z, y.z, z.z, 0),
                SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
            )
        }

        private func makeProjectionMatrix(aspectRatio: Float) -> simd_float4x4 {
            let fov: Float = Float.pi / 2 // Wider field of view (90 degrees, was 60)
            let near: Float = 0.01 // Very close near plane
            let far: Float = 10 // Closer far plane for better depth precision

            let yScale = 1 / tanf(fov * 0.5)
            let xScale = yScale / aspectRatio
            let zRange = far - near
            let zScale = -(far + near) / zRange
            let wzScale = -2 * far * near / zRange

            return simd_float4x4(
                SIMD4<Float>(xScale, 0, 0, 0),
                SIMD4<Float>(0, yScale, 0, 0),
                SIMD4<Float>(0, 0, zScale, -1),
                SIMD4<Float>(0, 0, wzScale, 0)
            )
        }
    }
}

// MARK: - Depth Uniforms

struct DepthUniforms {
    let viewMatrix: simd_float4x4
    let projectionMatrix: simd_float4x4
    let inverseIntrinsics: simd_float3x3
    let localToWorld: simd_float4x4
    let depthResolution: SIMD2<Float>
    let pointSize: Float
    let confidenceThreshold: Int32

    init(viewMatrix: simd_float4x4,
         projectionMatrix: simd_float4x4,
         inverseIntrinsics: simd_float3x3,
         localToWorld: simd_float4x4,
         depthResolution: SIMD2<Float>,
         pointSize: Float,
         confidenceThreshold: Int) {
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.inverseIntrinsics = inverseIntrinsics
        self.localToWorld = localToWorld
        self.depthResolution = depthResolution
        self.pointSize = pointSize
        self.confidenceThreshold = Int32(confidenceThreshold)
    }
}

// MARK: - simd_float3x3 Extension

extension simd_float3x3 {
    var inverse: simd_float3x3 {
        return simd_inverse(self)
    }
}
