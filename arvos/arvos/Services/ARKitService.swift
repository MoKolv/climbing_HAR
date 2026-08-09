//
//  ARKitService.swift
//  arvos
//
//  ARKit service for depth/LiDAR and pose tracking
//

import Foundation
import ARKit
import Combine
import CoreImage
import UIKit

protocol ARKitServiceDelegate: AnyObject {
    func arKitService(_ service: ARKitService, didUpdate pose: PoseData)
    func arKitService(_ service: ARKitService, didCapture depth: DepthFrame)
    func arKitService(_ service: ARKitService, didCapture camera: CameraFrame)
    func arKitService(_ service: ARKitService, didEncounterError error: Error)
    func arKitService(_ service: ARKitService, didOutputDepthSample sample: DepthVisualizationSample)
}

extension ARKitServiceDelegate {
    func arKitService(_ service: ARKitService, didOutputDepthSample sample: DepthVisualizationSample) {}
}

class ARKitService: NSObject {
    weak var delegate: ARKitServiceDelegate?

    private var arSession: ARSession?
    private var configuration: ARWorldTrackingConfiguration?

    private var isRunning = false
    private var depthEnabled = false
    private var targetDepthFPS: Int = 5
    private var targetPoseFPS: Int = 30

    private var lastDepthTime: UInt64 = 0
    private var lastPoseTime: UInt64 = 0
    private var depthInterval: UInt64 = 0
    private var poseInterval: UInt64 = 0

    // Camera frame timing
    private var lastCameraTime: UInt64 = 0
    private var cameraInterval: UInt64 = 200_000_000  // 5 FPS (200ms) - VERY conservative to prevent ARFrame retention
    private let arkitJPEGQuality: CGFloat = 0.2  // Very low quality for fastest processing

    // Frame counters
    private var frameCount = 0
    private var cameraFrameCount = 0
    private var depthFrameCount = 0

    private let depthProcessingQueue = DispatchQueue(label: "com.arvos.depthProcessing", qos: .userInitiated)
    private let cameraProcessingQueue = DispatchQueue(label: "com.arvos.cameraProcessing", qos: .userInitiated)
    private let processingLock = NSLock()
    private var _isProcessingDepth = false
    private var _isProcessingCamera = false

    private var isProcessingDepth: Bool {
        get {
            processingLock.lock()
            defer { processingLock.unlock() }
            return _isProcessingDepth
        }
        set {
            processingLock.lock()
            defer { processingLock.unlock() }
            _isProcessingDepth = newValue
        }
    }

    private var isProcessingCamera: Bool {
        get {
            processingLock.lock()
            defer { processingLock.unlock() }
            return _isProcessingCamera
        }
        set {
            processingLock.lock()
            defer { processingLock.unlock() }
            _isProcessingCamera = newValue
        }
    }

    // Frame drop counters for monitoring
    private var droppedDepthFrames = 0
    private var droppedCameraFrames = 0

    private let cameraContext = CIContext(options: [.useSoftwareRenderer: false])

    // Device capabilities
    let hasLiDAR: Bool
    let supportsDepth: Bool

    // MARK: - Initialization

    override init() {
        self.hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        self.supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        super.init()
    }

    // MARK: - Configuration

    func configure(depthEnabled: Bool, depthFPS: Int, poseFPS: Int) throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw ARKitError.notSupported
        }

        self.depthEnabled = depthEnabled
        self.targetDepthFPS = depthFPS
        self.targetPoseFPS = poseFPS
        self.depthInterval = depthFPS > 0 ? Constants.Time.nanosPerSecond / UInt64(depthFPS) : 0
        self.poseInterval = poseFPS > 0 ? Constants.Time.nanosPerSecond / UInt64(poseFPS) : 0

        arSession = ARSession()
        arSession?.delegate = self

        configuration = ARWorldTrackingConfiguration()
        configuration?.worldAlignment = .gravity

        // Enable depth if supported and requested
        if depthEnabled {
            if hasLiDAR && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                // Enable mesh reconstruction for LiDAR
                configuration?.sceneReconstruction = .mesh
                // ALSO enable scene depth to get depth frames
                if supportsDepth {
                    configuration?.frameSemantics.insert(.sceneDepth)
                }
            } else if supportsDepth {
                // Fallback to estimated depth for non-LiDAR devices
                configuration?.frameSemantics.insert(.sceneDepth)
            }
        }

        // Enable plane detection for better tracking
        configuration?.planeDetection = [.horizontal, .vertical]
    }

    // MARK: - Control

    func start() {
        guard let session = arSession, let config = configuration, !isRunning else {
            return
        }


        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        guard let session = arSession, isRunning else { return }

        session.pause()
        isRunning = false
    }

    func pause() {
        guard let session = arSession else { return }
        session.pause()
    }

    func resume() {
        guard let session = arSession, let config = configuration else { return }
        session.run(config)
    }

    // MARK: - Update Settings

    func updateDepthSettings(enabled: Bool, fps: Int) {
        depthEnabled = enabled
        targetDepthFPS = fps
        depthInterval = Constants.Time.nanosPerSecond / UInt64(fps)

        guard let config = configuration else { return }

        if enabled {
            if hasLiDAR && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
                // ALSO enable scene depth for LiDAR
                if supportsDepth {
                    config.frameSemantics.insert(.sceneDepth)
                }
            } else if supportsDepth {
                config.frameSemantics.insert(.sceneDepth)
            }
        } else {
            config.sceneReconstruction = []
            config.frameSemantics.remove(.sceneDepth)
        }

        arSession?.run(config)
    }

    func updatePoseFPS(_ fps: Int) {
        targetPoseFPS = fps
        poseInterval = Constants.Time.nanosPerSecond / UInt64(fps)
    }

    // MARK: - Helper Methods

    private func processDepthFrame(
        sceneDepth: ARDepthData?,
        estimatedDepth: CVPixelBuffer?,
        cameraTransform: simd_float4x4,
        cameraIntrinsics: simd_float3x3,
        viewportSize: CGSize
    ) {
        autoreleasepool {
            guard depthEnabled else { return }

            let timestamp = Constants.Time.now()

            // Rate limiting for depth
            let timeSinceLastDepth = timestamp - lastDepthTime
            guard lastDepthTime == 0 || timeSinceLastDepth >= depthInterval else {
                return
            }
            lastDepthTime = timestamp

            // Try to get depth data (already extracted from frame)
            var depthMap: CVPixelBuffer?
            var confidenceMap: CVPixelBuffer?

            // LiDAR depth (preferred)
            if let sceneDepth = sceneDepth {
                depthMap = sceneDepth.depthMap
                confidenceMap = sceneDepth.confidenceMap
            }
            // ARKit depth estimation (fallback)
            else if let estimatedDepth = estimatedDepth {
                depthMap = estimatedDepth
            } else {
                // Only print first few failures
                if depthFrameCount < 5 {
                }
                return
            }

            guard let depthBuffer = depthMap else { return }
            guard !isProcessingDepth else {
                droppedDepthFrames += 1
                if droppedDepthFrames % 10 == 0 {
                }
                return
            }
            isProcessingDepth = true

            // Copy pixel buffers for async processing
            guard let depthCopy = copyPixelBuffer(depthBuffer) else {
                isProcessingDepth = false
                return
            }

            let confidenceCopy: CVPixelBuffer? = {
                if let confidenceMap, let copied = copyPixelBuffer(confidenceMap) {
                    return copied
                }
                return nil
            }()
            let hasConfidence = confidenceMap != nil

            // Explicitly release references to original buffers to avoid retaining ARFrame
            depthMap = nil
            confidenceMap = nil

        // Calculate projection matrix manually to avoid retaining ARCamera
        let projectionMatrix = calculateProjectionMatrix(
            intrinsics: cameraIntrinsics,
            viewportSize: viewportSize,
            zNear: 0.001,
            zFar: 1000
        )

        // Emit depth visualization sample for real-time rendering
        let depthSample = DepthVisualizationSample(
            timestamp: timestamp,
            depthMap: depthCopy,
            confidenceMap: confidenceCopy,
            intrinsics: cameraIntrinsics,
            cameraTransform: cameraTransform,
            projectionMatrix: projectionMatrix
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.arKitService(self, didOutputDepthSample: depthSample)
        }

        depthProcessingQueue.async { [weak self] in
            guard let self else { return }
            
            // Use autoreleasepool to reduce memory pressure during intensive processing
            autoreleasepool {
                let cloud = self.createPointCloud(
                    from: depthCopy,
                    cameraTransform: cameraTransform,
                    intrinsics: cameraIntrinsics,
                    confidenceMap: confidenceCopy
                )

                DispatchQueue.main.async {
                    self.isProcessingDepth = false

                    let pointCount = cloud.points.count
                    if pointCount == 0 {
                        if self.depthFrameCount < 5 {
                        }
                        return
                    }

                    self.depthFrameCount += 1
                    if self.depthFrameCount <= 3 || self.depthFrameCount % 10 == 0 {
                    }

                    let depthFrame = DepthFrame(
                        timestamp: timestamp,
                        pointCloud: cloud,
                        cameraTransform: cameraTransform,
                        intrinsics: cameraIntrinsics,
                        hasConfidenceData: hasConfidence
                    )
                    self.delegate?.arKitService(self, didCapture: depthFrame)
                }
            }
        }
        }
    }

    private func createPointCloud(from depthMap: CVPixelBuffer, cameraTransform: simd_float4x4, intrinsics: simd_float3x3, confidenceMap: CVPixelBuffer?) -> PointCloud {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let depthPointer = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self) else {
            return PointCloud(timestamp: Constants.Time.now(), points: [], colors: nil, confidenceLevels: nil)
        }

        // Confidence map
        var confidencePointer: UnsafeMutablePointer<UInt8>?
        if let conf = confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            confidencePointer = CVPixelBufferGetBaseAddress(conf)?.assumingMemoryBound(to: UInt8.self)
        }
        defer {
            if let conf = confidenceMap {
                CVPixelBufferUnlockBaseAddress(conf, .readOnly)
            }
        }

        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        let rotation = simd_float3x3(rows: [
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        ])
        let translation = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(Constants.Depth.maxPoints)

        var confidenceLevels: [UInt8] = []
        confidenceLevels.reserveCapacity(Constants.Depth.maxPoints)

        // Downsample for performance
        let step = max(1, Constants.Depth.downsampleFactor)

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let index = y * width + x
                // Bounds check to prevent buffer overrun
                guard index < (width * height) else { continue }
                let depthValue = depthPointer[index]

                guard depthValue.isFinite,
                      depthValue >= Constants.Depth.minDepth,
                      depthValue <= Constants.Depth.maxDepth else {
                    continue
                }

                if let confidencePointer {
                    let confidence = confidencePointer[index]
                    if confidence == 0 {
                        continue
                    }
                    confidenceLevels.append(confidence)
                } else {
                    confidenceLevels.append(2)
                }

                let xn = (Float(x) - cx) / fx
                let yn = (Float(y) - cy) / fy

                let cameraPoint = SIMD3<Float>(xn * depthValue, yn * depthValue, -depthValue)
                let worldPoint = rotation * cameraPoint + translation
                points.append(worldPoint)

                if points.count >= Constants.Depth.maxPoints {
                    break
                }
            }
            if points.count >= Constants.Depth.maxPoints {
                break
            }
        }

        return PointCloud(
            timestamp: Constants.Time.now(),
            points: points,
            colors: nil,
            confidenceLevels: confidenceLevels.isEmpty ? nil : confidenceLevels
        )
    }

    // Calculate projection matrix from intrinsics
    private func calculateProjectionMatrix(
        intrinsics: simd_float3x3,
        viewportSize: CGSize,
        zNear: Float,
        zFar: Float
    ) -> simd_float4x4 {
        // Extract camera parameters from intrinsics matrix
        let fx = intrinsics[0][0]  // Focal length X
        let fy = intrinsics[1][1]  // Focal length Y
        let cx = intrinsics[2][0]  // Principal point X
        let cy = intrinsics[2][1]  // Principal point Y
        
        let width = Float(viewportSize.width)
        let height = Float(viewportSize.height)
        
        // Calculate projection matrix (similar to ARCamera.projectionMatrix)
        // This is a standard perspective projection matrix
        let fovX = 2.0 * atan(width / (2.0 * fx))
        let fovY = 2.0 * atan(height / (2.0 * fy))
        
        // Use the larger FOV for consistency
        let fov = max(fovX, fovY)
        let aspect = width / height
        
        // Build perspective projection matrix
        let f = 1.0 / tan(fov / 2.0)
        let range = zFar - zNear
        
        // Column-major matrix
        let projection = simd_float4x4(
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>((cx / width - 0.5) * 2.0, (0.5 - cy / height) * 2.0, -(zFar + zNear) / range, -1),
            SIMD4<Float>(0, 0, -2 * zFar * zNear / range, 0)
        )
        
        return projection
    }
    
    // Copy pixel buffer for async processing
    // Swift 6 uses automatic memory management for Core Foundation objects
    private func copyPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var copy: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            &copy
        )

        guard status == kCVReturnSuccess, let copy else {
            return nil
        }

        CVPixelBufferLockBaseAddress(copy, [])
        defer { CVPixelBufferUnlockBaseAddress(copy, []) }

        guard let sourceBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let destinationBase = CVPixelBufferGetBaseAddress(copy) else {
            return nil
        }

        memcpy(destinationBase, sourceBase, sourceBytesPerRow * height)
        return copy
    }
}

// MARK: - ARSessionDelegate

extension ARKitService: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // CRITICAL: Wrap entire delegate in autoreleasepool to prevent ARFrame retention
        autoreleasepool {
            let timestamp = Constants.Time.now()

            frameCount += 1

            // CRITICAL: Skip this frame entirely if we're still processing previous frames
            // This prevents frame buildup in async queues
            let shouldProcessCamera = !isProcessingCamera && (lastCameraTime == 0 || timestamp - lastCameraTime >= cameraInterval)
            let shouldProcessDepth = depthEnabled && !isProcessingDepth && (timestamp - lastDepthTime >= depthInterval)

            // If nothing to process, return immediately - don't even extract data
            if !shouldProcessCamera && !shouldProcessDepth && (timestamp - lastPoseTime < poseInterval) {
                return
            }

            // Extract ONLY what we need (don't copy buffers we won't use)
            let camera = frame.camera

            // Process camera with COPIED buffer
            if shouldProcessCamera {
                let cameraIntrinsics = camera.intrinsics
                let capturedImageCopy = copyPixelBuffer(frame.capturedImage)
                lastCameraTime = timestamp
                processCameraFrameWithCopy(
                    pixelBuffer: capturedImageCopy!,
                    intrinsics: cameraIntrinsics,
                    timestamp: timestamp
                )
            }

            // Process pose at target FPS
            if timestamp - lastPoseTime >= poseInterval {
                lastPoseTime = timestamp
                let poseData = PoseData(timestamp: timestamp, camera: camera)
                delegate?.arKitService(self, didUpdate: poseData)
            }

            // Process depth with COPIED buffers
            if shouldProcessDepth {
                if let sceneDepth = frame.sceneDepth {
                    let cameraTransform = camera.transform
                    let cameraIntrinsics = camera.intrinsics
                    let depthMapCopy = copyPixelBuffer(sceneDepth.depthMap)
                    
                    let confidenceMapCopy = sceneDepth.confidenceMap.map { copyPixelBuffer($0) }

                    lastDepthTime = timestamp
                    processDepthFrameWithCopy(
                        depthMap: depthMapCopy!,
                        confidenceMap: confidenceMapCopy!,
                        cameraTransform: cameraTransform,
                        cameraIntrinsics: cameraIntrinsics
                    )
                }
            }
        }
        // Autoreleasepool ends - all temporary objects released
    }

    private func processCameraFrameWithCopy(pixelBuffer: CVPixelBuffer, intrinsics: simd_float3x3, timestamp: UInt64) {
        // Buffer is ALREADY copied - don't copy again
        isProcessingCamera = true

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frameIntrinsics = CameraIntrinsics(intrinsics: intrinsics)

        cameraProcessingQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }

                guard let jpegData = self.encodeJPEG(from: pixelBuffer, quality: self.arkitJPEGQuality) else {
                    DispatchQueue.main.async {
                        self.isProcessingCamera = false
                    }
                    return
                }

                let cameraFrame = CameraFrame(
                    timestamp: timestamp,
                    data: jpegData,
                    width: width,
                    height: height,
                    intrinsics: frameIntrinsics
                )

                self.cameraFrameCount += 1
                if self.cameraFrameCount <= 3 || self.cameraFrameCount % 10 == 0 {
                }

                DispatchQueue.main.async {
                    self.delegate?.arKitService(self, didCapture: cameraFrame)
                    self.isProcessingCamera = false
                }
            }
        }
    }

    private func processDepthFrameWithCopy(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        cameraTransform: simd_float4x4,
        cameraIntrinsics: simd_float3x3
    ) {
        // Buffers are ALREADY copied - no retention risk
        isProcessingDepth = true
        let timestamp = Constants.Time.now()

        // DON'T emit depth visualization sample - it causes CVPixelBuffer retention
        // SensorManager doesn't use it anyway (line 440-443 does nothing)

        depthProcessingQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }

                let cloud = self.createPointCloud(
                    from: depthMap,
                    cameraTransform: cameraTransform,
                    intrinsics: cameraIntrinsics,
                    confidenceMap: confidenceMap
                )

                DispatchQueue.main.async {
                    self.isProcessingDepth = false

                    let pointCount = cloud.points.count
                    guard pointCount > 0 else { return }

                    self.depthFrameCount += 1
                    
                    let hasConfidence = confidenceMap != nil
                    
                    let depthFrame = DepthFrame(
                        timestamp: timestamp,
                        pointCloud: cloud,
                        cameraTransform: cameraTransform,
                        intrinsics: cameraIntrinsics,
                        hasConfidenceData: hasConfidence
                    )
                    self.delegate?.arKitService(self, didCapture: depthFrame)
                }
            }
        }
    }

    private func encodeJPEG(from pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = cameraContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        delegate?.arKitService(self, didEncounterError: error)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // Session interrupted (e.g., app backgrounded)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Session resumed
    }
}

// MARK: - Depth Frame

struct DepthFrame {
    let timestamp: UInt64
    let pointCloud: PointCloud
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let hasConfidenceData: Bool

    func metadata() -> DepthFrameMetadata {
        let plyData = pointCloud.toPLY()
        let minDepth = pointCloud.points.map { simd_length($0) }.min() ?? 0
        let maxDepth = pointCloud.points.map { simd_length($0) }.max() ?? 0

        return DepthFrameMetadata(
            timestamp: timestamp,
            width: 0, // Point cloud doesn't have width/height
            height: 0,
            pointCount: pointCloud.points.count,
            format: "point_cloud",
            size: plyData.count,
            minDepth: minDepth,
            maxDepth: maxDepth,
            hasConfidenceData: hasConfidenceData
        )
    }
}

// MARK: - Errors

enum ARKitError: LocalizedError {
    case notSupported
    case depthNotAvailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "ARKit is not supported on this device"
        case .depthNotAvailable:
            return "Depth data is not available on this device"
        case .configurationFailed:
            return "Failed to configure ARKit session"
        }
    }
}
