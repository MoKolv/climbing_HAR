//
//  WatchSensorService.swift
//  arvosWatchApp
//
//  Captures IMU and other sensor data on Apple Watch
//

import Foundation
import CoreMotion
import Combine

class WatchSensorService: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var currentHz: Double = 0
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var latestAttitude: WatchAttitudeData?
    @Published private(set) var latestActivity: WatchMotionActivityData?
    
    private let motionManager = CMMotionManager()
    private let activityManager = CMMotionActivityManager()
    private let connectivityService = WatchConnectivityService.shared
    
    private var updateTimer: Timer?
    private var sampleTimestamps: [TimeInterval] = []
    private let fpsWindow: TimeInterval = 1.0
    
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    
    private let activityQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    
    private var isMotionCaptureRunninging = false
    private var resumeCaptureAfterSyncPause = false
    private var sensorTransmissionPaused = false

    
    
    // Configuration
    private var targetHz: Int = 50 // Default to 50Hz for watch (battery friendly)
    private var updateInterval: TimeInterval {
        return 1.0 / Double(targetHz)
    }
    
    init() {
        setupMotionManager()
        setupCommandObserver()
    }

    deinit {
        updateTimer?.invalidate()
    }

    private func setupCommandObserver() {
        NotificationCenter.default.addObserver(
            forName: .watchCommandReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self = self,
                  let command = notification.userInfo?["command"] as? String,
                  let parameters = notification.userInfo?["parameters"] as? [String: Any] else {
                return
            }
            
            self.handleCommand(command, parameters: parameters)
        }
    }
    
    private func parseHz(from parameters:[String: Any], defaultHz: Int = 50) -> Int {
        let rawHz = parameters["hz"]
        
        print("Raw hz parameter", String(describing: rawHz), "type:", type(of:rawHz as Any))
        
        if let hz = rawHz as? Int {
            return hz
        }
        
        if let hz = rawHz as? Double {
            return Int(hz)
        }
        
        if let hz = rawHz as? NSNumber {
            return hz.intValue
        }
        
        if let hzString = rawHz as? String, let hz = Int(hzString) {
            return hz
        }
        
        return defaultHz
    }
    
    private func handleCommand(_ command: String, parameters: [String: Any]) {
        
        print("WatchSensorService received command :", command, parameters)
        
        switch command {
        case "start_streaming":
            let hz = parseHz(from: parameters, defaultHz: 50)
            print("Starting WatchSensorService streaming at \(hz) penHz")
            startStreaming(hz: hz)
            
        case "stop_streaming":
            stopStreaming()
            
        case "update_frequency":
            let hz = parseHz(from: parameters, defaultHz: 50)
            updateFrequency(hz)
            
        case "pause_sensor_transmission":
            sensorTransmissionPaused = true
            resumeCaptureAfterSyncPause = isStreaming && isMotionCaptureRunninging
            
            stopMotionCapture()
            connectivityService.discardBufferedSensorPackers()
            connectivityService.cancelOutstandingSensorTransfers()
            
            print("Watch sensor transmission paused, backlog cleared")
            
        case "resume_sensor_transmission":
            let shouldResumeCapture = resumeCaptureAfterSyncPause && isStreaming
            
            sensorTransmissionPaused = false
            resumeCaptureAfterSyncPause = false
            
            if shouldResumeCapture {
                motionManager.deviceMotionUpdateInterval = updateInterval
                startMotionCapture()
            }
            print("Watch sensor transmission resumed")
                        
        default:
            print("⚠️ Unknown command: \(command)")
        }
    }
    
    private func setupMotionManager() {
        guard motionManager.isDeviceMotionAvailable else {
            print("❌ Device motion not available on this watch")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = updateInterval
    }
    
    private func startMotionCapture() {
        guard !isMotionCaptureRunninging else { return }
        
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self, let motion else {
                if let error {
                    print("Motion update error: \(error)")
                }
                return
            }
            self.handleMotionUpdate(motion)
        }
        
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: activityQueue) { [weak self] activity in
                guard let self, let activity else {return}
                self.handleActivityUpdate(activity)
            }
        } else {
            print("Motion activity classification not available on this watch")
        }
        
        isMotionCaptureRunninging = true
            
    }

    private func stopMotionCapture(resetDisplayedHz: Bool = true) {
        guard isMotionCaptureRunninging else {return}
        
        motionManager.stopDeviceMotionUpdates()
        
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.stopActivityUpdates()
        }
        
        updateTimer?.invalidate()
        updateTimer = nil
        isMotionCaptureRunninging = false
        
        if resetDisplayedHz {
            DispatchQueue.main.async {
                self.currentHz = 0
            }
        }
    }
    // MARK: - Streaming Control
    
    func startStreaming(hz: Int = 50) {
        sensorTransmissionPaused = false
        resumeCaptureAfterSyncPause = false
        
        guard !isStreaming else {
            print("start_streaming on watch called while already streaming, ignored")
            return
        }
        guard motionManager.isDeviceMotionAvailable else {
            print("❌ Cannot start streaming: device motion not available")
            return
        }
        
        targetHz = min(hz, 100) // Cap at 100Hz for watch
        motionManager.deviceMotionUpdateInterval = updateInterval
        
        startMotionCapture()
        
        DispatchQueue.main.async {
            self.isStreaming = true
            self.sampleCount = 0
            self.sampleTimestamps.removeAll()
        }
        
        print(" Watch sensor streaming started at \(targetHz) Hz")
    }
    
    func stopStreaming() {
        guard isStreaming else {
            print("stop_streaming on watch called while not streaming, ignored")
            return
        }
        
        resumeCaptureAfterSyncPause = false
        stopMotionCapture(resetDisplayedHz: false)
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.currentHz = 0
        }
        
        sensorTransmissionPaused = false
        connectivityService.discardBufferedSensorPackers()
        connectivityService.cancelOutstandingSensorTransfers()
        
        print("⏹️ Watch sensor streaming stopped")
    }
    
    func updateFrequency(_ hz: Int) {
        let newHz = min(hz, 100)
        guard newHz != targetHz else { return }
        
        targetHz = newHz
        
        if isStreaming {
            stopStreaming()
            startStreaming(hz: targetHz)
        }
    }
    
    // MARK: - Motion Handling
    
    private func handleMotionUpdate(_ motion: CMDeviceMotion) {
        
        guard !sensorTransmissionPaused else { return }
        // Create timestamp (nanoseconds since reference date)
        let timestamp = UInt64(motion.timestamp * 1_000_000_000)
        
        // Extract IMU data
        let angularVelocity = SIMD3<Double>(
            motion.rotationRate.x,
            motion.rotationRate.y,
            motion.rotationRate.z
        )
        
        let linearAcceleration = SIMD3<Double>(
            motion.userAcceleration.x,
            motion.userAcceleration.y,
            motion.userAcceleration.z
        )
        
        let gravity = SIMD3<Double>(
            motion.gravity.x,
            motion.gravity.y,
            motion.gravity.z
        )
        
        // Create packet
        guard let packet = WatchSensorPacket.imu(
            timestamp: timestamp,
            angularVelocity: angularVelocity,
            linearAcceleration: linearAcceleration,
            gravity: gravity
        ) else {
            return
        }

        // Send to phone
        if !sensorTransmissionPaused {
            connectivityService.send(packet: packet)
        }
        
        
        let attitude = motion.attitude
        let quaternion = SIMD4<Double>(
            attitude.quaternion.x,
            attitude.quaternion.y,
            attitude.quaternion.z,
            attitude.quaternion.w
        )
        guard let attitudePacket = WatchSensorPacket.attitude(
            timestamp: timestamp,
            quaternion: quaternion,
            pitch: attitude.pitch,
            roll: attitude.roll,
            yaw: attitude.yaw,
            referenceFrame: "xArbitraryZVertical"
        ) else {
            return
        }
        
        if !sensorTransmissionPaused {
            connectivityService.send(packet: attitudePacket)
        }
        
        
        // Update statistics
        DispatchQueue.main.async {
            self.sampleCount += 1
            self.updateFPS()
            self.latestAttitude = attitudePacket.decodeAttitude()
        }
    }
    
    private func updateFPS() {
        let now = Date().timeIntervalSinceReferenceDate
        sampleTimestamps.append(now)
        
        // Remove old timestamps
        sampleTimestamps.removeAll { now - $0 > fpsWindow }
        
        // Calculate FPS
        currentHz = Double(sampleTimestamps.count) / fpsWindow
    }
    
    private func handleActivityUpdate(_ activity: CMMotionActivity) {
        guard !sensorTransmissionPaused else {return}
        let timestamp = UInt64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        
        let activityData = WatchMotionActivityData(
            isWalking: activity.walking,
            isRunning: activity.running,
            isCycling: activity.cycling,
            isDriving: activity.automotive,
            isStationary: activity.stationary,
            isUnknown: activity.unknown,
            confidence: activity.confidence.rawValue
        )
        
        guard let activityPacket = WatchSensorPacket.motionActivity(timestamp: timestamp, activity: activityData) else {
            return
        }
        if !sensorTransmissionPaused {
            connectivityService.send(packet: activityPacket)                
        }
        
        
        DispatchQueue.main.async {
            self.latestActivity = activityData
        }
    }

    // MARK: - Future Extensions
    
    // Placeholder for heart rate monitoring
    func startHeartRateMonitoring() {
        // TODO: Implement HealthKit heart rate monitoring
        print("⚠️ Heart rate monitoring not yet implemented")
    }
    
    // Placeholder for workout metrics
    func startWorkoutSession() {
        // TODO: Implement workout session with metrics
        print("⚠️ Workout session not yet implemented")
    }
}
