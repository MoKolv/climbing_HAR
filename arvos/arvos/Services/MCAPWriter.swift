//
//  MCAPWriter.swift
//  arvos
//
//  Simple MCAP (Modular Container for Arbitrary Protocols) writer
//  Spec: https://mcap.dev/specification
//

import Foundation

class MCAPWriter {
    private let fileHandle: FileHandle
    private let filePath: URL
    private let lock = NSLock()

    private var channels: [UInt16: Channel] = [:]
    private var nextChannelId: UInt16 = 1
    private var messageCount: UInt64 = 0

    struct Channel {
        let id: UInt16
        let topic: String
        let messageEncoding: String
        let schema: String?
    }

    // MARK: - Initialization

    init(filePath: URL) throws {
        self.filePath = filePath

        // Create file
        FileManager.default.createFile(atPath: filePath.path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: filePath.path) else {
            throw MCAPError.cannotCreateFile
        }

        self.fileHandle = handle

        // Write MCAP header
        do {
            try writeHeader()
        } catch {
            try? handle.close()
            throw error
        }
    }

    // MARK: - Header

    private func writeHeader() throws {
        // MCAP magic bytes
        let magic = Data([0x89, 0x4D, 0x43, 0x41, 0x50, 0x30, 0x0D, 0x0A]) // "\x89MCAP0\r\n"
        fileHandle.write(magic)

        // Write Header record
        var headerData = Data()
        headerData.append(string: "arvos") // profile
        headerData.append(string: "arvos-ios-1.0") // library

        try writeRecord(opcode: 0x01, data: headerData)
    }

    // MARK: - Channels

    func addChannel(topic: String, messageEncoding: String = "application/json", schema: String? = nil) -> UInt16 {
        lock.lock()
        defer { lock.unlock() }

        let channelId = nextChannelId
        nextChannelId += 1

        let channel = Channel(
            id: channelId,
            topic: topic,
            messageEncoding: messageEncoding,
            schema: schema
        )

        channels[channelId] = channel

        // Write Channel record
        var channelData = Data()
        channelData.append(uint16: channelId)
        channelData.append(uint16: 0) // schema_id (0 = no schema)
        channelData.append(string: topic)
        channelData.append(string: messageEncoding)
        channelData.append(map: [:]) // metadata

        do {
            try writeRecord(opcode: 0x02, data: channelData)
        } catch {
        }

        return channelId
    }

    // MARK: - Messages

    func writeMessage(channelId: UInt16, timestamp: UInt64, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard channels[channelId] != nil else {
            throw MCAPError.invalidChannel
        }

        var messageData = Data()
        messageData.append(uint16: channelId)
        messageData.append(uint32: 0) // sequence
        messageData.append(uint64: timestamp) // log_time (nanoseconds)
        messageData.append(uint64: timestamp) // publish_time (nanoseconds)
        messageData.append(data)

        try writeRecord(opcode: 0x05, data: messageData)
        messageCount += 1
    }

    // MARK: - Footer

    func finalize() throws {
        // Write Footer record
        var footerData = Data()
        footerData.append(uint64: 0) // summary_start
        footerData.append(uint64: 0) // summary_offset_start
        footerData.append(uint32: 0) // summary_crc

        try writeRecord(opcode: 0x0C, data: footerData)

        // Write magic bytes again at end
        let magic = Data([0x89, 0x4D, 0x43, 0x41, 0x50, 0x30, 0x0D, 0x0A])
        fileHandle.write(magic)

        try fileHandle.synchronize()
        try fileHandle.close()
    }

    // MARK: - Low-level Writing

    private func writeRecord(opcode: UInt8, data: Data) throws {
        // Record format: [opcode (1 byte)][length (8 bytes)][data][crc (4 bytes)]

        var record = Data()
        record.append(opcode)
        record.append(uint64: UInt64(data.count))
        record.append(data)

        // Simple CRC32 (for production, use proper CRC32)
        let crc = calculateCRC32(data)
        record.append(uint32: crc)

        fileHandle.write(record)
    }

    private func calculateCRC32(_ data: Data) -> UInt32 {
        // Simplified CRC32 - in production, use a proper implementation
        var crc: UInt32 = 0xFFFFFFFF

        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1)))
            }
        }

        return ~crc
    }

    // MARK: - Statistics

    func getStatistics() -> RecordingStatistics {
        return RecordingStatistics(
            messageCount: messageCount,
            channelCount: channels.count,
            fileSizeBytes: fileSize()
        )
    }

    private func fileSize() -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
}

// MARK: - Data Extensions

extension Data {
    mutating func append(uint8: UInt8) {
        var value = uint8
        append(Data(bytes: &value, count: 1))
    }

    mutating func append(uint16: UInt16) {
        var value = uint16.littleEndian
        append(Data(bytes: &value, count: 2))
    }

    mutating func append(uint32: UInt32) {
        var value = uint32.littleEndian
        append(Data(bytes: &value, count: 4))
    }

    mutating func append(uint64: UInt64) {
        var value = uint64.littleEndian
        append(Data(bytes: &value, count: 8))
    }

    mutating func append(string: String) {
        let data = string.data(using: .utf8) ?? Data()
        append(uint32: UInt32(data.count))
        append(data)
    }

    mutating func append(map: [String: String]) {
        var mapData = Data()
        mapData.append(uint32: UInt32(map.count))

        for (key, value) in map {
            mapData.append(string: key)
            mapData.append(string: value)
        }

        append(mapData)
    }
}

// MARK: - Statistics

struct RecordingStatistics {
    let messageCount: UInt64
    let channelCount: Int
    let fileSizeBytes: Int64

    var fileSizeMB: Double {
        return Double(fileSizeBytes) / (1024.0 * 1024.0)
    }
}

// MARK: - Errors

enum MCAPError: LocalizedError {
    case cannotCreateFile
    case invalidChannel
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile:
            return "Cannot create MCAP file"
        case .invalidChannel:
            return "Invalid channel ID"
        case .writeFailed:
            return "Failed to write to MCAP file"
        }
    }
}
