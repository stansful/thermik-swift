// SystemLoad.swift — Thermik (MIT). OWNER: Unit 2.
// Per-core CPU load, Activity Monitor-compatible memory figures and GPU utilization (SYS §3). Public Mach / IORegistry
// APIs only: no root, no SMC, sandbox-safe. Verified on M4 Max / macOS 27.0.1.
import Darwin
import Foundation
import IOKit

// MARK: CPU load per logical core

/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, ~0.02–0.2 ms. Usage is the delta between two calls.
/// Stateful and not thread-safe: owned by `SystemSampler`.
final class CPULoadSampler {
    /// Previous tick counters, flattened: `CPU_STATE_MAX` (user, system, idle, nice) per logical CPU.
    private var previous: [UInt32] = []

    /// Per-logical-CPU load since the previous call; empty on the first call (or after `reset()`).
    /// Index = logical CPU id. On Apple Silicon ids 0..<E are the Efficiency cores (`MachineInfo.cpuTopology`).
    func sample() -> [CoreLoad] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        // The kernel allocates the array in our address space: it must always be returned.
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }

        let states = Int(CPU_STATE_MAX)
        let n = Int(cpuCount)
        var now = [UInt32](repeating: 0, count: n * states)
        for i in 0..<(n * states) { now[i] = UInt32(bitPattern: info[i]) }
        defer { previous = now }
        guard previous.count == now.count else { return [] }

        var out: [CoreLoad] = []
        out.reserveCapacity(n)
        for cpu in 0..<n {
            let b = cpu * states
            // Wrapping subtraction: the tick counters are 32-bit and wrap around.
            let user = Double(now[b + Int(CPU_STATE_USER)] &- previous[b + Int(CPU_STATE_USER)])
            let system = Double(now[b + Int(CPU_STATE_SYSTEM)] &- previous[b + Int(CPU_STATE_SYSTEM)])
            let idle = Double(now[b + Int(CPU_STATE_IDLE)] &- previous[b + Int(CPU_STATE_IDLE)])
            let nice = Double(now[b + Int(CPU_STATE_NICE)] &- previous[b + Int(CPU_STATE_NICE)])
            let total = user + system + idle + nice
            guard total > 0 else { out.append(CoreLoad(user: 0, system: 0, nice: 0, idle: 1)); continue }
            out.append(CoreLoad(user: user / total, system: system / total, nice: nice / total, idle: idle / total))
        }
        return out
    }

    /// Drops the baseline (after wake the first delta would span the whole sleep).
    func reset() { previous = [] }
}

// MARK: Memory

/// `host_statistics64(HOST_VM_INFO64)` + 4 sysctls, ~0.03 ms. Formulas match Activity Monitor (SYS §3.2):
/// App = internal − purgeable, Used = App + Wired + Compressed, Cached = external + purgeable, Free = free + speculative.
enum MemoryReader {
    static func read() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)                    // 16 KiB on Apple Silicon, 4 KiB on Intel
        let ps = UInt64(pageSize)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }
        let purgeable = UInt64(stats.purgeable_count) * ps
        let anonymous = UInt64(stats.internal_page_count) * ps
        return MemorySnapshot(
            total: UInt64(SysctlReader.int("hw.memsize") ?? 0),
            app: anonymous > purgeable ? anonymous - purgeable : 0,
            wired: UInt64(stats.wire_count) * ps,
            compressed: UInt64(stats.compressor_page_count) * ps,  // bytes held by the compressor, not the logical size
            cached: UInt64(stats.external_page_count) * ps + purgeable,
            free: (UInt64(stats.free_count) + UInt64(stats.speculative_count)) * ps,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            freePercentLevel: SysctlReader.int("kern.memorystatus_level"),
            // XNU reports its level as DISPATCH_MEMORYPRESSURE_* bits: 1 normal, 2 warning, 4 critical.
            pressure: MemoryPressure(rawValue: SysctlReader.int("kern.memorystatus_vm_pressure_level") ?? 0) ?? .unknown)
    }
}

// MARK: GPU utilization

/// IORegistry `IOAccelerator › PerformanceStatistics`, ~0.02–0.2 ms. One entry per accelerator
/// (Apple Silicon: one; Intel dual-GPU MacBook Pro: two). IOReport GPU "active residency" is NOT utilization (SYS §3.3).
enum GPUReader {
    static func read() -> [GPUUtilization] {
        IOKitHelpers.services(matching: "IOAccelerator").map { gpu in
            defer { IOObjectRelease(gpu) }
            let stats: [String: Any] = IOKitHelpers.property(gpu, "PerformanceStatistics") ?? [:]
            func percent(_ k: String) -> Int? { (stats[k] as? NSNumber)?.intValue }
            return GPUUtilization(
                model: IOKitHelpers.property(gpu, "model", as: String.self),
                coreCount: IOKitHelpers.property(gpu, "gpu-core-count", as: NSNumber.self)?.intValue,
                devicePercent: percent("Device Utilization %") ?? percent("GPU Activity(%)"),   // 2nd key: some AMD/Intel drivers
                rendererPercent: percent("Renderer Utilization %"),
                tilerPercent: percent("Tiler Utilization %"),
                inUseSystemMemory: (stats["In use system memory"] as? NSNumber)?.uint64Value)
        }
    }

    /// The accelerator to show: the busiest one (dual-GPU Intel), else the first.
    static func primary() -> GPUUtilization? {
        let all = read()
        return all.max { ($0.devicePercent ?? -1) < ($1.devicePercent ?? -1) } ?? all.first
    }
}
