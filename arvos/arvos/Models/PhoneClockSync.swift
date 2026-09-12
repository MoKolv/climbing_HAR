//
//  PhoneClockSync.swift
//  arvos
//
//  Created by Moritz Kolvenbach on 11.09.26.
//

import Foundation

struct PhoneClockSyncPingMessage: Encodable {
    let type = "phone_clock_sync_ping"
    let sequenceId: UInt64
    let clientSendNs: UInt64
}

struct PhoneClockSyncResult: Codable {
    let phase: String
    let serverMinusPhoneOffsetNs: Int64
    let phoneAnchorNs: UInt64
    let serverAnchorNs: UInt64
    let minRTTNs: UInt64
    let medianSelectedRTTNs: UInt64
    let offsetSpreadNs: UInt64
    let validSampleCount: Int
    let selectedSampleCount: Int
}

struct PhoneClockSyncResultMessage: Encodable {
    let type = "phone_clock_sync_result"
    let phase: String
    let serverMinusPhoneOffsetNs: Int64
    let phoneAnchorNs: UInt64
    let serverAnchorNs: UInt64
    let minRTTNs: UInt64
    let medianSelectedRTTNs: UInt64
    let offsetSpreadNs: UInt64
    let validSampleCount: Int
    let selectedSampleCount: Int
    
    init(result: PhoneClockSyncResult) {
        phase = result.phase
        serverMinusPhoneOffsetNs = result.serverMinusPhoneOffsetNs
        phoneAnchorNs = result.phoneAnchorNs
        serverAnchorNs = result.serverAnchorNs
        minRTTNs = result.minRTTNs
        medianSelectedRTTNs = result.medianSelectedRTTNs
        offsetSpreadNs = result.offsetSpreadNs
        validSampleCount = result.validSampleCount
        selectedSampleCount = result.selectedSampleCount
    }
}
