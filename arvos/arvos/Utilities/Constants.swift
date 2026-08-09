//
//  Constants.swift
//  arvos
//
//  App-wide constants and configuration
//

import Foundation

enum Constants {
    // MARK: - Network
    enum Network {
        static let defaultPort = 9090
        static let reconnectDelay: TimeInterval = 1.0  // Reduced from 2.0 for faster recovery
        static let maxReconnectAttempts = 10  // Increased from 5 for better resilience
        static let connectionTimeout: TimeInterval = 10.0
        static let heartbeatInterval: TimeInterval = 15.0  // Reduced from 30.0 (if it was higher) to detect connection issues faster
    }

    // MARK: - Recording
    enum Recording {
        static let maxRecordingDuration: TimeInterval = 3600 // 1 hour
        static let minFreeSpace: Int64 = 1_000_000_000 // 1 GB
        static let recordingsDirectory = "Recordings"
    }

    // MARK: - Camera
    enum Camera {
        static let jpegQuality: CGFloat = 0.25
        static let maxResolution = CGSize(width: 1920, height: 1080)
        static let h264Bitrate = 5_000_000 // 5 Mbps
    }

    // MARK: - Depth
    enum Depth {
        static let maxPoints = 100_000
        static let minDepth: Float = 0.1 // meters
        static let maxDepth: Float = 5.0 // meters
        static let downsampleFactor = 4  // Original value - works well for iOS
    }

    // MARK: - UI
    enum UI {
        static let animationDuration: TimeInterval = 0.3
        static let cornerRadius: CGFloat = 12.0
        static let padding: CGFloat = 16.0
    }

    // MARK: - Timestamps
    enum Time {
        static let nanosPerSecond: UInt64 = 1_000_000_000

        /// Get current timestamp in nanoseconds since boot
        static func now() -> UInt64 {
            var time = mach_timebase_info()
            mach_timebase_info(&time)
            let nanos = mach_absolute_time() * UInt64(time.numer) / UInt64(time.denom)
            return nanos
        }

        /// Get current system time in nanoseconds since Unix epoch
        static func systemTime() -> UInt64 {
            let now = Date().timeIntervalSince1970
            return UInt64(now * Double(nanosPerSecond))
        }
    }
}
