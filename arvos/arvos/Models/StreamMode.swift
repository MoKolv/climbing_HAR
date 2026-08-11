//
//  StreamMode.swift
//  arvos
//
//  Core streaming modes with specific sensor configurations
//

import Foundation

/// Streaming mode defining which sensors to use and at what rates
enum StreamMode: String, Codable, CaseIterable, Identifiable {
    case rgbdCamera = "RGBD Camera"
    case visualInertial = "Visual-Inertial"
    case lidarScanner = "LiDAR Scanner"
    case imuOnly = "IMU Only"
    case gpsTracker = "GPS Tracker"
    case fullSensor = "Full Sensor"
    case lowPower = "Low Power"
    case custom = "Custom"

    var id: String { rawValue }

    /// User-facing description of the mode
    var description: String {
        switch self {
        case .rgbdCamera:
            return "RGB camera + depth\n(RealSense/Kinect mode)"
        case .visualInertial:
            return "Camera + IMU\n(VIO/SLAM mode)"
        case .lidarScanner:
            return "Depth point clouds\n(3D scanning)"
        case .imuOnly:
            return "Accel + Gyro\n(Motion tracking)"
        case .gpsTracker:
            return "Location + Pose\n(Navigation)"
        case .fullSensor:
            return "All sensors max rate\n(Research mode)"
        case .lowPower:
            return "Minimal sensors\n(Battery saver)"
        case .custom:
            return "Choose specific sensors\n(Custom configuration)"
        }
    }

    /// SF Symbol icon for the mode
    var icon: String {
        switch self {
        case .rgbdCamera:
            return "camera.metering.matrix"
        case .visualInertial:
            return "video.badge.waveform"
        case .lidarScanner:
            return "cube.transparent"
        case .imuOnly:
            return "gyroscope"
        case .gpsTracker:
            return "location.circle"
        case .fullSensor:
            return "cpu.fill"
        case .lowPower:
            return "battery.100"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    /// Configuration for this mode
    var config: ModeConfiguration {
        switch self {
        case .rgbdCamera:
            // Acts like Intel RealSense D435 or Kinect
            return ModeConfiguration(
                cameraEnabled: true,
                cameraFPS: 30,
                depthEnabled: true,
                depthFPS: 30,  // Synchronized RGB-D
                imuEnabled: false,
                imuHz: 0,
                poseEnabled: false,
                poseHz: 0,
                gpsEnabled: false,
                watchEnabled: false,
                watchHz: 0,
                recordingEnabled: false,
                autoDuration: nil
            )
        case .visualInertial:
            // Camera + IMU for VIO/SLAM (like OAK-D, ZED)
            return ModeConfiguration(
                cameraEnabled: true,
                cameraFPS: 30,
                depthEnabled: false,  // Optional: can enable for VI-SLAM
                depthFPS: 0,
                imuEnabled: true,
                imuHz: 200,  // High-rate IMU for VIO
                poseEnabled: false,
                poseHz: 0,
                gpsEnabled: false,
                watchEnabled: false,
                watchHz: 0,
                recordingEnabled: false,
                autoDuration: nil
            )
        case .lidarScanner:
            // Pure depth scanning (like Faro, BLK360)
            return ModeConfiguration(
                cameraEnabled: false,
                cameraFPS: 0,
                depthEnabled: true,
                depthFPS: 10,
                imuEnabled: false,
                imuHz: 0,
                poseEnabled: true,  // For pose context
                poseHz: 10,
                gpsEnabled: false,
                watchEnabled: false,
                watchHz: 0,
                recordingEnabled: true,  // Auto-record scans
                autoDuration: nil
            )
        case .imuOnly:
            // Pure inertial measurement (like Xsens, VectorNav)
            return ModeConfiguration(
                cameraEnabled: false,
                cameraFPS: 0,
                depthEnabled: false,
                depthFPS: 0,
                imuEnabled: true,
                imuHz: 200,  // High-rate for accurate integration
                poseEnabled: false,
                poseHz: 0,
                gpsEnabled: false,
                watchEnabled: true,  // Enable watch IMU for dual-device tracking
                watchHz: 50,
                recordingEnabled: false,
                autoDuration: nil
            )
        case .gpsTracker:
            // Location tracking (like Garmin, survey-grade GPS)
            return ModeConfiguration(
                cameraEnabled: false,
                cameraFPS: 0,
                depthEnabled: false,
                depthFPS: 0,
                imuEnabled: false,
                imuHz: 0,
                poseEnabled: true,
                poseHz: 10,
                gpsEnabled: true,
                watchEnabled: false,
                watchHz: 0,
                recordingEnabled: false,
                autoDuration: nil
            )
        case .fullSensor:
            // All sensors at maximum rates (research/dataset collection)
            return ModeConfiguration(
                cameraEnabled: true,
                cameraFPS: 30,
                depthEnabled: true,
                depthFPS: 10,
                imuEnabled: true,
                imuHz: 200,
                poseEnabled: true,
                poseHz: 60,
                gpsEnabled: true,
                watchEnabled: true,  // Include watch sensors in full mode
                watchHz: 50,
                recordingEnabled: true,
                autoDuration: nil
            )
        case .lowPower:
            // Minimal sensors for extended battery life
            return ModeConfiguration(
                cameraEnabled: true,
                cameraFPS: 2,
                depthEnabled: false,
                depthFPS: 0,
                imuEnabled: true,
                imuHz: 50,
                poseEnabled: false,
                poseHz: 0,
                gpsEnabled: false,
                watchEnabled: false,
                watchHz: 0,
                recordingEnabled: false,
                autoDuration: nil
            )
        case .custom:
            // Default configuration for custom mode - will be modified by user selection
            return ModeConfiguration(
                cameraEnabled: true,
                cameraFPS: 30,
                depthEnabled: false,
                depthFPS: 10,
                imuEnabled: true,
                imuHz: 200,
                poseEnabled: false,
                poseHz: 60,
                gpsEnabled: false,
                watchEnabled: true,
                watchHz: 100 ,
                recordingEnabled: false,
                autoDuration: nil
            )
        }
    }
}

/// Configuration parameters for a streaming mode
struct ModeConfiguration: Codable {
    var cameraEnabled: Bool
    var cameraFPS: Int
    var depthEnabled: Bool
    var depthFPS: Int
    var imuEnabled: Bool
    var imuHz: Int
    var poseEnabled: Bool
    var poseHz: Int
    var gpsEnabled: Bool
    var watchEnabled: Bool
    var watchHz: Int
    var recordingEnabled: Bool
    var autoDuration: TimeInterval? // Auto-stop duration in seconds
}
