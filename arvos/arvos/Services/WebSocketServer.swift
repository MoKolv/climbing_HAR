//
//  WebSocketServer.swift
//  arvos
//
//  Embedded WebSocket server running on iPhone (Foxglove-style architecture)
//

import Foundation
import Network

/// WebSocket server that runs ON the iPhone, allowing Studio to connect as a client
/// This follows Foxglove Studio's architecture where the data source is the server
class WebSocketServer: NSObject {
    private var listener: NWListener?
    private var connections: Set<WebSocketConnection> = []
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.arvos.websocket.server")

    weak var delegate: WebSocketServiceDelegate?
    private(set) var isRunning = false

    init(port: UInt16 = 8765) {
        self.port = port
        super.init()
    }

    func start() throws {
        guard !isRunning else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Network interface configuration:
        // - acceptLocalOnly = false: Accept connections from local network (same WiFi)
        //   This works WITHOUT multicast entitlement for local network connections
        // - With multicast entitlement (when Apple approves): Can also accept from
        //   cellular/hotspot interfaces. Until then, local WiFi network works fine.
        parameters.acceptLocalOnly = false  // Listen on all local interfaces (WiFi)

        // Enable WebSocket upgrade
        let wsOptions = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
        } catch {
            // If setting acceptLocalOnly = false fails (shouldn't happen on local network),
            // we could fall back to acceptLocalOnly = true, but that would only allow
            // localhost connections, which isn't useful for our use case.
            throw WebSocketServerError.failedToStart(error.localizedDescription)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                self?.printConnectionInfo()
            case .failed(let error):
                self?.isRunning = false
            case .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        connections.forEach { $0.connection.cancel() }
        connections.removeAll()
        isRunning = false
    }

    func broadcast(data: Data) {
        connections.forEach { conn in
            conn.send(data: data)
        }
    }

    func broadcast<T: Encodable>(json: T) throws {
        let data = try JSONEncoder().encode(json)
        broadcast(data: data)
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {

        let conn = WebSocketConnection(connection: nwConnection)
        connections.insert(conn)

        conn.onDisconnect = { [weak self] in
            self?.connections.remove(conn)
        }

        conn.start()
        // Note: WebSocketServer doesn't use delegate - it broadcasts to all connections
    }

    private func printConnectionInfo() {
        let ips = getLocalIPAddresses()
        for ip in ips {
        }
    }

    func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Include all network interfaces: WiFi (en), cellular (pdp_ip), and link-local (bridge, awdl, llw, utun)
                if name.starts(with: "en") || name.starts(with: "pdp_ip") || name.starts(with: "bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    let address = String(cString: hostname)
                    // Filter out localhost
                    if !address.starts(with: "127.") && !addresses.contains(address) {
                        addresses.append(address)
                    }
                }
            }
        }

        return addresses
    }

    var connectionCount: Int {
        return connections.count
    }
}

/// Individual WebSocket connection to a client
class WebSocketConnection: Hashable {
    let connection: NWConnection
    let id = UUID()
    var onDisconnect: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.onDisconnect?()
            }
        }
        connection.start(queue: .global())
    }

    func send(data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "data", metadata: [metadata])

        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    static func == (lhs: WebSocketConnection, rhs: WebSocketConnection) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum WebSocketServerError: LocalizedError {
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .failedToStart(let reason):
            return "Failed to start WebSocket server: \(reason)"
        }
    }
}
