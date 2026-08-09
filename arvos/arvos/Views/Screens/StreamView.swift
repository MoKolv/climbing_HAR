//
//  StreamView.swift
//  arvos
//
//  Clean device control interface design
//

import SwiftUI
import Charts

struct StreamView: View {
    @EnvironmentObject var viewModel: StreamingViewModel
    @State private var scannedQRCode: String?
    @State private var showingModeSelector = false
    @State private var showingConnectionSheet = false
    @State private var fpsHistory: [Double] = []
    @State private var imuMagnitudeHistory: [Double] = []
    @State private var fpsTimer: Timer?
    @State private var imuTimer: Timer?
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isiPad = UIDevice.current.userInterfaceIdiom == .pad
            let isWideScreen = isiPad || geometry.size.width > 800
        ZStack {
            // Background
                Color(.systemBackground)
                .ignoresSafeArea()

            // Main Content
                VStack(spacing: 0) {
                    // Top Header Bar
                    topHeaderBar
                        .padding(.horizontal, isWideScreen ? 40 : 20)
                        .padding(.top, isWideScreen ? 24 : 16)
                        .padding(.bottom, isLandscape ? 12 : (isWideScreen ? 24 : 20))

                    // Main Content Area - fills all available space
                    if viewModel.isStreaming {
                        streamingBentoGrid
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        idleContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Action Buttons
                    actionButtons
                        .padding(.horizontal, isWideScreen ? 40 : 20)
                        .padding(.bottom, isWideScreen ? 40 : 34)
                }
            }
        }
        .onAppear {
            startDataCollection()
        }
        .onDisappear {
            stopDataCollection()
        }
        .onChange(of: viewModel.isStreaming) { isStreaming in
            if isStreaming {
                startDataCollection()
            } else {
                stopDataCollection()
            }
        }
        .onChange(of: viewModel.currentFPS) { newValue in
            if viewModel.isStreaming {
                updateFPSHistory(newValue)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !viewModel.isStreaming {
                    // Connection Config
                    Button {
                        showingConnectionSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(.primary)
                    }
                    .accessibilityLabel("Connection Settings")

                    // QR Scanner
                    Button {
                        viewModel.showingQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .foregroundColor(.primary)
                    }
                    .accessibilityLabel("Scan QR Code")
                }
            }
        }
        .sheet(isPresented: $showingConnectionSheet) {
            ConnectionSheet()
        }
        .sheet(isPresented: $viewModel.showingQRScanner) {
            QRScannerView(scannedCode: $scannedQRCode)
        }
        .sheet(isPresented: $showingModeSelector) {
            ModeSelectorSheet(
                selectedMode: $viewModel.selectedMode,
                customCameraEnabled: $viewModel.customCameraEnabled,
                customDepthEnabled: $viewModel.customDepthEnabled,
                customIMUEnabled: $viewModel.customIMUEnabled,
                customPoseEnabled: $viewModel.customPoseEnabled,
                customGPSEnabled: $viewModel.customGPSEnabled
            )
        }
        .onChange(of: scannedQRCode) { newValue in
            if let code = newValue {
                if self.validateQRCode(code) {
                    viewModel.scanQRCode(code)
                } else {
                    viewModel.showError(message: "Invalid QR code format. Expected ws:// or wss:// URL.")
                }
                scannedQRCode = nil
            }
        }
        .alert("Error", isPresented: $viewModel.showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred")
        }
    }

    // MARK: - Top Header Bar

    private var topHeaderBar: some View {
        let isiPad = UIDevice.current.userInterfaceIdiom == .pad
        return HStack {
            // ARVOS text (top left, smaller)
                        Text("ARVOS")
                .font(.system(size: isiPad ? 32 : 24, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)

            Spacer()

            // Status (top right, smaller)
            HStack(spacing: 8) {
                            Circle()
                    .fill(statusColor)
                    .frame(width: isiPad ? 10 : 8, height: isiPad ? 10 : 8)
                Text(statusText)
                    .font(.system(size: isiPad ? 18 : 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }

    private var statusText: String {
        if viewModel.isStreaming {
            return "Streaming"
        } else if NetworkManager.shared.connectedClients > 0 {
            return "Ready"
        } else {
            return "Idle"
        }
    }

    private var statusColor: Color {
        if viewModel.isStreaming {
            return Theme.recording
        } else if NetworkManager.shared.connectedClients > 0 {
            return Theme.success
        } else {
            return Color.secondary.opacity(0.3)
        }
    }

    // MARK: - Idle Content

    private var idleContent: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isiPad = UIDevice.current.userInterfaceIdiom == .pad
            let isWideScreen = isiPad || geometry.size.width > 800
            ScrollView(showsIndicators: false) {
                VStack(spacing: isWideScreen ? 40 : (isLandscape ? 24 : 32)) {
                    Spacer(minLength: isWideScreen ? 40 : 20)
                    
                    // Main centered content
                    VStack(spacing: isWideScreen ? 48 : 32) {
                        // Quote/Message
                        VStack(spacing: isWideScreen ? 24 : 16) {
                            Text("Ready to Stream")
                                .font(.system(size: isWideScreen ? 44 : (isLandscape ? 32 : 36), weight: .bold, design: .monospaced))
                                .foregroundColor(.primary)
                            
                            Text("Start streaming sensor data to visualize real-time metrics and monitor your device performance.")
                                .font(.system(size: isWideScreen ? 20 : (isLandscape ? 15 : 17), weight: .regular))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(6)
                                .padding(.horizontal, isWideScreen ? 120 : (isLandscape ? 60 : 40))
                        }
                        
                        Divider()
                            .padding(.horizontal, isWideScreen ? 200 : (isLandscape ? 100 : 60))
                        
                        // Status Metrics in a nice card
                BentoCard {
                            VStack(alignment: .leading, spacing: isWideScreen ? 28 : 20) {
                                HStack {
                                    Image(systemName: "info.circle.fill")
                                        .font(.system(size: isWideScreen ? 20 : 16))
                                        .foregroundColor(.secondary)
                                    Text("Current Status")
                                        .font(.system(size: isWideScreen ? 20 : 16, weight: .semibold))
                            .foregroundColor(.primary)
                                }
                                
                                VStack(alignment: .leading, spacing: isWideScreen ? 20 : 16) {
                                    if isWideScreen || isLandscape {
                                        HStack(spacing: isWideScreen ? 80 : 40) {
                                            idleMetricItem(label: "Status", value: "Off", isWide: isWideScreen)
                                            idleMetricItem(label: "Mode", value: viewModel.selectedMode.rawValue, isWide: isWideScreen)
                                            idleMetricItem(label: "Clients", value: "\(NetworkManager.shared.connectedClients)", isWide: isWideScreen)
                                        }
                                    } else {
                                        VStack(alignment: .leading, spacing: isWideScreen ? 20 : 16) {
                                            idleMetricItem(label: "Status", value: "Off", isWide: isWideScreen)
                                            idleMetricItem(label: "Mode", value: viewModel.selectedMode.rawValue, isWide: isWideScreen)
                                            idleMetricItem(label: "Clients", value: "\(NetworkManager.shared.connectedClients)", isWide: isWideScreen)
                                        }
                                    }
                                    
                                    if viewModel.recordingDuration > 0 {
                                        idleMetricItem(label: "Recording", value: formatDuration(viewModel.recordingDuration), isWide: isWideScreen)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, isWideScreen ? 120 : (isLandscape ? 60 : 40))
                    }
                    
                    Spacer(minLength: isWideScreen ? 40 : 20)
                }
                .padding(.horizontal, isWideScreen ? 40 : 20)
                .padding(.vertical, isWideScreen ? 60 : (isLandscape ? 20 : 40))
            }
        }
    }
    
    private func idleMetricItem(label: String, value: String, isWide: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: isWide ? 18 : 14, weight: .medium))
                            .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: isWide ? 18 : 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    // MARK: - Streaming Bento Grid

    private var streamingBentoGrid: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isiPad = UIDevice.current.userInterfaceIdiom == .pad
            let isWideScreen = isiPad || geometry.size.width > 800
            ScrollView(showsIndicators: false) {
                VStack(spacing: isWideScreen ? 16 : (isLandscape ? 10 : 12)) {
                    Spacer(minLength: 0)
                    
                    // Row 1: Server Box (full width at top)
                    if NetworkManager.shared.isServerMode && !NetworkManager.shared.serverIPAddresses.isEmpty {
                BentoCard {
                            VStack(alignment: .leading, spacing: isWideScreen ? 14 : 10) {
                                HStack {
                                    Image(systemName: "network")
                                        .font(.system(size: isWideScreen ? 18 : 14))
                                        .foregroundColor(.secondary)
                                    Text("Server")
                                        .font(.system(size: isWideScreen ? 19 : 15, weight: .medium))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(NetworkManager.shared.connectedClients) client\(NetworkManager.shared.connectedClients == 1 ? "" : "s")")
                                        .font(.system(size: isWideScreen ? 16 : 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                }
                                
                                if isWideScreen || isLandscape {
                                    HStack(spacing: isWideScreen ? 40 : 20) {
                                        ForEach(NetworkManager.shared.serverIPAddresses, id: \.self) { ip in
                                            Text(ip)
                                                .font(.system(size: isWideScreen ? 16 : 13, design: .monospaced))
                                                .foregroundColor(.primary)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: isWideScreen ? 10 : 6) {
                                        ForEach(NetworkManager.shared.serverIPAddresses, id: \.self) { ip in
                                            Text(ip)
                                                .font(.system(size: isWideScreen ? 16 : 13, design: .monospaced))
                                                .foregroundColor(.primary)
                                        }
                                    }
                                }
                    }
                }
                .frame(maxWidth: .infinity)
                        .frame(height: isWideScreen ? 110 : (isLandscape ? 70 : 90))
                    }
                    
                    // Row 2: FPS (left) + Mode/Rec (right, stacked - heights match)
                    if isWideScreen && isLandscape {
                        // iPad Landscape: Optimized 2-row layout
                        VStack(spacing: isWideScreen ? 16 : 10) {
                            // Top row: FPS + Mode/Rec
                            HStack(alignment: .top, spacing: isWideScreen ? 16 : 10) {
                                // FPS Chart Box (left, large)
            BentoCard {
                                    VStack(alignment: .leading, spacing: isWideScreen ? 14 : 10) {
                                        HStack {
                                            Image(systemName: "gauge")
                                                .font(.system(size: isWideScreen ? 18 : 14))
                                                .foregroundColor(.secondary)
                                            Text("FPS")
                                                .font(.system(size: isWideScreen ? 18 : 14, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                        Text(viewModel.fpsFormatted)
                                            .font(.system(size: isWideScreen ? 40 : 28, weight: .bold, design: .monospaced))
                                            .foregroundColor(.primary)
                                        
                                        // Chart
                                        if !fpsHistory.isEmpty {
                                            FPSChartView(data: fpsHistory)
                                                .frame(height: isWideScreen ? 120 : 80)
                                        } else {
                                            Rectangle()
                                                .fill(Color(.systemGray5).opacity(0.3))
                                                .frame(height: isWideScreen ? 100 : 60)
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: isWideScreen ? 220 : 140)

                                // Mode + Recording Boxes (right, stacked vertically)
                                VStack(spacing: isWideScreen ? 14 : 10) {
                                    // Mode Box (top)
                BentoCard {
                                        VStack(spacing: isWideScreen ? 10 : 6) {
                                            Image(systemName: viewModel.selectedMode.icon)
                                                .font(.system(size: isWideScreen ? 28 : 18))
                                                .foregroundColor(.primary)
                                            Text(viewModel.selectedMode.rawValue)
                                                .font(.system(size: isWideScreen ? 15 : 11, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.center)
                                        }
                                    }
                                    .frame(width: isWideScreen ? 180 : 120)
                                    .frame(height: isWideScreen ? 100 : 65)
                                    
                                    // Recording Box (bottom)
                                    BentoCard {
                                        VStack(alignment: .leading, spacing: isWideScreen ? 10 : 6) {
                                            HStack {
                                                Image(systemName: "record.circle.fill")
                                                    .font(.system(size: isWideScreen ? 16 : 11))
                                                    .foregroundColor(Theme.recording)
                                                Text("Rec")
                                                    .font(.system(size: isWideScreen ? 15 : 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            if viewModel.recordingDuration > 0 {
                                                Text(formatDuration(viewModel.recordingDuration))
                                                    .font(.system(size: isWideScreen ? 20 : 14, weight: .bold, design: .monospaced))
                                                    .foregroundColor(Theme.recording)
                                                
                                                Text(viewModel.recordingSizeFormatted)
                                                    .font(.system(size: isWideScreen ? 13 : 9))
                                                    .foregroundColor(.secondary)
                                            } else {
                                                Text("Not Recording")
                                                    .font(.system(size: isWideScreen ? 15 : 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .frame(width: isWideScreen ? 180 : 120)
                                    .frame(height: isWideScreen ? 100 : 65)
                                }
                                .frame(minHeight: isWideScreen ? 220 : 140)
                            }
                            
                            // Bottom row: IMU Chart (full width)
                BentoCard {
                                VStack(alignment: .leading, spacing: isWideScreen ? 12 : 8) {
                                    HStack {
                                        Image(systemName: "gyroscope")
                                            .font(.system(size: isWideScreen ? 18 : 14))
                                            .foregroundColor(.secondary)
                                        Text("IMU")
                                            .font(.system(size: isWideScreen ? 18 : 14, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    Text(String(format: "%.2f", imuMagnitudeHistory.last ?? 0.0))
                                        .font(.system(size: isWideScreen ? 32 : 20, weight: .bold, design: .monospaced))
                                        .foregroundColor(.primary)
                                    
                                    // IMU chart
                                    if !imuMagnitudeHistory.isEmpty {
                                        IMUChartView(data: imuMagnitudeHistory)
                                            .frame(height: isWideScreen ? 120 : 80)
                                    } else {
                                        Rectangle()
                                            .fill(Color(.systemGray5).opacity(0.3))
                                            .frame(height: isWideScreen ? 100 : 60)
                                            .cornerRadius(4)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: isWideScreen ? 220 : 140)
                        }
                    } else if isLandscape {
                        // iPhone Landscape: FPS and Mode/Rec side by side, IMU below
                        VStack(spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                // FPS Chart Box (left, large)
                BentoCard {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Image(systemName: "gauge")
                                                .font(.system(size: 14))
                                                .foregroundColor(.secondary)
                                            Text("FPS")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                        Text(viewModel.fpsFormatted)
                                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                                            .foregroundColor(.primary)
                                        
                                        // Chart
                                        if !fpsHistory.isEmpty {
                                            FPSChartView(data: fpsHistory)
                                                .frame(height: 80)
                                        } else {
                                            Rectangle()
                                                .fill(Color(.systemGray5).opacity(0.3))
                                                .frame(height: 60)
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 140)

                                // Mode + Recording Boxes (right, stacked vertically)
                                VStack(spacing: 10) {
                                    // Mode Box (top)
                                    BentoCard {
                                        VStack(spacing: 6) {
                                            Image(systemName: viewModel.selectedMode.icon)
                                                .font(.system(size: 18))
                                                .foregroundColor(.primary)
                                            Text(viewModel.selectedMode.rawValue)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.center)
                                        }
                                    }
                                    .frame(width: 120)
                                    .frame(height: 65)
                                    
                                    // Recording Box (bottom)
                BentoCard {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Image(systemName: "record.circle.fill")
                                                    .font(.system(size: 11))
                            .foregroundColor(Theme.recording)
                                                Text("Rec")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            if viewModel.recordingDuration > 0 {
                                                Text(formatDuration(viewModel.recordingDuration))
                                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                    .foregroundColor(Theme.recording)
                                                
                                                Text(viewModel.recordingSizeFormatted)
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.secondary)
                                            } else {
                                                Text("Not Recording")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .frame(width: 120)
                                    .frame(height: 65)
                                }
                                .frame(minHeight: 140)
                            }
                            
                            // Row 3: IMU Chart (full width in landscape)
                BentoCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "gyroscope")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                        Text("IMU")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    Text(String(format: "%.2f", imuMagnitudeHistory.last ?? 0.0))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                                        .foregroundColor(.primary)
                                    
                                    // IMU chart
                                    if !imuMagnitudeHistory.isEmpty {
                                        IMUChartView(data: imuMagnitudeHistory)
                                            .frame(height: 80)
                                    } else {
                                        Rectangle()
                                            .fill(Color(.systemGray5).opacity(0.3))
                                            .frame(height: 60)
                                            .cornerRadius(4)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 140)
                        }
                    } else if isWideScreen {
                        // iPad Portrait: Optimized layout with larger boxes
                        VStack(spacing: isWideScreen ? 16 : 12) {
                            HStack(alignment: .top, spacing: isWideScreen ? 20 : 12) {
                                // FPS Chart Box (left, large)
                                BentoCard {
                                    VStack(alignment: .leading, spacing: isWideScreen ? 16 : 12) {
                                        HStack {
                                            Image(systemName: "gauge")
                                                .font(.system(size: isWideScreen ? 20 : 16))
                                                .foregroundColor(.secondary)
                        Text("FPS")
                                                .font(.system(size: isWideScreen ? 19 : 15, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                                        Text(viewModel.fpsFormatted)
                                            .font(.system(size: isWideScreen ? 48 : 36, weight: .bold, design: .monospaced))
                                            .foregroundColor(.primary)
                                        
                                        // Chart
                                        if !fpsHistory.isEmpty {
                                            FPSChartView(data: fpsHistory)
                                                .frame(minHeight: isWideScreen ? 160 : 120, maxHeight: isWideScreen ? 200 : 150)
                                        } else {
                                            Rectangle()
                                                .fill(Color(.systemGray5).opacity(0.3))
                                                .frame(height: isWideScreen ? 140 : 100)
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: isWideScreen ? 320 : 220)

                                // Mode + Recording Boxes (right, stacked vertically)
                                VStack(spacing: isWideScreen ? 16 : 12) {
                                    // Mode Box (top)
                    BentoCard {
                                        VStack(spacing: isWideScreen ? 12 : 8) {
                                            Image(systemName: viewModel.selectedMode.icon)
                                                .font(.system(size: isWideScreen ? 32 : 20))
                                                .foregroundColor(.primary)
                                            Text(viewModel.selectedMode.rawValue)
                                                .font(.system(size: isWideScreen ? 16 : 12, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.center)
                                        }
                                    }
                                    .frame(width: isWideScreen ? 200 : 140)
                                    .frame(height: isWideScreen ? 150 : 104)
                                    
                                    // Recording Box (bottom)
                                    BentoCard {
                                        VStack(alignment: .leading, spacing: isWideScreen ? 12 : 8) {
                                            HStack {
                                                Image(systemName: "record.circle.fill")
                                                    .font(.system(size: isWideScreen ? 18 : 12))
                                .foregroundColor(Theme.recording)
                                                Text("Rec")
                                                    .font(.system(size: isWideScreen ? 16 : 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                                            
                                            if viewModel.recordingDuration > 0 {
                                                Text(formatDuration(viewModel.recordingDuration))
                                                    .font(.system(size: isWideScreen ? 22 : 16, weight: .bold, design: .monospaced))
                                                    .foregroundColor(Theme.recording)
                                                
                                                Text(viewModel.recordingSizeFormatted)
                                                    .font(.system(size: isWideScreen ? 14 : 10))
                                                    .foregroundColor(.secondary)
                                            } else {
                                                Text("Not Recording")
                                                    .font(.system(size: isWideScreen ? 16 : 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                                    }
                                    .frame(width: isWideScreen ? 200 : 140)
                                    .frame(height: isWideScreen ? 150 : 104)
                                }
                                .frame(minHeight: isWideScreen ? 320 : 220)
                            }
                            
                            // Row 3: IMU Chart (full width)
            BentoCard {
                                VStack(alignment: .leading, spacing: isWideScreen ? 14 : 10) {
                                    HStack {
                                        Image(systemName: "gyroscope")
                                            .font(.system(size: isWideScreen ? 20 : 14))
                                            .foregroundColor(.secondary)
                                        Text("IMU")
                                            .font(.system(size: isWideScreen ? 19 : 15, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    Text(String(format: "%.2f", imuMagnitudeHistory.last ?? 0.0))
                                        .font(.system(size: isWideScreen ? 36 : 24, weight: .bold, design: .monospaced))
                                        .foregroundColor(.primary)
                                    
                                    // IMU chart
                                    if !imuMagnitudeHistory.isEmpty {
                                        IMUChartView(data: imuMagnitudeHistory)
                                            .frame(minHeight: isWideScreen ? 140 : 100, maxHeight: isWideScreen ? 180 : 140)
                                    } else {
                                        Rectangle()
                                            .fill(Color(.systemGray5).opacity(0.3))
                                            .frame(height: isWideScreen ? 120 : 80)
                                            .cornerRadius(4)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: isWideScreen ? 260 : 180)
                        }
                    } else {
                        // iPhone Portrait: Original layout
                        VStack(spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                // FPS Chart Box (left, large)
                                BentoCard {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Image(systemName: "gauge")
                                                .font(.system(size: 16))
                                                .foregroundColor(.secondary)
                                            Text("FPS")
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                        Text(viewModel.fpsFormatted)
                                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                                            .foregroundColor(.primary)
                                        
                                        // Chart
                                        if !fpsHistory.isEmpty {
                                            FPSChartView(data: fpsHistory)
                                                .frame(minHeight: 120, maxHeight: 150)
                                        } else {
                                            Rectangle()
                                                .fill(Color(.systemGray5).opacity(0.3))
                                                .frame(height: 100)
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 220)

                                // Mode + Recording Boxes (right, stacked vertically)
                                VStack(spacing: 12) {
                                    // Mode Box (top)
                BentoCard {
                                        VStack(spacing: 8) {
                                            Image(systemName: viewModel.selectedMode.icon)
                                                .font(.system(size: 20))
                                                .foregroundColor(.primary)
                                            Text(viewModel.selectedMode.rawValue)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.center)
                                        }
                                    }
                                    .frame(width: 140)
                                    .frame(height: 104)
                                    
                                    // Recording Box (bottom)
                                    BentoCard {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Image(systemName: "record.circle.fill")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(Theme.recording)
                                                Text("Rec")
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                if viewModel.recordingDuration > 0 {
                                                Text(formatDuration(viewModel.recordingDuration))
                                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                                    .foregroundColor(Theme.recording)
                                                
                                                Text(viewModel.recordingSizeFormatted)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                            } else {
                                                Text("Not Recording")
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .frame(width: 140)
                                    .frame(height: 104)
                                }
                                .frame(minHeight: 220)
                            }
                            
                            // Row 3: IMU Chart (full width)
                    BentoCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Image(systemName: "gyroscope")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                        Text("IMU")
                                            .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                                    }
                                    Text(String(format: "%.2f", imuMagnitudeHistory.last ?? 0.0))
                                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                                        .foregroundColor(.primary)
                                    
                                    // IMU chart
                                    if !imuMagnitudeHistory.isEmpty {
                                        IMUChartView(data: imuMagnitudeHistory)
                                            .frame(minHeight: 100, maxHeight: 140)
                                    } else {
                                        Rectangle()
                                            .fill(Color(.systemGray5).opacity(0.3))
                                            .frame(height: 80)
                                            .cornerRadius(4)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 180)
                        }
                    }
                    
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, isWideScreen ? 40 : 20)
                .padding(.vertical, isWideScreen ? 16 : (isLandscape ? 8 : 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Collection

    private func startDataCollection() {
        // Stop existing timers
        stopDataCollection()
        
        // Update FPS history less frequently for better performance (1 second instead of 0.5)
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if self.viewModel.isStreaming {
                self.updateFPSHistory(self.viewModel.currentFPS)
            }
        }
        if let timer = fpsTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        // Update IMU history less frequently for better performance (0.5 seconds instead of 0.1)
        imuTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            if self.viewModel.isStreaming {
                // Calculate IMU magnitude from latest IMU data
                // For now, use a simple calculation - you can enhance this
                let mockMagnitude = Double.random(in: 0.8...1.2) // Placeholder
                self.updateIMUHistory(mockMagnitude)
            }
        }
        if let timer = imuTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func stopDataCollection() {
        fpsTimer?.invalidate()
        fpsTimer = nil
        imuTimer?.invalidate()
        imuTimer = nil
    }

    private func updateFPSHistory(_ fps: Double) {
        // Throttle updates - only update if significant change or every 5 updates
        fpsHistory.append(fps)
        // Keep less data for better performance (30 points instead of 50)
        if fpsHistory.count > 30 {
            fpsHistory.removeFirst()
        }
    }

    private func updateIMUHistory(_ magnitude: Double) {
        // Throttle updates - only update if significant change or every 5 updates
        imuMagnitudeHistory.append(magnitude)
        // Keep less data for better performance (50 points instead of 100)
        if imuMagnitudeHistory.count > 50 {
            imuMagnitudeHistory.removeFirst()
        }
    }


    // MARK: - Action Buttons

    private var actionButtons: some View {
        let isiPad = UIDevice.current.userInterfaceIdiom == .pad
        return VStack(spacing: isiPad ? 16 : 12) {
            if viewModel.isStreaming {
                // Stop button - white with black text in dark mode, black with white text in light mode
                Button {
                    viewModel.toggleStreaming()
                } label: {
                    Text("Stop Streaming")
                        .font(.system(size: isiPad ? 20 : 17, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: isiPad ? 64 : 56)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous)
                                .fill(colorScheme == .dark ? .white : .black)
                        )
                }
                .buttonStyle(.plain)
            } else {
                // Start button - white with black text in dark mode, black with white text in light mode
            Button {
                viewModel.toggleStreaming()
            } label: {
                    Text("Start Streaming")
                        .font(.system(size: isiPad ? 20 : 17, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: isiPad ? 64 : 56)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous)
                                .fill(colorScheme == .dark ? .white : .black)
                        )
                }
                .buttonStyle(.plain)

                // Change Mode (secondary)
                Button {
                    showingModeSelector = true
                } label: {
                    Text("Change Mode")
                        .font(.system(size: isiPad ? 20 : 17, weight: .medium))
                        .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                        .frame(height: isiPad ? 64 : 56)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 1)
                    .background(
                                    RoundedRectangle(cornerRadius: Theme.buttonCornerRadius, style: .continuous)
                                        .fill(Color(.systemBackground))
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helper Functions

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Metric Row Component (Like Image)

struct MetricRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(valueColor)
        }
    }
}

// MARK: - Bento Card Component

struct BentoCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            )
    }
}

// MARK: - FPS Chart View

struct FPSChartView: View {
    let data: [Double]
    
    private var chartData: [FPSDataPoint] {
        data.enumerated().map { FPSDataPoint(index: $0, value: $1) }
    }

    var body: some View {
        if !data.isEmpty {
            let maxValue = max(data.max() ?? 30, 30)
            let minValue = max(0, (data.min() ?? 0) - 2)
            
            Chart(chartData) { point in
                LineMark(
                    x: .value("Time", point.index),
                    y: .value("FPS", point.value)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYScale(domain: minValue...maxValue)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color(.separator).opacity(0.3))
                    AxisValueLabel {
                        if let intValue = value.as(Double.self) {
                            Text(String(format: "%.0f", intValue))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(maxWidth: .infinity)
        } else {
            // Empty state
            Rectangle()
                .fill(Color(.systemGray5).opacity(0.3))
        }
    }
}

private struct FPSDataPoint: Identifiable {
    let id = UUID()
    let index: Int
    let value: Double
}

// MARK: - IMU Chart View

struct IMUChartView: View {
    let data: [Double]
    
    private var chartData: [IMUDataPoint] {
        data.enumerated().map { IMUDataPoint(index: $0, value: $1) }
    }
    
    var body: some View {
        if !data.isEmpty {
            let maxValue = max(data.max() ?? 2.0, 2.0)
            let minValue = 0.0
            
            Chart(chartData) { point in
                LineMark(
                    x: .value("Time", point.index),
                    y: .value("Magnitude", point.value)
                )
                .foregroundStyle(Color.green)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYScale(domain: minValue...maxValue)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color(.separator).opacity(0.3))
                    AxisValueLabel {
                        if let doubleValue = value.as(Double.self) {
                            Text(String(format: "%.2f", doubleValue))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(maxWidth: .infinity)
        } else {
            // Empty state
            Rectangle()
                .fill(Color(.systemGray5).opacity(0.3))
        }
    }
}

private struct IMUDataPoint: Identifiable {
    let id = UUID()
    let index: Int
    let value: Double
}


// MARK: - Sensor Indicator Component

struct SensorIndicator: View {
    let icon: String
    let label: String

    var body: some View {
            HStack(spacing: 6) {
            Image(systemName: icon)
                    .font(.system(size: 12))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
            .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.accent)
        )
    }
}

// MARK: - Server Status Compact View

struct ServerStatusCompactView: View {
    let ipAddresses: [String]
    let connectedClients: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Text("Server")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(connectedClients) client\(connectedClients == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if let firstIP = ipAddresses.first {
                Text(firstIP)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
            .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Mode Selector Sheet

struct ModeSelectorSheet: View {
    @Binding var selectedMode: StreamMode
    @Binding var customCameraEnabled: Bool
    @Binding var customDepthEnabled: Bool
    @Binding var customIMUEnabled: Bool
    @Binding var customPoseEnabled: Bool
    @Binding var customGPSEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(StreamMode.allCases) { mode in
                        ModeOptionCard(
                            mode: mode,
                            isSelected: selectedMode == mode,
                            action: {
                                selectedMode = mode
                            }
                        )
                    }

                    if selectedMode == .custom {
                        CustomSensorOptions(
                            cameraEnabled: $customCameraEnabled,
                            depthEnabled: $customDepthEnabled,
                            imuEnabled: $customIMUEnabled,
                            poseEnabled: $customPoseEnabled,
                            gpsEnabled: $customGPSEnabled
                        )
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Select Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ModeOptionCard: View {
    let mode: StreamMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: mode.icon)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .white : .primary)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.black : Color(.secondarySystemBackground))
                    )

                VStack(alignment: .leading, spacing: 4) {
                Text(mode.rawValue)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(mode.description)
                    .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.black)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                    .fill(isSelected ? Color(.systemGray6) : Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                            .stroke(isSelected ? Color.black : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct CustomSensorOptions: View {
    @Binding var cameraEnabled: Bool
    @Binding var depthEnabled: Bool
    @Binding var imuEnabled: Bool
    @Binding var poseEnabled: Bool
    @Binding var gpsEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Sensors")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                SensorToggle(icon: "camera.fill", label: "Camera", isEnabled: $cameraEnabled)
                SensorToggle(icon: "cube.fill", label: "LiDAR Depth", isEnabled: $depthEnabled)
                SensorToggle(icon: "gyroscope", label: "IMU", isEnabled: $imuEnabled)
                SensorToggle(icon: "location.fill", label: "ARKit Pose", isEnabled: $poseEnabled)
                SensorToggle(icon: "map.fill", label: "GPS", isEnabled: $gpsEnabled)
            }
        }
        .padding(16)
            .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            )
    }
}

struct SensorToggle: View {
    let icon: String
    let label: String
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            HStack(spacing: 12) {
        Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.primary)
                    .frame(width: 32)
                Text(label)
                    .font(.system(size: 16))
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: .black))
    }
}

// MARK: - QR Code Validation Extension

extension StreamView {
    private func validateQRCode(_ code: String) -> Bool {
        guard let url = URL(string: code) else {
            return false
        }

        guard let scheme = url.scheme, (scheme == "ws" || scheme == "wss") else {
            return false
        }

        guard let host = url.host, !host.isEmpty else {
            return false
        }

        if let port = url.port {
            guard (1...65535).contains(port) else {
                return false
            }
        }

        return true
    }
}

#Preview {
    StreamView()
        .environmentObject(StreamingViewModel())
}
