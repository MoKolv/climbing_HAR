//
//  WatchSensorManager.swift
//  arvos
//
//  Manages watch sensor data integration on iPhone
//

import Foundation
import Combine

protocol WatchSensorManagerDelegate: AnyObject {
    func watchSensorManager(_ manager: WatchSensorManager, didReceiveIMU data: WatchIMUNetworkData)
    func watchSensorManager(_ manager: WatchSensorManager, didReceiveAttitude data: WatchAttitudeNetworkData)
}

class WatchSensorManager: ObservableObject {
    static let shared = WatchSensorManager()
    
    @Published private(set) var isWatchConnected = false
    @Published private(set) var isWatchStreaming = false
    @Published private(set) var watchSampleCount: Int = 0
    @Published private(set) var watchHz: Double = 0
    @Published private(set) var latestAttitude: WatchAttitudeData?
    @Published private(set) var latestActivity: WatchMotionActivityData?
    
    weak var delegate: WatchSensorManagerDelegate?
    
    private let connectivityService = WatchConnectivityService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // FPS tracking
    private var sampleTimestamps: [TimeInterval] = []
    private let fpsWindow: TimeInterval = 1.0
    
    // Time synchronization
    private var timeOffsetNs: Int64 = 0 // Offset between watch and phone clocks
    private var lastSyncTime: Date?
    
    // watch/phone time sync variables
    private var watchToPhoneOffsetNs: Int64?
    private var lastSyncRTTNs: UInt64?
    private var syncSequence: UInt64 = 0
    private var timeSyncTimer: Timer?
    private var pendingTimeSyncId: UInt64?
    private var pendingPhoneSendNs: UInt64?
    private let timeSyncQueue = DispatchQueue(label: "watch.timeSync.queue")
    private let timeSyncTimeoutSeconds: TimeInterval = 0.3
    
    private var initialSyncCompletion: (() -> Void)?
    private var initialSyncAttemptsRemaining = 0
    private var initialSyncBestOffsetNs: Int64?
    private var initialSyncBestRTTNs: UInt64?
    
    private let initialSyncAttemptCount = 8
    private let initialSyncSpacingSeconds: TimeInterval = 0.4
    private let initialSyncTimeoutSeconds: TimeInterval = 0.3
    
    private let initialMacAcceptableRTTNs: UInt64 = 300_000_000 //300ms
    
    private enum TimeSyncMode {
        case initialBurst
        case normal
    }
    
    
    
    // max round trip delay 100ms atm
    private var bestRTTNs: UInt64?
    private let initialMaxAcceptableRTTNs: UInt64 = 1_000_000_000
    private let normalMaxAcceptableRTTNs: UInt64 = 100_000_000
    private let offsetSmoothingFactor: Double = 0.2
    
    // time sync variables
    
    
    private init() {
        setupConnectivity()
        setupObservers()
    }
    
    private func setupConnectivity() {
        connectivityService.delegate = self
    }
    
    private func setupObservers() {
        // Observe watch reachability
        connectivityService.$isWatchReachable
            .sink { [weak self] isReachable in
                self?.isWatchConnected = isReachable
                if !isReachable {
                    self?.isWatchStreaming = false
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Control
    
    func startWatchStreaming(hz: Int = 50) {
        guard isWatchConnected else {
            print("⚠️ Watch not connected")
            return
        }
        
        guard !isWatchStreaming else { return }
        
        resetTimeSyncState()
        
        runInitialTimeSyncBurst {[weak self] in
            guard let self = self else {
                print("Initial sync completeion entered, but self is nil")
                return
            }
            
            print("initial sync completion entered")
            print("watchToPhoneOffsetNs =", self.watchToPhoneOffsetNs.map(String.init) ?? "nil")
            
            guard self.watchToPhoneOffsetNs != nil else {
                print("Could not start Watch streaming: no valid time sync offset")
                return
            }
            
            print("sending start_streaming command to Watch")
            
            self.connectivityService.sendCommand("start_streaming", parameters: ["hz": hz])
            
            self.isWatchStreaming = true
            self.watchSampleCount = 0
            self.sampleTimestamps.removeAll()
            
            print("Watch streaming started after initial time syns")
            
        }
       
    }
    
    func stopWatchStreaming() {
        guard isWatchStreaming else { return }
        
        connectivityService.sendCommand("stop_streaming")
        isWatchStreaming = false
        watchHz = 0
        stopTimeSyncTimer()
        
    }
    
    func updateWatchFrequency(_ hz: Int) {
        guard isWatchStreaming else { return }
        connectivityService.sendCommand("update_frequency", parameters: ["hz": hz])
    }
    
    // MARK: - Time Synchronization
    
    private func phoneNowNs() -> UInt64 {
        Constants.Time.now()
    }
    
    private func performTimeSync(mode: TimeSyncMode) {
        
        guard pendingTimeSyncId == nil else {
            print("Skipping time sync because id \(pendingTimeSyncId!) is still pending")
            return
        }
        
        syncSequence += 1
        
        let syncId = syncSequence
        let phoneSendNs = phoneNowNs()
        
        pendingTimeSyncId = syncId
        pendingPhoneSendNs = phoneSendNs
        
        print("📱 Sending timeSync id=\(syncSequence), phoneSendNs=\(phoneSendNs)")
        
        // send time_sync to watch
        let sent = connectivityService.sendTimeSync(
            syncId: syncId,
            phoneSendNs: phoneSendNs,
            replyHandler: {[weak self] reply in
                DispatchQueue.main.async {self?.handleTimeSyncReply(reply, mode:mode)}},
            errorHandler: {[weak self] error in
                DispatchQueue.main.async {
                    print("time_sync error:", error)
                    self?.pendingTimeSyncId = nil
                    self?.pendingPhoneSendNs = nil
                }
            }
        )
        
        // reset pending timesyncs if time_sync message to watch failed
        if !sent {
            pendingTimeSyncId = nil
            pendingPhoneSendNs = nil
            return
        }
        
        // timeout if message takes to long
        timeSyncQueue.asyncAfter(deadline: .now() + timeSyncTimeoutSeconds) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else {return}
                
                if self.pendingTimeSyncId == syncId {
                    print("time_sync id: \(syncId) timed out")
                    self.pendingTimeSyncId = nil
                    self.pendingPhoneSendNs = nil
                }
            }}
    }
    
    private func handleTimeSyncReply(_ reply: [String: Any], mode: TimeSyncMode) {
        guard
            let syncIdNumber = reply["sync_id"] as? NSNumber,
            let phoneSendNumber = reply["phone_send_ns"] as? NSNumber,
            let watchReceiveNumber = reply["watch_receive_ns"] as? NSNumber,
            let watchSendNumber = reply["watch_send_ns"] as? NSNumber
        else {
            print("⚠️ Invalid time sync reply: \(reply)")
            pendingTimeSyncId = nil
            pendingPhoneSendNs = nil
            return
        }
        
        let responseSyncId = syncIdNumber.uint64Value
        let responsePhoneSendNs = phoneSendNumber.uint64Value
        let watchReceiveNs = watchReceiveNumber.uint64Value
        let watchSendNs = watchSendNumber.uint64Value
        
        guard pendingTimeSyncId == responseSyncId else {
            print(" Ignoring stale direct time_synce reply id= \(responseSyncId)")
            return
        }
        
        // compare returned timestamp from watch with last stored send timestamp from phone
        guard let originalPhoneSendNs = pendingPhoneSendNs,
              originalPhoneSendNs == responsePhoneSendNs
        else {
            print("Ignoring mismatched direct time_sync id= \(responseSyncId)")
            pendingTimeSyncId = nil
            pendingPhoneSendNs = nil
            return
        }
        
        pendingTimeSyncId = nil
        pendingPhoneSendNs = nil
        
        let phoneReceiveNs = phoneNowNs()
        
        guard phoneReceiveNs >= responsePhoneSendNs else {
            print("Invalid direct time sync: phoneReceiveNs < phoneSendNs")
            return
        }
        
        let rttNs = phoneReceiveNs - responsePhoneSendNs
        
        let maxRTT = watchToPhoneOffsetNs == nil ? initialMaxAcceptableRTTNs : normalMaxAcceptableRTTNs
        
        guard rttNs <= maxRTT else {
            print("Ignoring direct time_sync with RTT \(rttNs) ns")
            return
        }
        
        // calculate phone-watch offset, assuming roughly symmetrical trip
        let offset1 = Int64(responsePhoneSendNs) - Int64(watchReceiveNs)
        let offset2 = Int64(phoneReceiveNs) - Int64(watchSendNs)
        let estimatedOffset = (offset1 + offset2) / 2
        
        switch mode {
        case .initialBurst:
            updateInitialSyncBestOffset(
                estimatedOffset: estimatedOffset,
                rttNs: rttNs,
                syncId: responseSyncId
            )
        case .normal:
            updateOffsetEstimate(
                estimatedOffset: estimatedOffset,
                rttNs: rttNs,
                syncId: responseSyncId
            )
        }
        
        
        updateOffsetEstimate(
            estimatedOffset: estimatedOffset,
            rttNs: rttNs,
            syncId: responseSyncId
        )
    }
    
    private func resetTimeSyncState() {
        pendingTimeSyncId = nil
        pendingPhoneSendNs = nil

        initialSyncCompletion = nil
        initialSyncAttemptsRemaining = 0
        initialSyncBestOffsetNs = nil
        initialSyncBestRTTNs = nil
        
        watchToPhoneOffsetNs = nil
        lastSyncRTTNs = nil
    }
    
    private func runInitialTimeSyncBurst(completion: @escaping () -> Void) {
        initialSyncCompletion = completion
        initialSyncAttemptsRemaining = initialSyncAttemptCount
        initialSyncBestOffsetNs = nil
        initialSyncBestRTTNs = nil
        
        performInitialTimeSyncAttempt()
    }
    
    private func updateInitialSyncBestOffset(estimatedOffset: Int64, rttNs: UInt64, syncId: UInt64) {
        if let bestRTT = initialSyncBestRTTNs, rttNs >= bestRTT {
            print("Initial sync id= \(syncId) accepted but not better than best RTT")
            return
        }
        
        initialSyncBestRTTNs = rttNs
        initialSyncBestOffsetNs = estimatedOffset
        
        print("""
            Initial sync condidate improved
            syncId      = \(syncId)
            offsetNs    = \(estimatedOffset)
            rttNs       = \(rttNs)
            rttMs       = \(Double(rttNs) / 1_000_000.0)
            """)
    }
    
    private func finishInitialTimeSyncBurst() {
        print("finishInitialTimeSyncBurst called")
        
        if let bestOffset = initialSyncBestOffsetNs,
           let bestRTT = initialSyncBestRTTNs {
            watchToPhoneOffsetNs = bestOffset
            lastSyncRTTNs = bestRTT
            
            print("""
                Initial time sync complete:
                selectedOffsetNs    = \(bestOffset)
                selectedRTTNs       = \(bestRTT)
                selectedRTTMs       = \(Double(bestRTT) / 1_000_000.0)
                """)
        } else {
            print("initial time sync failed: no valid sync replies")
        }
        
        let completion = initialSyncCompletion
        initialSyncCompletion = nil
        print("Valling initial sync completion:", completion != nil)
        completion?()
    }
    
    private func performInitialTimeSyncAttempt() {
        guard initialSyncAttemptsRemaining > 0 else {
            finishInitialTimeSyncBurst()
            return
        }
        
        initialSyncAttemptsRemaining -= 1
        performTimeSync(mode: .initialBurst)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + initialSyncSpacingSeconds) {[weak self] in
            self?.performInitialTimeSyncAttempt()
        }
    }
    
    private func updateOffsetEstimate(estimatedOffset: Int64, rttNs: UInt64, syncId: UInt64) {
        if watchToPhoneOffsetNs == nil {
            watchToPhoneOffsetNs = estimatedOffset
            lastSyncRTTNs = rttNs
            
            print("""
                Initial time_sync accepted:
                syncId:     =\(syncId)
                offsetNs    =\(estimatedOffset)
                rttNs:      =\(rttNs)
                rttMs:      =\(Double(rttNs) / 1_000_000.0)
                """)
            
            return
        }
        
        let currentOffset = watchToPhoneOffsetNs!
        
        // smoothe offset with incoming, non stale time_syncs
        let smoothed = Double(currentOffset) * (1.0 - offsetSmoothingFactor) + Double(estimatedOffset) * offsetSmoothingFactor
        
        watchToPhoneOffsetNs = Int64(smoothed)
        lastSyncRTTNs = rttNs
        
        print("""
            Time_sync update accepted:
            syncId:             =\(syncId)
            estimatedOffset:    =\(estimatedOffset)
            smoothedOffset:     =\(smoothed)
            rttNs:              =\(rttNs)
            rttMs:              =\(Double(rttNs) / 1_000_000.0)
            """)
    }
    
    private func adjustTimestamp(_ watchTimestampNs: UInt64) -> UInt64? {
        
//        print("adjustedTimestamp called | raw=\(watchTimestampNs), offset=\(watchToPhoneOffsetNs.map(String.init) ?? "nil")")
        
        guard let offset = watchToPhoneOffsetNs else {
            return nil
        }
        
        guard watchTimestampNs <= UInt64(Int64.max) else {
            print("⚠️ watchTimestamps too large to be represented as Int64")
            return nil
        }
        
        let watchSigned = Int64(watchTimestampNs)
        let result = watchSigned.addingReportingOverflow(offset)
        
        guard !result.overflow, result.partialValue > 0 else {
            return nil
        }
        
        
        return UInt64(result.partialValue)
    }
    
    private func stopTimeSyncTimer() {
        timeSyncTimer?.invalidate()
        timeSyncTimer = nil
        
        pendingTimeSyncId = nil
        pendingPhoneSendNs = nil
    }
    
    // MARK: - Statistics
    
    func getStatistics() -> WatchStatistics {
        return WatchStatistics(
            isConnected: isWatchConnected,
            isStreaming: isWatchStreaming,
            sampleCount: watchSampleCount,
            hz: watchHz,
            messagesSent: connectivityService.messagesSent,
            messagesReceived: connectivityService.messagesReceived,
            bytesSent: connectivityService.bytesSent
        )
    }
    
    func resetStatistics() {
        DispatchQueue.main.async {
            self.watchSampleCount = 0
            self.watchHz = 0
            self.sampleTimestamps.removeAll()
        }
        connectivityService.resetStatistics()
    }
    
    private func updateFPS() {
        let now = Date().timeIntervalSinceReferenceDate
        sampleTimestamps.append(now)
        
        // Remove old timestamps
        sampleTimestamps.removeAll { now - $0 > fpsWindow }
        
        // Calculate FPS
        watchHz = Double(sampleTimestamps.count) / fpsWindow
    }
}

// MARK: - WatchConnectivityDelegate

extension WatchSensorManager: WatchConnectivityDelegate {
    func watchConnectivity(_ service: WatchConnectivityService, didReceivePacket packet: WatchSensorPacket) {
        // Adjust timestamp
        let rawWatchTimestampNs = packet.timestampNs
        let phoneReceiveTimestampNs = phoneNowNs()
       
        // Handle different packet types
        switch packet.sensorType {
                       
        case "watch_imu":
            guard let adjustedTimestamp = adjustTimestamp(packet.timestampNs) else {
                print("Dropping Watch IMU before time sync")
                return
            }
            guard let watchIMU = packet.decodeIMU() else {
                print("❌Failed to decode IMU packet")
                return
            }
            
    
            // create watch network payload
            let payload = WatchIMUNetworkData(
                timestampNs: adjustedTimestamp,
                sensorType: "watch_imu",
                watchTimestampNs: rawWatchTimestampNs,
                phoneReceivedTimestampNs: phoneReceiveTimestampNs,
                angularVelocity: watchIMU.angularVelocity,
                linearAcceleration: watchIMU.linearAcceleration,
                gravity: watchIMU.gravity
            )

            // Forward to delegate
            delegate?.watchSensorManager(self, didReceiveIMU: payload)
            
            // Update published stats on the main thread
            DispatchQueue.main.async {
                self.watchSampleCount += 1
                self.updateFPS()
            }
            
        case "watch_attitude":
            guard let adjustedTimestamp = adjustTimestamp(packet.timestampNs) else {
                print("Dropping watch attitude before time sync")
                return
            }
            guard let attitude = packet.decodeAttitude() else { return }
            
            // create attitude payload
            let payload = WatchAttitudeNetworkData(
                timestampNs: adjustedTimestamp,
                sensorType: "watch_attitude",
                watchTimestampNs: rawWatchTimestampNs,
                phoneReceivedTimestampNs: phoneReceiveTimestampNs,
                quaternion: attitude.quaternion,
                pitch: attitude.pitch,
                roll: attitude.roll,
                yaw: attitude.yaw,
                referenceFrame: attitude.referenceFrame
            )
            
            // forward to delegate
            delegate?.watchSensorManager(self, didReceiveAttitude: payload)
            
            DispatchQueue.main.async {
                self.latestAttitude = attitude
            }
            
        case "watch_activity":
            guard let activity = packet.decodeMotionActivity() else { return }
            DispatchQueue.main.async {
                self.latestActivity = activity
            }
            
        default:
            break
        }
    }
    
    func watchConnectivity(_ service: WatchConnectivityService, didChangeReachability isReachable: Bool) {
        isWatchConnected = isReachable
        
        if !isReachable {
            isWatchStreaming = false
            watchHz = 0
        }
        
    }
}

// MARK: - Statistics

struct WatchStatistics {
    let isConnected: Bool
    let isStreaming: Bool
    let sampleCount: Int
    let hz: Double
    let messagesSent: Int
    let messagesReceived: Int
    let bytesSent: Int64
    
    var description: String {
        return """
        Watch Connected: \(isConnected)
        Watch Streaming: \(isStreaming)
        Sample Rate: \(String(format: "%.1f Hz", hz))
        Samples: \(sampleCount)
        Messages Sent: \(messagesSent)
        Messages Received: \(messagesReceived)
        Data Sent: \(bytesSent / 1024) KB
        """
    }
}


