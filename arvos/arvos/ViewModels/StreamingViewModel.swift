//
//  StreamingViewModel.swift
//  arvos
//
//  ViewModel for streaming and sensor control
//

import Foundation
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

class StreamingViewModel: ObservableObject {
    // Managers
     let sensorManager = SensorManager.shared
    private let networkManager = NetworkManager.shared
    private let recordingManager = RecordingManager()

    // Published properties
    @Published var selectedMode: StreamMode = .fullSensor
    @Published var isStreaming = false
    @Published var isConnected = false
    @Published var connectionHost = ""
    @Published var connectionPort = "9090"
    @Published var selectedProtocol: NetworkManager.ProtocolType = .websocket {
        didSet {
            guard oldValue != selectedProtocol else { return }
            networkManager.selectedProtocol = selectedProtocol
            applyDefaultsForProtocolChange(from: oldValue)
        }
    }

    @Published var currentFPS: Double = 0
    @Published var sensorStatuses: SensorStatuses = SensorStatuses()
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingSize: Int64 = 0

    @Published var showingQRScanner = false
    @Published var showingConnectionSheet = false
    @Published var showingSettings = false
    @Published var errorMessage: String?
    @Published var showingError = false
    // Removed LiDAR preview - it was causing ARFrame retention issues

    // Custom mode sensor toggles
    @Published var customCameraEnabled = true
    @Published var customDepthEnabled = true
    @Published var customIMUEnabled = true
    @Published var customPoseEnabled = true
    @Published var customGPSEnabled = false

    private var cancellables = Set<AnyCancellable>()
    private var updateTimer: Timer?
    private let updateQueue = DispatchQueue(label: "com.arvos.viewmodel.stats", qos: .utility)

    init() {
        setupBindings()
        selectedProtocol = networkManager.selectedProtocol
        applyDefaultsForProtocolChange(from: nil)
        startUpdateTimer()
    }

    private func setupBindings() {
        // Observe sensor manager
        sensorManager.$currentMode
            .assign(to: &$selectedMode)

        sensorManager.$isStreaming
            .assign(to: &$isStreaming)

        // Observe network manager
        networkManager.$connectionState
            .map { $0 == .connected }
            .assign(to: &$isConnected)
    }

    private func startUpdateTimer() {
        // Reduced from 0.5s to 1.0s to halve UI update frequency
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatistics()
        }
    }

    private func updateStatistics() {
        // Move stats calculation to background queue
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            let stats = self.sensorManager.getStatistics()

            // Only update on main thread if values actually changed
            DispatchQueue.main.async {
                if abs(self.currentFPS - stats.fps) > 0.1 {
                    self.currentFPS = stats.fps
                }
                if self.sensorStatuses != stats.sensorStatuses {
                    self.sensorStatuses = stats.sensorStatuses
                }
                if abs(self.recordingDuration - stats.recordingDuration) > 0.5 {
                    self.recordingDuration = stats.recordingDuration
                }
                if self.recordingSize != stats.recordingSize {
                    self.recordingSize = stats.recordingSize
                }
            }
        }
    }

    // MARK: - Actions

    func selectMode(_ mode: StreamMode) {
        guard !isStreaming else { return }
        selectedMode = mode

        if mode == .custom {
            // Apply custom configuration
            applyCustomConfiguration()
        } else {
            sensorManager.setMode(mode)
        }
    }

    // MARK: - Custom Mode Toggles

    func toggleCustomCamera() {
        customCameraEnabled.toggle()
        if selectedMode == .custom {
            applyCustomConfiguration()
        }
    }

    func toggleCustomDepth() {
        customDepthEnabled.toggle()
        if selectedMode == .custom {
            applyCustomConfiguration()
        }
    }

    func toggleCustomIMU() {
        customIMUEnabled.toggle()
        if selectedMode == .custom {
            applyCustomConfiguration()
        }
    }

    func toggleCustomPose() {
        customPoseEnabled.toggle()
        if selectedMode == .custom {
            applyCustomConfiguration()
        }
    }

    func toggleCustomGPS() {
        customGPSEnabled.toggle()
        if selectedMode == .custom {
            applyCustomConfiguration()
        }
    }

    private func applyCustomConfiguration() {
        let config = ModeConfiguration(
            cameraEnabled: customCameraEnabled,
            cameraFPS: customCameraEnabled ? 30 : 0,
            depthEnabled: customDepthEnabled,
            depthFPS: customDepthEnabled ? 10 : 0,
            imuEnabled: customIMUEnabled,
            imuHz: customIMUEnabled ? 200 : 0,
            poseEnabled: customPoseEnabled,
            poseHz: customPoseEnabled ? 60 : 0,
            gpsEnabled: customGPSEnabled,
            watchEnabled: false,
            watchHz: 0,
            recordingEnabled: false,
            autoDuration: nil
        )
        sensorManager.applyCustomConfiguration(config)
    }

    func toggleStreaming() {
        if isStreaming {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    func startStreaming() {
        // Foxglove-style: iPhone IS the server - no need to connect anywhere!
        // Server mode is enabled by default in NetworkManager.
        // When streaming starts, the embedded WebSocket server starts automatically.

        // Just start sensors - SensorManager will handle starting the server
        sensorManager.startStreaming()
    }

    func stopStreaming() {
        sensorManager.stopStreaming()
    }

    func connectToServer() {
        switch selectedProtocol {
        case .ble:
            let name = connectionHost.isEmpty ? UIDevice.current.name : connectionHost
            let config = ConnectionConfig.ble(deviceName: name)
            networkManager.connect(protocolType: .ble, config: config)
        default:
            guard !connectionHost.isEmpty else { return }
            let port = Int(connectionPort) ?? selectedProtocol.defaultPort
        networkManager.connect(host: connectionHost, port: port)
        }
    }

    func disconnect() {
        networkManager.disconnect()
    }

    func scanQRCode(_ code: String) {
        // Parse QR code: ws://192.168.1.100:9090
        if let url = URL(string: code),
           let host = url.host,
           let port = url.port {
            connectionHost = host
            connectionPort = String(port)
            connectToServer()
        }
    }

    var canAttemptConnection: Bool {
        if selectedProtocol == .ble {
            return true
        }
        return !connectionHost.isEmpty
    }

    private func applyDefaultsForProtocolChange(from oldValue: NetworkManager.ProtocolType?) {
        switch selectedProtocol {
        case .ble:
            if connectionHost.isEmpty {
                connectionHost = UIDevice.current.name
            }
            connectionPort = ""
        default:
            let defaultPort = "\(selectedProtocol.defaultPort)"
            if connectionPort.isEmpty || oldValue == nil || connectionPort == "\(oldValue?.defaultPort ?? 0)" {
                connectionPort = defaultPort
            }
        }
    }

    // MARK: - Sensor Controls

    func updateDataSources(camera: Bool, depth: Bool, imu: Bool, pose: Bool, gps: Bool) {
        // Create custom configuration based on user selection
        let config = ModeConfiguration(
            cameraEnabled: camera,
            cameraFPS: camera ? 30 : 0,
            depthEnabled: depth,
            depthFPS: depth ? 10 : 0,
            imuEnabled: imu,
            imuHz: imu ? 200 : 0,
            poseEnabled: pose,
            poseHz: pose ? 60 : 0,
            gpsEnabled: gps,
            watchEnabled: false,
            watchHz: 0,
            recordingEnabled: false,
            autoDuration: nil
        )

        // Apply the custom configuration
        sensorManager.applyCustomConfiguration(config)

    }

    func updateCameraFPS(_ fps: Int) {
        sensorManager.updateCameraFPS(fps)
    }

    func updateIMUHz(_ hz: Int) {
        sensorManager.updateIMUFrequency(hz)
    }

    func updateDepthFPS(_ fps: Int) {
        sensorManager.updateDepthSettings(enabled: true, fps: fps)
    }

    func updatePoseHz(_ hz: Int) {
        sensorManager.updatePoseFPS(hz)
    }

    // MARK: - LiDAR Preview Controls
    // Removed - LiDAR preview was causing ARFrame retention issues and poor performance

    // MARK: - Formatting Helpers

    var recordingDurationFormatted: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var recordingSizeFormatted: String {
        let mb = Double(recordingSize) / (1024.0 * 1024.0)
        if mb < 1.0 {
            let kb = Double(recordingSize) / 1024.0
            return String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", mb)
    }

    var fpsFormatted: String {
        return String(format: "%.1f", currentFPS)
    }

    var burstScanRemainingTime: String? {
        guard let remaining = sensorManager.burstScanRemainingTime else { return nil }
        return String(format: "%.0fs", remaining)
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Error Handling

    func showError(message: String) {
        errorMessage = message
        showingError = true
    }
}
