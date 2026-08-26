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

struct WatchTimeSyncResult {
    let phase: String
    
    let offsetNs: Int64
    
    let phoneAnchorNs: UInt64
    let watchAnchorNs: UInt64
    
    let minRTTNs: UInt64
    let medianSelectedRTTNs: UInt64
    let offsetSpreadNs: UInt64
    
    let validSampleCount: Int
    let selectedSampleCount: Int
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
    
    // watch/phone time sync variables
    // time sync struct
    private struct TimeSyncSample{
        let syncId: UInt64
        
        let phoneSendNs: UInt64
        let watchReceiveNs: UInt64
        let watchSendNs: UInt64
        let phoneReceiveNs: UInt64
        
        let rttNs: UInt64
        let estimatedOffsetNs: Int64
        
        var phoneAnchorNs: UInt64 {
            phoneSendNs + (phoneReceiveNs - phoneSendNs) / 2
        }
        
        var watchAnchorNs: UInt64 {
            watchReceiveNs + (watchSendNs - watchReceiveNs) / 2
        }
    }
    
    private var watchToPhoneOffsetNs: Int64?
    private var lastSyncRTTNs: UInt64?
    
    private var syncSequence: UInt64 = 0
    private var pendingTimeSyncId: UInt64?
    private var pendingPhoneSendNs: UInt64?
    private var currentSyncPhase = "unknown"
    
    private let timeSyncQueue = DispatchQueue(label: "watch.timeSync.queue")
    private var syncBurstCompletion: ((WatchTimeSyncResult?) -> Void)?
    
    private var initialSyncCompletion: (() -> Void)? //
    private var syncAttemptsRemaining = 0
    private var syncBurstSamples: [TimeSyncSample] = []
    
    private let syncSpacingSeconds: TimeInterval = 0.25
    private let timeSyncTimeoutSeconds: TimeInterval = 2.0
    private let syncAttemptCount = 15
    private let selectedSyncSampleCount = 5
    
    private var isTrialSyncinProgress = false
    private var pendingStopAfterTrialSync = false


    
    
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
        
        print("Sending start_streaming command to watch")
        
        connectivityService.sendCommand("start_streaming", parameters: ["hz": hz])
        
        isWatchStreaming = true
        watchSampleCount = 0
        sampleTimestamps.removeAll()
        
        print("watch streaming started")
    }
    
    func stopWatchStreaming() {
        guard isWatchStreaming else { return }
        
        
        if isTrialSyncinProgress {
            print("Deferring stop_streaming until trial sync completes")
            pendingStopAfterTrialSync = true
            return
        }
        
        connectivityService.sendCommand("stop_streaming")
        isWatchStreaming = false
        watchHz = 0
    }
    
    func updateWatchFrequency(_ hz: Int) {
        guard isWatchStreaming else { return }

        connectivityService.sendCommand("update_frequency", parameters: ["hz": hz])
    }
    
    // MARK: - Time Synchronization
    
    private func phoneNowNs() -> UInt64 {
        Constants.Time.now()
    }
    
    private func performTimeSync(completion: @escaping () -> Void) {
        
        guard pendingTimeSyncId == nil else {
            print("Skipping time sync because another request is still pending")
            completion()
            return
        }
        
        syncSequence += 1
        
        let syncId = syncSequence
        let phoneSendNs = phoneNowNs()
        
        pendingTimeSyncId = syncId
        pendingPhoneSendNs = phoneSendNs
        
        print("📱 Sending timeSync id=\(syncSequence), phoneSendNs=\(phoneSendNs)")
        
        var finished = false
        let finishOnce: () -> Void = {
            [weak self] in guard !finished else { return }
            finished = true
            self?.pendingTimeSyncId = nil
            self?.pendingPhoneSendNs = nil
            completion()
        }
        
        let sent = connectivityService.sendTimeSync(
            syncId: syncId,
            phoneSendNs: phoneSendNs,
            replyHandler: {[weak self] reply in
                DispatchQueue.main.async {
                    self?.handleTimeSyncReply(reply)
                    finishOnce()
                }
            },
            
            errorHandler: { error in
                DispatchQueue.main.async {
                    print("time_sync error:", error)
                    finishOnce()
                }
            }
        )
        
        guard sent else {
            finishOnce()
            return
        }
        
        timeSyncQueue.asyncAfter(deadline: .now() + timeSyncTimeoutSeconds) {
            [weak self] in DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingTimeSyncId == syncId else { return }
                print("time_sync id \(syncId) timed out)")
                finishOnce()            }
        }
        
    }
    
    
    private func handleTimeSyncReply(_ reply: [String: Any]) {
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
                
        guard watchSendNs >= watchReceiveNs else {
            print("Invalid time sync: watchSendNs < watchReceiveNs")
            return
        }
        
        let phoneElapsedNs = phoneReceiveNs - responsePhoneSendNs
        let watchProcessingNs = watchSendNs - watchReceiveNs
        
        
        
        guard phoneElapsedNs >= watchProcessingNs else {
            print("Invalid time sync: processing time > phone elapsed time")
            return
        }
    
        let networkRTTNs = phoneElapsedNs - watchProcessingNs
        
        // calculate phone-watch offset, assuming roughly symmetrical trip
        let offset1 = Int64(responsePhoneSendNs) - Int64(watchReceiveNs)
        let offset2 = Int64(phoneReceiveNs) - Int64(watchSendNs)
        let estimatedOffset = (offset1 + offset2) / 2
        
        let sample = TimeSyncSample(
            syncId: responseSyncId,
            phoneSendNs: responsePhoneSendNs,
            watchReceiveNs: watchReceiveNs,
            watchSendNs: watchSendNs,
            phoneReceiveNs: phoneReceiveNs,
            rttNs: networkRTTNs,
            estimatedOffsetNs: estimatedOffset
            
        )
        
        syncBurstSamples.append(sample)
    }
    
    
    
    private func runTimeSyncBurst(phase: String, completion: @escaping (WatchTimeSyncResult?) -> Void) {
        guard syncBurstCompletion == nil else {
            print("Sync burst already active")
            completion(nil)
            return
        }
        
        currentSyncPhase = phase
        syncBurstSamples.removeAll()
        syncAttemptsRemaining = syncAttemptCount
        syncBurstCompletion = completion
        performNextTimeSyncAttempt()
    }
    
    private func performNextTimeSyncAttempt() {
        guard syncAttemptsRemaining > 0 else {
            finishTimeSyncBurst()
            return
        }
        
        syncAttemptsRemaining -= 1
        performTimeSync {
            [weak self] in guard let self else { return }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.syncSpacingSeconds) { self.performNextTimeSyncAttempt()}
        }
    }
    
    private func finishTimeSyncBurst() {
        
        let completion = syncBurstCompletion
        syncBurstCompletion = nil
        
        guard syncBurstSamples.count >= selectedSyncSampleCount else {
            print ("Sync Failed: only \(syncBurstSamples.count) valid samples")
            completion?(nil)
            return
        }
        
        let selectedSamples = Array(
            syncBurstSamples
                .sorted { $0.rttNs < $1.rttNs }
                .prefix(selectedSyncSampleCount)
        )
        
        guard let offset = medianOffset(from: selectedSamples),
              let medianRTT = medianRTT(from: selectedSamples),
              let spread = offsetSpread(from: selectedSamples),
              let medianSample = selectedSamples.first(
                where: {$0.estimatedOffsetNs == offset}
              )
        else {
            print("Sync failed while calculating the result")
            completion?(nil)
            return
        }
        
        watchToPhoneOffsetNs = offset
        lastSyncRTTNs = selectedSamples[0].rttNs
        
        let result = WatchTimeSyncResult(
            phase: currentSyncPhase,
            offsetNs: offset,
            phoneAnchorNs: medianSample.phoneAnchorNs,
            watchAnchorNs: medianSample.watchAnchorNs,
            minRTTNs: selectedSamples[0].rttNs,
            medianSelectedRTTNs: medianRTT,
            offsetSpreadNs: spread,
            validSampleCount: syncBurstSamples.count,
            selectedSampleCount: selectedSamples.count
            )
        completion?(result)
    }
    
    private func medianOffset(from samples: [TimeSyncSample]) -> Int64? {
        guard !samples.isEmpty else { return nil }
        
        let offsets = samples
            .map { $0.estimatedOffsetNs }
            .sorted()
        
        return offsets[offsets.count/2]
    }
    
    private func medianRTT (from samples: [TimeSyncSample]) -> UInt64? {
        guard !samples.isEmpty else { return nil }
        
        let values =
            samples
                .map { $0.rttNs }
                .sorted()
        
        return values[values.count/2]
    }
    
    private func offsetSpread(from samples: [TimeSyncSample]) -> UInt64? {
        
        let offsets = samples.map { $0.estimatedOffsetNs }
        
        guard let min = offsets.min(),
              let max = offsets.max()
        else {
            return nil
        }
        return UInt64(max - min)
    }
   
    
    private func adjustTimestamp(_ watchTimestampNs: UInt64) -> UInt64? {
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
    
    func synchronizeForTrial(phase: String, completion: @escaping (WatchTimeSyncResult?) -> Void) {
        guard isWatchConnected else {
            print("watch not connected")
            completion(nil)
            return
        }
        
        guard !isTrialSyncinProgress else {
            print("Trial sync already in progress")
            completion(nil)
            return
        }
        
        isTrialSyncinProgress = true
        pendingStopAfterTrialSync = false
        
        var didFinish = false
        
        let finishSync: (WatchTimeSyncResult?) -> Void = { [weak self] result in
            guard let self, !didFinish else { return }
            
            didFinish = true
            
            self.isTrialSyncinProgress = false
            
            if self.pendingStopAfterTrialSync {
                self.connectivityService.sendCommand("stop_streaming")
                self.isWatchStreaming = false
                self.watchHz = 0
            } else {
                self.connectivityService.sendCommand("resume_sensor_transmission")
            }
        
            self.pendingStopAfterTrialSync = false
            completion(result)
        }
        
        connectivityService.sendCommand("pause_sensor_transmission")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            
            self.runTimeSyncBurst(phase: phase) { result in
                finishSync(result)
            }
            
        }
      
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
            let rawWatchTimestampNs = packet.timestampNs
            let phoneReceiveTimestampNs = phoneNowNs()
            
            guard let adjustedTimestamp = adjustTimestamp(rawWatchTimestampNs) else {
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
                sequenceId: packet.sequenceId,
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
                return
            }
            guard let attitude = packet.decodeAttitude() else { return }
            
            // create attitude payload
            let payload = WatchAttitudeNetworkData(
                timestampNs: adjustedTimestamp,
                sensorType: "watch_attitude",
                sequenceId: packet.sequenceId,
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


