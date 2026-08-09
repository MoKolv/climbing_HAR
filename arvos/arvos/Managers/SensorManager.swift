//
//  SensorManager.swift
//  arvos
//
//  Coordinates all sensor services and manages streaming modes
//

import Foundation
import Combine
import ARKit
import AVFoundation

class SensorManager: ObservableObject {
    static let shared = SensorManager()

    @Published private(set) var currentMode: StreamMode = .custom
    @Published private(set) var isStreaming = false
    @Published private(set) var currentFPS: Double = 0
    @Published private(set) var sensorStatuses: SensorStatuses = SensorStatuses()
    @Published private(set) var latestDepthFrame: DepthFrame?
    // Removed latestDepthSample to avoid ARFrame retention issues

    // Custom mode configuration storage
    private var customModeConfig: ModeConfiguration?

    /// Returns the current active configuration (custom config if in custom mode, otherwise mode's default config)
    var currentConfig: ModeConfiguration {
        if currentMode == .custom, let customConfig = customModeConfig {
            return customConfig
        }
        return currentMode.config
    }

    // Services (exposed for sensor test view)
    let cameraService = CameraService()
    let arKitService = ARKitService()
    let imuService = IMUService()
    let gpsService = GPSService()
    let watchSensorManager = WatchSensorManager.shared
    private var awaitingCameraAuthorization = false

    // Managers
    private let networkManager = NetworkManager.shared
    private let recordingManager = RecordingManager()

    private var cameraServiceRunning = false
    var usingARKitCamera = false // Exposed for sensor test view

    // Burst scan timer
    private var burstScanTimer: Timer?
    private var burstScanStartTime: Date?

    // FPS tracking
    private var frameTimestamps: [TimeInterval] = []
    private let fpsWindow: TimeInterval = 1.0

    private init() {
        setupDelegates()
    }

    deinit {
        burstScanTimer?.invalidate()
    }

    private func setupDelegates() {
        cameraService.delegate = self
        arKitService.delegate = self
        imuService.delegate = self
        gpsService.delegate = self
        watchSensorManager.delegate = self
    }

    // MARK: - Mode Management

    func setMode(_ mode: StreamMode) {
        guard !isStreaming else {
            return
        }

        currentMode = mode
        networkManager.sendModeConfig(mode)
    }

    func startStreaming() {
        guard !isStreaming else { return }

        let config = currentConfig

        // Camera system selection:
        // - Use ARKit camera when both camera AND depth are enabled (integrated depth+RGB)
        // - Use AVFoundation camera for camera-only modes (better control, no ARKit overhead)
        usingARKitCamera = config.cameraEnabled && config.depthEnabled

        let needsCameraAccess = config.cameraEnabled || config.depthEnabled || config.poseEnabled

        if needsCameraAccess {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                break
            case .notDetermined:
                guard !awaitingCameraAuthorization else { return }
                awaitingCameraAuthorization = true
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.awaitingCameraAuthorization = false
                        if granted {
                            self.startStreaming()
                        } else {
                            if config.cameraEnabled {
                                self.sensorStatuses.camera = .error
                            }
                            if config.depthEnabled {
                                self.sensorStatuses.depth = .error
                            }
                            self.networkManager.sendError(
                                "camera_permission_denied",
                                details: "Camera access denied by user"
                            )
                        }
                    }
                }
                return
            default:
                if config.cameraEnabled {
                    sensorStatuses.camera = .error
                }
                if config.depthEnabled {
                    sensorStatuses.depth = .error
                }
                networkManager.sendError(
                    "camera_permission_denied",
                    details: "Camera access denied. Enable camera in Settings."
                )
                return
            }
        }

        do {
            // Configure and start camera
            if config.cameraEnabled {
                if usingARKitCamera {
                    sensorStatuses.camera = .active
                } else if config.cameraFPS > 0 {
                    try cameraService.configure(fps: config.cameraFPS)
                    cameraService.start()
                    cameraServiceRunning = true
                    sensorStatuses.camera = .active
                }
            }

            // Configure and start ARKit
            if config.depthEnabled || config.poseEnabled {
                try arKitService.configure(
                    depthEnabled: config.depthEnabled,
                    depthFPS: config.depthFPS,
                    poseFPS: config.poseHz
                )
                arKitService.start()
                if config.depthEnabled {
                    sensorStatuses.depth = .active
                    if usingARKitCamera {
                        sensorStatuses.camera = .active
                    }
                }
                if config.poseEnabled {
                    sensorStatuses.pose = .active
                }
            }

            // Configure and start IMU
            if config.imuEnabled {
                try imuService.configure(hz: config.imuHz)
                imuService.start()
                sensorStatuses.imu = .active
                #if DEBUG
                print("✅ IMU started: \(config.imuHz) Hz")
                #endif
            }

            // Configure and start GPS
            if config.gpsEnabled {
                gpsService.configure(hz: 1) // GPS is typically 1 Hz
                gpsService.start()
                sensorStatuses.gps = .active
                #if DEBUG
                print("✅ GPS started")
                #endif
            }

            // Configure and start Watch sensors
            if config.watchEnabled {
                if watchSensorManager.isWatchConnected {
                    watchSensorManager.startWatchStreaming(hz: config.watchHz)
                    sensorStatuses.watch = .active
                } else {
                    sensorStatuses.watch = .inactive
                }
            }

            // Start recording if enabled
            if config.recordingEnabled {
                try recordingManager.startRecording(mode: currentMode)
            }

            isStreaming = true

            // Start embedded WebSocket server (Foxglove-style)
            networkManager.startServer()

            networkManager.sendStatus("streaming", sessionId: recordingManager.sessionId)

            // Start burst scan timer if applicable
            if let duration = config.autoDuration {
                startBurstScanTimer(duration: duration)
            }

        } catch {
            handleStartupFailure(error, config: config)
            return
        }
    }

    private func handleStartupFailure(_ error: Error, config: ModeConfiguration) {

        if let cameraError = error as? CameraError, config.cameraEnabled {
            sensorStatuses.camera = .error
            networkManager.sendError("camera_error", details: cameraError.localizedDescription)
        }

        if let arError = error as? ARKitError, (config.depthEnabled || config.poseEnabled) {
            sensorStatuses.depth = .error
            sensorStatuses.pose = .error
            networkManager.sendError("arkit_error", details: arError.localizedDescription)
        }

        if let imuError = error as? IMUError, config.imuEnabled {
            sensorStatuses.imu = .error
            networkManager.sendError("imu_error", details: imuError.localizedDescription)
        }

        if let gpsError = error as? GPSError, config.gpsEnabled {
            sensorStatuses.gps = .error
            networkManager.sendError("gps_error", details: gpsError.localizedDescription)
        }

        let failureStatuses = sensorStatuses
        stopStreaming()
        sensorStatuses = failureStatuses
    }

    func stopStreaming() {
        guard isStreaming else { return }

        // Stop all services
        if cameraServiceRunning {
            cameraService.stop()
            cameraServiceRunning = false
        }
        usingARKitCamera = false
        arKitService.stop()
        imuService.stop()
        gpsService.stop()
        
        // Stop watch sensors
        if watchSensorManager.isWatchStreaming {
            watchSensorManager.stopWatchStreaming()
        }

        // Stop recording
        if recordingManager.isRecording {
            try? recordingManager.stopRecording()
        }

        // Cancel burst scan timer
        burstScanTimer?.invalidate()
        burstScanTimer = nil
        burstScanStartTime = nil

        isStreaming = false
        sensorStatuses = SensorStatuses()
        latestDepthFrame = nil

        networkManager.sendStatus("stopped")
    }

    func pauseStreaming() {
        arKitService.pause()
        // Other sensors don't need explicit pause
    }

    func resumeStreaming() {
        arKitService.resume()
    }

    // MARK: - Burst Scan

    private func startBurstScanTimer(duration: TimeInterval) {
        burstScanStartTime = Date()

        burstScanTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stopStreaming()
        }
    }

    var burstScanRemainingTime: TimeInterval? {
        guard let startTime = burstScanStartTime, let duration = currentConfig.autoDuration else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return max(0, duration - elapsed)
    }

    // MARK: - Dynamic Configuration

    func updateCameraFPS(_ fps: Int) {
        guard !usingARKitCamera else { return }
        cameraService.updateFPS(fps)
    }

    func updateIMUFrequency(_ hz: Int) {
        imuService.updateFrequency(hz)
    }

    func updateDepthSettings(enabled: Bool, fps: Int) {
        arKitService.updateDepthSettings(enabled: enabled, fps: fps)
    }

    func updatePoseFPS(_ hz: Int) {
        arKitService.updatePoseFPS(hz)
    }

    func updateGPSFrequency(_ hz: Int) {
        gpsService.updateFrequency(hz)
    }

    /// Apply a custom mode configuration
    /// This allows creating custom modes by directly specifying sensor settings
    func applyCustomConfiguration(_ config: ModeConfiguration) {
        guard !isStreaming else {
            return
        }

        // Store the custom configuration
        customModeConfig = config

        // Set to custom mode
        currentMode = .custom


        // Send config to network
        networkManager.sendModeConfig(.custom)
    }

    // MARK: - FPS Calculation

    private func updateFPS() {
        let now = Date().timeIntervalSinceReferenceDate
        frameTimestamps.append(now)

        // Remove old timestamps
        frameTimestamps.removeAll { now - $0 > fpsWindow }

        // Calculate FPS
        currentFPS = Double(frameTimestamps.count) / fpsWindow
    }

    // MARK: - Statistics

    func getStatistics() -> StreamingStatistics {
        return StreamingStatistics(
            mode: currentMode,
            isStreaming: isStreaming,
            fps: currentFPS,
            sensorStatuses: sensorStatuses,
            recordingDuration: recordingManager.recordingDuration,
            recordingSize: recordingManager.fileSize
        )
    }
}

// MARK: - Camera Service Delegate

extension SensorManager: CameraServiceDelegate {
    func cameraService(_ service: CameraService, didCapture frame: CameraFrame) {
        updateFPS()

        // Only stream if camera is enabled in current mode
        guard currentConfig.cameraEnabled else { return }

        // Stream to network
        networkManager.stream(cameraFrame: frame)

        // Record if enabled
        if recordingManager.isRecording {
            recordingManager.record(cameraFrame: frame)
        }
    }

    func cameraService(_ service: CameraService, didEncounterError error: Error) {
        sensorStatuses.camera = .error
        networkManager.sendError("camera_error", details: error.localizedDescription)
    }
}

// MARK: - ARKit Service Delegate

extension SensorManager: ARKitServiceDelegate {
    func arKitService(_ service: ARKitService, didUpdate pose: PoseData) {
        // Only stream if pose is enabled in current mode
        guard currentConfig.poseEnabled else { return }

        // Stream to network
        networkManager.stream(poseData: pose)

        // Record if enabled
        if recordingManager.isRecording {
            recordingManager.record(poseData: pose)
        }
    }

    func arKitService(_ service: ARKitService, didCapture depth: DepthFrame) {
        // Only stream if depth is enabled in current mode
        guard currentConfig.depthEnabled else { return }
        // Stream to network
        networkManager.stream(depthFrame: depth)

        // Record if enabled
        if recordingManager.isRecording {
            recordingManager.record(depthFrame: depth)
        }

        DispatchQueue.main.async {
            self.latestDepthFrame = depth
        }
    }

    func arKitService(_ service: ARKitService, didOutputDepthSample sample: DepthVisualizationSample) {
        // Don't store depth samples to avoid ARFrame retention
        // The sample will be released immediately after this function returns
    }

    func arKitService(_ service: ARKitService, didCapture camera: CameraFrame) {
        updateFPS()

        // Stream to network
        networkManager.stream(cameraFrame: camera)

        // Record if enabled
        if recordingManager.isRecording {
            recordingManager.record(cameraFrame: camera)
        }
    }

    func arKitService(_ service: ARKitService, didEncounterError error: Error) {
        sensorStatuses.depth = .error
        sensorStatuses.pose = .error
        networkManager.sendError("arkit_error", details: error.localizedDescription)
    }
}

// MARK: - IMU Service Delegate

extension SensorManager: IMUServiceDelegate {
    func imuService(_ service: IMUService, didUpdate data: IMUData) {
        // Only stream if IMU is enabled in current mode
        guard currentConfig.imuEnabled else {
            #if DEBUG
            print("⚠️ IMU data blocked - imuEnabled: false")
            #endif
            return
        }
        
        // Stream to network
        networkManager.stream(imuData: data)

        // Record if enabled
        if recordingManager.isRecording {
            recordingManager.record(imuData: data)
        }
    }

    func imuService(_ service: IMUService, didEncounterError error: Error) {
        sensorStatuses.imu = .error
        networkManager.sendError("imu_error", details: error.localizedDescription)
    }
}

// MARK: - GPS Service Delegate

extension SensorManager: GPSServiceDelegate {
    func gpsService(_ service: GPSService, didUpdate location: GPSData) {
        // Only stream if GPS is enabled in current mode
        guard currentConfig.gpsEnabled else {
            #if DEBUG
            print("⚠️ GPS data blocked - gpsEnabled: false")
            #endif
            return
        }

        // Stream to network
        networkManager.stream(gpsData: location)

        // Record if enabled
        if recordingManager.isRecording {
            recordingManager.record(gpsData: location)
        }
    }

    func gpsService(_ service: GPSService, didEncounterError error: Error) {
        sensorStatuses.gps = .error
        networkManager.sendError("gps_error", details: error.localizedDescription)
    }
}

// MARK: - Watch Sensor Manager Delegate

extension SensorManager: WatchSensorManagerDelegate {
    func watchSensorManager(_ manager: WatchSensorManager, didReceiveIMU data: IMUData) {
        
        print("Watch IMU delegate received")
        print("Watch IMU forwarding via networkManager \(ObjectIdentifier(networkManager))")
        // Stream to network
        networkManager.stream(imuData: data)
        
        // Record if enabled
        if recordingManager.isRecording {
            recordingManager.record(imuData: data)
        }
    }
    func watchSensorManager(_ manager: WatchSensorManager, didReceiveIMU data: WatchIMUNetworkData) {
        networkManager.stream(watchIMUNetworkData: data)
    }
    
    func watchSensorManager(_ manager:WatchSensorManager, didReceiveAttitude data: WatchAttitudeNetworkData){
        networkManager.stream(watchAttitudeNetworkData: data)
    }
}

// MARK: - Sensor Status

enum SensorStatus: String {
    case inactive = "Inactive"
    case active = "Active"
    case error = "Error"
}

struct SensorStatuses: Equatable {
    var camera: SensorStatus = .inactive
    var depth: SensorStatus = .inactive
    var pose: SensorStatus = .inactive
    var imu: SensorStatus = .inactive
    var gps: SensorStatus = .inactive
    var watch: SensorStatus = .inactive

    func merged(with other: SensorStatuses) -> SensorStatuses {
        return SensorStatuses(
            camera: self.camera == .error ? other.camera : self.camera,
            depth: self.depth == .error ? other.depth : self.depth,
            pose: self.pose == .error ? other.pose : self.pose,
            imu: self.imu == .error ? other.imu : self.imu,
            gps: self.gps == .error ? other.gps : self.gps,
            watch: self.watch == .error ? other.watch : self.watch
        )
    }
}

// MARK: - Statistics

struct StreamingStatistics {
    let mode: StreamMode
    let isStreaming: Bool
    let fps: Double
    let sensorStatuses: SensorStatuses
    let recordingDuration: TimeInterval
    let recordingSize: Int64

    var description: String {
        return """
        Mode: \(mode.rawValue)
        Streaming: \(isStreaming)
        FPS: \(String(format: "%.1f", fps))
        Recording: \(recordingDuration > 0 ? String(format: "%.1fs", recordingDuration) : "No")
        Size: \(recordingSize / 1024 / 1024) MB
        """
    }
}
