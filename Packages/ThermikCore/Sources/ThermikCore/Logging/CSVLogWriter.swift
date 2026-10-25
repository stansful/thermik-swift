// CSVLogWriter.swift — Thermik (MIT). OWNER: Unit 6. STUB from Unit 0; API FROZEN.
// Buffered (flush every 10 s or 64 rows), rotating, never deletes unless retentionDays is set by the user.
import Foundation

public actor CSVLogWriter {
    public init(config: LogConfig, header: CSVLogHeader) {}
    public func update(config: LogConfig, header: CSVLogHeader) {}
    public func append(_ row: CSVLogRow) {}
    public func flush() {}
    public func close() {}
    public var currentFileURL: URL? { nil }
}
