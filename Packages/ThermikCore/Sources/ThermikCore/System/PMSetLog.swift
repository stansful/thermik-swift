// PMSetLog.swift — Thermik (MIT). OWNER: Unit 2.
// Parsed `pmset -g log` events (SYS §7.3): ~36 k lines / 8 MB on this Mac, 1.4–3.4 s → on demand only (Diagnostics),
// never on the main thread. The CLI output is not API: parsing is defensive and skips anything unexpected.
import Foundation

enum PMSetLog {
    /// Event kinds worth showing (the log is dominated by ~35 k "Assertions" lines).
    static let interestingKinds: Set<String> = ["Sleep", "Wake", "DarkWake", "Start", "ThermalEvent", "BatteryHealth",
                                                "Notification", "Shutdown", "Restart", "Failure"]

    /// The newest `limit` interesting events, oldest first. [] when `pmset` fails.
    static func events(limit: Int) async -> [PowerLogEvent] {
        guard limit > 0, let data = await ProcessRunner.run("/usr/bin/pmset", ["-g", "log"], timeout: 20) else { return [] }
        return parse(data, limit: limit)
    }

    /// Line layout: `2026-10-25 05:09:18 +0300 Sleep               \tEntering Sleep state due to …\t330 secs`.
    /// The kind column is space-padded to 20 columns and may itself contain spaces ("Wake Requests", "PM Client Acks").
    /// Scans backwards over the raw bytes and decodes only the lines it keeps, so the cost does not grow with the
    /// ~35 k assertion lines.
    static func parse(_ data: Data, limit: Int) -> [PowerLogEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let dateLength = 25                                      // "yyyy-MM-dd HH:mm:ss +ZZZZ"
        var out: [PowerLogEvent] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var end = bytes.count                                   // exclusive end of the current line
            while end > 0, out.count < limit {
                var start = end
                while start > 0, bytes[start - 1] != 0x0A { start -= 1 }      // just after the previous "\n"
                defer { end = start - 1 }                                     // that "\n" ends the line before; −1 stops
                let length = end - start
                // Cheap pre-filter on the bytes: "2…-…-… …" date prefix, then a kind column.
                guard length > dateLength + 1, (0x30...0x39).contains(bytes[start]), bytes[start + 4] == 0x2D,
                      bytes[start + dateLength] == 0x20 else { continue }
                let rest = UnsafeBufferPointer(rebasing: bytes[(start + dateLength + 1)..<end])
                let tab = rest.firstIndex(of: 0x09) ?? rest.endIndex
                let kind = String(decoding: UnsafeBufferPointer(rebasing: rest[..<tab]), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                guard interestingKinds.contains(kind),
                      let date = formatter.date(from: String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<(start + dateLength)]),
                                                             as: UTF8.self)) else { continue }
                var message = ""
                if tab < rest.endIndex {
                    message = String(decoding: UnsafeBufferPointer(rebasing: rest[(tab + 1)...]), as: UTF8.self)
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                }
                out.append(PowerLogEvent(date: date, kind: kind, message: message))
            }
        }
        return out.reversed()
    }
}
