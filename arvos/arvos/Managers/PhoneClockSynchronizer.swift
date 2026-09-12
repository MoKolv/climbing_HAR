//
//  PhoneClockSynchronizer.swift
//  arvos
//
//  Created by Moritz Kolvenbach on 11.09.26.
//

import Foundation

final class PhoneClockSynchronizer {
    enum SyncError: LocalizedError {
        case alreadyRunning
        case notEnoughSamples
        case sendFailed(Error)
        
        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Phone clock synchronization is already running"
            case .notEnoughSamples:
                return "Not enough valid samples to synchronize phone clock"
            case .sendFailed(let error):
                return "Failed to send clock-sync request: \(error)"
            }
        }
    }
    
    private struct Sample {
        let clientSendNs: UInt64
        let clientReceiveNs: UInt64
        let serverReceiveNs: UInt64
        let serverSendNs: UInt64
        let networkRTTNs: UInt64
        let offsetNs: Int64
        
        var phoneAnchorNs: UInt64 {
            clientSendNs + (clientReceiveNs - clientSendNs) / 2
        }
    }
    
    private let totalAttempts = 12
    private let selectedCount = 5
    private let requestTimeout: TimeInterval = 1.0
    
    private var phase: String?
    private var attempts = 0
    private var sequenceId: UInt64 = 0
    private var samples: [Sample] = []
    private var pendingSequenceId: UInt64?
    private var pendingClientSendNs: UInt64?
    private var timeoutWorkItem: DispatchWorkItem?
    private var sendPing: ((PhoneClockSyncPingMessage) throws -> Void)?
    private var completion: ((Result<PhoneClockSyncResult, Error>) -> Void)?
    
    private(set) var results: [String: PhoneClockSyncResult] = [:]
    
    func synchronize(
        phase: String,
        send: @escaping (PhoneClockSyncPingMessage) throws -> Void,
        completion: @escaping (Result<PhoneClockSyncResult, Error>) -> Void
    ) {
        guard self.phase == nil else {
            completion(.failure(SyncError.alreadyRunning))
            return
        }
        
        self.phase = phase
        attempts = 0
        samples.removeAll()
        self.sendPing = send
        self.completion = completion
        requestNextSample()
    }
    
    func handleResponse(
        _ json: [String: Any],
        clientReceiveNs: UInt64,
    ) {
        guard
            let sequence = uint64(json["sequenceId"]),
            sequence == pendingSequenceId,
            let clientSendNs = uint64(json["clientSendNs"]),
            clientSendNs == pendingClientSendNs,
            let serverReceiveNs = uint64(json["serverReceiveNs"]),
            let serverSendNs = uint64(json["serverSendNs"]),
            clientReceiveNs >= clientSendNs,
            serverSendNs >= serverReceiveNs
        else {
            return
        }
        
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        pendingSequenceId = nil
        pendingClientSendNs = nil
        
        let clientElapsed = clientReceiveNs - clientSendNs
        let serverProcessing = serverSendNs - serverReceiveNs
        
        guard clientElapsed >= serverProcessing else {
            scheduleNextSample()
            return
        }
        
        let offset1 = Int64(serverReceiveNs) - Int64(clientSendNs)
        let offset2 = Int64(serverSendNs) - Int64(clientReceiveNs)
        
        samples.append(
            Sample(
                clientSendNs: clientSendNs,
                clientReceiveNs: clientReceiveNs,
                serverReceiveNs: serverReceiveNs,
                serverSendNs: serverSendNs,
                networkRTTNs: clientElapsed - serverProcessing,
                offsetNs: (offset1 + offset2) / 2
            )
        )
        
        scheduleNextSample()
    }
    
    func result(for phase: String) -> PhoneClockSyncResult? {
        results[phase]
    }
    
    func phoneTime(forServerTime serverNs: UInt64, phase: String) -> UInt64? {
        guard let result = results[phase] else { return nil }
        
        let local = Int64(serverNs) - result.serverMinusPhoneOffsetNs
        return local > 0 ? UInt64(local) : nil
    }
    
    private func requestNextSample() {
        guard attempts < totalAttempts else {
            finish()
            return
        }
        
        attempts += 1
        sequenceId &+= 1
        
        let clientSendNs = Constants.Time.now()
        pendingSequenceId = sequenceId
        pendingClientSendNs = clientSendNs
        
        do {
            try sendPing?(
                PhoneClockSyncPingMessage(sequenceId: sequenceId, clientSendNs: clientSendNs)
            )
        } catch {
            complete(.failure(SyncError.sendFailed(error)))
            return
        }
        
        let expectedSequence = sequenceId
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSequenceId == expectedSequence else { return }
            
            self.pendingSequenceId = nil
            self.pendingClientSendNs = nil
            self.scheduleNextSample()
        }
        
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
    }
    
    private func scheduleNextSample() {
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.04) {
            self.requestNextSample()
        }
    }
    
    private func finish() {
        guard
            let phase,
            samples.count >= selectedCount
        else {
            complete(.failure(SyncError.notEnoughSamples))
            return
        }
        
        let selected = Array(
            samples.sorted {$0.networkRTTNs < $1.networkRTTNs}
                .prefix(selectedCount)
        )
        let offsets = selected.map(\.offsetNs).sorted()
        let medianOffset = offsets[offsets.count / 2]
        let rtts = selected.map(\.networkRTTNs).sorted()
        let anchorSample = selected.min {
            abs($0.offsetNs - medianOffset) < abs($1.offsetNs - medianOffset)
        }!
        let phoneAnchorNs = anchorSample.phoneAnchorNs
        let serverAnchor = Int64(phoneAnchorNs) + medianOffset
        let spread = UInt64(offsets.last! - offsets.first!)
        
        guard serverAnchor > 0 else {
            complete(.failure(SyncError.notEnoughSamples))
            return
        }
        
        let result = PhoneClockSyncResult(
            phase: phase,
            serverMinusPhoneOffsetNs: medianOffset,
            phoneAnchorNs: phoneAnchorNs,
            serverAnchorNs: UInt64(serverAnchor),
            minRTTNs: selected.map(\.networkRTTNs).min()!,
            medianSelectedRTTNs: rtts[rtts.count / 2],
            offsetSpreadNs: spread,
            validSampleCount: samples.count,
            selectedSampleCount: selected.count,
            )
        results[phase] = result
        complete(.success(result))
    }
    
    private func complete(_ result: Result<PhoneClockSyncResult, Error>) {
        timeoutWorkItem?.cancel()
        let callback = completion
        
        phase = nil
        attempts = 0
        samples.removeAll()
        pendingSequenceId = nil
        pendingClientSendNs = nil
        sendPing = nil
        completion = nil
        timeoutWorkItem = nil
        
        callback?(result)
    }
    
    private func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        
        if let string = value as? String {
            return UInt64(string)
        }
        
        return nil
    }
}
