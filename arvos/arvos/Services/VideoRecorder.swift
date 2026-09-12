//
//  VideoRecorder.swift
//  arvos
//
//  H264 video recording using AVAssetWriter
//

import Foundation
import AVFoundation

struct CompletedLocalVideo{
    let trialId: String
    let uploadBaseURL: URL
    let videoURL: URL
    let sidecarURL: URL
}

final class VideoRecorder {
    enum RecorderError: LocalizedError {
        case noFrames
        case cannotAddInput
        case cannotStartWriter
        case appendFailed
        
        var errorDescription: String? {
            switch self {
            case .noFrames: return "No frames to write"
            case .cannotAddInput: return "Cannot add video input"
            case .cannotStartWriter: return "Cannot start video writer"
            case .appendFailed: return "Failed to append sample buffer"
            }
        }
    }
    
    private struct FrameTiming {
        let frameIndex: Int
        let videoPTSNs: UInt64
        let videoPhoneTimestampNs: UInt64
    }
    
    let trialId: String
    let uploadBaseURL: URL
    let videoURL: URL
    let sidecarURL: URL
    
    private let fps: Int
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private let boundaryLock = NSLock()
    private var scheduledStartPhoneNs: UInt64?
    private var scheduledStopPhoneNs: UInt64?
    private var timings: [FrameTiming] = []
    private var terminalError: Error?
    
    init(trialId: String, fps: Int, uploadBaseURL: URL) throws {
        self.trialId = trialId
        self.fps = fps
        self.uploadBaseURL = uploadBaseURL
        
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent("PendingVideoUploads", isDirectory: true)
            .appendingPathComponent(trialId, isDirectory: true)
        
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        
        videoURL = directory.appendingPathComponent("camera_video.mp4")
        sidecarURL = directory.appendingPathComponent("video_timestamps.csv")
        
        for url in [videoURL, sidecarURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    func start(atPhoneTimestampsNs timestampNs: UInt64) {
        boundaryLock.lock()
        scheduledStartPhoneNs = timestampNs
        scheduledStopPhoneNs = nil
        boundaryLock.unlock()
    }
    
    func stopAcceptingFrames(atPhoneTimestampsNs timestampNs: UInt64) {
        boundaryLock.lock()
        scheduledStopPhoneNs = timestampNs
        boundaryLock.unlock()
    }
    
    func append(sampleBuffer: CMSampleBuffer, phoneTimestampNs: UInt64) -> Bool{
        boundaryLock.lock()
        let start = scheduledStartPhoneNs
        let stop = scheduledStopPhoneNs
        boundaryLock.unlock()
        
        guard terminalError == nil else {return false}
        guard let start, phoneTimestampNs >= start else {return false}
        if let stop, phoneTimestampNs > stop {return false}
        
        do {
            if writer == nil {
                try configureWriter(using: sampleBuffer)
            }
            
            guard let writer, let input, let firstPTS else {return false}
            guard writer.status == .writing else {
                throw writer.error ?? RecorderError.appendFailed
            }
            guard input.isReadyForMoreMediaData else {return false}
            
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard input.append(sampleBuffer) else {
                throw writer.error ?? RecorderError.appendFailed
            }
            
            let relativePTS = CMTimeSubtract(pts, firstPTS)
            timings.append(
                FrameTiming(
                    frameIndex: timings.count,
                    videoPTSNs: nanoseconds(from: relativePTS),
                    videoPhoneTimestampNs: phoneTimestampNs
                    )
                )
            return true
        } catch {
            terminalError = error
            return false
        }
    }
    
    func finish(
        preSync: PhoneClockSyncResult,
        postSync: PhoneClockSyncResult,
        completion: @escaping (Result<CompletedLocalVideo, Error>) -> Void
    ) {
        if let terminalError {
            completion(.failure(terminalError))
            return
        }
        
        guard let writer, let input, !timings.isEmpty else {
            completion(.failure(RecorderError.noFrames))
            return
        }
        
        input.markAsFinished()
        writer.finishWriting { [self] in
            do {
                if writer.status == .failed {
                    throw writer.error ?? RecorderError.appendFailed
                }
                
                try writeSidecar(preSync: preSync, postSync: postSync)
                let completed = CompletedLocalVideo(
                    trialId: trialId,
                    uploadBaseURL: uploadBaseURL,
                    videoURL: videoURL,
                    sidecarURL: sidecarURL
                )
                DispatchQueue.main.async {completion(.success(completed))}
            } catch {
                DispatchQueue.main.async {completion(.failure(error))}
            }
        }
    }
    
    func cancel() {
        boundaryLock.lock()
        scheduledStartPhoneNs = nil
        scheduledStopPhoneNs = nil
        boundaryLock.unlock()
        
        if let writer, writer.status == .writing {
            writer.cancelWriting()
        }
        
        writer = nil
        input = nil
        firstPTS = nil
        timings.removeAll()
        
        try? FileManager.default.removeItem(
            at: videoURL.deletingLastPathComponent()
        )
    }
    private func configureWriter(using sampleBuffer: CMSampleBuffer) throws {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw RecorderError.cannotAddInput
        }
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Constants.Camera.h264Bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ]
        
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings,
            sourceFormatHint: format
        )
        input.expectsMediaDataInRealTime = true
        
        guard writer.canAdd(input) else {
            throw RecorderError.cannotAddInput
        }
        
        writer.add(input)
        
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.cannotStartWriter
        }
        
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: firstPTS)
        
        self.writer = writer
        self.input = input
        self.firstPTS = firstPTS
    }
    
    private func writeSidecar(
        preSync: PhoneClockSyncResult,
        postSync: PhoneClockSyncResult
    ) throws {
        var csv = "frame_index;video_pts_ns;video_phone_timestamp_ns;server_timestamp_ns\n"
        
        for timing in timings {
            let serverTimestamp = mapToServerTime(
                phoneTimestampNs: timing.videoPhoneTimestampNs,
                preSync: preSync,
                postSync: postSync
            )
            csv += "\(timing.frameIndex);\(timing.videoPTSNs);"
            csv += "\(timing.videoPhoneTimestampNs);\(serverTimestamp)\n"
        }
        
        try csv.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }
    
    private func mapToServerTime(
        phoneTimestampNs: UInt64,
        preSync: PhoneClockSyncResult,
        postSync: PhoneClockSyncResult
    ) -> UInt64 {
        let start = preSync.phoneAnchorNs
        let end = postSync.phoneAnchorNs
        let fraction: Double
        
        if phoneTimestampNs <= start || end <= start {
            fraction = 0
        } else if phoneTimestampNs >= end {
            fraction = 1
        } else {
            fraction = Double(phoneTimestampNs - start) / Double(end - start)
        }
        
        let offset = Double(preSync.serverMinusPhoneOffsetNs) + fraction * Double(postSync.serverMinusPhoneOffsetNs - preSync.serverMinusPhoneOffsetNs)
        let serverTimestamp = Int64(phoneTimestampNs) + Int64(offset.rounded())
        return UInt64(max(0, serverTimestamp))
    }
    
    private func nanoseconds(from time: CMTime) -> UInt64 {
        guard time.isValid else { return 0 }
        
        let scaled = CMTimeConvertScale(
            time,
            timescale: 1_000_000_000,
            method: .default
        )
        return UInt64(max(0, scaled.value))
    }
    
}
