//
//  WatchSensorService.swift
//  arvosWatchApp
//
//  Captures IMU and other sensor data on Apple Watch
//

import Foundation
import CoreMotion
import Combine
import HealthKit

class WatchSensorService: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var currentHz: Double = 0
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var latestAttitude: MotionAttitude?
    @Published private(set) var latestActivity: WatchMotionActivityData?
    
    private let motionManager = CMMotionManager()
    private let activityManager = CMMotionActivityManager()
    private let connectivityService = WatchConnectivityService.shared
    
    
    @Published private(set) var isBackgroundRuntimeActive = false
    @Published private(set) var backgroundRuntimeError: String?
    
    private let workoutRuntime = WorkoutRuntimeController()
    private var cancellables = Set<AnyCancellable>()
    
    private var uiWindowStartNs = WatchTime.now()
    private var uiWindowSampleCount = 0
    private var lastUIUpdateNs: UInt64 = 0
    private let uiUpdateIntervalNs: UInt64 = 250_000_000
    
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
    
    private var isMotionCaptureRunning = false
    private var resumeCaptureAfterSyncPause = false
    private var sensorTransmissionPaused = false
    private var nextMotionSequenceId: UInt64 = 0

    
    
    // Configuration
    private var targetHz: Int = 50 // Default to 50Hz for watch (battery friendly)
    private var updateInterval: TimeInterval {
        return 1.0 / Double(targetHz)
    }
    
    init() {
        setupMotionManager()
        setupCommandObserver()
        
        workoutRuntime.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                self?.isBackgroundRuntimeActive = isRunning
            }
            .store(in: &cancellables)
        
        workoutRuntime.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.backgroundRuntimeError = error
            }
            .store(in: &cancellables)
    }

    private func setupCommandObserver() {
        NotificationCenter.default.addObserver(
            forName: .watchCommandReceived,
            object: nil,
            queue: .main
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
            let preserveBuffer =
            (parameters["preserve_buffer"] as? Bool)
            ?? (parameters["preserveBuffer"] as? NSNumber)?.boolValue
            ?? false
            
            if !preserveBuffer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    
                    do {
                        try await self.workoutRuntime.start()
                    } catch {
                        self.backgroundRuntimeError = error.localizedDescription
                        self.connectivityService.sendCommand(
                            "watch_runtime_error",
                            parameters: ["dtails": error.localizedDescription]
                        )
                    }
                    
                }
            }
            
            sensorTransmissionPaused = true
            resumeCaptureAfterSyncPause = isStreaming && isMotionCaptureRunning
            
            stopMotionCapture()
            connectivityService.pauseSensorDelivery()
            
            if preserveBuffer {
                print("Watch transmission paused: preserving queued packets for post-trial drain")
            } else {
                connectivityService.discardBufferedSensorPackers()
                connectivityService.cancelOutstandingSensorTransfers()
                print("Watch transmission paused; backlog cleared")
            }
          
        case "resume_sensor_transmission":
            connectivityService.resumeSensorDelivery()
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
        guard !isMotionCaptureRunning else { return }
        
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
        
        isMotionCaptureRunning = true
            
    }

    private func stopMotionCapture(resetDisplayedHz: Bool = true) {
        guard isMotionCaptureRunning else {return}
        
        motionManager.stopDeviceMotionUpdates()
        
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.stopActivityUpdates()
        }
    
        isMotionCaptureRunning = false
        
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
        
        nextMotionSequenceId = 0
        uiWindowStartNs = WatchTime.now()
        uiWindowSampleCount = 0
        lastUIUpdateNs = 0
        connectivityService.resetSensorTransportMetrics()
        
        if !workoutRuntime.isRunning {
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                do {
                    try await self.workoutRuntime.start()
                } catch {
                    self.backgroundRuntimeError = error.localizedDescription
                }
            }
        }
        
        startMotionCapture()
        
        DispatchQueue.main.async {
            self.isStreaming = true
            self.sampleCount = 0
        }
        
        print(" Watch sensor streaming started at \(targetHz) Hz")
    }
    
    func stopStreaming() {
        guard isStreaming else {
            print("stop_streaming on watch called while not streaming, ignored")
            return
        }
        
        sensorTransmissionPaused = true
        resumeCaptureAfterSyncPause = false
        stopMotionCapture(resetDisplayedHz: false)
        
        let capturedSampleCount = nextMotionSequenceId
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.currentHz = 0
        }
        
        connectivityService.drainSensorPackets { [weak self] in
            guard let self else { return }
            
            self.connectivityService.sendCommand(
                "watch_stream_drained",
                parameters: ["captured_sample_count": NSNumber(value: capturedSampleCount)]
            )
            
            // Keep background execution alive until every queued sensor batch has finished
            self.workoutRuntime.stop()
            print("Watch sensor queue drained: \(capturedSampleCount) motion samples")
        }
        
        print("Watch capture stopped; draining queued packets")
     }
    
    func updateFrequency(_ hz: Int) {
        let newHz = min(max(hz, 1), 100)
        guard newHz != targetHz else { return }
        
        targetHz = newHz
        motionManager.deviceMotionUpdateInterval = updateInterval
        
        guard isStreaming,
              isMotionCaptureRunning,
              !sensorTransmissionPaused else {
            return
        }
        
        stopMotionCapture(resetDisplayedHz: false)
        startMotionCapture()
    }
    
    // MARK: - Motion Handling
    
    private func handleMotionUpdate(_ motion: CMDeviceMotion) {
        guard !sensorTransmissionPaused else {return}
        
        let timestamp = UInt64(motion.timestamp * 1_000_000_000)
        let sequenceId = nextMotionSequenceId
        nextMotionSequenceId &+= 1
        
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
        
        let gravity = SIMD3<Double> (
            motion.gravity.x,
            motion.gravity.y,
            motion.gravity.z
        )
        
        let coreMotionAttitude = motion.attitude
        let attitude = MotionAttitude(
            quaternion: SIMD4(
                coreMotionAttitude.quaternion.x,
                coreMotionAttitude.quaternion.y,
                coreMotionAttitude.quaternion.z,
                coreMotionAttitude.quaternion.w
            ),
            pitch: coreMotionAttitude.pitch,
            roll: coreMotionAttitude.roll,
            yaw: coreMotionAttitude.yaw,
            referenceFrame: "xArbitraryZVertical"
        )
        
        guard let packet = WatchSensorPacket.motion(
            timestamp: timestamp,
            sequenceId: sequenceId,
            angularVelocity: angularVelocity,
            linearAcceleration: linearAcceleration,
            gravity: gravity,
            attitude: attitude
        ) else {
            return
        }
        
        connectivityService.send(packet: packet)
        
        updateDisplayedState(sequenceId: sequenceId, attitude: attitude)
    }
    
    private func updateDisplayedState(
        sequenceId: UInt64,
        attitude: MotionAttitude,
    ) {
        let nowNs = WatchTime.now()
        uiWindowSampleCount += 1
        
        guard lastUIUpdateNs == 0 || nowNs - lastUIUpdateNs >= uiUpdateIntervalNs else {
            return
        }
        
        let elapsedNs = max(nowNs - uiWindowStartNs, 1)
        let measuredHz = Double(uiWindowSampleCount) * 1_000_000_000 / Double(elapsedNs)
        lastUIUpdateNs = nowNs
        
        if elapsedNs >= 1_000_000_000 {
            uiWindowStartNs = nowNs
            uiWindowSampleCount = 0
        }
        
        DispatchQueue.main.async {
            self.sampleCount = Int(sequenceId + 1)
            self.currentHz = measuredHz
            self.latestAttitude = attitude
        }
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
    
    func prepareBackgroundRuntime() async {
        await workoutRuntime.prepareAuthorization()
    }

    // MARK: - Future Extensions
    
    // Placeholder for heart rate monitoring
    func startHeartRateMonitoring() {
        // TODO: Implement HealthKit heart rate monitoring
        print("⚠️ Heart rate monitoring not yet implemented")
    }
}

// MARK: Workout Session
@MainActor
final class WorkoutRuntimeController: NSObject, ObservableObject {
    enum RuntimeError: LocalizedError {
        case healthDataUnavailable
        case authorizationDenied
        
        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable:
                return "Health data is unavailable on this watch"
            case .authorizationDenied:
                return "Workout permission was not granted"
            }
        }
    }
    
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    
    private let healthStore = HKHealthStore()
    private let workoutType = HKObjectType.workoutType()
    private var workoutSession: HKWorkoutSession?
    
    func prepareAuthorization() async {
        do {
            try await authorizeIfNeeded()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    func start() async throws {
        guard workoutSession == nil else { return }
        
        try await authorizeIfNeeded()
        
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .climbing
        configuration.locationType = .indoor
        
        let session = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        
        session.delegate = self
        workoutSession = session
        lastError = nil
        session.startActivity(with: Date())
    }
    
    func stop() {
        workoutSession?.end()
    }
    
    private func authorizeIfNeeded() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw RuntimeError.healthDataUnavailable
        }
        
        switch healthStore.authorizationStatus(for: workoutType) {
        case .sharingAuthorized:
            return
        case .sharingDenied:
            throw RuntimeError.authorizationDenied
        case .notDetermined:
            try await healthStore.requestAuthorization(
                toShare: [workoutType],
                read: [],
            )
            
            guard healthStore.authorizationStatus(for: workoutType) == .sharingAuthorized else {
                throw RuntimeError.authorizationDenied
            }
        @unknown default:
            throw RuntimeError.authorizationDenied
        }
    }
}

extension WorkoutRuntimeController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
    didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRunning = toState == .running
            
            if toState == .ended {
                self.workoutSession = nil
            }
        }
    }
    
    nonisolated func workoutSession(
        _ workoutSEssion: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self ] in
            self?.lastError = error.localizedDescription
            self?.isRunning = false
            self?.workoutSession = nil
        }
    }
}
