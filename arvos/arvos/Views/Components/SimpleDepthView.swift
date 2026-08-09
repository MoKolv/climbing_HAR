//
//  SimpleDepthView.swift
//  arvos
//
//  Simple depth visualization for debugging
//

import SwiftUI
import MetalKit
import ARKit

struct SimpleDepthView: UIViewRepresentable {
    let depthSample: DepthVisualizationSample?

    func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.delegate = context.coordinator
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = false

        if let device = metalView.device {
            context.coordinator.setupMetal(device: device)
        }

        return metalView
    }

    func updateUIView(_ metalView: MTKView, context: Context) {
        context.coordinator.updateDepthSample(depthSample)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?

        private var depthSample: DepthVisualizationSample?
        private var pointCount: Int = 0

        func setupMetal(device: MTLDevice) {
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            guard let library = device.makeDefaultLibrary() else {
                return
            }

            // Create simple pipeline
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "simpleDepthVertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "simpleDepthFragment")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
            }
        }

        func updateDepthSample(_ sample: DepthVisualizationSample?) {
            guard let sample = sample else { return }
            self.depthSample = sample
            self.pointCount = sample.width * sample.height
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let commandQueue = commandQueue,
                  let pipelineState = pipelineState,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  depthSample != nil else {
                return
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            renderEncoder.setRenderPipelineState(pipelineState)

            // Create simple test vertices - just 3 colored points
            struct SimpleVertex {
                var position: SIMD4<Float>
                var color: SIMD4<Float>
            }

            let testVertices: [SimpleVertex] = [
                SimpleVertex(position: SIMD4<Float>(0, 0.5, 0, 1), color: SIMD4<Float>(1, 0, 0, 1)),  // Red top
                SimpleVertex(position: SIMD4<Float>(-0.5, -0.5, 0, 1), color: SIMD4<Float>(0, 1, 0, 1)), // Green left
                SimpleVertex(position: SIMD4<Float>(0.5, -0.5, 0, 1), color: SIMD4<Float>(0, 0, 1, 1))   // Blue right
            ]

            renderEncoder.setVertexBytes(testVertices, length: testVertices.count * MemoryLayout<SimpleVertex>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 3)

            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
