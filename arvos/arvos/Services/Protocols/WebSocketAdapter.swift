//
//  WebSocketAdapter.swift
//  arvos
//
//  WebSocket adapter conforming to StreamingProtocol
//

import Foundation

final class WebSocketAdapter: NSObject, StreamingProtocol {
    weak var delegate: StreamingProtocolDelegate?
    
    private let service: WebSocketService
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                delegate?.streamingProtocol(self, didChangeState: state)
            }
        }
    }
    
    var protocolName: String { "WebSocket" }
    
    init(service: WebSocketService) {
        self.service = service
        super.init()
        service.delegate = self
    }
    
    func connect(config: ConnectionConfig) async throws {
        guard let url = URL(string: config.useTLS ? "wss://\(config.host):\(config.port)" : "ws://\(config.host):\(config.port)") else {
            throw StreamingProtocolError.connectionFailed("Invalid URL")
        }
        
        state = .connecting
        service.connect(to: url)
        service.startHeartbeat()
        
        // Wait for connection with timeout (30 seconds)
        let timeout: TimeInterval = 30.0
        let startTime = Date()
        
        while state == .connecting {
            if Date().timeIntervalSince(startTime) > timeout {
                state = .error
                throw StreamingProtocolError.connectionFailed("Connection timeout after \(timeout) seconds")
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            if state == .connected {
                return
            }
            if state == .error {
                throw StreamingProtocolError.connectionFailed("Connection failed")
            }
        }
    }
    
    func disconnect() {
        service.disconnect()
        state = .disconnected
    }
    
    func send<T: Encodable>(json object: T) throws {
        guard state == .connected else {
            throw StreamingProtocolError.notConnected
        }
        try service.send(json: object)
    }
    
    func send(data: Data) throws {
        guard state == .connected else {
            throw StreamingProtocolError.notConnected
        }
        service.send(data: data, asText: false)
    }
    
    func getStatistics() -> StreamingProtocolStatistics {
        let stats = service.getStatistics()
        return StreamingProtocolStatistics(networkStats: stats, protocolName: protocolName)
    }
    
    func resetStatistics() {
        service.resetStatistics()
    }
    
    static func isAvailable() -> Bool {
        return true
    }
}

extension WebSocketAdapter: WebSocketServiceDelegate {
    func webSocketService(_ service: WebSocketService, didChangeState state: ConnectionState) {
        self.state = state
    }
    
    func webSocketService(_ service: WebSocketService, didReceiveMessage message: String) {
        delegate?.streamingProtocol(self, didReceiveMessage: message)
    }
    
    func webSocketService(_ service: WebSocketService, didEncounterError error: Error) {
        delegate?.streamingProtocol(self, didEncounterError: error)
    }
}

