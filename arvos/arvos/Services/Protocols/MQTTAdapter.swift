//
//  MQTTAdapter.swift
//  arvos
//
//  MQTT adapter for streaming sensor data
//

import Foundation

// Note: This requires CocoaMQTT package
// To use: Add CocoaMQTT via Swift Package Manager
// URL: https://github.com/emqx/CocoaMQTT

#if canImport(CocoaMQTT)
import CocoaMQTT
#endif

final class MQTTAdapter: NSObject, StreamingProtocol {
    weak var delegate: StreamingProtocolDelegate?
    
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                delegate?.streamingProtocol(self, didChangeState: state)
            }
        }
    }
    
    #if canImport(CocoaMQTT)
    private var mqttClient: CocoaMQTT?
    #endif
    
    private var clientId: String?
    private var topicTelemetry: String?
    private var topicBinary: String?
    private var host: String?
    private var port: UInt16?
    
    private var bytesSent: Int64 = 0
    private var messagesSent: Int64 = 0
    private var queuedMessages: Int = 0
    private var reconnectAttempts: Int = 0
    
    var protocolName: String { "MQTT" }
    
    override init() {
        super.init()
    }
    
    func connect(config: ConnectionConfig) async throws {
        state = .connecting
        
        #if canImport(CocoaMQTT)
        // Store configuration
        self.host = config.host
        self.port = UInt16(config.port)
        self.clientId = config.clientId ?? "arvos-\(UUID().uuidString)"
        self.topicTelemetry = config.topicTelemetry ?? "arvos/telemetry"
        self.topicBinary = config.topicBinary ?? "arvos/binary"
        
        // Create MQTT client
        guard let host = host, let port = port, let clientId = clientId else {
            state = .error
            throw StreamingProtocolError.connectionFailed("Invalid MQTT configuration")
        }
        
        let mqtt = CocoaMQTT(clientID: clientId, host: host, port: port)
        mqtt.delegate = self
        mqtt.keepAlive = 60
        mqtt.autoReconnect = true
        mqtt.autoReconnectTimeInterval = 5
        
        // Connect
        let connected = mqtt.connect()
        if !connected {
            state = .error
            throw StreamingProtocolError.connectionFailed("Failed to initiate MQTT connection")
        }
        
        self.mqttClient = mqtt
        
        // Wait for connection with timeout
        let timeout: TimeInterval = 10.0
        let startTime = Date()
        
        while state == .connecting {
            if Date().timeIntervalSince(startTime) > timeout {
                state = .error
                throw StreamingProtocolError.connectionFailed("MQTT connection timeout")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        if state != .connected {
            throw StreamingProtocolError.connectionFailed("MQTT connection failed")
        }
        #else
        // CocoaMQTT not available
        state = .error
        throw StreamingProtocolError.protocolNotSupported
        #endif
    }
    
    func disconnect() {
        #if canImport(CocoaMQTT)
        mqttClient?.disconnect()
        mqttClient = nil
        #endif
        state = .disconnected
    }
    
    func send<T: Encodable>(json object: T) throws {
        guard state == .connected else {
            throw StreamingProtocolError.notConnected
        }
        
        #if canImport(CocoaMQTT)
        do {
            let data = try JSONEncoder().encode(object)
            let topic = topicTelemetry ?? "arvos/telemetry"
            
            guard let mqtt = mqttClient else {
                throw StreamingProtocolError.notConnected
            }
            
            queuedMessages += 1
            
            let message = CocoaMQTTMessage(topic: topic, payload: data)
            let published = mqtt.publish(message)
            
            if published {
                bytesSent += Int64(data.count)
                messagesSent += 1
                queuedMessages = max(0, queuedMessages - 1)
            } else {
                queuedMessages = max(0, queuedMessages - 1)
                throw StreamingProtocolError.connectionFailed("Failed to publish MQTT message")
            }
        } catch {
            throw StreamingProtocolError.encodingFailed(error.localizedDescription)
        }
        #else
        throw StreamingProtocolError.protocolNotSupported
        #endif
    }
    
    func send(data: Data) throws {
        guard state == .connected else {
            throw StreamingProtocolError.notConnected
        }
        
        #if canImport(CocoaMQTT)
        let topic = topicBinary ?? "arvos/binary"
        
        guard let mqtt = mqttClient else {
            throw StreamingProtocolError.notConnected
        }
        
        queuedMessages += 1
        
        let message = CocoaMQTTMessage(topic: topic, payload: data)
        let published = mqtt.publish(message)
        
        if published {
            bytesSent += Int64(data.count)
            messagesSent += 1
            queuedMessages = max(0, queuedMessages - 1)
        } else {
            queuedMessages = max(0, queuedMessages - 1)
            throw StreamingProtocolError.connectionFailed("Failed to publish MQTT message")
        }
        #else
        throw StreamingProtocolError.protocolNotSupported
        #endif
    }
    
    func getStatistics() -> StreamingProtocolStatistics {
        return StreamingProtocolStatistics(
            state: state,
            bytesSent: bytesSent,
            messagesSent: messagesSent,
            queuedMessages: queuedMessages,
            reconnectAttempts: reconnectAttempts,
            protocolName: protocolName
        )
    }
    
    func resetStatistics() {
        bytesSent = 0
        messagesSent = 0
        queuedMessages = 0
        reconnectAttempts = 0
    }
    
    static func isAvailable() -> Bool {
        #if canImport(CocoaMQTT)
        return true
        #else
        return false
        #endif
    }
}

#if canImport(CocoaMQTT)
extension MQTTAdapter: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .accept {
            state = .connected
            reconnectAttempts = 0
        } else {
            state = .error
            let error = StreamingProtocolError.connectionFailed("MQTT connection rejected: \(ack)")
            delegate?.streamingProtocol(self, didEncounterError: error)
        }
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        // Message published successfully
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        // Acknowledgment received
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        if let text = String(data: message.payload, encoding: .utf8) {
            delegate?.streamingProtocol(self, didReceiveMessage: text)
        }
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        // Subscription successful
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {
        // Unsubscribed
    }
    
    func mqttDidPing(_ mqtt: CocoaMQTT) {
        // Ping sent
    }
    
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        // Pong received
    }
    
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        if let error = err {
            state = .error
            delegate?.streamingProtocol(self, didEncounterError: error)
        } else {
            state = .disconnected
        }
    }
}
#endif

