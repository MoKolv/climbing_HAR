//
//  PointCloudMetalView.swift
//  arvos
//
//  Metal-based point cloud renderer for LiDAR visualization
//

import SwiftUI
import MetalKit
import simd

// MARK: - SwiftUI Wrapper

struct PointCloudMetalView: UIViewRepresentable {
    let pointCloud: PointCloud?

    func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.delegate = context.coordinator
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 30

        context.coordinator.setupMetal(device: metalView.device!)

        return metalView
    }

    func updateUIView(_ metalView: MTKView, context: Context) {
        context.coordinator.updatePointCloud(pointCloud)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var depthState: MTLDepthStencilState?

        private var pointCloud: PointCloud?
        private var vertexBuffer: MTLBuffer?
        private var colorBuffer: MTLBuffer?

        private var rotation: Float = 0

        func setupMetal(device: MTLDevice) {
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            // Create shader library
            guard let library = device.makeDefaultLibrary() else {
                return
            }

            // Create pipeline
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "pointCloudVertexShader")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "pointCloudFragmentShader")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
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
        }

        func updatePointCloud(_ pointCloud: PointCloud?) {
            guard let pointCloud = pointCloud, let device = self.device else { return }

            self.pointCloud = pointCloud

            // Create vertex buffer
            let points = pointCloud.points
            if !points.isEmpty {
                vertexBuffer = device.makeBuffer(
                    bytes: points,
                    length: points.count * MemoryLayout<SIMD3<Float>>.stride,
                    options: .storageModeShared
                )

                // Create color buffer
                if let colors = pointCloud.colors {
                    let normalizedColors = colors.map { color -> SIMD3<Float> in
                        return SIMD3<Float>(
                            Float(color.x) / 255.0,
                            Float(color.y) / 255.0,
                            Float(color.z) / 255.0
                        )
                    }
                    colorBuffer = device.makeBuffer(
                        bytes: normalizedColors,
                        length: normalizedColors.count * MemoryLayout<SIMD3<Float>>.stride,
                        options: .storageModeShared
                    )
                } else {
                    // Default white color
                    let whiteColors = Array(repeating: SIMD3<Float>(1, 1, 1), count: points.count)
                    colorBuffer = device.makeBuffer(
                        bytes: whiteColors,
                        length: whiteColors.count * MemoryLayout<SIMD3<Float>>.stride,
                        options: .storageModeShared
                    )
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle resize
        }

        func draw(in view: MTKView) {
            guard let commandQueue = commandQueue,
                  let pipelineState = pipelineState,
                  let depthState = depthState,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let vertexBuffer = vertexBuffer,
                  let colorBuffer = colorBuffer,
                  let pointCloud = pointCloud else {
                return
            }

            // Create command buffer
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setDepthStencilState(depthState)

            // Set up camera
            rotation += 0.01
            let modelMatrix = makeRotationMatrix(rotation)
            let viewMatrix = makeViewMatrix()
            let projectionMatrix = makeProjectionMatrix(aspectRatio: Float(view.bounds.width / view.bounds.height))

            var uniforms = Uniforms(
                modelViewProjectionMatrix: projectionMatrix * viewMatrix * modelMatrix
            )

            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(colorBuffer, offset: 0, index: 1)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

            renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCloud.points.count)

            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Matrix Math

        private func makeRotationMatrix(_ angle: Float) -> simd_float4x4 {
            let cos = cosf(angle)
            let sin = sinf(angle)
            return simd_float4x4(
                SIMD4<Float>(cos, 0, sin, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sin, 0, cos, 0),
                SIMD4<Float>(0, 0, 0, 1)
            )
        }

        private func makeViewMatrix() -> simd_float4x4 {
            let eye = SIMD3<Float>(0, 0, 2)
            let center = SIMD3<Float>(0, 0, 0)
            let up = SIMD3<Float>(0, 1, 0)

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
            let fov: Float = Float.pi / 3 // 60 degrees
            let near: Float = 0.1
            let far: Float = 100

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

// MARK: - Uniforms

struct Uniforms {
    let modelViewProjectionMatrix: simd_float4x4
}
