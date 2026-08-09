//
//  WatchSensorPacket.swift
//  arvos
//
//  Data packet for watch sensor transmission
//

import Foundation
import CoreMotion
import simd

/// Packet containing sensor data from Apple Watch
struct WatchSensorPacket: Codable {
    let timestampNs: UInt64
    let sensorType: String
    let data: Data
    
    /// Create an IMU packet from watch sensor data
    static func imu(timestamp: UInt64, angularVelocity: SIMD3<Double>, linearAcceleration: SIMD3<Double>, gravity: SIMD3<Double>) -> WatchSensorPacket? {
        let imuData = WatchIMUData(
            angularVelocity: angularVelocity,
            linearAcceleration: linearAcceleration,
            gravity: gravity
        )

        guard let encoded = try? JSONEncoder().encode(imuData) else {
            #if DEBUG
            #endif
            return nil
        }

        return WatchSensorPacket(
            timestampNs: timestamp,
            sensorType: "watch_imu",
            data: encoded
        )
    }
    
    /// Create an attitude packet from watch pose data
    static func attitude(timestamp: UInt64, quaternion: SIMD4<Double>, pitch: Double, roll: Double, yaw: Double, referenceFrame: String) -> WatchSensorPacket? {
        let attitude = WatchAttitudeData(
            quaternion: quaternion,
            pitch: pitch,
            roll: roll,
            yaw: yaw,
            referenceFrame: referenceFrame
        )

        guard let encoded = try? JSONEncoder().encode(attitude) else {
            #if DEBUG
            #endif
            return nil
        }

        return WatchSensorPacket(
            timestampNs: timestamp,
            sensorType: "watch_attitude",
            data: encoded
        )
    }
    
    /// Create a motion activity packet
    static func motionActivity(timestamp: UInt64, activity: WatchMotionActivityData) -> WatchSensorPacket? {
        guard let encoded = try? JSONEncoder().encode(activity) else {
            #if DEBUG
            #endif
            return nil
        }

        return WatchSensorPacket(
            timestampNs: timestamp,
            sensorType: "watch_activity",
            data: encoded
        )
    }

    /// Decode IMU data from packet
    func decodeIMU() -> WatchIMUData? {
        guard sensorType == "watch_imu" else { return nil }
        
        do {
            return try JSONDecoder().decode(WatchIMUData.self, from: data)
        } catch {
            print("failed to decode WatchImuDdata:", error)
            
            if let json = String(data: data, encoding: .utf8) {
                print("raw watch imu payload", json)
            }
            return nil
        }
    }
    
    
    func decodeAttitude() -> WatchAttitudeData? {
        guard sensorType == "watch_attitude" else { return nil }
        return try? JSONDecoder().decode(WatchAttitudeData.self, from: data)
    }
    
    func decodeMotionActivity() -> WatchMotionActivityData? {
        guard sensorType == "watch_activity" else { return nil }
        return try? JSONDecoder().decode(WatchMotionActivityData.self, from: data)
    }
    
}

/// Watch IMU sensor data
struct WatchIMUData: Codable {
    let angularVelocity: SIMD3<Double>
    let linearAcceleration: SIMD3<Double>
    let gravity: SIMD3<Double>
}

/// Watch attitude pose data
struct WatchAttitudeData: Codable {
    let quaternion: SIMD4<Double>
    let pitch: Double
    let roll: Double
    let yaw: Double
    let referenceFrame: String
}

/// Apple Motion Activity classification (ML-backed)
struct WatchMotionActivityData: Codable {
    let isWalking: Bool
    let isRunning: Bool
    let isCycling: Bool
    let isDriving: Bool
    let isStationary: Bool
    let isUnknown: Bool
    let confidence: Int
}

extension WatchMotionActivityData {
    var descriptionLabel: String {
        if isRunning { return "running" }
        if isWalking { return "walking" }
        if isCycling { return "cycling" }
        if isDriving { return "in vehicle" }
        if isStationary { return "stationary" }
        return "unknown"
    }
    
    var confidenceDescription: String {
        switch confidence {
        case CMMotionActivityConfidence.low.rawValue:
            return "Low"
        case CMMotionActivityConfidence.medium.rawValue:
            return "Medium"
        case CMMotionActivityConfidence.high.rawValue:
            return "High"
        default:
            return "Unknown"
        }
    }
}

/// Watch heart rate data (future extension)
struct WatchHeartRateData: Codable {
    let bpm: Double
    let confidence: Double
}

/// Watch workout metrics (future extension)
struct WatchWorkoutData: Codable {
    let activeCalories: Double
    let distance: Double
    let steps: Int
}
