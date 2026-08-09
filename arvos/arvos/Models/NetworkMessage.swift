//
//  NetworkMessage.swift
//  arvos
//
//  Network message protocol for WebSocket streaming
//

import Foundation
import UIKit
import ARKit
import CoreLocation

// MARK: - Message Protocol

/// Base protocol for all network messages
protocol NetworkMessage: Codable {
    var type: String { get }
    var timestampNs: UInt64 { get }
}

// MARK: - Message Types

/// JSON message wrapper for small sensor data
struct JSONMessage: NetworkMessage, Codable {
    let type: String
    let timestampNs: UInt64
    let payload: Data

    init<T: SensorData>(data: T) throws {
        self.type = data.sensorType
        self.timestampNs = data.timestampNs
        self.payload = try JSONEncoder().encode(data)
    }
}

/// Binary message header for large data (images, point clouds)
struct BinaryMessageHeader: Codable {
    let type: String
    let timestampNs: UInt64
    let dataSize: Int
    let metadata: Data // JSON-encoded metadata

    init<T: SensorData>(metadata: T, dataSize: Int) throws {
        self.type = metadata.sensorType
        self.timestampNs = metadata.timestampNs
        self.dataSize = dataSize
        self.metadata = try JSONEncoder().encode(metadata)
    }
}

/// Binary message format: [Header (JSON)] + [Binary Data]
struct BinaryMessage {
    let header: BinaryMessageHeader
    let data: Data

    func encode() -> Data? {
        var result = Data()

        // Encode header as JSON
        guard let headerJSON = try? JSONEncoder().encode(header) else {
            #if DEBUG
            #endif
            return nil
        }
        let headerSize = UInt32(headerJSON.count)

        // Write header size (4 bytes) + header JSON + binary data
        var size = headerSize.littleEndian
        result.append(Data(bytes: &size, count: 4))
        result.append(headerJSON)
        result.append(data)

        return result
    }
}

// MARK: - Control Messages

/// Connection handshake message
struct HandshakeMessage: Codable {
    let type: String
    let deviceName: String
    let deviceModel: String
    let osVersion: String
    let appVersion: String
    let capabilities: DeviceCapabilities
    let timestampNs: UInt64

    init(timestamp: UInt64) {
        self.type = "handshake"
        self.deviceName = UIDevice.current.name
        self.deviceModel = UIDevice.current.model
        self.osVersion = UIDevice.current.systemVersion
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        self.capabilities = DeviceCapabilities()
        self.timestampNs = timestamp
    }
}

/// Device capabilities
struct DeviceCapabilities: Codable {
    let hasLiDAR: Bool
    let hasARKit: Bool
    let hasGPS: Bool
    let hasIMU: Bool
    let supportedModes: [String]

    init() {
        self.hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        self.hasARKit = ARWorldTrackingConfiguration.isSupported
        // Check location services availability
        let servicesEnabled = CLLocationManager.locationServicesEnabled()
        self.hasGPS = servicesEnabled
        self.hasIMU = true // All iPhones have IMU
        self.supportedModes = StreamMode.allCases.map { $0.rawValue }
    }
}

/// Mode configuration message
struct ModeConfigMessage: Codable {
    let type: String
    let mode: StreamMode
    let config: ModeConfiguration
    let timestampNs: UInt64

    init(mode: StreamMode, timestamp: UInt64) {
        self.type = "mode_config"
        self.mode = mode
        self.config = mode.config
        self.timestampNs = timestamp
    }
}

/// Status message
struct StatusMessage: Codable, Sendable {
    let type: String
    let timestampNs: UInt64
    let status: String // "connected", "streaming", "recording", "stopped", "error"
    let message: String?
    let sessionId: String?

    init(timestamp: UInt64, status: String, message: String? = nil, sessionId: String? = nil) {
        self.type = "status"
        self.timestampNs = timestamp
        self.status = status
        self.message = message
        self.sessionId = sessionId
    }
}

/// Error message
struct ErrorMessage: Codable {
    let type: String
    let timestampNs: UInt64
    let error: String
    let details: String?

    init(timestamp: UInt64, error: String, details: String? = nil) {
        self.type = "error"
        self.timestampNs = timestamp
        self.error = error
        self.details = details
    }
}

// MARK: - Session Metadata

/// Recording session metadata
struct SessionMetadata: Codable {
    let sessionId: String
    let mode: StreamMode
    let startTime: Date
    let endTime: Date?
    let duration: TimeInterval
    let fileFormats: [String] // ["mcap", "ply", "h264"]
    let fileSize: Int64 // bytes
    let sensorCounts: SensorCounts

    struct SensorCounts: Codable {
        let cameraFrames: Int
        let depthFrames: Int
        let imuSamples: Int
        let poseSamples: Int
        let gpsSamples: Int
    }
}
