//
//  SettingsView.swift
//  arvos
//
//  Merged Settings and Diagnostics view
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var viewModel: StreamingViewModel
    @State private var cameraFPS: Double = 30
    @State private var imuHz: Double = 100
    @State private var depthFPS: Double = 10
    @State private var poseHz: Double = 30

    // Collapsible sections
    @State private var showPerformance = false
    @State private var showSensorStatus = false
    @State private var showConnection = false
    @State private var showModeConfig = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Sensor Configuration

                Section {
                    HStack {
                        Text("Camera FPS")
                        Spacer()
                        Text("\(Int(cameraFPS))")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $cameraFPS, in: 1...30, step: 1) {
                        Text("Camera FPS")
                    } minimumValueLabel: {
                        Text("1")
                    } maximumValueLabel: {
                        Text("30")
                    }
                    .onChange(of: cameraFPS) { newValue in
                        viewModel.updateCameraFPS(Int(newValue))
                    }
                } header: {
                    Text("Camera")
                }

                Section {
                    HStack {
                        Text("Depth FPS")
                        Spacer()
                        Text("\(Int(depthFPS))")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $depthFPS, in: 1...10, step: 1) {
                        Text("Depth FPS")
                    } minimumValueLabel: {
                        Text("1")
                    } maximumValueLabel: {
                        Text("10")
                    }
                    .onChange(of: depthFPS) { newValue in
                        viewModel.updateDepthFPS(Int(newValue))
                    }
                } header: {
                    Text("Depth / LiDAR")
                }

                Section {
                    HStack {
                        Text("IMU Frequency")
                        Spacer()
                        Text("\(Int(imuHz)) Hz")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $imuHz, in: 50...400, step: 50) {
                        Text("IMU Hz")
                    } minimumValueLabel: {
                        Text("50")
                    } maximumValueLabel: {
                        Text("400")
                    }
                    .onChange(of: imuHz) { newValue in
                        viewModel.updateIMUHz(Int(newValue))
                    }

                    HStack {
                        Text("Pose Frequency")
                        Spacer()
                        Text("\(Int(poseHz)) Hz")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $poseHz, in: 10...60, step: 10) {
                        Text("Pose Hz")
                    } minimumValueLabel: {
                        Text("10")
                    } maximumValueLabel: {
                        Text("60")
                    }
                    .onChange(of: poseHz) { newValue in
                        viewModel.updatePoseHz(Int(newValue))
                    }
                } header: {
                    Text("Motion Sensors")
                }

                // MARK: - Diagnostics (Collapsible)

                Section {
                    DisclosureGroup("Performance Metrics", isExpanded: $showPerformance) {
                        HStack {
                            Text("FPS")
                            Spacer()
                            Text(viewModel.fpsFormatted)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Recording Duration")
                            Spacer()
                            Text(viewModel.recordingDurationFormatted)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Recording Size")
                            Spacer()
                            Text(viewModel.recordingSizeFormatted)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    DisclosureGroup("Sensor Status", isExpanded: $showSensorStatus) {
                        StatusRow(label: "Camera", status: viewModel.sensorStatuses.camera)
                        StatusRow(label: "Depth", status: viewModel.sensorStatuses.depth)
                        StatusRow(label: "IMU", status: viewModel.sensorStatuses.imu)
                        StatusRow(label: "Pose", status: viewModel.sensorStatuses.pose)
                        StatusRow(label: "GPS", status: viewModel.sensorStatuses.gps)
                    }
                }

                Section {
                    DisclosureGroup("Connection Info", isExpanded: $showConnection) {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(viewModel.isConnected ? "Connected" : "Disconnected")
                                .foregroundColor(viewModel.isConnected ? Theme.success : Theme.recording)
                        }

                        HStack {
                            Text("Host")
                            Spacer()
                            Text(viewModel.connectionHost.isEmpty ? "Not set" : viewModel.connectionHost)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Port")
                            Spacer()
                            Text(viewModel.connectionPort)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section {
                    DisclosureGroup("Mode Configuration", isExpanded: $showModeConfig) {
                        HStack {
                            Text("Current Mode")
                            Spacer()
                            Text(viewModel.selectedMode.rawValue)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Camera Enabled")
                            Spacer()
                            Text(viewModel.selectedMode.config.cameraEnabled ? "Yes" : "No")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Depth Enabled")
                            Spacer()
                            Text(viewModel.selectedMode.config.depthEnabled ? "Yes" : "No")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("IMU Enabled")
                            Spacer()
                            Text(viewModel.selectedMode.config.imuEnabled ? "Yes" : "No")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Recording Enabled")
                            Spacer()
                            Text(viewModel.selectedMode.config.recordingEnabled ? "Yes" : "No")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Apple Watch

                Section {
                    let watchManager = viewModel.sensorManager.watchSensorManager
                    HStack {
                        Text("Watch Connected")
                        Spacer()
                        HStack(spacing: 8) {
                            Circle()
                                .fill(watchManager.isWatchConnected ? Theme.success : Theme.recording)
                                .frame(width: 8, height: 8)
                            Text(watchManager.isWatchConnected ? "Yes" : "No")
                                .foregroundColor(.secondary)
                        }
                    }

                    if watchManager.isWatchConnected {
                        HStack {
                            Text("Watch Sample Rate")
                            Spacer()
                            Text(String(format: "%.1f Hz", watchManager.watchHz))
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Watch Samples")
                            Spacer()
                            Text("\(watchManager.watchSampleCount)")
                                .foregroundColor(.secondary)
                        }

                        if let attitude = watchManager.latestAttitude {
                            WatchSettingsRow(title: "Pitch / Roll / Yaw", value: "\(formatAngle(attitude.pitch)) / \(formatAngle(attitude.roll)) / \(formatAngle(attitude.yaw))")
                        }

                        if let activity = watchManager.latestActivity {
                            WatchSettingsRow(title: "Activity", value: activity.descriptionLabel.capitalized)
                            WatchSettingsRow(title: "Confidence", value: activity.confidenceDescription)
                        }

                    } else {
                        Text("Pair your Apple Watch and install the arvos Watch app to enable watch sensor streaming.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Apple Watch")
                }

                // MARK: - About

                Section {
                    HStack {
                        Text("Device")
                        Spacer()
                        Text(UIDevice.current.model)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("iOS Version")
                        Spacer()
                        Text(UIDevice.current.systemVersion)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Device Name")
                        Spacer()
                        Text(UIDevice.current.name)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("App Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func formatAngle(_ value: Double) -> String {
        let degrees = value * 180 / .pi
        return String(format: "%.1f°", degrees)
    }
}

// MARK: - Supporting Views

struct StatusRow: View {
    let label: String
    let status: SensorStatus

    var body: some View {
        HStack {
            Text(label)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(status.rawValue)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .inactive:
            return .gray
        case .active:
            return Theme.success
        case .error:
            return Theme.recording
        }
    }
}

private struct WatchSettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(StreamingViewModel())
}
