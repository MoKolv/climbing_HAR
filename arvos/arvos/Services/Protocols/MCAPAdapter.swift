//
//  MCAPAdapter.swift
//  arvos
//
//  MCAP Stream adapter for streaming sensor data
//

import Foundation

final class MCAPAdapter: NSObject, StreamingProtocol {
    weak var delegate: StreamingProtocolDelegate?

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                delegate?.streamingProtocol(self, didChangeState: state)
            }
        }
    }

    private var urlSession: URLSession?
    private var baseURL: URL?

    private var bytesSent: Int64 = 0
    private var messagesSent: Int64 = 0
    private var queuedMessages: Int = 0
    private var reconnectAttempts: Int = 0
    private var droppedMessages: Int64 = 0

    // Retry configuration
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 0.5

    // Task tracking for proper cleanup
    private var activeTasks = Set<UUID>()

    var protocolName: String { "MCAP Stream" }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5.0  // Reduced timeout for faster failure detection
        configuration.httpMaximumConnectionsPerHost = 6  // Allow multiple parallel connections
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil  // Disable caching for streaming
        urlSession = URLSession(configuration: configuration)
    }
    
    func connect(config: ConnectionConfig) async throws {
        guard let url = URL(string: config.useTLS ? "https://\(config.host):\(config.port)" : "http://\(config.host):\(config.port)") else {
            throw StreamingProtocolError.connectionFailed("Invalid URL")
        }

        state = .connecting
        baseURL = url

        // Test connection with health check
        do {
            guard let session = urlSession else {
                state = .error
                throw StreamingProtocolError.connectionFailed("URL session not initialized")
            }
            let healthURL = url.appendingPathComponent("/api/mcap/health")
            var request = URLRequest(url: healthURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 3.0

            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    state = .connected
                    reconnectAttempts = 0
                } else {
                    throw StreamingProtocolError.connectionFailed("Health check failed with status \(httpResponse.statusCode)")
                }
            }
        } catch {
            // Health endpoint might not exist, try connecting anyway
            state = .connected
        }
    }

    func disconnect() {
        state = .disconnected
        baseURL = nil
        // Cancel all active tasks
        urlSession?.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        activeTasks.removeAll()
    }
    
    func send<T: Encodable>(json object: T) throws {
        guard state == .connected, let baseURL = baseURL else {
            droppedMessages += 1
            throw StreamingProtocolError.notConnected
        }

        let data = try JSONEncoder().encode(object)
        let url = baseURL.appendingPathComponent("/api/mcap/telemetry")

        queuedMessages += 1

        Task {
            await self.sendWithRetry(data: data, url: url, contentType: "application/json", dataSize: data.count)
        }
    }
    
    func send(data: Data) throws {
        guard state == .connected, let baseURL = baseURL else {
            droppedMessages += 1
            throw StreamingProtocolError.notConnected
        }

        let url = baseURL.appendingPathComponent("/api/mcap/binary")

        queuedMessages += 1

        Task {
            await self.sendWithRetry(data: data, url: url, contentType: "application/octet-stream", dataSize: data.count)
        }
    }

    // Retry logic with exponential backoff
    private func sendWithRetry(data: Data, url: URL, contentType: String, dataSize: Int, attempt: Int = 0) async {
        guard let session = urlSession else {
            self.queuedMessages = max(0, self.queuedMessages - 1)
            self.droppedMessages += 1
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    self.bytesSent += Int64(dataSize)
                    self.messagesSent += 1
                    self.queuedMessages = max(0, self.queuedMessages - 1)
                } else if httpResponse.statusCode >= 500 && attempt < maxRetries {
                    // Server error - retry
                    let delay = retryDelay * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await sendWithRetry(data: data, url: url, contentType: contentType, dataSize: dataSize, attempt: attempt + 1)
                } else {
                    // Client error or max retries reached - drop message
                    self.queuedMessages = max(0, self.queuedMessages - 1)
                    self.droppedMessages += 1
                    let error = StreamingProtocolError.connectionFailed("HTTP \(httpResponse.statusCode)")
                    self.delegate?.streamingProtocol(self, didEncounterError: error)
                }
            }
        } catch {
            // Network error - retry
            if attempt < maxRetries {
                let delay = retryDelay * pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await sendWithRetry(data: data, url: url, contentType: contentType, dataSize: dataSize, attempt: attempt + 1)
            } else {
                // Max retries reached
                self.queuedMessages = max(0, self.queuedMessages - 1)
                self.droppedMessages += 1
                if self.droppedMessages % 50 == 0 {
                }
                self.delegate?.streamingProtocol(self, didEncounterError: error)
            }
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
        return true
    }
}

