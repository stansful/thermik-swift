// IOKitHelpers.swift — Thermik (MIT). OWNER: Unit 2.
// Small, allocation-light IORegistry / sysctl / process helpers shared by the System readers (SYS Appendix A.2).
// Internal on purpose: nothing here is API. Every function is safe to call from any thread.
import Foundation
import IOKit

enum IOKitHelpers {
    /// All properties of a registry entry as a Swift dictionary (bridged copy; fine for plain data).
    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    static func property<T>(_ entry: io_registry_entry_t, _ key: String, as _: T.Type = T.self) -> T? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
    }

    static func className(_ entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)            // io_name_t is 128 bytes
        IOObjectGetClass(entry, &buf)
        return SysctlReader.decodeCString(buf)
    }

    /// Children in `plane`. The caller owns (must IOObjectRelease) each returned entry.
    static func children(_ entry: io_registry_entry_t, plane: String = kIOServicePlane) -> [io_registry_entry_t] {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [io_registry_entry_t] = []
        while case let c = IOIteratorNext(it), c != 0 { out.append(c) }
        return out
    }

    /// Every service matching `className`. The caller owns (must IOObjectRelease) each returned service.
    static func services(matching className: String) -> [io_service_t] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [io_service_t] = []
        while case let s = IOIteratorNext(it), s != 0 { out.append(s) }
        return out
    }

    /// Device-tree properties are CFData holding one or more NUL-separated C strings.
    static func deviceTreeStrings(_ entry: io_registry_entry_t, _ key: String) -> [String] {
        guard let d: Data = property(entry, key) else { return [] }
        return d.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// AppleSmartBattery stores signed quantities (Amperage, CellCurrent, …) as UInt64 two's complement:
    /// 18446744073709551401 is −215 mA. `int64Value` reinterprets the bits, which is exactly the conversion needed.
    static func signedInt(_ any: Any?) -> Int? {
        (any as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
    }
}

enum SysctlReader {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return decodeCString(buf)
    }

    /// NUL-terminated C buffer → String (String(cString:) on arrays is deprecated in Swift 6.x).
    static func decodeCString(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Handles both 4-byte and 8-byte integer sysctls.
    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: var v: Int32 = 0; return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        case 8: var v: Int64 = 0; return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        default: return nil
        }
    }

    static func timeval(_ name: String) -> Date? {
        var tv = Darwin.timeval(); var size = MemoryLayout<Darwin.timeval>.size
        guard sysctlbyname(name, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }
}

/// Runs a system tool (`pmset`, `system_profiler`, `log`) on a utility GCD thread, never on the cooperative pool
/// or the main thread. stdout is drained BEFORE `waitUntilExit` (a full 64 KB pipe would otherwise deadlock).
enum ProcessRunner {
    /// stdout, or nil when the tool cannot be launched, dies from a signal or is terminated by the timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let watchdog = ProcessWatchdog(p)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { watchdog.fire() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let killed = watchdog.finish()
                cont.resume(returning: killed || p.terminationReason != .exit ? nil : data)
            }
        }
    }
}

/// Terminates a tool that outlives its timeout. `@unchecked Sendable`: `done` / `fired` are guarded by `lock`, and the
/// watchdog only calls `isRunning` / `terminate()` on the `Process`, which NSTask allows from any thread.
/// `terminate()` is a no-op once the task has finished (Foundation tracks the reaped child itself), so a late watchdog
/// can never signal a recycled pid.
private final class ProcessWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var done = false, fired = false
    init(_ process: Process) { self.process = process }
    func fire() { lock.withLock { guard !done, process.isRunning else { return }; fired = true; process.terminate() } }
    /// Marks the process as finished; returns true if the watchdog terminated it.
    func finish() -> Bool { lock.withLock { done = true; return fired } }
}
