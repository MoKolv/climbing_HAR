//
//  CameraService.swift
//  arvos
//
//  Camera capture service using AVFoundation
//

import Foundation
import AVFoundation
import UIKit
import Combine

protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didCapture frame: CameraFrame)
    func cameraService(_ service: CameraService, didEncounterError error: Error)
}

class CameraService: NSObject {
    weak var delegate: CameraServiceDelegate?

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private let sessionQueue = DispatchQueue(label: "com.arvos.camera")

    private var isRunning = false
    private var targetFPS: Int = 30
    private var lastFrameTime: UInt64 = 0
    private var frameInterval: UInt64 = 0

    // Cached CIContext - reuse instead of creating per frame
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Preview layer for UI
    var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Lifecycle

    override init() {
        super.init()
    }

    // MARK: - Configuration

    func configure(fps: Int) throws {
        targetFPS = fps
        frameInterval = Constants.Time.nanosPerSecond / UInt64(fps)

        var configurationError: Error?

        sessionQueue.sync {
            do {
                try self.configureSessionLocked(fps: fps)
            } catch {
                configurationError = error
            }
        }

        if let error = configurationError {
            throw error
        }
    }

    private func configureSessionLocked(fps: Int) throws {
        captureSession = AVCaptureSession()
        guard let session = captureSession else { return }

        session.beginConfiguration()

//        if session.canSetSessionPreset(.hd1920x1080) {
//            session.sessionPreset = .hd1920x1080
//        } else if session.canSetSessionPreset(.hd1280x720) {
//            session.sessionPreset = .hd1280x720
//        } else {
//            session.sessionPreset = .high
//        }
        
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            session.sessionPreset = .medium
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            throw CameraError.noCameraAvailable
        }

        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            camera.unlockForConfiguration()

            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                throw CameraError.cannotAddInput
            }
        } catch {
            session.commitConfiguration()
            throw CameraError.configurationFailed(error)
        }

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput?.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput?.alwaysDiscardsLateVideoFrames = true

        if let output = videoOutput, session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            session.commitConfiguration()
            throw CameraError.cannotAddOutput
        }

        if let connection = videoOutput?.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer?.videoGravity = .resizeAspectFill

        session.commitConfiguration()
    }

    // MARK: - Control

    func start() {
        guard let session = captureSession, !isRunning else {
            return
        }

        sessionQueue.async { [weak self] in
            session.startRunning()
            self?.isRunning = true
        }
    }

    func stop() {
        guard let session = captureSession, isRunning else { return }

        sessionQueue.async { [weak self] in
            session.stopRunning()
            self?.isRunning = false
        }
    }

    func updateFPS(_ fps: Int) {
        guard fps != targetFPS else { return }
        targetFPS = fps
        frameInterval = Constants.Time.nanosPerSecond / UInt64(fps)

        // Reconfigure camera FPS
        guard let session = captureSession,
              let input = session.inputs.first as? AVCaptureDeviceInput else { return }

        sessionQueue.async {
            session.beginConfiguration()
            do {
                try input.device.lockForConfiguration()
                input.device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                input.device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                input.device.unlockForConfiguration()
            } catch {
            }
            session.commitConfiguration()
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let frameCountLock = NSLock()
    private static var cameraFrameCount = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = Constants.Time.now()

        // Frame rate limiting
        let timeSinceLastFrame = timestamp - lastFrameTime
        if lastFrameTime > 0 && timeSinceLastFrame < frameInterval {
            return
        }
        lastFrameTime = timestamp

        Self.frameCountLock.lock()
        Self.cameraFrameCount += 1
        let currentCount = Self.cameraFrameCount
        Self.frameCountLock.unlock()

        if currentCount <= 3 || currentCount % 10 == 0 {
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Get intrinsics if available
        var intrinsics: CameraIntrinsics?
        if let camData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data {
            camData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                if let baseAddress = ptr.baseAddress, ptr.count >= MemoryLayout<simd_float3x3>.size {
                    let matrix = baseAddress.assumingMemoryBound(to: simd_float3x3.self).pointee
                    intrinsics = CameraIntrinsics(intrinsics: matrix)
                }
            }
        }

        // Convert to JPEG using cached context with correct orientation
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        // Fix rotation: iPhone camera is rotated 90 degrees, use .right orientation
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        guard let jpegData = uiImage.jpegData(compressionQuality: Constants.Camera.jpegQuality) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let frame = CameraFrame(
            timestamp: timestamp,
            data: jpegData,
            width: width,
            height: height,
            intrinsics: intrinsics
        )
        
        if currentCount % 30 == 0 {
            print("Sent camera frame #\(currentCount), jpg size: \(jpegData.count) bytes")
        }

        delegate?.cameraService(self, didCapture: frame)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("⚠️ Camera frame dropped")
    }
}

// MARK: - Camera Frame

struct CameraFrame {
    let timestamp: UInt64
    let data: Data // JPEG encoded
    let width: Int
    let height: Int
    let intrinsics: CameraIntrinsics?

    func metadata() -> CameraFrameMetadata {
        return CameraFrameMetadata(
            timestamp: timestamp,
            width: width,
            height: height,
            format: "jpeg",
            size: data.count,
            intrinsics: intrinsics
        )
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput
    case configurationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available on this device"
        case .cannotAddInput:
            return "Cannot add camera input to capture session"
        case .cannotAddOutput:
            return "Cannot add video output to capture session"
        case .configurationFailed(let error):
            return "Camera configuration failed: \(error.localizedDescription)"
        }
    }
}
