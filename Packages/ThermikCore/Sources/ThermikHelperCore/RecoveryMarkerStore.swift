// RecoveryMarkerStore.swift — Thermik (MIT). HELPER ONLY. OWNER: Unit 4.
// Invariant I7 (SPEC §2.6.2): a per-boot JSON `RecoveryMarker` at /var/run/app.thermik.helper.manual exists while
// the helper holds any fan in manual mode. It is written BEFORE the first manual write and removed only after a
// complete restore, so a helper that crashed or was SIGKILLed restores the fans when launchd relaunches it
// (KeepAlive{SuccessfulExit=false}). /var/run is emptied at boot (verified, HELP §1), so a marker never outlives
// the boot it describes. Without a marker the helper never touches the fans at startup: they may belong to
// another fan-control app. Not thread-safe by itself: HelperService calls it on its state queue only.
import Foundation
import ThermikHelperShared

public struct RecoveryMarkerStore: Sendable {
    public enum Contents: Sendable, Equatable {
        case absent
        case valid(RecoveryMarker)
        /// Something is at the path but it is not a readable marker (truncated write, foreign file, symlink).
        /// Treated as present: restoring fans that are already automatic is harmless.
        case unreadable
    }

    /// nil disables the marker (in-process tools that must not leave files behind).
    public let path: String?

    public init(path: String?) { self.path = path }

    public var exists: Bool {
        guard let path else { return false }
        var st = stat()
        return lstat(path, &st) == 0
    }

    public func read() -> Contents {
        guard let path else { return .absent }
        var st = stat()
        guard lstat(path, &st) == 0 else { return .absent }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_size <= 64 * 1024,
              let data = FileManager.default.contents(atPath: path),
              let marker = try? Self.decoder.decode(RecoveryMarker.self, from: data) else { return .unreadable }
        return .valid(marker)
    }

    /// Atomic replace: a fresh temp file (O_EXCL | O_NOFOLLOW, 0644) in the same directory, fsync, rename(2).
    /// rename replaces a planted symlink instead of following it.
    public func write(_ marker: RecoveryMarker) throws {
        guard let path else { return }
        let data = try Self.encoder.encode(marker)
        let temp = "\(path).\(getpid()).tmp"
        unlink(temp)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Self.posixError("open \(temp)") }
        var ok = data.withUnsafeBytes { buf in Darwin.write(fd, buf.baseAddress, buf.count) == buf.count }
        ok = ok && fchmod(fd, 0o644) == 0 && fsync(fd) == 0
        let closed = close(fd) == 0
        guard ok, closed else {
            let error = Self.posixError("write \(temp)")
            unlink(temp)
            throw error
        }
        guard rename(temp, path) == 0 else {
            let error = Self.posixError("rename \(temp)")
            unlink(temp)
            throw error
        }
    }

    public func remove() {
        guard let path else { return }
        unlink(path)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func posixError(_ what: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(code)))"])
    }
}
