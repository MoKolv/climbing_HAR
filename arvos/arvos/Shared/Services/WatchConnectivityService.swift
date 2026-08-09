//
//  WatchConnectivityService.swift
//  arvos
//
//  Manages WatchConnectivity session for bidirectional communication
//

import Foundation
import WatchConnectivity
import Combine

protocol WatchConnectivityDelegate: AnyObject {
    func watchConnectivity(_ service: WatchConnectivityService, didReceivePacket packet: WatchSensorPacket)
    func watchConnectivity(_ service: WatchConnectivityService, didChangeReachability isReachable: Bool)
}

class WatchConnectivityService: NSObject, ObservableObject {
    static let shared = WatchConnectivityService()
    
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var isWatchReachable = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    
    weak var delegate: WatchConnectivityDelegate?
    
    private var session: WCSession?
    private var messageQueue: [WatchSensorPacket] = []
    private let queueLock = NSLock()
    private var flushTimer: Timer?
    
    // Statistics
    @Published private(set) var messagesSent: Int = 0
    @Published private(set) var messagesReceived: Int = 0
    @Published private(set) var bytesSent: Int64 = 0
    
    override private init() {
        super.init()

        guard WCSession.isSupported() else {
            #if DEBUG
            #endif
            return
        }

        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    deinit {
        flushTimer?.invalidate()
    }
    
    // MARK: - Sending
    
    /// Send a sensor packet to the companion device
    func send(packet: WatchSensorPacket) {
        guard let session = session, session.activationState == .activated else {
            #if DEBUG
            #endif
            bufferPacket(packet)
            return
        }
        
        #if os(iOS)
        guard session.isWatchAppInstalled else {
            return
        }
        #endif
        
        // Try live messaging first for low latency
        if session.isReachable {
            sendLiveMessage(packet)
        } else {
            // Buffer for background transfer
            bufferPacket(packet)
        }
    }
        
    private func sendLiveMessage(_ packet: WatchSensorPacket) {
        guard let session = session else { return }
        
        do {
            let encoded = try JSONEncoder().encode(packet)
            let dict: [String: Any] = [
                "packet": encoded
            ]
            
            session.sendMessage(dict, replyHandler: nil) { error in
                // Fallback to buffering
                self.bufferPacket(packet)
            }
            
            updateSendStatistics(messages: 1, bytes: Int64(encoded.count))
            
        } catch {
        }
    }
    
    // sends a timsync message independent of sensor-data stream
    @discardableResult
    func sendTimeSync(
        syncId: UInt64,
        phoneSendNs: UInt64,
        replyHandler: @escaping ([String: Any]) -> Void,
        errorHandler: @escaping (Error) -> Void
    ) -> Bool {
        guard let session = session,
              session.activationState == .activated,
              session.isReachable
        else {
            print(" Cannot send time_sync: Watch Session not reachable")
            return false
        }
        
        let message: [String: Any] = [
            "command": "time_sync",
            "sync_id": NSNumber(value: syncId),
            "phone_send_ns": NSNumber(value: Int64(phoneSendNs))
        ]
        
        session.sendMessage(message, replyHandler: replyHandler, errorHandler: errorHandler)
        return true
    }
    
        
    
    
    
    private func bufferPacket(_ packet: WatchSensorPacket) {
        queueLock.lock()
        messageQueue.append(packet)
        
        // Limit buffer size to prevent memory issues
        if messageQueue.count > 1000 {
            messageQueue.removeFirst(500) // Drop oldest half
        }
        
        queueLock.unlock()
        
        // Schedule flush if not already scheduled
        if flushTimer == nil {
            scheduleFlush()
        }
    }
    
    private func scheduleFlush() {
        DispatchQueue.main.async {
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                self?.flushBuffer()
            }
        }
    }
    
    private func flushBuffer() {
        guard let session = session, session.activationState == .activated else {
            scheduleFlush() // Retry later
            return
        }
        
        queueLock.lock()
        let packetsToSend = messageQueue
        messageQueue.removeAll()
        queueLock.unlock()
        
        guard !packetsToSend.isEmpty else {
            flushTimer = nil
            return
        }
        
        // Use transferUserInfo for background delivery
        do {
            let encoded = try JSONEncoder().encode(packetsToSend)
            let dict: [String: Any] = [
                "packets": encoded,
                "count": packetsToSend.count
            ]
            
            session.transferUserInfo(dict)
            
            updateSendStatistics(messages: packetsToSend.count, bytes: Int64(encoded.count))
            
            
        } catch {
            // Re-buffer the packets
            queueLock.lock()
            messageQueue.insert(contentsOf: packetsToSend, at: 0)
            queueLock.unlock()
        }
        
        flushTimer = nil
        
        // Check if more packets accumulated
        queueLock.lock()
        let hasMore = !messageQueue.isEmpty
        queueLock.unlock()
        
        if hasMore {
            scheduleFlush()
        }
    }
    
    // MARK: - Commands
    
    /// Send a command to the companion device
    func sendCommand(_ command: String, parameters: [String: Any] = [:]) {
        print("sendCommand callsed:", command, parameters)
        
        guard let session = session, session.activationState == .activated else {
            return
        }
        
        var dict = parameters
        dict["command"] = command
        
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil) { error in
                print("sendCommand error:", error)
            }
        } else {
            if command == "time_sync" {
                print("Skipping time_sync because session is not reachable")
                return
            }
            
            print("transferUserInfo command:", command)
            session.transferUserInfo(dict)
        }
    }
    
    // MARK: - Statistics
    
    func resetStatistics() {
        DispatchQueue.main.async {
            self.messagesSent = 0
            self.messagesReceived = 0
            self.bytesSent = 0
        }
    }

    private func updateSendStatistics(messages: Int = 0, bytes: Int64 = 0) {
        guard messages != 0 || bytes != 0 else { return }
        DispatchQueue.main.async {
            self.messagesSent += messages
            self.bytesSent += bytes
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                print("WatchConnectivityService: session activation failed:", error)
                return
            }
            
            
            #if os(iOS)
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
            #else
            self.isPhoneReachable = session.isReachable
            #endif
        }
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
        }
    }
    #endif
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            #if os(iOS)
            self.isWatchReachable = session.isReachable
            self.delegate?.watchConnectivity(self, didChangeReachability: session.isReachable)
            #else
            self.isPhoneReachable = session.isReachable
            self.delegate?.watchConnectivity(self, didChangeReachability: session.isReachable)
            #endif
        }
    }
    
    // MARK: - Receiving Messages
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleReceivedMessage(message)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        
        guard let command = message["command"] as? String else {
            handleReceivedMessage(message)
            replyHandler(["status": "ok"])
            return
        }
        
        switch command {
        
        case "time_sync":
            handleTimeSyncCommand(message, replyHandler: replyHandler)
            
        default :
            handleReceivedMessage(message)
            replyHandler(["status": "ok"])
        }
        
      
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handleReceivedMessage(userInfo)
    }
    
   
    private func handleTimeSyncCommand(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        
        let watchReceiveNs = WatchTime.now()
        
        guard
            let syncIdNumber = message["sync_id"] as? NSNumber,
            let phoneSendNumber = message["phone_send_ns"] as? NSNumber
        else {
            print("Invalid time_sync parameters:", message)
            replyHandler(["error": "invalid_time_sync_parameters"])
            return
        }
        
        let watchSendNs = WatchTime.now()
        
        print("Replying to time_sync id:\(syncIdNumber.uint64Value)")
        
        replyHandler([
            "sync_id": syncIdNumber,
            "phone_send_ns": phoneSendNumber,
            "watch_receive_ns": NSNumber(value: Int64(watchReceiveNs)),
            "watch_send_ns": NSNumber(value: Int64(watchSendNs))
        ])
    }
    
    
    private func handleReceivedMessage(_ message: [String: Any]) {
        // Handle single packet
        if let packetData = message["packet"] as? Data {
            do {
                let packet = try JSONDecoder().decode(WatchSensorPacket.self, from: packetData)
                DispatchQueue.main.async {
                    self.messagesReceived += 1
                    self.delegate?.watchConnectivity(self, didReceivePacket: packet)
                }
            } catch {
            }
        }
        
        // Handle batch of packets
        if let packetsData = message["packets"] as? Data {
            do {
                let packets = try JSONDecoder().decode([WatchSensorPacket].self, from: packetsData)
                DispatchQueue.main.async {
                    self.messagesReceived += packets.count
                    for packet in packets {
                        self.delegate?.watchConnectivity(self, didReceivePacket: packet)
                    }
                }
            } catch {
            }
        }
        
        // Handle commands
        if let command = message["command"] as? String {
            handleCommand(command, parameters: message)
        }
    }
    
    private func handleCommand(_ command: String, parameters: [String: Any]) {
        
        // Post notification for command handling
        NotificationCenter.default.post(
            name: .watchCommandReceived,
            object: nil,
            userInfo: ["command": command, "parameters": parameters]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let watchCommandReceived = Notification.Name("watchCommandReceived")
}

enum WatchTime {
    /// Monotonic watch timestamp in nanosecond
    static func now() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        
        let ticks = mach_absolute_time()
        return ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

