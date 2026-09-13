//
//  WatchSensorPacket.swift
//  arvos
//
//  Data packet for watch sensor transmission
//

import Foundation
import CoreMotion
import simd

struct MotionAttitude: Codable {
    let quaternion: SIMD4<Double>
    let pitch: Double
    let roll: Double
    let yaw: Double
    let referenceFrame: String
}

struct WatchMotionData: Codable {
    let angularVelocity: SIMD3<Double>
    let linearAcceleration: SIMD3<Double>
    let gravity: SIMD3<Double>
    let attitude: MotionAttitude
}

struct WatchSensorPacket: Codable {
    let timestampNs: UInt64
    let sequenceId: UInt64
    let sensorType: String
    let data: Data
    
    static func motion(
        timestamp: UInt64,
        sequenceId: UInt64,
        angularVelocity: SIMD3<Double>,
        linearAcceleration: SIMD3<Double>,
        gravity: SIMD3<Double>,
        attitude: MotionAttitude
    ) -> WatchSensorPacket? {
        let motion = WatchMotionData(
            angularVelocity: angularVelocity,
            linearAcceleration: linearAcceleration,
            gravity: gravity,
            attitude: attitude
        )
        
        guard let encoded = try? JSONEncoder().encode(motion) else {
            return nil
        }
        
        return WatchSensorPacket(
            timestampNs: timestamp,
            sequenceId: sequenceId,
            sensorType: "watch_motion",
            data: encoded
        )
    }
    
    static func motionActivity(
        timestamp: UInt64,
        activity: WatchMotionActivityData
    ) -> WatchSensorPacket? {
        guard let encoded = try? JSONEncoder().encode(activity) else {
            return nil
        }
        
        return WatchSensorPacket(
            timestampNs: timestamp,
            sequenceId: 0,
            sensorType: "watch_activity",
            data: encoded
        )
    }
    
    func decodeMotion() -> WatchMotionData? {
        guard sensorType == "watch_motion" else { return nil }
        return try? JSONDecoder().decode(WatchMotionData.self, from: data)
    }
    
    func decodeMotionActivity() -> WatchMotionActivityData? {
        guard sensorType == "watch_activity" else { return nil }
        return try? JSONDecoder().decode(WatchMotionActivityData.self, from: data)
    }
    
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
