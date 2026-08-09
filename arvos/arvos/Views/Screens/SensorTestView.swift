//
//  SensorTestView.swift
//  arvos
//
//  Dashboard-style sensor testing view with full-screen LiDAR/depth and minimizable overlays
//

import SwiftUI
import ARKit
import CoreMotion

struct SensorTestView: View {
    @StateObject private var viewModel = SensorTestViewModel()
    @State private var cameraBoxMinimized = false
    @State private var sensorBoxMinimized = false
    @State private var hasLiDAR: Bool = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height

                ZStack {
                    // Full-screen LiDAR/Depth background
                    Color.black
                        .ignoresSafeArea()
                    
                    // Main depth/LiDAR view
                    if let depthSample = viewModel.latestDepthSample {
                        // Point cloud view mode
                        if hasLiDAR {
                            DepthPointCloudView(depthSample: depthSample)
                                .ignoresSafeArea()
                        } else {
                            SimpleDepthView(depthSample: depthSample)
                                .ignoresSafeArea()
                        }
                    } else {
                        // Loading state
                        VStack(spacing: 18) {
                            if viewModel.isRunning {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.3)
                            } else {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 48, weight: .light))
                                    .foregroundColor(.white.opacity(0.4))
                            }

                            Text(viewModel.isRunning ? "Initializing depth sensor…" : "Tap Start to begin")
                                .font(.system(.subheadline, design: .monospaced))
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    
                    // Top status bar
                    VStack {
                        HStack(spacing: 12) {
                            // Status indicator
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(viewModel.isRunning ? Color.green : Color.gray.opacity(0.8))
                                    .frame(width: 8, height: 8)

                                Text(viewModel.isRunning ? "LIVE" : "STOPPED")
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.7))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                            )

                            Spacer()

                            // Device capability indicator
                            if hasLiDAR {
                                HStack(spacing: 6) {
                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("LiDAR")
                                        .font(.system(.caption2, design: .monospaced))
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.7))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                        )
                                )
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "cube.transparent.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("DEPTH")
                                        .font(.system(.caption2, design: .monospaced))
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.7))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                        )
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                        Spacer()
                    }
                    
                    // Minimizable Camera Box (top-right)
                    VStack {
                        HStack {
                            Spacer()

                            if !cameraBoxMinimized {
                                cameraOverlayBox
                                    .frame(width: isLandscape ? min(geometry.size.width * 0.25, 180) : min(geometry.size.width * 0.35, 200))
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .trailing).combined(with: .opacity)
                                    ))
                            } else {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                        cameraBoxMinimized = false
                                    }
                                } label: {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(14)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.7))
                                                .overlay(
                                                    Circle()
                                                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                                )
                                        )
                                }
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.trailing, isLandscape ? 16 : 20)
                        .padding(.top, isLandscape ? 16 : 72)

                        Spacer()
                    }
                    
                    // Minimizable Sensor Data Box (bottom-left)
                    VStack {
                        Spacer()

                        HStack {
                            if !sensorBoxMinimized {
                                sensorDataOverlayBox(isLandscape: isLandscape)
                                    .frame(width: isLandscape ? min(geometry.size.width * 0.30, 220) : min(geometry.size.width * 0.45, 240))
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .leading).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)
                                    ))
                            } else {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                        sensorBoxMinimized = false
                                    }
                                } label: {
                                    Image(systemName: "chart.bar.fill")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(14)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.7))
                                                .overlay(
                                                    Circle()
                                                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                                )
                                        )
                                }
                                .transition(.scale.combined(with: .opacity))
                            }

                            Spacer()
                        }
                        .padding(.leading, isLandscape ? 16 : 20)
                        .padding(.bottom, isLandscape ? 80 : 100)
                    }
                    
                    // Bottom controls
                    VStack {
                        Spacer()

                        HStack(spacing: 12) {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    viewModel.toggleTesting()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                                        .font(.system(size: 16, weight: .semibold))

                                    Text(viewModel.isRunning ? "Stop" : "Start")
                                        .font(.system(.headline, design: .monospaced))
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous)
                                        .fill(viewModel.isRunning ? Theme.recording : Theme.accent)
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("Sensor Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(viewModel.isRunning ? "Stop" : "Start") {
                        viewModel.toggleTesting()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(viewModel.isRunning ? Theme.recording : Theme.accent)
                }
            }
        }
        .onAppear {
            // Check for LiDAR capability
            hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }
    
    // MARK: - Camera Overlay Box

    private var cameraOverlayBox: some View {
        VStack(spacing: 0) {
            // Header with minimize button
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("CAMERA")
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .tracking(0.5)
                }
                .foregroundColor(.white)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        cameraBoxMinimized = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.8))

            // Camera feed
            if let image = viewModel.latestCameraImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 120)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                            Text("Waiting…")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Sensor Data Overlay Box

    @ViewBuilder
    private func sensorDataOverlayBox(isLandscape: Bool) -> some View {
        VStack(spacing: 0) {
            // Header with minimize button
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("SENSORS")
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .tracking(0.5)
                }
                .foregroundColor(.white)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        sensorBoxMinimized = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.8))

            // Sensor data content
            ScrollView {
                VStack(alignment: .leading, spacing: isLandscape ? 8 : 10) {
                    // IMU Data
                    if let imu = viewModel.latestIMU {
                        SensorDataRow(
                            icon: "gyroscope",
                            label: "IMU",
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    CompactDataRow(label: "Accel", x: imu.linearAcceleration.x, y: imu.linearAcceleration.y, z: imu.linearAcceleration.z, unit: "m/s²")
                                    CompactDataRow(label: "Gyro", x: imu.angularVelocity.x, y: imu.angularVelocity.y, z: imu.angularVelocity.z, unit: "rad/s")
                                }
                            }
                        )
                    }

                    // Pose Data
                    if let pose = viewModel.latestPose {
                        SensorDataRow(
                            icon: "location.fill",
                            label: "POSE",
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    CompactDataRow(label: "Pos", x: Double(pose.position.x), y: Double(pose.position.y), z: Double(pose.position.z), unit: "m")
                                    HStack(spacing: 4) {
                                        let statusColor = pose.isTrackingGood ? Color.green : Color.orange
                                        Circle()
                                            .fill(statusColor)
                                            .frame(width: 6, height: 6)
                                        Text(pose.trackingState)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                }
                            }
                        )
                    }

                    // GPS Data
                    if let gps = viewModel.latestGPS {
                        SensorDataRow(
                            icon: "map.fill",
                            label: "GPS",
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(String(format: "%.5f°", gps.latitude))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.9))
                                    Text(String(format: "%.5f°", gps.longitude))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.9))
                                    Text(String(format: "±%.0fm", gps.horizontalAccuracy))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                        )
                    }

                    // Watch Data
                    if viewModel.watchConnected {
                        SensorDataRow(
                            icon: "applewatch",
                            label: "WATCH",
                            content: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                    Text(String(format: "%.1f Hz", viewModel.watchHz))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                        )
                    }
                }
                .padding(isLandscape ? 12 : 14)
            }
            .frame(maxHeight: isLandscape ? 180 : 220)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Supporting Views

struct SensorDataRow<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .tracking(0.3)
                    .foregroundColor(.white.opacity(0.9))
            }

            content
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}

struct CompactDataRow: View {
    let label: String
    let x: Double
    let y: Double
    let z: Double
    let unit: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 42, alignment: .leading)
            Text(String(format: "%.2f,%.2f,%.2f", x, y, z))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.white.opacity(0.95))
            Text(unit)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}

#Preview {
    SensorTestView()
}
