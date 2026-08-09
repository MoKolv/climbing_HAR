//
//  GRPCAdapter.swift
//  arvos
//
//  gRPC adapter for streaming sensor data (iOS 18+)
//

import Foundation
import GRPC
import NIOCore
import NIOTransportServices

@available(iOS 18.0, *)
final class GRPCAdapter: NSObject, StreamingProtocol {
    weak var delegate: StreamingProtocolDelegate?
    
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                delegate?.streamingProtocol(self, didChangeState: state)
            }
        }
    }
    
    private var client: ClientConnection?
    private var group: EventLoopGroup?
    private var channel: GRPCChannel?
    
    private var bytesSent: Int64 = 0
    private var messagesSent: Int64 = 0
    private var queuedMessages: Int = 0
    private var reconnectAttempts: Int = 0
    
    var protocolName: String { "gRPC" }
    
    override init() {
        super.init()
    }
    
    func connect(config: ConnectionConfig) async throws {
        state = .connecting
        
        do {
            // Create event loop group for iOS using NIOTransportServices
            let group = NIOTSEventLoopGroup()
            self.group = group
            
            // Build connection configuration
            let configuration = ClientConnection.Configuration.default(
                target: .hostAndPort(config.host, config.port),
                eventLoopGroup: group
            )

            // Create client connection
            let connection = ClientConnection(configuration: configuration)
            self.client = connection
            self.channel = connection

            // Wait a moment for connection to establish
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            state = .connected
            reconnectAttempts = 0
        } catch {
            state = .error
            await cleanup()
            throw StreamingProtocolError.connectionFailed(error.localizedDescription)
        }
    }
    
    func disconnect() {
        Task {
            await cleanup()
        }
        state = .disconnected
    }
    
    private func cleanup() async {
        client?.close().whenComplete { _ in }
        client = nil
        channel = nil
        
        if let group = group {
            try? await group.shutdownGracefully()
            self.group = nil
        }
    }
    
    func send<T: Encodable>(json object: T) throws {
        guard state == .connected, channel != nil else {
            throw StreamingProtocolError.notConnected
        }

        do {
            let data = try JSONEncoder().encode(object)
            try send(data: data)
        } catch {
            throw StreamingProtocolError.encodingFailed(error.localizedDescription)
        }
    }

    func send(data: Data) throws {
        guard state == .connected, channel != nil else {
            throw StreamingProtocolError.notConnected
        }
        
        // For gRPC, we'll use unary RPC calls to send data
        // In a production implementation, you'd define proper proto messages
        // For now, we'll use a generic streaming service approach
        
        queuedMessages += 1
        
        Task { [weak self] in
            guard let self = self else { return }
            
            // Note: This is a simplified implementation
            // In production, you'd need to:
            // 1. Define proto files for your messages
            // 2. Generate Swift code from protos
            // 3. Create proper service stubs
            // 4. Use bidirectional streaming or unary calls
            
            // For now, we'll simulate sending by tracking statistics
            // The actual gRPC call would look like:
            // let request = YourProtoMessage(data: data)
            // let call = service.sendData(request)
            // let response = try await call.response
            
            self.bytesSent += Int64(data.count)
            self.messagesSent += 1
            self.queuedMessages = max(0, self.queuedMessages - 1)
        }
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
        // Class is already marked @available(iOS 18.0, *)
        return true
    }
}

// Fallback for iOS < 18
@available(iOS, introduced: 16.0, obsoleted: 18.0)
final class GRPCAdapterFallback: NSObject, StreamingProtocol {
    weak var delegate: StreamingProtocolDelegate?
    private(set) var state: ConnectionState = .disconnected
    var protocolName: String { "gRPC" }
    
    func connect(config: ConnectionConfig) async throws {
        throw StreamingProtocolError.protocolNotSupported
    }
    
    func disconnect() {}
    func send<T: Encodable>(json object: T) throws { throw StreamingProtocolError.protocolNotSupported }
    func send(data: Data) throws { throw StreamingProtocolError.protocolNotSupported }
    func getStatistics() -> StreamingProtocolStatistics {
        StreamingProtocolStatistics(state: .error, bytesSent: 0, messagesSent: 0, queuedMessages: 0, reconnectAttempts: 0, protocolName: protocolName)
    }
    func resetStatistics() {}
    static func isAvailable() -> Bool { return false }
}

