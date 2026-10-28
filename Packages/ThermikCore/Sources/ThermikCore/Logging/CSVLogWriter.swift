// CSVLogWriter.swift — Thermik (MIT). OWNER: Unit 6. API FROZEN (init / update / append / flush / close /
// currentFileURL); additions are marked. SPEC §2.12.
//
// Buffered (flush every 10 s, at 64 rows, on rotation and on close), rotating, NON-DESTRUCTIVE:
//   • daily  → Thermik-YYYY-MM-DD.csv          • weekly → Thermik-YYYY-Www.csv (ISO week)
//   • sizeMB → Thermik-YYYY-MM-DD-HHMMSS.csv, a new file once the current one would pass N MB
//   • never  → Thermik.csv
// An existing file is APPENDED to (restarting the app never truncates anything). If its column line differs from
// the current columns (sensors added, groups changed), a new file `<name>-HHMMSS.csv` is started instead, so a file
// never mixes two layouts. Files are deleted only when the user set `retentionDays`, and only logs this writer made:
// a name of the patterns above (or their `-HHMMSS` / `-N` variants), a first line `# Thermik log v1` AND the
// `.columns.json` sidecar written with it (deleted too); never the file being written, never an export such as
// `Thermik-history-….csv`. A log file deleted or moved away while open (Finder's Move to Trash) is noticed on the next
// flush: the writer starts a new file at the path instead of writing into the moved one.
//
// Format: a `# Thermik log v1; …` comment line, the column line, then one row per append. Timestamps are ISO 8601
// with the local offset, numbers use "." whatever the locale (String(format:) is POSIX), an empty cell means no
// value, and events are `;`-joined machine tokens in their own column (never prefixes inside value cells).
// Cells containing a comma, quote or newline are quoted (RFC 4180).
import Foundation
import os

public actor CSVLogWriter {
    public static let flushInterval: TimeInterval = 10
    public static let flushRowCount = 64
    /// Rows kept while the folder is unwritable (≈ 2 h at the 2 s default cadence); the oldest are dropped first.
    public static let maxBufferedRows = 4_096
    static let headerPrefix = "# Thermik log v1"

    private struct OpenFile {
        let url: URL
        let handle: FileHandle
        var size: Int
        let period: String
    }

    private var config: LogConfig
    private var header: CSVLogHeader
    private var columnLine: String
    private var buffer: [String] = []
    private var bufferPeriod: String?
    private var bufferFirstDate: Date?
    private var file: OpenFile?
    private var lastURL: URL?
    private var lastFlush: ContinuousClock.Instant?
    private var lastRetentionSweep: Date?
    private let timestamps = ISO8601DateFormatter()
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "logging")

    /// ADDED (Unit 6): the last I/O problem (folder not writable, disk full…); nil after a successful write.
    public private(set) var lastError: String?
    /// ADDED (Unit 6): rows written to disk since this writer was created.
    public private(set) var rowsWritten = 0

    public init(config: LogConfig, header: CSVLogHeader) {
        self.config = config
        self.header = header
        self.columnLine = Self.columnLine(header)
        timestamps.formatOptions = [.withInternetDateTime]
    }

    public func update(config newConfig: LogConfig, header newHeader: CSVLogHeader) {
        let newLine = Self.columnLine(newHeader)
        let reopen = newConfig.folderPath != config.folderPath || newConfig.rotation != config.rotation
            || newLine != columnLine || !newConfig.enabled
        if reopen { close() }                         // buffered rows go to the file of the OLD layout first
        if newConfig.retentionDays != config.retentionDays || newConfig.folderPath != config.folderPath {
            lastRetentionSweep = nil
        }
        config = newConfig
        header = newHeader
        columnLine = newLine
    }

    public func append(_ row: CSVLogRow) {
        guard config.enabled else { return }
        let period = periodKey(for: row.date)
        if let p = bufferPeriod, p != period { flush() }          // day / week boundary: rotate with the old rows
        if bufferPeriod != period { bufferPeriod = period; bufferFirstDate = row.date }
        buffer.append(format(row))
        if buffer.count > Self.maxBufferedRows { buffer.removeFirst(buffer.count - Self.maxBufferedRows) }
        let now = ContinuousClock.now
        // The very first row is written at once (the file appears immediately); then every 10 s or 64 rows.
        if lastFlush == nil || buffer.count >= Self.flushRowCount
            || lastFlush.map({ $0.duration(to: now) >= .seconds(Self.flushInterval) }) == true {
            flush()
        }
    }

    public func flush() {
        lastFlush = ContinuousClock.now
        guard !buffer.isEmpty, let period = bufferPeriod else { return }
        do {
            let data = Data(buffer.joined().utf8)
            var target = try openFile(period: period, firstRow: bufferFirstDate ?? Date())
            if case .sizeMB(let mb) = config.rotation, target.size + data.count > Self.limitBytes(mb),
               target.size > headerBytes() {                       // never rotate a file that holds only its header
                closeHandle()
                target = try createFile(url: uniqueURL(base: "Thermik-" + Self.stamp(Date(), dateAndTime: true)), period: period)
            }
            try target.handle.write(contentsOf: data)
            target.size += data.count
            file = target
            rowsWritten += buffer.count
            buffer.removeAll(keepingCapacity: true)
            bufferFirstDate = nil
            lastError = nil
        } catch {
            fail("write failed: \(error.localizedDescription)")
            closeHandle()                              // reopen (and re-check the folder) on the next flush
        }
    }

    public func close() {
        flush()
        closeHandle()
        if buffer.isEmpty { bufferPeriod = nil }      // keep the period of rows that could not be written yet
    }

    public var currentFileURL: URL? { file?.url ?? lastURL }

    // MARK: Files

    private var folderURL: URL {
        URL(fileURLWithPath: (config.folderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func limitBytes(_ mb: Int) -> Int { max(mb, 1) * 1_048_576 }

    private func headerBytes() -> Int { (headerComment() + "\n" + columnLine + "\n").utf8.count }

    private func openFile(period: String, firstRow: Date) throws -> OpenFile {
        if let f = file, f.period == period {
            if Self.isStillAtPath(f) { return f }
            log.notice("log file \(f.url.lastPathComponent, privacy: .public) was moved or deleted; starting a new one")
        }
        closeHandle()
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        sweepRetentionIfNeeded()
        // Newest compatible file of this period, else a new one. Never truncate, never rewrite an existing header.
        if let url = newestCandidate(period: period) {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let underLimit: Bool
            if case .sizeMB(let mb) = config.rotation { underLimit = size < Self.limitBytes(mb) } else { underLimit = true }
            if size == 0 {
                return try createFile(url: url, period: period)
            } else if underLimit, headerMatches(url) {
                let handle = try FileHandle(forWritingTo: url)
                var appended = size
                do {
                    try handle.seekToEnd()
                    // A crash may have left half a line: start our rows on a fresh line.
                    if !Self.endsWithNewline(url, size: size) {
                        try handle.write(contentsOf: Data("\n".utf8))
                        appended += 1
                    }
                } catch {
                    try? handle.close()
                    throw error
                }
                writeSidecar(for: url)
                lastURL = url
                log.info("appending to existing log (\(size, privacy: .public) bytes)")
                return OpenFile(url: url, handle: handle, size: appended, period: period)
            }
        }
        let url: URL
        switch config.rotation {
        case .sizeMB:
            url = uniqueURL(base: "Thermik-" + Self.stamp(firstRow, dateAndTime: true))
        case .daily, .weekly, .never:
            let base = baseName(period: period)
            let primary = folderURL.appendingPathComponent(base + ".csv")
            url = fm.fileExists(atPath: primary.path) ? uniqueURL(base: base + "-" + Self.timeStamp(Date())) : primary
        }
        return try createFile(url: url, period: period)
    }

    /// Writes the comment + column lines into a new (or empty) file and its sidecar.
    private func createFile(url: URL, period: String) throws -> OpenFile {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        let head = Data((headerComment() + "\n" + columnLine + "\n").utf8)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: head)
        } catch {
            try? handle.close()
            throw error
        }
        writeSidecar(for: url)
        lastURL = url
        log.info("started log file \(url.lastPathComponent, privacy: .public)")
        return OpenFile(url: url, handle: handle, size: head.count, period: period)
    }

    private func closeHandle() {
        if let f = file {
            try? f.handle.synchronize()
            try? f.handle.close()
            lastURL = f.url
        }
        file = nil
    }

    /// True while the open handle's file is still the one at its path (same device and inode, not unlinked). A
    /// rename (Move to Trash) or a delete leaves the handle valid, so writes would silently land outside the folder.
    private static func isStillAtPath(_ f: OpenFile) -> Bool {
        var held = stat(), atPath = stat()
        guard fstat(f.handle.fileDescriptor, &held) == 0 else { return false }
        guard held.st_nlink > 0, stat(f.url.path, &atPath) == 0 else { return false }
        return held.st_dev == atPath.st_dev && held.st_ino == atPath.st_ino
    }

    /// The most recently modified file of `period` this writer may append to (its own naming patterns only).
    private func newestCandidate(period: String) -> URL? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let matching: [String]
        switch config.rotation {
        case .sizeMB:
            matching = names.filter { Self.matches($0, prefix: "Thermik-", stamp: "dddd-dd-dd-dddddd") }
        case .daily, .weekly, .never:
            let base = baseName(period: period)
            matching = names.filter { $0 == base + ".csv" || Self.matches($0, prefix: base + "-", stamp: "dddddd") }
        }
        var best: (name: String, modified: Date)?
        for name in matching {
            let attributes = try? fm.attributesOfItem(atPath: folderURL.appendingPathComponent(name).path)
            let modified: Date = attributes?[.modificationDate] as? Date ?? .distantPast
            if let b = best, b.modified > modified || (b.modified == modified && b.name > name) { continue }
            best = (name, modified)
        }
        return best.map { folderURL.appendingPathComponent($0.name) }
    }

    /// `<prefix><stamp>[-N].csv`, where `stamp` uses "d" for one digit and any other character literally.
    static func matches(_ name: String, prefix: String, stamp: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(".csv") else { return false }
        let middle: [Character] = Array(name.dropFirst(prefix.count).dropLast(4))
        let pattern: [Character] = Array(stamp)
        guard middle.count >= pattern.count else { return false }
        for i in pattern.indices {
            let ok: Bool = pattern[i] == "d" ? middle[i].isASCIIDigit : middle[i] == pattern[i]
            if !ok { return false }
        }
        let rest: ArraySlice<Character> = middle.dropFirst(pattern.count)   // optional uniqueness suffix "-2", "-3"…
        if rest.isEmpty { return true }
        guard rest.first == "-", rest.count > 1 else { return false }
        return rest.dropFirst().allSatisfy { $0.isASCIIDigit }
    }

    private func uniqueURL(base: String) -> URL {
        var url = folderURL.appendingPathComponent(base + ".csv")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folderURL.appendingPathComponent("\(base)-\(n).csv"); n += 1
        }
        return url
    }

    private func headerMatches(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let chunk = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        let lines = String(decoding: chunk, as: UTF8.self).split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[0].hasPrefix(Self.headerPrefix) else { return false }
        return lines[1].trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == columnLine
    }

    private static func endsWithNewline(_ url: URL, size: Int) -> Bool {
        guard size > 0, let h = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(size - 1))) != nil, let last = try? h.read(upToCount: 1) else { return true }
        return last.first == UInt8(ascii: "\n")
    }

    // MARK: Names

    private func periodKey(for date: Date) -> String {
        switch config.rotation {
        case .daily: return Self.stamp(date, dateAndTime: false)
        case .weekly:
            var cal = Calendar(identifier: .iso8601)
            cal.timeZone = .current
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        case .sizeMB: return "size"
        case .never: return "never"
        }
    }

    private func baseName(period: String) -> String {
        switch config.rotation {
        case .daily, .weekly: return "Thermik-" + period
        case .sizeMB, .never: return "Thermik"
        }
    }

    /// "2026-10-26" or "2026-10-26-153012" (local time; POSIX digits).
    static func stamp(_ date: Date, dateAndTime: Bool) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return dateAndTime ? day + "-" + timeStamp(date) : day
    }

    /// "153012" (local time).
    static func timeStamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // MARK: Retention (only when the user set retentionDays)

    /// Names this writer produces for any rotation, except `Thermik.csv` itself: daily `Thermik-YYYY-MM-DD`, weekly
    /// `Thermik-YYYY-Www`, size `Thermik-YYYY-MM-DD-HHMMSS`, and the `-HHMMSS` (new layout) / `-N` (unique) variants.
    /// `Thermik-history-2026-10-26.csv` (the History export) or any other user file never matches.
    static func isOwnLogName(_ name: String) -> Bool {
        ["dddd-dd-dd", "dddd-dd-dd-dddddd", "dddd-Wdd", "dddd-Wdd-dddddd", "dddddd"]
            .contains { matches(name, prefix: "Thermik-", stamp: $0) }
    }

    /// The file starts with the comment line this writer puts first (an export or any other CSV does not).
    private static func hasLogHeader(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let prefix = Data(headerPrefix.utf8)
        return (try? h.read(upToCount: prefix.count)) == prefix
    }

    private func sweepRetentionIfNeeded() {
        guard let days = config.retentionDays, days > 0 else { return }
        let now = Date()
        if let last = lastRetentionSweep, now.timeIntervalSince(last) < 6 * 3600 { return }
        lastRetentionSweep = now
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let names = (try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []
        for name in names where Self.isOwnLogName(name) {
            let url = folderURL.appendingPathComponent(name)
            guard url != file?.url, url != lastURL,
                  let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff, Self.hasLogHeader(url),
                  fm.fileExists(atPath: Self.sidecarURL(for: url).path) else { continue }   // the writer's own record
            do {
                try fm.removeItem(at: url)
                try? fm.removeItem(at: Self.sidecarURL(for: url))
                log.info("retention: removed \(name, privacy: .public)")
            } catch {
                log.error("retention: cannot remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Formatting

    private func headerComment() -> String {
        let iv = header.intervalSeconds
        let interval = iv <= 0 ? "tick" : (iv == iv.rounded() ? String(format: "%.0fs", iv) : String(format: "%.1fs", iv))
        return "\(Self.headerPrefix); model=\(header.modelIdentifier); chip=\(header.chip); macOS=\(header.osVersion); "
            + "app=\(header.appVersion); unit=C; interval=\(interval)"
    }

    static func columnLine(_ h: CSVLogHeader) -> String {
        var ids = ["timestamp"] + h.numericColumns.map(\.id)
        if h.includesFanMode { ids.append("fan_mode") }
        if h.includesEvents { ids.append("event") }
        return ids.map(escape).joined(separator: ",")
    }

    private func format(_ row: CSVLogRow) -> String {
        timestamps.timeZone = .current                // follows time-zone changes (travel) row by row
        var cells: [String] = [timestamps.string(from: row.date)]
        cells.reserveCapacity(header.numericColumns.count + 3)
        for (i, column) in header.numericColumns.enumerated() {
            let v = i < row.numbers.count ? row.numbers[i] : nil
            cells.append(v.map { Self.number($0, decimals: Self.decimals(for: column.id)) } ?? "")
        }
        if header.includesFanMode { cells.append(row.fanMode ?? "") }
        if header.includesEvents { cells.append(row.events.joined(separator: ";")) }
        return cells.map(Self.escape).joined(separator: ",") + "\n"
    }

    /// Integers for rpm / percentages / flags, 2 decimals for GB, 1 decimal for temperatures, watts and usage.
    /// ADDED (Unit 6, public): CSVLoggingService and the probe use the same rule.
    public static func decimals(for id: String) -> Int {
        if id.hasSuffix("_rpm") || id.hasSuffix("_target") || id.hasSuffix("_pct") || id == "on_ac" || id == "thermal_pressure" {
            return 0
        }
        return id.hasSuffix("_gb") ? 2 : 1
    }

    /// Locale-independent ("." decimals, no grouping); non-finite → empty cell; never "-0.0".
    /// ADDED (Unit 6, public).
    public static func number(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "" }
        let scale = pow(10, Double(max(decimals, 0)))
        let rounded = (v * scale).rounded() / scale
        return String(format: "%.\(max(decimals, 0))f", rounded == 0 ? 0 : rounded)   // `== 0` folds -0.0 into 0
    }

    static func escape(_ cell: String) -> String {
        guard cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Sidecar  (Thermik-YYYY-MM-DD.columns.json: id → {en, ru, group, index})

    /// ADDED (Unit 6): the sidecar path for a log file.
    public static func sidecarURL(for csv: URL) -> URL {
        csv.deletingPathExtension().appendingPathExtension("columns.json")
    }

    /// ADDED (Unit 6): the `LogColumnGroup` (or "time") a column id belongs to, for the sidecar.
    public static func columnGroup(for id: String) -> String {
        switch id {
        case "timestamp": return "time"
        case "cpu_avg", "cpu_hottest", "gpu_avg", "gpu_hottest", "soc", "memory", "ssd", "battery":
            return LogColumnGroup.headline.rawValue
        case "fan_mode": return LogColumnGroup.fans.rawValue
        case "cpu_usage", "gpu_usage", "mem_used_gb": return LogColumnGroup.usage.rawValue
        case "thermal_pressure": return LogColumnGroup.thermal.rawValue
        case "battery_pct", "on_ac": return LogColumnGroup.battery.rawValue
        case "event": return LogColumnGroup.events.rawValue
        default:
            if id.contains(":") { return LogColumnGroup.sensors.rawValue }
            if id.hasPrefix("fan") { return LogColumnGroup.fans.rawValue }
            if id.hasSuffix("_w") { return LogColumnGroup.power.rawValue }
            return "other"
        }
    }

    private func writeSidecar(for csv: URL) {
        var columns: [(String, String, String)] = [("timestamp", "Time", "Время")]
        columns += header.numericColumns.map { ($0.id, $0.nameEN, $0.nameRU) }
        if header.includesFanMode { columns.append(("fan_mode", "Fan mode", "Режим вентиляторов")) }
        if header.includesEvents { columns.append(("event", "Events", "События")) }
        var map: [String: [String: Any]] = [:]
        for (i, c) in columns.enumerated() {
            map[c.0] = ["en": c.1, "ru": c.2, "group": Self.columnGroup(for: c.0), "index": i]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        let url = Self.sidecarURL(for: csv)
        if (try? Data(contentsOf: url)) == data { return }
        do { try data.write(to: url, options: .atomic) } catch { fail("sidecar: \(error.localizedDescription)") }
    }

    private func fail(_ message: String) {
        if lastError != message { log.error("\(message, privacy: .public)") }
        lastError = message
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
