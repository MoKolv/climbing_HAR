//
//  RecordingManager.swift
//  arvos
//
//  Manages recording to MCAP, PLY, and H264 formats
//

import Foundation
import Combine

class RecordingManager: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var sessionId: String?
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var fileSize: Int64 = 0

    private var mcapWriter: MCAPWriter?
    private var videoRecorder: VideoRecorder?
    private var pointCloudFiles: [URL] = []
    private var currentRecordingMode: StreamMode?

    private var startTime: Date?
    private var timer: Timer?

    // File I/O queue for async writes
    private let fileIOQueue = DispatchQueue(label: "com.arvos.recording.fileio", qos: .utility)

    private var recordingsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(Constants.Recording.recordingsDirectory)
    }

    // Channel IDs for MCAP
    private var imuChannelId: UInt16?
    private var gpsChannelId: UInt16?
    private var poseChannelId: UInt16?
    private var cameraChannelId: UInt16?
    private var depthChannelId: UInt16?

    private var sensorCounts = SensorCounts()

    struct SensorCounts {
        var cameraFrames = 0
        var depthFrames = 0
        var imuSamples = 0
        var poseSamples = 0
        var gpsSamples = 0
    }

    // MARK: - Initialization

    deinit {
        timer?.invalidate()
    }

    init() {
        createRecordingsDirectory()
    }

    private func createRecordingsDirectory() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Recording Control

    func startRecording(mode: StreamMode) throws {
        guard !isRecording else { return }

        // Check available space
        guard hasEnoughSpace() else {
            throw RecordingError.insufficientSpace
        }

        // Generate session ID
        sessionId = UUID().uuidString
        startTime = Date()
        currentRecordingMode = mode
        sensorCounts = SensorCounts()

        // Create session directory
        let sessionDir = recordingsDirectory.appendingPathComponent(sessionId!)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Initialize MCAP writer
        let mcapPath = sessionDir.appendingPathComponent("session.mcap")
        mcapWriter = try MCAPWriter(filePath: mcapPath)

        // Add MCAP channels
        imuChannelId = mcapWriter?.addChannel(topic: "/imu", messageEncoding: "application/json")
        gpsChannelId = mcapWriter?.addChannel(topic: "/gps", messageEncoding: "application/json")
        poseChannelId = mcapWriter?.addChannel(topic: "/pose", messageEncoding: "application/json")
        cameraChannelId = mcapWriter?.addChannel(topic: "/camera", messageEncoding: "image/jpeg")
        depthChannelId = mcapWriter?.addChannel(topic: "/depth", messageEncoding: "application/octet-stream")

        // Initialize video recorder if camera enabled
        if mode.config.cameraEnabled {
            let videoPath = sessionDir.appendingPathComponent("camera.mov")
            videoRecorder = try VideoRecorder(
                outputURL: videoPath,
                width: 1920,
                height: 1080,
                fps: mode.config.cameraFPS
            )
            try videoRecorder?.start()
        }

        isRecording = true

        // Start duration timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
            self.updateFileSize()
        }
    }

    func stopRecording() throws {
        guard isRecording else { return }

        isRecording = false
        timer?.invalidate()
        timer = nil

        // Finalize MCAP
        try mcapWriter?.finalize()
        mcapWriter = nil

        // Stop video
        try videoRecorder?.stop()
        videoRecorder = nil

        // Save metadata
        try saveMetadata()

        // Reset
        sessionId = nil
        startTime = nil
        recordingDuration = 0
        fileSize = 0
        sensorCounts = SensorCounts()
    }

    // MARK: - Recording Data

    func record(imuData: IMUData) {
        guard isRecording, let channelId = imuChannelId, let writer = mcapWriter else { return }

        do {
            let data = try JSONEncoder().encode(imuData)
            try writer.writeMessage(channelId: channelId, timestamp: imuData.timestampNs, data: data)
            sensorCounts.imuSamples += 1
        } catch {
        }
    }

    func record(gpsData: GPSData) {
        guard isRecording, let channelId = gpsChannelId, let writer = mcapWriter else { return }

        do {
            let data = try JSONEncoder().encode(gpsData)
            try writer.writeMessage(channelId: channelId, timestamp: gpsData.timestampNs, data: data)
            sensorCounts.gpsSamples += 1
        } catch {
        }
    }

    func record(poseData: PoseData) {
        guard isRecording, let channelId = poseChannelId, let writer = mcapWriter else { return }

        do {
            let data = try JSONEncoder().encode(poseData)
            try writer.writeMessage(channelId: channelId, timestamp: poseData.timestampNs, data: data)
            sensorCounts.poseSamples += 1
        } catch {
        }
    }

    func record(cameraFrame: CameraFrame) {
        guard isRecording else { return }

        // Record to MCAP
        if let channelId = cameraChannelId, let writer = mcapWriter {
            do {
                try writer.writeMessage(channelId: channelId, timestamp: cameraFrame.timestamp, data: cameraFrame.data)
            } catch {
            }
        }

        // Record to video
        if let recorder = videoRecorder {
            do {
                try recorder.write(frame: cameraFrame)
                sensorCounts.cameraFrames += 1
            } catch {
            }
        }
    }

    func record(depthFrame: DepthFrame) {
        guard isRecording, let sessionId = sessionId else { return }

        // Save point cloud as PLY file asynchronously to prevent frame drops
        let plyData = depthFrame.pointCloud.toPLY()
        let filename = "pointcloud_\(depthFrame.timestamp).ply"
        let plyPath = recordingsDirectory.appendingPathComponent(sessionId).appendingPathComponent(filename)

        fileIOQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try plyData.write(to: plyPath)

                // Update state on main queue
                DispatchQueue.main.async {
                    self.pointCloudFiles.append(plyPath)

                    // Also record to MCAP (reference to PLY file)
                    if let channelId = self.depthChannelId, let writer = self.mcapWriter {
                        let reference = filename.data(using: .utf8) ?? Data()
                        try? writer.writeMessage(channelId: channelId, timestamp: depthFrame.timestamp, data: reference)
                    }

                    self.sensorCounts.depthFrames += 1
                }
            } catch {
            }
        }
    }

    // MARK: - Metadata

    private func saveMetadata() throws {
        guard let sessionId = sessionId, let startTime = startTime else { return }

        let metadata = SessionMetadata(
            sessionId: sessionId,
            mode: currentRecordingMode ?? .fullSensor,
            startTime: startTime,
            endTime: Date(),
            duration: recordingDuration,
            fileFormats: ["mcap", "mov", "ply"],
            fileSize: fileSize,
            sensorCounts: SessionMetadata.SensorCounts(
                cameraFrames: sensorCounts.cameraFrames,
                depthFrames: sensorCounts.depthFrames,
                imuSamples: sensorCounts.imuSamples,
                poseSamples: sensorCounts.poseSamples,
                gpsSamples: sensorCounts.gpsSamples
            )
        )

        let metadataPath = recordingsDirectory.appendingPathComponent(sessionId).appendingPathComponent("metadata.json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataPath)
    }

    // MARK: - Utilities

    private func hasEnoughSpace() -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: recordingsDirectory.path)
            if let freeSpace = attributes[.systemFreeSize] as? Int64 {
                return freeSpace > Constants.Recording.minFreeSpace
            }
        } catch {
        }
        return true
    }

    private func updateFileSize() {
        guard let sessionId = sessionId else { return }
        let sessionDir = recordingsDirectory.appendingPathComponent(sessionId)

        do {
            let files = try FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: [.fileSizeKey])
            var totalSize: Int64 = 0

            for file in files {
                let attributes = try file.resourceValues(forKeys: [.fileSizeKey])
                totalSize += Int64(attributes.fileSize ?? 0)
            }

            fileSize = totalSize
        } catch {
        }
    }

    // MARK: - Replay

    func listRecordings() -> [SessionMetadata] {
        var recordings: [SessionMetadata] = []

        do {
            let sessions = try FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)

            for sessionDir in sessions where sessionDir.hasDirectoryPath {
                let metadataPath = sessionDir.appendingPathComponent("metadata.json")

                if let data = try? Data(contentsOf: metadataPath),
                   let metadata = try? JSONDecoder().decode(SessionMetadata.self, from: data) {
                    recordings.append(metadata)
                }
            }
        } catch {
        }

        return recordings.sorted { $0.startTime > $1.startTime }
    }

    func deleteRecording(sessionId: String) throws {
        let sessionDir = recordingsDirectory.appendingPathComponent(sessionId)
        try FileManager.default.removeItem(at: sessionDir)
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case insufficientSpace
    case recordingInProgress
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .insufficientSpace:
            return "Insufficient storage space to start recording"
        case .recordingInProgress:
            return "A recording is already in progress"
        case .noActiveRecording:
            return "No active recording to stop"
        }
    }
}
