// SystemLoad.swift — Thermik (MIT).
// Per-core CPU load, Activity Monitor-compatible memory figures and GPU utilization (SYS §3). Public Mach / IORegistry
// APIs only: no root, no SMC, sandbox-safe. Verified on M4 Max / macOS 27.0.1.
import Darwin
import Foundation
import IOKit

// MARK: CPU load per logical core

/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, ~0.02–0.2 ms. Usage is the delta between two calls.
/// Stateful and not thread-safe: owned by `SystemSampler`.
final class CPULoadSampler {
    private struct Reading { var counters: [UInt32]; var count: Int }

    /// Previous tick counters, flattened: `CPU_STATE_MAX` (user, system, idle, nice) per logical CPU.
    private var previous: [UInt32] = []

    /// Per-logical-CPU load since the previous call; empty on the first call (or after `reset()`).
    /// Index = logical CPU id. On Apple Silicon ids 0..<E are the Efficiency cores (`MachineInfo.cpuTopology`).
    func sample() -> [CoreLoad] {
        guard let reading = readCounters() else { return [] }
        defer { previous = reading.counters }
        guard previous.count == reading.counters.count else { return [] }
        return coreLoads(reading)
    }

    private func readCounters() -> Reading? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        // The kernel allocates the array in our address space: it must always be returned.
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return makeCounters(info: info, cpuCount: cpuCount)
    }

    private func makeCounters(info: processor_info_array_t, cpuCount: natural_t) -> Reading {
        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount)
        var counters = [UInt32](repeating: 0, count: count * states)
        for i in 0..<(count * states) { counters[i] = UInt32(bitPattern: info[i]) }
        return Reading(counters: counters, count: count)
    }

    private func coreLoads(_ reading: Reading) -> [CoreLoad] {
        var out: [CoreLoad] = []
        out.reserveCapacity(reading.count)
        for cpu in 0..<reading.count { out.append(coreLoad(cpu: cpu, now: reading.counters)) }
        return out
    }

    private func coreLoad(cpu: Int, now: [UInt32]) -> CoreLoad {
        let base = cpu * Int(CPU_STATE_MAX)
        // Wrapping subtraction: the tick counters are 32-bit and wrap around.
        let user = Double(now[base + Int(CPU_STATE_USER)] &- previous[base + Int(CPU_STATE_USER)])
        let system = Double(now[base + Int(CPU_STATE_SYSTEM)] &- previous[base + Int(CPU_STATE_SYSTEM)])
        let idle = Double(now[base + Int(CPU_STATE_IDLE)] &- previous[base + Int(CPU_STATE_IDLE)])
        let nice = Double(now[base + Int(CPU_STATE_NICE)] &- previous[base + Int(CPU_STATE_NICE)])
        let total = user + system + idle + nice
        guard total > 0 else { return CoreLoad(user: 0, system: 0, nice: 0, idle: 1) }
        return CoreLoad(user: user / total, system: system / total, nice: nice / total, idle: idle / total)
    }

    /// Drops the baseline (after wake the first delta would span the whole sleep).
    func reset() { previous = [] }
}

// MARK: Memory

/// `host_statistics64(HOST_VM_INFO64)` + 4 sysctls, ~0.03 ms. Formulas match Activity Monitor (SYS §3.2):
/// App = internal − purgeable, Used = App + Wired + Compressed, Cached = external + purgeable, Free = free + speculative.
enum MemoryReader {
    static func read() -> MemorySnapshot? {
        guard let (stats, pageSize) = memoryStatistics() else { return nil }
        let swap = swapUsage()
        return makeSnapshot(stats: stats, pageSize: pageSize, swap: swap)
    }

    private static func memoryStatistics() -> (vm_statistics64, UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)                    // 16 KiB on Apple Silicon, 4 KiB on Intel
        return (stats, UInt64(pageSize))
    }

    private static func swapUsage() -> xsw_usage {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) != 0 { swap = xsw_usage() }
        return swap
    }

    /// XNU reports pressure as DISPATCH_MEMORYPRESSURE_* bits: 1 normal, 2 warning, 4 critical.
    private static func makeSnapshot(stats: vm_statistics64, pageSize: UInt64, swap: xsw_usage) -> MemorySnapshot {
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let anonymous = UInt64(stats.internal_page_count) * pageSize
        return MemorySnapshot(
            total: UInt64(SysctlReader.int("hw.memsize") ?? 0), app: anonymous > purgeable ? anonymous - purgeable : 0,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize, // bytes held by the compressor, not the logical size
            cached: UInt64(stats.external_page_count) * pageSize + purgeable,
            free: (UInt64(stats.free_count) + UInt64(stats.speculative_count)) * pageSize,
            swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, freePercentLevel: SysctlReader.int("kern.memorystatus_level"),
            pressure: MemoryPressure(rawValue: SysctlReader.int("kern.memorystatus_vm_pressure_level") ?? 0) ?? .unknown)
    }
}

// MARK: GPU utilization

/// IORegistry `IOAccelerator › PerformanceStatistics`, ~0.02–0.2 ms. One entry per accelerator
/// (Apple Silicon: one; Intel dual-GPU MacBook Pro: two). IOReport GPU "active residency" is NOT utilization (SYS §3.3).
enum GPUReader {
    static func read() -> [GPUUtilization] {
        IOKitHelpers.services(matching: "IOAccelerator").map { read(gpu: $0) }
    }

    private static func read(gpu: io_service_t) -> GPUUtilization {
        defer { IOObjectRelease(gpu) }
        let stats: [String: Any] = IOKitHelpers.property(gpu, "PerformanceStatistics") ?? [:]
        func percent(_ key: String) -> Int? { (stats[key] as? NSNumber)?.intValue }
        return GPUUtilization(
            model: IOKitHelpers.property(gpu, "model", as: String.self),
            coreCount: IOKitHelpers.property(gpu, "gpu-core-count", as: NSNumber.self)?.intValue,
            devicePercent: percent("Device Utilization %") ?? percent("GPU Activity(%)"), // 2nd key: some AMD/Intel drivers
            rendererPercent: percent("Renderer Utilization %"), tilerPercent: percent("Tiler Utilization %"),
            inUseSystemMemory: (stats["In use system memory"] as? NSNumber)?.uint64Value)
    }

    /// The accelerator to show: the busiest one (dual-GPU Intel), else the first.
    static func primary() -> GPUUtilization? {
        let all = read()
        return all.max { ($0.devicePercent ?? -1) < ($1.devicePercent ?? -1) } ?? all.first
    }
}
