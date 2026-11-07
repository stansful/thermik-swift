// TopProcesses.swift — Thermik (MIT). CPU process sampling for alert notification bodies.
// libproc: proc_listallpids + proc_pid_rusage(RUSAGE_INFO_V4). CPU % = Δ(ri_user_time + ri_system_time) / Δwall × 100,
// i.e. percent of ONE core (Activity Monitor's convention). Without root only the user's own processes are readable;
// the others fail silently and are skipped. ~2–4 ms for ~700 processes.
import Darwin
import Foundation

/// Stateful (keeps the previous CPU times); not thread-safe: owned by `SystemSampler`.
final class TopProcessSampler {
    private struct Entry { var startAbs: UInt64; var cpuNs: Double }
    private var previous: [pid_t: Entry] = [:]
    private var previousAt: UInt64?                              // uptime ns of the previous snapshot

    /// rusage times are Mach absolute-time units (24 MHz ticks on Apple Silicon, ns on Intel).
    private let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    /// Age of the baseline in seconds (nil = none yet).
    var baselineAge: TimeInterval? {
        previousAt.map { Double(DispatchTime.now().uptimeNanoseconds &- $0) / 1e9 }
    }

    /// Takes a snapshot and returns the busiest processes since the previous snapshot ([] when there is none).
    func sample(limit: Int) -> [ProcessCPU] {
        let now = DispatchTime.now().uptimeNanoseconds
        let current = snapshot()
        defer { previous = current; previousAt = now }
        guard let previousAt, now > previousAt, limit > 0 else { return [] }
        var out = cpuDeltas(current: current, wallNs: Double(now - previousAt))
        out.sort { $0.percent > $1.percent }
        return out.prefix(limit).map { ProcessCPU(pid: $0.pid, name: Self.name($0.pid), cpuPercent: $0.percent) }
    }

    private func cpuDeltas(current: [pid_t: Entry], wallNs: Double) -> [(pid: pid_t, percent: Double)] {
        var out: [(pid: pid_t, percent: Double)] = []
        for (pid, entry) in current {
            // A different start time means the pid was reused: no meaningful delta.
            guard let previous = previous[pid], previous.startAbs == entry.startAbs, entry.cpuNs >= previous.cpuNs else { continue }
            let percent = (entry.cpuNs - previous.cpuNs) / wallNs * 100
            if percent >= 0.1 { out.append((pid, percent)) }
        }
        return out
    }

    func reset() { previous = [:]; previousAt = nil }

    private func snapshot() -> [pid_t: Entry] {
        let pids = processIDs()
        var out: [pid_t: Entry] = [:]
        out.reserveCapacity(pids.count)
        var info = rusage_info_v4()
        for pid in pids {
            guard let entry = entry(pid: pid, info: &info) else { continue }
            out[pid] = entry
        }
        return out
    }

    private func processIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64            // the list can grow between the two calls
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) })
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(count, capacity)).filter { $0 > 0 })
    }

    private func entry(pid: pid_t, info: inout rusage_info_v4) -> Entry? {
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }                            // EPERM for other users' processes
        let ticks = info.ri_user_time &+ info.ri_system_time
        return Entry(startAbs: info.ri_proc_start_abstime, cpuNs: Double(ticks) * nsPerTick)
    }

    /// `proc_name` (≤ 32 bytes, so long helper names are cut); when it looks truncated, the executable's file name
    /// from `proc_pidpath` is used if it extends it ("Google Chrome Helper (Aperitif" → "… (Aperitif)").
    private static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        let short = n > 0 ? SysctlReader.decodeCString(buf).trimmingCharacters(in: .whitespaces) : ""
        if short.utf8.count < 2 * Int(MAXCOMLEN) - 3, !short.isEmpty { return short }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let file = (SysctlReader.decodeCString(path) as NSString).lastPathComponent
            if !file.isEmpty, short.isEmpty || file.hasPrefix(short) { return file }
        }
        return short.isEmpty ? "pid \(pid)" : short
    }
}
