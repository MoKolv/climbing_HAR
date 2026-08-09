//
//  StreamingProtocol.swift
//  arvos
//
//  Protocol abstraction layer for all streaming protocols
//

import Foundation

// MARK: - Streaming Protocol Interface

protocol StreamingProtocol: AnyObject {
    var protocolName: String { get }
    var delegate: StreamingProtocolDelegate? { get set }
    
    func connect(config: ConnectionConfig) async throws
    func disconnect()
    func send<T: Encodable>(json object: T) throws
    func send(data: Data) throws
    func getStatistics() -> StreamingProtocolStatistics
    func resetStatistics()
    
    static func isAvailable() -> Bool
}

// MARK: - Protocol Delegate

protocol StreamingProtocolDelegate: AnyObject {
    func streamingProtocol(_ adapter: StreamingProtocol, didChangeState state: ConnectionState)
    func streamingProtocol(_ adapter: StreamingProtocol, didReceiveMessage message: String)
    func streamingProtocol(_ adapter: StreamingProtocol, didEncounterError error: Error)
}

// MARK: - Connection Configuration

struct ConnectionConfig {
    let host: String
    let port: Int
    let useTLS: Bool
    
    // Protocol-specific parameters
    let deviceName: String? // For BLE
    let clientId: String? // For MQTT
    let topicTelemetry: String? // For MQTT
    let topicBinary: String? // For MQTT
    
    init(host: String, port: Int, useTLS: Bool = false, deviceName: String? = nil, clientId: String? = nil, topicTelemetry: String? = nil, topicBinary: String? = nil) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.deviceName = deviceName
        self.clientId = clientId
        self.topicTelemetry = topicTelemetry
        self.topicBinary = topicBinary
    }
    
    static func websocket(host: String, port: Int = 9090, useTLS: Bool = false) -> ConnectionConfig {
        return ConnectionConfig(host: host, port: port, useTLS: useTLS)
    }
    
    static func http(host: String, port: Int = 8080, useTLS: Bool = false) -> ConnectionConfig {
        return ConnectionConfig(host: host, port: port, useTLS: useTLS)
    }
    
    static func grpc(host: String, port: Int = 50051, useTLS: Bool = false) -> ConnectionConfig {
        return ConnectionConfig(host: host, port: port, useTLS: useTLS)
    }
    
    static func mqtt(host: String, port: Int = 1883, useTLS: Bool = false, clientId: String? = nil, topicTelemetry: String? = nil, topicBinary: String? = nil) -> ConnectionConfig {
        return ConnectionConfig(host: host, port: port, useTLS: useTLS, clientId: clientId, topicTelemetry: topicTelemetry, topicBinary: topicBinary)
    }
    
    static func quic(host: String, port: Int = 4433, useTLS: Bool = true) -> ConnectionConfig {
        return ConnectionConfig(host: host, port: port, useTLS: useTLS)
    }
    
    static func ble(deviceName: String) -> ConnectionConfig {
        return ConnectionConfig(host: deviceName, port: 0, useTLS: false, deviceName: deviceName)
    }
}

// MARK: - Protocol Statistics

struct StreamingProtocolStatistics {
    let state: ConnectionState
    let bytesSent: Int64
    let messagesSent: Int64
    let queuedMessages: Int
    let reconnectAttempts: Int
    let protocolName: String
    
    init(state: ConnectionState, bytesSent: Int64, messagesSent: Int64, queuedMessages: Int, reconnectAttempts: Int, protocolName: String) {
        self.state = state
        self.bytesSent = bytesSent
        self.messagesSent = messagesSent
        self.queuedMessages = queuedMessages
        self.reconnectAttempts = reconnectAttempts
        self.protocolName = protocolName
    }
    
    // Convenience initializer for converting from NetworkStatistics
    init(networkStats: NetworkStatistics, protocolName: String) {
        self.state = networkStats.state
        self.bytesSent = networkStats.bytesSent
        self.messagesSent = networkStats.messagesSent
        self.queuedMessages = networkStats.queuedMessages
        self.reconnectAttempts = networkStats.reconnectAttempts
        self.protocolName = protocolName
    }
    
    var bandwidth: String {
        if bytesSent < 1024 {
            return "\(bytesSent) B"
        } else if bytesSent < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytesSent) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytesSent) / (1024.0 * 1024.0))
        }
    }
}

// MARK: - Protocol Errors

enum StreamingProtocolError: LocalizedError {
    case notConnected
    case encodingFailed(String)
    case protocolNotSupported
    case connectionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .protocolNotSupported:
            return "Protocol not supported on this device"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        }
    }
}

