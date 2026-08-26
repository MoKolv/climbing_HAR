//
//  SensorData.swift
//  arvos
//
//  Data structures for all sensor types
//

import Foundation
import CoreMotion
import CoreLocation
import ARKit
import simd

// MARK: - Base Protocol

/// Base protocol for all sensor data with timestamps
protocol SensorData: Codable {
    var timestampNs: UInt64 { get }
    var sensorType: String { get }
}

// MARK: - IMU Data

/// Accelerometer and gyroscope data from CoreMotion
struct IMUData: SensorData {
    let timestampNs: UInt64
    let sensorType: String
    let sequenceId: UInt64

    /// Angular velocity in rad/s (x, y, z)
    let angularVelocity: SIMD3<Double>

    /// Linear acceleration in m/s² (x, y, z)
    let linearAcceleration: SIMD3<Double>

    /// Gravity vector in m/s² (for calibration reference)
    let gravity: SIMD3<Double>

    init(timestamp: UInt64, sequenceId: UInt64, motion: CMDeviceMotion) {
        self.timestampNs = timestamp
        self.sensorType = "imu"
        self.sequenceId = sequenceId
        self.angularVelocity = SIMD3(
            motion.rotationRate.x,
            motion.rotationRate.y,
            motion.rotationRate.z
        )
        self.linearAcceleration = SIMD3(
            motion.userAcceleration.x,
            motion.userAcceleration.y,
            motion.userAcceleration.z
        )
        self.gravity = SIMD3(
            motion.gravity.x,
            motion.gravity.y,
            motion.gravity.z
        )
    }
    
    // Initializer for watch_imu data
    init(timestampNs: UInt64, sequenceId: UInt64 = 0, sensorType: String = "imu", angularVelocity: SIMD3<Double>, linearAcceleration: SIMD3<Double>, gravity: SIMD3<Double> = SIMD3<Double>(0,0, -9.81)) {
        
        self.timestampNs = timestampNs
        self.sensorType = sensorType
        self.angularVelocity = angularVelocity
        self.linearAcceleration = linearAcceleration
        self.gravity = gravity
        self.sequenceId = sequenceId
    }

    // Memberwise initializer for custom use
    init(timestampNs: UInt64, sequenceId: UInt64, angularVelocity: SIMD3<Double>, linearAcceleration: SIMD3<Double>, gravity: SIMD3<Double> = SIMD3(0, 0, -9.81)) {
        self.sequenceId = sequenceId
        self.timestampNs = timestampNs
        self.sensorType = "imu"
        self.angularVelocity = angularVelocity
        self.linearAcceleration = linearAcceleration
        self.gravity = gravity
    }
}

// MARK: - Watch Network Data

struct WatchIMUNetworkData: SensorData {
    let timestampNs: UInt64 // adjusted to phone domain
    let sensorType: String
    let sequenceId: UInt64
    
    let watchTimestampNs: UInt64 // raw watch timestamp
    let phoneReceivedTimestampNs: UInt64 // iPhone receive timestamp
    
    let angularVelocity: SIMD3<Double>
    let linearAcceleration: SIMD3<Double>
    let gravity: SIMD3<Double>
        
}

struct WatchAttitudeNetworkData: SensorData {
    let timestampNs: UInt64 // adjusted to phone domain
    let sensorType: String
    let sequenceId: UInt64
    
    let watchTimestampNs: UInt64  // raw watch timestamp
    let phoneReceivedTimestampNs: UInt64 // iPhone receive timestamp
    
    let quaternion: SIMD4<Double>
    let pitch: Double
    let roll: Double
    let yaw: Double
    let referenceFrame: String
}


// MARK: - GPS Data

/// GPS location data from CoreLocation
struct GPSData: SensorData {
    let timestampNs: UInt64
    let sensorType: String

    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let speed: Double // m/s
    let course: Double // degrees

    init(timestamp: UInt64, location: CLLocation) {
        self.timestampNs = timestamp
        self.sensorType = "gps"
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.speed = location.speed
        self.course = location.course
    }
}


// MARK: - ARKit Pose Data

/// 6DOF pose from ARKit world tracking
struct PoseData: SensorData {
    let timestampNs: UInt64
    let sensorType: String

    /// Position in 3D space (x, y, z) in meters
    let position: SIMD3<Float>

    /// Orientation as quaternion (x, y, z, w)
    let orientation: SIMD4<Float>

    /// Tracking state quality
    let trackingState: String

    /// Whether tracking quality is good (helper for researchers)
    var isTrackingGood: Bool {
        return trackingState == "normal"
    }

    init(timestamp: UInt64, camera: ARCamera) {
        self.timestampNs = timestamp
        self.sensorType = "pose"

        let transform = camera.transform
        self.position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // Convert rotation matrix to quaternion
        let quat = simd_quaternion(transform)
        self.orientation = SIMD4(quat.vector.x, quat.vector.y, quat.vector.z, quat.vector.w)

        switch camera.trackingState {
        case .normal:
            self.trackingState = "normal"
        case .limited(let reason):
            self.trackingState = "limited_\(reason)"
        case .notAvailable:
            self.trackingState = "not_available"
        @unknown default:
            self.trackingState = "unknown"
        }
    }
}

// MARK: - Camera Frame Metadata

/// Camera frame metadata (actual image sent as binary)
struct CameraFrameMetadata: SensorData {
    let timestampNs: UInt64
    let sensorType: String

    let width: Int
    let height: Int
    let format: String // "jpeg", "h264"
    let compressedSize: Int // bytes
    let intrinsics: CameraIntrinsics?

    init(timestamp: UInt64, width: Int, height: Int, format: String, size: Int, intrinsics: CameraIntrinsics? = nil) {
        self.timestampNs = timestamp
        self.sensorType = "camera"
        self.width = width
        self.height = height
        self.format = format
        self.compressedSize = size
        self.intrinsics = intrinsics
    }
}

/// Camera intrinsic parameters
struct CameraIntrinsics: Codable {
    let fx: Float // focal length x
    let fy: Float // focal length y
    let cx: Float // principal point x
    let cy: Float // principal point y

    init(intrinsics: simd_float3x3) {
        self.fx = intrinsics[0][0]
        self.fy = intrinsics[1][1]
        self.cx = intrinsics[2][0]
        self.cy = intrinsics[2][1]
    }
}

// MARK: - Depth Data Metadata

/// Depth/point cloud metadata (actual data sent as binary)
struct DepthFrameMetadata: SensorData {
    let timestampNs: UInt64
    let sensorType: String

    let width: Int
    let height: Int
    let pointCount: Int
    let format: String // "raw_depth", "point_cloud"
    let compressedSize: Int
    let minDepth: Float // meters
    let maxDepth: Float // meters
    let hasConfidenceData: Bool // Whether depth confidence map is available

    init(timestamp: UInt64, width: Int, height: Int, pointCount: Int, format: String, size: Int, minDepth: Float, maxDepth: Float, hasConfidenceData: Bool = false) {
        self.timestampNs = timestamp
        self.sensorType = "depth"
        self.width = width
        self.height = height
        self.pointCount = pointCount
        self.format = format
        self.compressedSize = size
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.hasConfidenceData = hasConfidenceData
    }
}

// MARK: - Point Cloud

/// 3D point cloud from LiDAR or ARKit depth
struct PointCloud {
    let timestamp: UInt64
    let points: [SIMD3<Float>] // xyz positions
    let colors: [SIMD3<UInt8>]? // rgb colors (optional)
    let confidenceLevels: [UInt8]? // Confidence per point: 0=low, 1=medium, 2=high (optional)

    /// Convert to PLY format binary data
    func toPLY() -> Data {
        var ply = Data()

        // PLY header
        let colorProps = colors != nil ? "property uchar red\nproperty uchar green\nproperty uchar blue\n" : ""
        let confidenceProps = confidenceLevels != nil ? "property uchar confidence\n" : ""
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        \(colorProps)\(confidenceProps)end_header

        """
        ply.append(header.data(using: .utf8)!)

        // Vertex data
        for i in 0..<points.count {
            var point = points[i]
            ply.append(Data(bytes: &point, count: MemoryLayout<SIMD3<Float>>.size))

            if let colors = colors {
                var color = colors[i]
                ply.append(Data(bytes: &color, count: MemoryLayout<SIMD3<UInt8>>.size))
            }

            if let confidence = confidenceLevels {
                var conf = confidence[i]
                ply.append(Data(bytes: &conf, count: MemoryLayout<UInt8>.size))
            }
        }

        return ply
    }
}

// MARK: - Depth Visualization Sample

struct DepthVisualizationSample {
    let timestamp: UInt64
    let depthMap: CVPixelBuffer
    let confidenceMap: CVPixelBuffer?
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let projectionMatrix: simd_float4x4 // ARKit camera projection matrix

    var width: Int {
        CVPixelBufferGetWidth(depthMap)
    }

    var height: Int {
        CVPixelBufferGetHeight(depthMap)
    }
}
