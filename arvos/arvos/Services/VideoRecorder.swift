//
//  VideoRecorder.swift
//  arvos
//
//  H264 video recording using AVAssetWriter
//

import Foundation
import AVFoundation
import UIKit

class VideoRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let outputURL: URL
    private var isRecording = false
    private var frameCount = 0
    private var startTime: CMTime?

    private let videoSettings: [String: Any]

    // MARK: - Initialization

    init(outputURL: URL, width: Int, height: Int, fps: Int) throws {
        self.outputURL = outputURL

        // Video settings
        videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Constants.Camera.h264Bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        // Create asset writer
        assetWriter = try AVAssetWriter(url: outputURL, fileType: .mov)

        // Create video input
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

        // Create pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        guard let videoInput = videoInput else {
            throw VideoRecorderError.cannotAddInput
        }

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        // Add input to writer
        guard let writer = assetWriter, writer.canAdd(videoInput) else {
            throw VideoRecorderError.cannotAddInput
        }
        writer.add(videoInput)
    }

    // MARK: - Recording Control

    func start() throws {
        guard let writer = assetWriter else { return }

        guard writer.startWriting() else {
            if let error = writer.error {
                throw error
            }
            throw VideoRecorderError.cannotStartWriting
        }

        writer.startSession(atSourceTime: .zero)
        isRecording = true
        startTime = .zero
    }

    func stop() throws {
        guard isRecording else { return }
        isRecording = false

        videoInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        var finalError: Error?

        assetWriter?.finishWriting {
            if let error = self.assetWriter?.error {
                finalError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let error = finalError {
            throw error
        }
    }

    // MARK: - Frame Writing

    func write(frame: CameraFrame) throws {
        guard isRecording, let input = videoInput, input.isReadyForMoreMediaData else {
            return
        }

        // Convert JPEG to pixel buffer
        guard let uiImage = UIImage(data: frame.data),
              let cgImage = uiImage.cgImage else {
            return
        }

        guard let pixelBuffer = createPixelBuffer(from: cgImage) else {
            throw VideoRecorderError.cannotCreatePixelBuffer
        }

        // Calculate presentation time
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(30)) // Assuming 30 FPS
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))

        // Append pixel buffer
        guard let adaptor = pixelBufferAdaptor else {
            throw VideoRecorderError.cannotCreatePixelBuffer
        }
        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            if let error = assetWriter?.error {
                throw error
            }
        }

        frameCount += 1
    }

    private func createPixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height

        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )

        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }

    // MARK: - Statistics

    func getStatistics() -> VideoStatistics {
        return VideoStatistics(
            frameCount: frameCount,
            fileSizeBytes: fileSize(),
            isRecording: isRecording
        )
    }

    private func fileSize() -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
}

// MARK: - Statistics

struct VideoStatistics {
    let frameCount: Int
    let fileSizeBytes: Int64
    let isRecording: Bool

    var fileSizeMB: Double {
        return Double(fileSizeBytes) / (1024.0 * 1024.0)
    }

    var duration: TimeInterval {
        return Double(frameCount) / 30.0 // Assuming 30 FPS
    }
}

// MARK: - Errors

enum VideoRecorderError: LocalizedError {
    case cannotAddInput
    case cannotStartWriting
    case cannotCreatePixelBuffer
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Cannot add video input to asset writer"
        case .cannotStartWriting:
            return "Cannot start video writing"
        case .cannotCreatePixelBuffer:
            return "Cannot create pixel buffer from image"
        case .writeFailed:
            return "Failed to write video frame"
        }
    }
}
