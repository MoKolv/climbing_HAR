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
    
    private let liveBatchSize = 50
    private let liveFlushInterval: TimeInterval = 0.02
    private let backgroundFlushInterval: TimeInterval = 1.0
    private let backgroundBatchSize = 250
    private let maxBufferedSensorPackets = 15_000
    
    private var liveBatchInFlight = false
    private var sensorGeneration: UInt64 = 0
    
    private struct BackgroundTransferContext {
        let generation: UInt64
        let packets: [WatchSensorPacket]
    }
    
    private var backgroundTransfers: [ObjectIdentifier: BackgroundTransferContext] = [:]
    private var backgroundInFlightPacketCount = 0
    
    private var sensorDeliveryPaused = false
    private var pendingSensorDrainCompletions: [() -> Void] = []
    
    private var peakOutstandingSensorPackets = 0
    private var droppedSensorPackets = 0
    private var acknowledgedSensorPackets = 0
    private var failedLiveBatchCount = 0
    private var failedBackgroundBatchCount = 0
    private var liveInFlightPacketCount = 0
    private var drainStartedAtNs: UInt64?
    
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
        
        // send sensor packet to buffer, so that it does not interfere with time syncs
        bufferPacket(packet)
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
        updatePeakOutstandingLocked()
        
        // Limit buffer size to prevent memory issues
        if messageQueue.count > maxBufferedSensorPackets {
            let droppedCount = messageQueue.count - maxBufferedSensorPackets // Drop oldest half
            
            messageQueue.removeFirst(droppedCount)
            droppedSensorPackets += droppedCount
            
            print("Watch sensor queue limit reached; dropped \(droppedCount) packets")
        }
        
        let shouldScheduleFlush = !sensorDeliveryPaused && flushTimer == nil
        queueLock.unlock()
        
        if shouldScheduleFlush {
            scheduleFlush()
        }
    }
    
    func pauseSensorDelivery() {
        queueLock.lock()
        sensorDeliveryPaused = true
        queueLock.unlock()
        
        flushTimer?.invalidate()
        flushTimer = nil
    }
    
    func resumeSensorDelivery() {
        queueLock.lock()
        sensorDeliveryPaused = false
        let shouldScheduleFlush = !messageQueue.isEmpty && !liveBatchInFlight
        queueLock.unlock()
        
        if shouldScheduleFlush {
            scheduleFlush()
        }
    }
    
    func drainSensorPackets(completion: @escaping () -> Void) {
        queueLock.lock()
        
        sensorDeliveryPaused = false
        drainStartedAtNs = WatchTime.now()
        
        if messageQueue.isEmpty && !liveBatchInFlight, backgroundTransfers.isEmpty {
            let summary = drainSummaryLocked()
            queueLock.unlock()
            
            print(summary)
            DispatchQueue.main.async(execute: completion)
            return
        }
        
        pendingSensorDrainCompletions.append(completion)
        let shouldScheduleFlush = !messageQueue.isEmpty
            && !liveBatchInFlight
            && backgroundTransfers.isEmpty
        queueLock.unlock()
        
        if shouldScheduleFlush {
            scheduleFlush()
        }
    }
    
    func resetSensorTransportMetrics() {
        queueLock.lock()
        peakOutstandingSensorPackets = messageQueue.count
            + liveInFlightPacketCount
            + backgroundInFlightPacketCount
        
        droppedSensorPackets = 0
        acknowledgedSensorPackets = 0
        failedLiveBatchCount = 0
        failedBackgroundBatchCount = 0
        drainStartedAtNs = nil
        
        queueLock.unlock()
    }
    
    func updatePeakOutstandingLocked() {
        let outstanding = messageQueue.count
            + liveInFlightPacketCount
            + backgroundInFlightPacketCount
        peakOutstandingSensorPackets = max(outstanding, peakOutstandingSensorPackets)
    }
    
    private func drainSummaryLocked() -> String {
        let durationNs: UInt64
        
        if let drainStartedAtNs {
            durationNs = WatchTime.now() - drainStartedAtNs
        } else {
            durationNs = 0
        }
        
        return """
            Watch transport summary:
            peak outstanding packets: \(peakOutstandingSensorPackets)
            acknowledged packets: \(acknowledgedSensorPackets)
            dropped queue packets: \(droppedSensorPackets)
            failed live batches: \(failedLiveBatchCount)
            drain duration: \(Double(durationNs) / 1_000_000.0) ms
            failed background batches: \(failedBackgroundBatchCount)
            """
    }
    
    private func takeDrainCompletionsIfReadyLocked() -> ([() -> Void], String?) {
        guard messageQueue.isEmpty,
              !liveBatchInFlight,
              backgroundTransfers.isEmpty,
              !pendingSensorDrainCompletions.isEmpty else {
            return ([], nil)
        }
        
        let completions = pendingSensorDrainCompletions
        pendingSensorDrainCompletions.removeAll()
        return (completions, drainSummaryLocked())
    }
    
    func discardBufferedSensorPackers() {
        
        queueLock.lock()
        sensorGeneration &+= 1
        
        let droppedCount = messageQueue.count
        
        messageQueue.removeAll()
        queueLock.unlock()
        
        flushTimer?.invalidate()
        flushTimer = nil
        
        print("Discarded \(droppedCount) buffered packets")
    }
    
    func cancelOutstandingSensorTransfers() {
        guard let session else { return }
        
        let transfers = session.outstandingUserInfoTransfers.filter { transfer in transfer.userInfo["packets"] != nil}
        
        transfers.forEach { $0.cancel() }
        
        queueLock.lock()
        for transfer in transfers {
            if let context = backgroundTransfers.removeValue(
                forKey: ObjectIdentifier(transfer)
            ) {
                backgroundInFlightPacketCount = max(0, backgroundInFlightPacketCount - context.packets.count)
            }
        }
        queueLock.unlock()
        print("Cancelled \(transfers.count) outstanding transfers")
    }
    
    private func scheduleFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.flushTimer == nil else { return }
            
            let interval = self.session?.isReachable == true
            ? self.liveFlushInterval
            : self.backgroundFlushInterval
            
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
                [weak self] _ in
                self?.flushBuffer()
            }
        }
    }
    
    private func flushBuffer() {
        flushTimer = nil
        
        guard let session = session, session.activationState == .activated else {
            scheduleFlush() // Retry later
            return
        }
        
        let useLiveMessage = session.isReachable
        
        queueLock.lock()
        
        if sensorDeliveryPaused {
            queueLock.unlock()
            return
        }
        
        if useLiveMessage && liveBatchInFlight {
            queueLock.unlock()
            return
        }
        
        if !useLiveMessage && !backgroundTransfers.isEmpty {
            queueLock.unlock()
            return
        }
        
        let maximumBatchSize = useLiveMessage ? liveBatchSize : backgroundBatchSize
        let batchCount = min(maximumBatchSize, messageQueue.count)
        
        guard batchCount > 0 else {
            queueLock.unlock()
            return
        }
        
        let packetsToSend = Array(messageQueue.prefix(batchCount))
        messageQueue.removeFirst(batchCount)
        let generation = sensorGeneration
        
        if useLiveMessage {
            liveBatchInFlight = true
            liveInFlightPacketCount = packetsToSend.count
            updatePeakOutstandingLocked()
        }
        
        queueLock.unlock()
        
        do {
            let encoded = try JSONEncoder().encode(packetsToSend)
            let message : [String: Any] = [
                "packets": encoded,
                "count": packetsToSend.count
            ]
            
            if useLiveMessage {
                session.sendMessage(
                    message,
                    replyHandler: { [weak self] _ in
                        self?.finishLiveBatch(generation: generation)
                    },
                    errorHandler: { [weak self] _ in
                        self?.finishLiveBatch(
                            generation: generation,
                            failedPackets: packetsToSend
                        )
                    }
                )
            } else {
                let transfer = session.transferUserInfo(message)
                queueLock.lock()
                backgroundTransfers[ObjectIdentifier(transfer)] = BackgroundTransferContext(
                    generation: generation,
                    packets: packetsToSend
                )
                
                backgroundInFlightPacketCount += packetsToSend.count
                updatePeakOutstandingLocked()
                queueLock.unlock()
            }
            
            updateSendStatistics(
                messages: packetsToSend.count,
                bytes: Int64(encoded.count)
            )
        } catch {
            queueLock.lock()
            
            if useLiveMessage {
                liveBatchInFlight = false
                liveInFlightPacketCount = 0
                failedLiveBatchCount += 1
            }
            
            if generation == sensorGeneration {
                messageQueue.insert(contentsOf: packetsToSend, at: 0)
            }
            
            let shouldFlushAgain = !messageQueue.isEmpty
            queueLock.unlock()
            
            if shouldFlushAgain {
                scheduleFlush()
            }
        }
    }

    
    private func finishLiveBatch(generation: UInt64, failedPackets: [WatchSensorPacket] = []) {
        queueLock.lock()
        
        let completedPacketCount = liveInFlightPacketCount
        liveBatchInFlight = false
        liveInFlightPacketCount = 0
        
        if failedPackets.isEmpty {
            acknowledgedSensorPackets += completedPacketCount
        } else {
            failedLiveBatchCount += 1
            
            if generation == sensorGeneration {
                messageQueue.insert(contentsOf: failedPackets, at: 0)
            }
        }
        
        let shouldFlushAgain = !messageQueue.isEmpty && !sensorDeliveryPaused
        let (drainCompletions, drainSummary) = takeDrainCompletionsIfReadyLocked()
        queueLock.unlock()
        
        if shouldFlushAgain {
            scheduleFlush()
        }
        
        if let drainSummary {
            print("Drained:", drainSummary)
        }
        
        drainCompletions.forEach { completion in
            DispatchQueue.main.async(execute: completion)
        }
    }
    
    private func finishBackgroundTransfer(_ transfer: WCSessionUserInfoTransfer, error: Error?) {
        queueLock.lock()
        
        guard let context = backgroundTransfers.removeValue(forKey: ObjectIdentifier(transfer)) else {
            queueLock.unlock()
            return
        }
        
        backgroundInFlightPacketCount = max(0, backgroundInFlightPacketCount - context.packets.count)
        
        if error == nil {
            acknowledgedSensorPackets += context.packets.count
        } else {
            failedBackgroundBatchCount += 1
            if context.generation == sensorGeneration {
                messageQueue.insert(contentsOf: context.packets, at: 0)
            }
        }
        
        let shouldFlushAgain = !messageQueue.isEmpty && !sensorDeliveryPaused
        let (drainCompletions, drainSummary) = takeDrainCompletionsIfReadyLocked()
        queueLock.unlock()
        
        if shouldFlushAgain {
            scheduleFlush()
        }
        
        if let drainSummary {
            print("Drained:", drainSummary)
        }
        
        drainCompletions.forEach { completion in
            DispatchQueue.main.async(execute: completion)
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
    
    @discardableResult
    func sendCommandWithReply(
        _ command: String,
        parameters: [String: Any] = [:],
        replyHandler: @escaping([String: Any]) -> Void,
        errorHandler: @escaping (Error) -> Void
    ) -> Bool {
        guard let session = session,
              session.activationState == .activated,
              session.isReachable else {
            print("Cannot send command with reply: \(command) because session is no reachable")
            return false
        }
        
        var dict = parameters
        dict["command"] = command
        
        session.sendMessage(dict, replyHandler: replyHandler, errorHandler: errorHandler)
        return true
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
    
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        finishBackgroundTransfer(userInfoTransfer, error: error)
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
                
                self.delegate?.watchConnectivity(self, didReceivePacket: packet)
                
                DispatchQueue.main.async {
                    self.messagesReceived += 1
                }
            } catch {}
        }
        
        // Handle batch of packets
        if let packetsData = message["packets"] as? Data {
            do {
                let packets = try JSONDecoder().decode([WatchSensorPacket].self, from: packetsData)
                
                for packet in packets {
                    self.delegate?.watchConnectivity(self, didReceivePacket: packet)
                }
                
                DispatchQueue.main.async {
                    self.messagesReceived += packets.count
                }
            }
            catch {}
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

