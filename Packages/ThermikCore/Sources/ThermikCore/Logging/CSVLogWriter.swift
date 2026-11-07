// CSVLogWriter.swift — Thermik (MIT).
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

    /// the last I/O problem (folder not writable, disk full…); nil after a successful write.
    public private(set) var lastError: String?
    /// rows written to disk since this writer was created.
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
        startBufferPeriod(period, firstDate: row.date)
        buffer.append(format(row))
        trimBufferIfNeeded()
        if shouldFlush(now: ContinuousClock.now) { flush() }
    }

    private func startBufferPeriod(_ period: String, firstDate: Date) {
        guard bufferPeriod != period else { return }
        bufferPeriod = period
        bufferFirstDate = firstDate
    }

    private func trimBufferIfNeeded() {
        guard buffer.count > Self.maxBufferedRows else { return }
        buffer.removeFirst(buffer.count - Self.maxBufferedRows)
    }

    /// The very first row is written at once (the file appears immediately); then every 10 s or 64 rows.
    private func shouldFlush(now: ContinuousClock.Instant) -> Bool {
        if lastFlush == nil || buffer.count >= Self.flushRowCount { return true }
        return lastFlush.map({ $0.duration(to: now) >= .seconds(Self.flushInterval) }) == true
    }

    public func flush() {
        lastFlush = ContinuousClock.now
        guard !buffer.isEmpty, let period = bufferPeriod else { return }
        do {
            try writeBufferedData(period: period)
        } catch {
            fail("write failed: \(error.localizedDescription)")
            closeHandle()                              // reopen (and re-check the folder) on the next flush
        }
    }

    private func writeBufferedData(period: String) throws {
        let data = Data(buffer.joined().utf8)
        var target = try writeTarget(period: period, dataCount: data.count)
        try target.handle.write(contentsOf: data)
        target.size += data.count
        file = target
        rowsWritten += buffer.count
        buffer.removeAll(keepingCapacity: true)
        bufferFirstDate = nil
        lastError = nil
    }

    private func writeTarget(period: String, dataCount: Int) throws -> OpenFile {
        var target = try openFile(period: period, firstRow: bufferFirstDate ?? Date())
        if shouldRotate(target: target, dataCount: dataCount) {
            closeHandle()
            target = try createFile(url: uniqueURL(base: "Thermik-" + Self.dateAndTimeStamp(Date())), period: period)
        }
        return target
    }

    /// Never rotate a file that holds only its header.
    private func shouldRotate(target: OpenFile, dataCount: Int) -> Bool {
        guard case .sizeMB(let mb) = config.rotation else { return false }
        return target.size + dataCount > Self.limitBytes(mb) && target.size > headerBytes()
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
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        sweepRetentionIfNeeded()
        if let existing = try openExistingFile(period: period) { return existing }
        return try createFile(url: newFileURL(period: period, firstRow: firstRow), period: period)
    }

    /// Use the newest compatible file of this period. Never truncate or rewrite an existing header.
    private func openExistingFile(period: String) throws -> OpenFile? {
        guard let url = newestCandidate(period: period) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size == 0 { return try createFile(url: url, period: period) }
        guard underLimit(size: size), headerMatches(url) else { return nil }
        return try appendToFile(url: url, size: size, period: period)
    }

    private func underLimit(size: Int) -> Bool {
        guard case .sizeMB(let mb) = config.rotation else { return true }
        return size < Self.limitBytes(mb)
    }

    private func appendToFile(url: URL, size: Int, period: String) throws -> OpenFile {
        let handle = try FileHandle(forWritingTo: url)
        let appended: Int
        do {
            appended = try prepareAppend(handle: handle, url: url, size: size)
        } catch {
            try? handle.close()
            throw error
        }
        return appendedOpenFile(url: url, handle: handle, originalSize: size, appendedSize: appended, period: period)
    }

    /// A crash may have left half a line: start our rows on a fresh line.
    private func prepareAppend(handle: FileHandle, url: URL, size: Int) throws -> Int {
        try handle.seekToEnd()
        guard !Self.endsWithNewline(url, size: size) else { return size }
        try handle.write(contentsOf: Data("\n".utf8))
        return size + 1
    }

    private func appendedOpenFile(url: URL, handle: FileHandle, originalSize: Int, appendedSize: Int, period: String) -> OpenFile {
        writeSidecar(for: url)
        lastURL = url
        log.info("appending to existing log (\(originalSize, privacy: .public) bytes)")
        return OpenFile(url: url, handle: handle, size: appendedSize, period: period)
    }

    private func newFileURL(period: String, firstRow: Date) -> URL {
        switch config.rotation {
        case .sizeMB: return uniqueURL(base: "Thermik-" + Self.dateAndTimeStamp(firstRow))
        case .daily, .weekly, .never:
            let base = baseName(period: period)
            let primary = folderURL.appendingPathComponent(base + ".csv")
            return FileManager.default.fileExists(atPath: primary.path) ? uniqueURL(base: base + "-" + Self.timeStamp(Date())) : primary
        }
    }

    /// Writes the comment + column lines into a new (or empty) file and its sidecar.
    private func createFile(url: URL, period: String) throws -> OpenFile {
        try ensureFileExists(url: url)
        let handle = try FileHandle(forWritingTo: url)
        let head = Data((headerComment() + "\n" + columnLine + "\n").utf8)
        try writeHeader(head, to: handle)
        return createdOpenFile(url: url, handle: handle, head: head, period: period)
    }

    private func ensureFileExists(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private func writeHeader(_ head: Data, to handle: FileHandle) throws {
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: head)
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func createdOpenFile(url: URL, handle: FileHandle, head: Data, period: String) -> OpenFile {
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
        var best: (name: String, modified: Date)?
        for name in candidateNames(period: period) {
            let attributes = try? fm.attributesOfItem(atPath: folderURL.appendingPathComponent(name).path)
            let modified: Date = attributes?[.modificationDate] as? Date ?? .distantPast
            if let b = best, b.modified > modified || (b.modified == modified && b.name > name) { continue }
            best = (name, modified)
        }
        return best.map { folderURL.appendingPathComponent($0.name) }
    }

    private func candidateNames(period: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        switch config.rotation {
        case .sizeMB: return names.filter { Self.matches($0, prefix: "Thermik-", stamp: "dddd-dd-dd-dddddd") }
        case .daily, .weekly, .never:
            let base = baseName(period: period)
            return names.filter { $0 == base + ".csv" || Self.matches($0, prefix: base + "-", stamp: "dddddd") }
        }
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
        return validUniquenessSuffix(middle.dropFirst(pattern.count))
    }

    /// Optional uniqueness suffix "-2", "-3"… after the timestamp.
    private static func validUniquenessSuffix(_ rest: ArraySlice<Character>) -> Bool {
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
        case .daily: return Self.dayStamp(date)
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

    /// "2026-10-26" (local time; POSIX digits).
    static func dayStamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-10-26-153012" (local time; POSIX digits).
    static func dateAndTimeStamp(_ date: Date) -> String { dayStamp(date) + "-" + timeStamp(date) }

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
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        for name in names where Self.isOwnLogName(name) {
            sweepRetainedFile(name: name, cutoff: cutoff)
        }
    }

    private func sweepRetainedFile(name: String, cutoff: Date) {
        let url = folderURL.appendingPathComponent(name)
        guard shouldRemoveRetainedFile(url: url, cutoff: cutoff) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Self.sidecarURL(for: url))
            log.info("retention: removed \(name, privacy: .public)")
        } catch {
            log.error("retention: cannot remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Both the log header and sidecar are the writer's own record; active paths are always excluded.
    private func shouldRemoveRetainedFile(url: URL, cutoff: Date) -> Bool {
        guard url != file?.url, url != lastURL else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes?[.modificationDate] as? Date, modified < cutoff else { return false }
        return Self.hasLogHeader(url) && FileManager.default.fileExists(atPath: Self.sidecarURL(for: url).path)
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
    /// CSVLoggingService and the probe use the same rule.
    public static func decimals(for id: String) -> Int {
        if id.hasSuffix("_rpm") || id.hasSuffix("_target") || id.hasSuffix("_pct") || id == "on_ac" || id == "thermal_pressure" {
            return 0
        }
        return id.hasSuffix("_gb") ? 2 : 1
    }

    /// Locale-independent ("." decimals, no grouping); non-finite → empty cell; never "-0.0".
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

    /// the sidecar path for a log file.
    public static func sidecarURL(for csv: URL) -> URL {
        csv.deletingPathExtension().appendingPathExtension("columns.json")
    }

    private static let columnGroups: [String: String] = [
        "timestamp": "time",
        "cpu_avg": LogColumnGroup.headline.rawValue, "cpu_hottest": LogColumnGroup.headline.rawValue,
        "gpu_avg": LogColumnGroup.headline.rawValue, "gpu_hottest": LogColumnGroup.headline.rawValue,
        "soc": LogColumnGroup.headline.rawValue, "memory": LogColumnGroup.headline.rawValue,
        "ssd": LogColumnGroup.headline.rawValue, "battery": LogColumnGroup.headline.rawValue,
        "fan_mode": LogColumnGroup.fans.rawValue,
        "cpu_usage": LogColumnGroup.usage.rawValue, "gpu_usage": LogColumnGroup.usage.rawValue,
        "mem_used_gb": LogColumnGroup.usage.rawValue, "thermal_pressure": LogColumnGroup.thermal.rawValue,
        "battery_pct": LogColumnGroup.battery.rawValue, "on_ac": LogColumnGroup.battery.rawValue,
        "event": LogColumnGroup.events.rawValue,
    ]

    /// the `LogColumnGroup` (or "time") a column id belongs to, for the sidecar.
    public static func columnGroup(for id: String) -> String {
        if let group = columnGroups[id] { return group }
        if id.contains(":") { return LogColumnGroup.sensors.rawValue }
        if id.hasPrefix("fan") { return LogColumnGroup.fans.rawValue }
        if id.hasSuffix("_w") { return LogColumnGroup.power.rawValue }
        return "other"
    }

    private func writeSidecar(for csv: URL) {
        let columns = sidecarColumns()
        var map: [String: [String: Any]] = [:]
        for (i, c) in columns.enumerated() {
            map[c.0] = ["en": c.1, "ru": c.2, "group": Self.columnGroup(for: c.0), "index": i]
        }
        writeSidecarData(map, for: csv)
    }

    private func sidecarColumns() -> [(String, String, String)] {
        var columns: [(String, String, String)] = [("timestamp", "Time", "Время")]
        columns += header.numericColumns.map { ($0.id, $0.nameEN, $0.nameRU) }
        if header.includesFanMode { columns.append(("fan_mode", "Fan mode", "Режим вентиляторов")) }
        if header.includesEvents { columns.append(("event", "Events", "События")) }
        return columns
    }

    private func writeSidecarData(_ map: [String: [String: Any]], for csv: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        let url = Self.sidecarURL(for: csv)
        if (try? Data(contentsOf: url)) == data { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            fail("sidecar: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        if lastError != message { log.error("\(message, privacy: .public)") }
        lastError = message
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
