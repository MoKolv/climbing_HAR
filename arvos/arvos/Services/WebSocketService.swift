//
//  WebSocketService.swift
//  arvos
//
//  WebSocket service for streaming sensor data
//

import Foundation
import Combine
import Network

protocol WebSocketServiceDelegate: AnyObject {
    func webSocketService(_ service: WebSocketService, didChangeState state: ConnectionState)
    func webSocketService(_ service: WebSocketService, didReceiveMessage message: String)
    func webSocketService(_ service: WebSocketService, didEncounterError error: Error)
}

enum ConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connectionURL: URL?

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if state != oldValue {
                delegate?.webSocketService(self, didChangeState: state)
            }
        }
    }

    // Reconnection
    private var shouldReconnect = false
    private var reconnectAttempts = 0
    private var reconnectTimer: Timer?

    // Small message queue for brief disconnections
    // For streaming-first use case, we drop old messages instead of buffering extensively
    private var messageQueue: [Data] = []
    private let maxQueueSize = 10

    // Network path monitor for detecting connection changes
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.arvos.networkMonitor")
    private var isNetworkAvailable = true

    // Heartbeat
    private var heartbeatTimer: Timer?

    // Statistics
    private var bytesSent: Int64 = 0
    private var messagesSent: Int64 = 0

    deinit {
        reconnectTimer?.invalidate()
        heartbeatTimer?.invalidate()
        pathMonitor?.cancel()
    }
    private var droppedMessages: Int64 = 0

    override init() {
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Constants.Network.connectionTimeout
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        setupNetworkMonitoring()
    }

    private func setupNetworkMonitoring() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let wasAvailable = self.isNetworkAvailable
            self.isNetworkAvailable = path.status == .satisfied

            if !wasAvailable && self.isNetworkAvailable {
                // Network came back - attempt reconnection immediately if we should reconnect
                if self.shouldReconnect && self.state != .connected {
                    DispatchQueue.main.async {
                        self.reconnectAttempts = 0 // Reset attempts on network restoration
                        self.attemptConnection()
                    }
                }
            } else if wasAvailable && !self.isNetworkAvailable {
            }
        }
        pathMonitor?.start(queue: monitorQueue)
    }

    // MARK: - Connection

    func connect(to url: URL) {
        connectionURL = url
        shouldReconnect = true
        reconnectAttempts = 0
        attemptConnection()
    }

    private func attemptConnection() {
        guard let url = connectionURL else { return }

        state = .connecting

        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        // Start receiving messages
        receiveMessage()

        // Send handshake after connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendHandshake()
        }
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        state = .disconnected
        messageQueue.removeAll()
    }

    // MARK: - Sending Messages

    /// Send JSON message
    func send<T: Encodable>(json object: T) throws {
        let data = try JSONEncoder().encode(object)
        send(data: data, asText: true)
    }

    /// Send binary message
    func send(data: Data, asText: Bool = false) {
        guard state == .connected else {
            // Buffer message if offline (small queue for brief disconnections)
            if messageQueue.count < maxQueueSize {
                messageQueue.append(data)
            } else {
                // Drop oldest message to make room (streaming-first: old data is stale)
                messageQueue.removeFirst()
                messageQueue.append(data)
                droppedMessages += 1
                if droppedMessages % 50 == 0 {
                }
            }
            return
        }

        let message: URLSessionWebSocketTask.Message = asText ? .string(String(data: data, encoding: .utf8) ?? "") : .data(data)

        webSocket?.send(message) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.delegate?.webSocketService(self, didEncounterError: error)
                self.handleConnectionError()
            } else {
                self.bytesSent += Int64(data.count)
                self.messagesSent += 1
            }
        }
    }

    /// Send handshake message
    private func sendHandshake() {
        let handshake = HandshakeMessage(timestamp: TimestampManager.shared.now())

        do {
            try send(json: handshake)
            state = .connected
            flushMessageQueue()
        } catch {
            delegate?.webSocketService(self, didEncounterError: error)
        }
    }

    /// Flush queued messages after reconnection
    private func flushMessageQueue() {
        guard state == .connected else { return }

        let queue = messageQueue
        messageQueue.removeAll()

        for data in queue {
            send(data: data, asText: false)
        }
    }

    // MARK: - Receiving Messages

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.delegate?.webSocketService(self, didReceiveMessage: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.delegate?.webSocketService(self, didReceiveMessage: text)
                    }
                @unknown default:
                    break
                }

                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                self.delegate?.webSocketService(self, didEncounterError: error)
                self.handleConnectionError()
            }
        }
    }

    // MARK: - Error Handling

    private func handleConnectionError() {
        state = .error

        // Don't retry if network is down
        guard isNetworkAvailable else {
            return
        }

        guard shouldReconnect, reconnectAttempts < Constants.Network.maxReconnectAttempts else {
            state = .disconnected
            return
        }

        reconnectAttempts += 1
        // Improved exponential backoff with jitter: min(initial * 2^attempt, max) + jitter
        let baseDelay = min(Constants.Network.reconnectDelay * pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        let jitter = Double.random(in: 0...1.0) // Add jitter to avoid thundering herd
        let delay = baseDelay + jitter


        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.attemptConnection()
        }
    }

    // MARK: - Heartbeat

    func startHeartbeat() {
        stopHeartbeat()
        // Run heartbeat on main thread for reliability
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Constants.Network.heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .connected else { return }

            let ping = StatusMessage(
                timestamp: TimestampManager.shared.now(),
                status: "ping"
            )

            // Ensure encoding happens on main actor to satisfy Swift 6 concurrency requirements
            Task { @MainActor in
                try? self.send(json: ping)
            }
        }
        // Add to run loop to ensure it fires even during UI updates
        if let timer = heartbeatTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Statistics

    func getStatistics() -> NetworkStatistics {
        return NetworkStatistics(
            state: state,
            bytesSent: bytesSent,
            messagesSent: messagesSent,
            queuedMessages: messageQueue.count,
            reconnectAttempts: reconnectAttempts,
            droppedMessages: droppedMessages
        )
    }

    func resetStatistics() {
        bytesSent = 0
        messagesSent = 0
        droppedMessages = 0
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // Connection opened
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if shouldReconnect {
            handleConnectionError()
        } else {
            state = .disconnected
        }
    }
}

// MARK: - Network Statistics

struct NetworkStatistics {
    let state: ConnectionState
    let bytesSent: Int64
    let messagesSent: Int64
    let queuedMessages: Int
    let reconnectAttempts: Int
    let droppedMessages: Int64

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
