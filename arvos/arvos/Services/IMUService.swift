//
//  IMUService.swift
//  arvos
//
//  IMU (accelerometer + gyroscope) service using CoreMotion
//

import Foundation
import CoreMotion
import Combine

protocol IMUServiceDelegate: AnyObject {
    func imuService(_ service: IMUService, didUpdate data: IMUData)
    func imuService(_ service: IMUService, didEncounterError error: Error)
}

class IMUService {
    weak var delegate: IMUServiceDelegate?

    private let motionManager = CMMotionManager()
    private let operationQueue = OperationQueue()

    private var isRunning = false
    private var targetHz: Int = 100
    private var updateInterval: TimeInterval = 0.01 // 100 Hz

    // MARK: - Initialization

    init() {
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInitiated
    }

    // MARK: - Configuration

    func configure(hz: Int) throws {
        guard motionManager.isDeviceMotionAvailable else {
            throw IMUError.notAvailable
        }

        targetHz = hz
        updateInterval = 1.0 / Double(hz)
        motionManager.deviceMotionUpdateInterval = updateInterval

        // Use CMAttitudeReferenceFrameXArbitraryCorrectedZVertical for best results
        // This gives us gravity-aligned coordinates
    }

    // MARK: - Control

    func start() {
        guard motionManager.isDeviceMotionAvailable, !isRunning else { return }

        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical,
            to: operationQueue
        ) { [weak self] (motion, error) in
            guard let self = self else { return }

            if let error = error {
                self.delegate?.imuService(self, didEncounterError: error)
                return
            }

            guard let motion = motion else { return }

            let timestamp = Constants.Time.now()
            let imuData = IMUData(timestamp: timestamp, motion: motion)

            self.delegate?.imuService(self, didUpdate: imuData)
        }

        isRunning = true
    }

    func stop() {
        guard isRunning else { return }

        motionManager.stopDeviceMotionUpdates()
        isRunning = false
    }

    func updateFrequency(_ hz: Int) {
        guard hz != targetHz else { return }

        let wasRunning = isRunning
        if wasRunning {
            stop()
        }

        targetHz = hz
        updateInterval = 1.0 / Double(hz)
        motionManager.deviceMotionUpdateInterval = updateInterval

        if wasRunning {
            start()
        }
    }

    // MARK: - Additional Data (Optional)

    /// Start accelerometer-only updates (for low-power mode)
    func startAccelerometerOnly(hz: Int) {
        guard motionManager.isAccelerometerAvailable else { return }

        motionManager.accelerometerUpdateInterval = 1.0 / Double(hz)
        motionManager.startAccelerometerUpdates(to: operationQueue) { [weak self] (data, error) in
            guard let self = self, let data = data else { return }

            let timestamp = Constants.Time.now()

            // Create simplified IMU data with only acceleration
            let imuData = IMUData(
                timestampNs: timestamp,
                angularVelocity: SIMD3<Double>(0, 0, 0),
                linearAcceleration: SIMD3<Double>(data.acceleration.x, data.acceleration.y, data.acceleration.z),
                gravity: SIMD3<Double>(0, 0, -9.81)
            )

            self.delegate?.imuService(self, didUpdate: imuData)
        }
    }

    func stopAccelerometerOnly() {
        motionManager.stopAccelerometerUpdates()
    }
}

// MARK: - Errors

enum IMUError: LocalizedError {
    case notAvailable
    case updatesFailed

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Device motion is not available on this device"
        case .updatesFailed:
            return "Failed to start device motion updates"
        }
    }
}
