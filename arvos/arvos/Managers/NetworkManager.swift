//
//  NetworkManager.swift
//  arvos
//
//  Coordinates network streaming of all sensor data
//

import Foundation
import Combine

// MARK: - Network Errors

enum NetworkError: Error {
    case encodingFailed
    case invalidURL
    case connectionFailed
    case sendFailed
}

class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    // MARK: - Protocol Type Selection
    
    enum ProtocolType: String, CaseIterable, Identifiable {
        case websocket = "WebSocket"
        case grpc = "gRPC"
        case mqtt = "MQTT"
        case quic = "QUIC/HTTP3"
        case mcapStream = "MCAP Stream"
        case http = "HTTP/REST"
        case ble = "Bluetooth LE"
        
        var id: String { self.rawValue }
        
        var defaultPort: Int {
            switch self {
            case .websocket: return 9090
            case .grpc: return 50051
            case .mqtt: return 1883
            case .quic: return 4433
            case .mcapStream: return 17500
            case .http: return 8080
            case .ble: return 0
            }
        }
        
        var description: String {
            switch self {
            case .websocket:
                return "Standard WebSocket (default)"
            case .grpc:
                return "gRPC - High performance, research standard"
            case .mqtt:
                return "MQTT - IoT, multi-subscriber"
            case .quic:
                return "QUIC/HTTP3 - Low latency (iOS 15+)"
            case .mcapStream:
                return "MCAP Stream - Robotics research"
            case .http:
                return "HTTP/REST - Simple integration"
            case .ble:
                return "Bluetooth LE - Low bandwidth, cable-free"
            }
        }
    }

    @Published var selectedProtocol: ProtocolType = .websocket
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var statistics: StreamingProtocolStatistics?

    // Server mode (Foxglove-style: iPhone is server, Studio connects as client)
    @Published private(set) var isServerMode: Bool = false  // Default to server mode
    @Published private(set) var serverIPAddresses: [String] = []
    @Published private(set) var connectedClients: Int = 0

    // Protocol adapter (abstraction layer)
    private var adapter: StreamingProtocol?

    // Embedded WebSocket server (Foxglove-style)
    private let webSocketServer = WebSocketServer(port: 8765)

    // Legacy WebSocket client service (for cloud relay fallback)
    private let webSocketService = WebSocketService()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        webSocketService.delegate = self
        webSocketServer.delegate = self
    }

    // MARK: - Connection

    /// Connect using currently selected protocol
    func connect(host: String, port: Int? = nil) {
        let config: ConnectionConfig
        switch selectedProtocol {
        case .http:
            let actualPort = port ?? selectedProtocol.defaultPort
            config = ConnectionConfig.http(host: host, port: actualPort)
        case .ble:
            config = ConnectionConfig.ble(deviceName: host)
        case .websocket:
            let actualPort = port ?? selectedProtocol.defaultPort
            // Auto-detect TLS: use WSS for onrender.com, vercel.app, and standard HTTPS ports
            let useTLS = host.contains("onrender.com") ||
                         host.contains("vercel.app") ||
                         host.contains("herokuapp.com") ||
                         actualPort == 443
            config = ConnectionConfig.websocket(host: host, port: actualPort, useTLS: useTLS)
        case .grpc:
            let actualPort = port ?? selectedProtocol.defaultPort
            config = ConnectionConfig.grpc(host: host, port: actualPort)
        case .mqtt:
            let actualPort = port ?? selectedProtocol.defaultPort
            config = ConnectionConfig.mqtt(host: host, port: actualPort)
        case .quic:
            let actualPort = port ?? selectedProtocol.defaultPort
            config = ConnectionConfig.quic(host: host, port: actualPort)
        case .mcapStream:
            let actualPort = port ?? selectedProtocol.defaultPort
            config = ConnectionConfig(host: host, port: actualPort)
        }
        connect(protocolType: selectedProtocol, config: config)
    }
    
    /// Connect using specific protocol
    func connect(protocolType: ProtocolType, config: ConnectionConfig) {
        selectedProtocol = protocolType
        
        // Create appropriate adapter
        adapter = createAdapter(for: protocolType)
        
        guard let adapter = adapter else {
            if protocolType == .websocket {
                connectWebSocket(host: config.host, port: config.port)
            } else {
                DispatchQueue.main.async {
                    self.connectionState = .error
                }
            }
            return
        }
        
        DispatchQueue.main.async {
            self.connectionState = .connecting
        }
        
        Task {
            do {
                try await adapter.connect(config: config)
                DispatchQueue.main.async {
                    self.connectionState = .connected
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionState = .error
                }
            }
        }
    }
    
    /// Legacy WebSocket connection (backward compatibility)
    func connectWebSocket(host: String, port: Int) {
        guard let url = URL(string: "ws://\(host):\(port)") else {
            return
        }

        webSocketService.connect(to: url)
        webSocketService.startHeartbeat()
    }

    func disconnect() {
        if let adapter = adapter {
            adapter.disconnect()
        } else {
            // Legacy path
            webSocketService.disconnect()
        }
        stopServer()
    }

    // MARK: - Server Mode (Foxglove-style)

    /// Start embedded WebSocket server (iPhone acts as server)
    func startServer() {
        guard isServerMode else {
            return
        }

        do {
            try webSocketServer.start()
            serverIPAddresses = webSocketServer.getLocalIPAddresses()
            connectionState = .connected  // Server is "connected" when running
            #if DEBUG
            print("📡 Server started. Connect Studio to:")
            for ip in serverIPAddresses {
                print("   ws://\(ip):8765")
            }
            #endif
        } catch {
            connectionState = .error
            #if DEBUG
            print("❌ Failed to start server: \(error)")
            #endif
        }
    }

    /// Stop embedded WebSocket server
    func stopServer() {
        webSocketServer.stop()
        if isServerMode {
            connectionState = .disconnected
        }
    }

    /// Toggle between server mode (iPhone is server) and client mode (cloud relay)
    func setServerMode(_ enabled: Bool) {
        isServerMode = enabled
        if enabled {
            stopServer()  // Stop if running
            connectionState = .disconnected
        } else {
            stopServer()
            disconnect()
        }
    }
    
    // MARK: - Protocol Adapter Factory
    
    private func createAdapter(for protocolType: ProtocolType) -> StreamingProtocol? {
        switch protocolType {
        case .websocket:
            return createWebSocketAdapter()
        case .grpc:
            return createGRPCAdapter()
        case .mqtt:
            return createMQTTAdapter()
        case .quic:
            return createQUICAdapter()
        case .mcapStream:
            return createMCAPStreamAdapter()
        case .http:
            return createHTTPAdapter()
        case .ble:
            return createBLEAdapter()
        }
    }
    
    private func createWebSocketAdapter() -> StreamingProtocol? {
        let adapter = WebSocketAdapter(service: webSocketService)
        adapter.delegate = self
        return adapter
    }
    
    private func createGRPCAdapter() -> StreamingProtocol? {
        if #available(iOS 18.0, *) {
            let adapter: StreamingProtocol = GRPCAdapter()
            adapter.delegate = self
            return adapter
        } else {
            return nil
        }
    }
    
    private func createMQTTAdapter() -> StreamingProtocol? {
        let adapter = MQTTAdapter()
        adapter.delegate = self
        return adapter
    }
    
    private func createQUICAdapter() -> StreamingProtocol? {
        if #available(iOS 15.0, *) {
            let adapter: StreamingProtocol = QUICAdapter()
            adapter.delegate = self
            return adapter
        } else {
            return nil
        }
    }
    
    private func createMCAPStreamAdapter() -> StreamingProtocol? {
        let adapter = MCAPAdapter()
        adapter.delegate = self
        return adapter
    }
    
    private func createHTTPAdapter() -> StreamingProtocol? {
        let adapter = HTTPAdapter()
        adapter.delegate = self
        return adapter
    }

    private func createBLEAdapter() -> StreamingProtocol? {
        let adapter = BLEAdapter()
        adapter.delegate = self
        return adapter
    }

    // MARK: - Streaming

    private var imuBroadcastCount = 0

    /// Stream IMU data
    func stream(imuData: IMUData) {
        do {
        
            
            if isServerMode {
                try webSocketServer.broadcast(json: imuData)
                #if DEBUG
                imuBroadcastCount += 1
                if imuBroadcastCount % 50 == 0 {
                    print("📤 IMU #\(imuBroadcastCount) broadcasted")
                }
                #endif
            } else if let adapter = adapter {
                
                try adapter.send(json: imuData)
            } else {
                
                // Legacy path
                try webSocketService.send(json: imuData)
            }
        } catch {
            #if DEBUG
            print("Failed to stream IMU: \(error)")
            #endif
        }
    }
    
    // steram watch_imu data
    
    func stream(watchIMUNetworkData data: WatchIMUNetworkData) {
        do {
            if isServerMode {
                try webSocketServer.broadcast(json: data)
            }
            else if let adapter = adapter {
                try adapter.send(json: data)
            }
            else {
                try webSocketService.send(json: data)
            }
            
            
        } catch {
            #if DEBUG
            print("Failed to stream Watch IMU data: \(error)")
            #endif
        }
    }
    
    // stream watch_attitude data
    func stream(watchAttitudeNetworkData data: WatchAttitudeNetworkData){
        do {
            if isServerMode {
                try webSocketServer.broadcast(json: data)
            }
            else if let adapter = adapter {
                try adapter.send(json: data)
            }
            else {
                try webSocketService.send(json: data)
            }
            
    
        } catch {
            #if DEBUG
            print("Failed to stream watch sensor packet: \(error)")
            #endif
        }
    }
    

    /// Stream GPS data
    func stream(gpsData: GPSData) {
        do {
            if isServerMode {
                try webSocketServer.broadcast(json: gpsData)
                #if DEBUG
                print("📤 GPS: \(gpsData.latitude), \(gpsData.longitude)")
                #endif
            } else if let adapter = adapter {
                try adapter.send(json: gpsData)
            } else {
                // Legacy path
                try webSocketService.send(json: gpsData)
            }
        } catch {
            #if DEBUG
            print("Failed to stream GPS: \(error)")
            #endif
        }
    }

    /// Stream pose data
    func stream(poseData: PoseData) {
        do {
            if isServerMode {
                try webSocketServer.broadcast(json: poseData)
            } else if let adapter = adapter {
                try adapter.send(json: poseData)
            } else {
                // Legacy path
                try webSocketService.send(json: poseData)
            }
        } catch {
        }
    }

    /// Stream camera frame (binary message)
    func stream(cameraFrame: CameraFrame) {
        do {
            let metadata = cameraFrame.metadata()
            let header = try BinaryMessageHeader(metadata: metadata, dataSize: cameraFrame.data.count)

            // Create binary message
            let message = BinaryMessage(header: header, data: cameraFrame.data)
            guard let encoded = message.encode() else {
                throw NetworkError.encodingFailed
            }

            #if DEBUG
            #endif

            if isServerMode {
                // Server mode: broadcast to all connected clients
                webSocketServer.broadcast(data: encoded)
            } else if let adapter = adapter {
                try adapter.send(data: encoded)
            } else {
                // Legacy path
                webSocketService.send(data: encoded, asText: false)
            }
        } catch {
        }
    }

    /// Stream depth frame (binary message)
    func stream(depthFrame: DepthFrame) {
        do {
            let plyData = depthFrame.pointCloud.toPLY()
            let metadata = depthFrame.metadata()
            let header = try BinaryMessageHeader(metadata: metadata, dataSize: plyData.count)

            let message = BinaryMessage(header: header, data: plyData)
            guard let encoded = message.encode() else {
                throw NetworkError.encodingFailed
            }

            if isServerMode {
                // Server mode: broadcast to all connected clients
                webSocketServer.broadcast(data: encoded)
            } else if let adapter = adapter {
                try adapter.send(data: encoded)
            } else {
                // Legacy path
                webSocketService.send(data: encoded, asText: false)
            }
        } catch {
        }
    }

    /// Send mode configuration
    func sendModeConfig(_ mode: StreamMode) {
        let config = ModeConfigMessage(mode: mode, timestamp: TimestampManager.shared.now())

        do {
            if isServerMode {
                // Server mode: broadcast to all connected clients
                try webSocketServer.broadcast(json: config)
            } else if let adapter = adapter {
                try adapter.send(json: config)
            } else {
                // Legacy path
                try webSocketService.send(json: config)
            }
        } catch {
        }
    }

    /// Send status message
    func sendStatus(_ status: String, message: String? = nil, sessionId: String? = nil) {
        let statusMsg = StatusMessage(
            timestamp: TimestampManager.shared.now(),
            status: status,
            message: message,
            sessionId: sessionId
        )

        do {
            if isServerMode {
                try webSocketServer.broadcast(json: statusMsg)
            } else if let adapter = adapter {
                try adapter.send(json: statusMsg)
            } else {
                // Legacy path
                try webSocketService.send(json: statusMsg)
            }
        } catch {
        }
    }

    /// Send error message
    func sendError(_ error: String, details: String? = nil) {
        let errorMsg = ErrorMessage(
            timestamp: TimestampManager.shared.now(),
            error: error,
            details: details
        )

        do {
            if isServerMode {
                try webSocketServer.broadcast(json: errorMsg)
            } else if let adapter = adapter {
                try adapter.send(json: errorMsg)
            } else {
                // Legacy path
                try webSocketService.send(json: errorMsg)
            }
        } catch {
        }
    }
    
    private func sendWatchSyncResult(_ result: WatchTimeSyncResult, boundaryPhoneNs: UInt64) {
        
        print("""
            Sending watch_sync_result
            phase: \(result.phase)
            offset: \(result.offsetNs)
            boundary: \(boundaryPhoneNs)
            """)
        
        let message =
            WatchSyncResultMessage(
                result: result,
                boundaryPhoneNs: boundaryPhoneNs
            )
        
        do {
            if isServerMode {
                print("watch_sync_result via iPhone server")
                try webSocketServer.broadcast(json: message)
            } else if let adapter {
                print("watch_sync_result via adapter")
                try adapter.send(json: message)
            } else {
                print("watch_sync_result via legacy WebSocket")
                try webSocketService.send(json: message)
            }
            
            print("watch_sync_result sent and returned")
        } catch {
            print("Failed to send Watch sync result:", error)
        }
    }
    
    func sendWatchStreamDrained(capturedSampleCount: UInt64) {
        let message = WatchStreamDrainMessage(capturedSampleCount: capturedSampleCount)
        
        do {
            if isServerMode{
                try webSocketServer.broadcast(json: message)
            } else if let adapter {
                try adapter.send(json: message)
            } else {
                try webSocketServer.broadcast(json: message)
            }
        } catch {
            print("Failed to send watch_stream_drained:", error)
        }
    }
    
    
    private func handleIncomingServerMessage(_ message: String) {
        print ("RAW SERVER MESSAGE:", message)
        
        guard let data = message.data(using: .utf8) else {
            print("Could not convert server message to Data")
            return
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Could not decode server message as JSON")
            return
        }
        
        print("SERVER JSON:", json)
        
        let messageType = (json["type"] as? String)
        
        guard let messageType else {
            print("Server message has no type")
            return
        }
        
        switch messageType {
        
        case "command":
            handleCommand(json)
            
        case "ack": break
            
        default:
            print("Unhandled server message type:", messageType)
        }
        
    }

    // MARK: - Statistics

    func updateStatistics() {
        if let adapter = adapter {
            statistics = adapter.getStatistics()
        } else {
            // Legacy path
            let legacyStats = webSocketService.getStatistics()
            statistics = StreamingProtocolStatistics(networkStats: legacyStats, protocolName: ProtocolType.websocket.rawValue)
        }
    }

    func resetStatistics() {
        if let adapter = adapter {
            adapter.resetStatistics()
        } else {
            // Legacy path
        webSocketService.resetStatistics()
            let legacyStats = webSocketService.getStatistics()
            statistics = StreamingProtocolStatistics(networkStats: legacyStats, protocolName: ProtocolType.websocket.rawValue)
            return
        }
        updateStatistics()
    }
}

// MARK: - WebSocketServiceDelegate

extension NetworkManager: WebSocketServiceDelegate {
    func webSocketService(_ service: WebSocketService, didChangeState state: ConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = state
        }
    }
    
    func webSocketService( _ service: WebSocketService, didReceiveMessage message: String) {
        print("Message received through WebSocketService")
        handleIncomingServerMessage(message)
    }

    func webSocketService(_ service: WebSocketService, didEncounterError error: Error) {
        sendError("websocket_error", details: error.localizedDescription)
    }

    private func handleCommand(_ json: [String: Any]) {
        // Handle server commands (e.g., change mode, start/stop recording)
        guard let command = json["command"] as? String else {
            print("Command JSON contains no command:", json)
            return
        }
        
        print("NetworkManager received command:", command)

        switch command {
        case "start_recording":
            // Notify app to start recording
            NotificationCenter.default.post(name: .startRecording, object: nil)
        case "stop_recording":
            // Notify app to stop recording
            NotificationCenter.default.post(name: .stopRecording, object: nil)
            
        case "prepare_trial_sync":
            print("Pre trial sync request")
            
            WatchSensorManager.shared.synchronizeForTrial(phase: "pre") {
                [weak self] result in guard let self, let result
                else {
                    self?.sendError("pre_sync_failed", details: "Watch time sync burst returned nil")
                    return
                }
                
                let boundary = Constants.Time.now()
                self.sendWatchSyncResult(result, boundaryPhoneNs: boundary)
        
            }
        
        case "post_trial_sync":
            print("Post trial sync request")
            
            let boundary = Constants.Time.now()
            
            WatchSensorManager.shared.synchronizeForTrial(phase: "post") { [weak self] result in
                
                guard let self,
                      let result
                else {
                    self?.sendError("post_sync_failed", details: "Watch time sync burst returned nil")
                    return
                }
                
                self.sendWatchSyncResult(result, boundaryPhoneNs: boundary)
            }
            
        case "start_streaming":
            print("Remote start streaming request")
            DispatchQueue.main.async {
                SensorManager.shared.startStreaming()
            }
        case "stop_streaming":
            print("Remote stop streaming request")
            DispatchQueue.main.async {
                SensorManager.shared.stopStreaming()
            }
        case "change_mode":
            if let modeString = json["mode"] as? String,
               let mode = StreamMode.allCases.first(where: { $0.rawValue == modeString }) {
                NotificationCenter.default.post(name: .changeMode, object: mode)
            }
        default:
            break
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startRecording = Notification.Name("startRecording")
    static let stopRecording = Notification.Name("stopRecording")
    static let changeMode = Notification.Name("changeMode")
}

// MARK: - StreamingProtocolDelegate

extension NetworkManager: StreamingProtocolDelegate {
    func streamingProtocol(_ adapter: StreamingProtocol, didChangeState state: ConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = state
        }
    }

    func streamingProtocol(_ adapter: StreamingProtocol, didReceiveMessage message: String) {
        print("Message received through adapter:", adapter.protocolName)
        
        handleIncomingServerMessage(message)
    }

    func streamingProtocol(_ adapter: StreamingProtocol, didEncounterError error: Error) {
        DispatchQueue.main.async {
            self.connectionState = .error
        }
        sendError("\(adapter.protocolName.lowercased())_error", details: error.localizedDescription)
    }
}
