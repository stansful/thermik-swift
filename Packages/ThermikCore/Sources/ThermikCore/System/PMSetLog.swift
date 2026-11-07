// PMSetLog.swift — Thermik (MIT).
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
        let events = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var parser = ReverseParser(bytes: raw.bindMemory(to: UInt8.self), formatter: dateFormatter(), limit: limit)
            return parser.parse()
        }
        return events.reversed()
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }

    private struct ReverseParser {
        let bytes: UnsafeBufferPointer<UInt8>
        let formatter: DateFormatter
        let limit: Int
        let dateLength = 25                                      // "yyyy-MM-dd HH:mm:ss +ZZZZ"
        var end: Int
        var out: [PowerLogEvent] = []

        init(bytes: UnsafeBufferPointer<UInt8>, formatter: DateFormatter, limit: Int) {
            self.bytes = bytes
            self.formatter = formatter
            self.limit = limit
            end = bytes.count
        }

        mutating func parse() -> [PowerLogEvent] {
            while end > 0, out.count < limit { parseNextLine() }
            return out
        }

        private mutating func parseNextLine() {
            let start = lineStart()
            defer { end = start - 1 }                            // that "\n" ends the line before; −1 stops
            guard isCandidate(start: start) else { return }
            let rest = UnsafeBufferPointer(rebasing: bytes[(start + dateLength + 1)..<end])
            guard let event = event(start: start, rest: rest) else { return }
            out.append(event)
        }

        private func lineStart() -> Int {
            var start = end
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            return start
        }

        /// Cheap pre-filter on the bytes: "2…-…-… …" date prefix, then a kind column.
        private func isCandidate(start: Int) -> Bool {
            let length = end - start
            return length > dateLength + 1 && (0x30...0x39).contains(bytes[start]) && bytes[start + 4] == 0x2D
                && bytes[start + dateLength] == 0x20
        }

        private func event(start: Int, rest: UnsafeBufferPointer<UInt8>) -> PowerLogEvent? {
            let tab = rest.firstIndex(of: 0x09) ?? rest.endIndex
            let kind = String(decoding: UnsafeBufferPointer(rebasing: rest[..<tab]), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard PMSetLog.interestingKinds.contains(kind) else { return nil }
            let dateText = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<(start + dateLength)]), as: UTF8.self)
            guard let date = formatter.date(from: dateText) else { return nil }
            return PowerLogEvent(date: date, kind: kind, message: message(rest: rest, tab: tab))
        }

        private func message(rest: UnsafeBufferPointer<UInt8>, tab: Int) -> String {
            guard tab < rest.endIndex else { return "" }
            return String(decoding: UnsafeBufferPointer(rebasing: rest[(tab + 1)...]), as: UTF8.self)
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
