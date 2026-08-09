//
//  TimestampManager.swift
//  arvos
//
//  Manages timestamp synchronization and clock offset
//

import Foundation

class TimestampManager {
    static let shared = TimestampManager()

    private var clockOffset: Int64 = 0 // Offset from system time to server time in nanoseconds
    private var bootTimeOffset: UInt64 = 0 // Offset to convert from boot time to Unix time

    private init() {
        calculateBootTimeOffset()
    }

    // MARK: - Boot Time Offset

    /// Calculate offset between boot time and Unix epoch
    private func calculateBootTimeOffset() {
        let systemTime = Date().timeIntervalSince1970
        let bootTime = ProcessInfo.processInfo.systemUptime

        let unixNanos = UInt64(systemTime * Double(Constants.Time.nanosPerSecond))
        let bootNanos = UInt64(bootTime * Double(Constants.Time.nanosPerSecond))

        bootTimeOffset = unixNanos - bootNanos
    }

    // MARK: - Timestamp Generation

    /// Get current timestamp in nanoseconds since boot (monotonic)
    func now() -> UInt64 {
        return Constants.Time.now()
    }

    /// Get current timestamp in nanoseconds since Unix epoch
    func systemTime() -> UInt64 {
        return Constants.Time.systemTime()
    }

    /// Convert boot time to Unix time
    func bootTimeToUnixTime(_ bootTime: UInt64) -> UInt64 {
        return bootTime + bootTimeOffset
    }

    /// Convert Unix time to boot time
    func unixTimeToBootTime(_ unixTime: UInt64) -> UInt64 {
        return unixTime - bootTimeOffset
    }

    // MARK: - Clock Synchronization

    /// Set clock offset from server (for NTP-style sync)
    func setClockOffset(_ offset: Int64) {
        clockOffset = offset
    }

    /// Get adjusted timestamp with clock offset applied
    func adjustedTimestamp(_ localTimestamp: UInt64) -> UInt64 {
        let signed = Int64(localTimestamp)
        let adjusted = signed + clockOffset
        return UInt64(max(0, adjusted))
    }

    /// Perform simple NTP-style clock sync with server
    func syncWithServer(serverUrl: URL, completion: @escaping (Result<Int64, Error>) -> Void) {
        let t1 = now() // Client send time

        var request = URLRequest(url: serverUrl)
        request.httpMethod = "GET"
        request.addValue("arvos-time-sync", forHTTPHeaderField: "X-Sync-Request")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            let t4 = self.now() // Client receive time

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t2Str = json["server_receive_time"] as? String,
                  let t3Str = json["server_send_time"] as? String,
                  let t2 = UInt64(t2Str),
                  let t3 = UInt64(t3Str) else {
                completion(.failure(TimestampError.invalidResponse))
                return
            }

            // Calculate offset: offset = ((t2 - t1) + (t3 - t4)) / 2
            let offset1 = Int64(t2) - Int64(t1)
            let offset2 = Int64(t3) - Int64(t4)
            let offset = (offset1 + offset2) / 2

            self.setClockOffset(offset)
            completion(.success(offset))
        }

        task.resume()
    }

    // MARK: - Timestamp Formatting

    /// Format timestamp as ISO 8601 string
    func formatTimestamp(_ timestamp: UInt64) -> String {
        let seconds = Double(timestamp) / Double(Constants.Time.nanosPerSecond)
        let date = Date(timeIntervalSince1970: seconds)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Parse ISO 8601 string to timestamp
    func parseTimestamp(_ string: String) -> UInt64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let date = formatter.date(from: string) else { return nil }

        let seconds = date.timeIntervalSince1970
        return UInt64(seconds * Double(Constants.Time.nanosPerSecond))
    }

    // MARK: - Statistics

    /// Get current clock offset
    func getClockOffset() -> Int64 {
        return clockOffset
    }

    /// Get boot time offset
    func getBootTimeOffset() -> UInt64 {
        return bootTimeOffset
    }

    /// Get detailed timing info
    func getTimingInfo() -> TimingInfo {
        return TimingInfo(
            bootTime: now(),
            systemTime: systemTime(),
            clockOffset: clockOffset,
            bootTimeOffset: bootTimeOffset
        )
    }
}

// MARK: - Timing Info

struct TimingInfo: Codable {
    let bootTime: UInt64
    let systemTime: UInt64
    let clockOffset: Int64
    let bootTimeOffset: UInt64

    var description: String {
        return """
        Boot Time: \(bootTime) ns
        System Time: \(systemTime) ns
        Clock Offset: \(clockOffset) ns (\(Double(clockOffset) / 1_000_000.0) ms)
        Boot Offset: \(bootTimeOffset) ns
        """
    }
}

// MARK: - Errors

enum TimestampError: LocalizedError {
    case invalidResponse
    case syncFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid time sync response from server"
        case .syncFailed:
            return "Failed to synchronize clock with server"
        }
    }
}
