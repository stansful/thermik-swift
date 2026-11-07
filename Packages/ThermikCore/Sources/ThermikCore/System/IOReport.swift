// IOReport.swift — Thermik (MIT).
// Apple Silicon CPU-cluster / per-core / GPU frequency and residency, SoC power and the SSD-controller temperature from
// the private /usr/lib/libIOReport.dylib (SYS §4). No root, works under Hardened Runtime without entitlements.
// Function signatures follow the open-source users of this API: macmon (vladkens/macmon, MIT, Rust) and
// socpowerbud (dehydratedpotato/socpowerbud, MIT, ObjC). Not allowed in the Mac App Store (private symbols).
import Foundation
import IOKit

/// dlsym'd entry points of libIOReport. `@unchecked Sendable`: immutable after `load()`, and every member is a plain C
/// function pointer into a library that is never unloaded. Copy/Create results are +1 (`takeRetainedValue()`),
/// Get results +0, as in the open-source users of the API.
struct IOReportAPI: @unchecked Sendable {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias MergeChannels = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
    /// Returns an `IOReportSubscription` CF object; the out parameter receives the subscribed channels (both +1).
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                   UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias ChannelInt32 = @convention(c) (CFDictionary) -> Int32
    typealias SimpleGetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    let copyChannelsInGroup: CopyChannelsInGroup
    let copyAllChannels: CopyAllChannels?                 // optional: the per-group path is the fallback
    let mergeChannels: MergeChannels
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let group: ChannelString, subGroup: ChannelString, name: ChannelString, unit: ChannelString
    let simpleInteger: SimpleGetInteger
    let stateCount: ChannelInt32
    let stateName: StateName
    let stateResidency: StateResidency

    /// nil when the library or any symbol is missing (Intel, a future macOS): callers degrade to "—".
    static let shared: IOReportAPI? = load()

    private static func load() -> IOReportAPI? {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let core = coreSymbols(handle), let channels = channelSymbols(handle), let states = stateSymbols(handle) else { return nil }
        return IOReportAPI(copyChannelsInGroup: core.copy, copyAllChannels: symbol(handle, "IOReportCopyAllChannels", CopyAllChannels.self),
                           mergeChannels: core.merge, createSubscription: core.sub, createSamples: core.samples,
                           createSamplesDelta: core.delta, group: channels.group, subGroup: channels.subGroup,
                           name: channels.name, unit: channels.unit, simpleInteger: channels.simple,
                           stateCount: states.count, stateName: states.name, stateResidency: states.residency)
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }

    private static func coreSymbols(_ handle: UnsafeMutableRawPointer) ->
        (copy: CopyChannelsInGroup, merge: MergeChannels, sub: CreateSubscription, samples: CreateSamples, delta: CreateSamplesDelta)? {
        guard let copy = symbol(handle, "IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let merge = symbol(handle, "IOReportMergeChannels", MergeChannels.self),
              let sub = symbol(handle, "IOReportCreateSubscription", CreateSubscription.self),
              let samples = symbol(handle, "IOReportCreateSamples", CreateSamples.self),
              let delta = symbol(handle, "IOReportCreateSamplesDelta", CreateSamplesDelta.self) else { return nil }
        return (copy, merge, sub, samples, delta)
    }

    private static func channelSymbols(_ handle: UnsafeMutableRawPointer) ->
        (group: ChannelString, subGroup: ChannelString, name: ChannelString, unit: ChannelString, simple: SimpleGetInteger)? {
        guard let group = symbol(handle, "IOReportChannelGetGroup", ChannelString.self),
              let subGroup = symbol(handle, "IOReportChannelGetSubGroup", ChannelString.self),
              let name = symbol(handle, "IOReportChannelGetChannelName", ChannelString.self),
              let unit = symbol(handle, "IOReportChannelGetUnitLabel", ChannelString.self),
              let simple = symbol(handle, "IOReportSimpleGetIntegerValue", SimpleGetInteger.self) else { return nil }
        return (group, subGroup, name, unit, simple)
    }

    private static func stateSymbols(_ handle: UnsafeMutableRawPointer) ->
        (count: ChannelInt32, name: StateName, residency: StateResidency)? {
        guard let count = symbol(handle, "IOReportStateGetCount", ChannelInt32.self),
              let name = symbol(handle, "IOReportStateGetNameForIndex", StateName.self),
              let residency = symbol(handle, "IOReportStateGetResidency", StateResidency.self) else { return nil }
        return (count, name, residency)
    }
}

/// One channel inside a sample. IMPORTANT: wraps the *original* CFDictionary. The IOReport getters cache values into
/// the dictionary, so a Swift-bridged copy (`as? [String: Any]`) is immutable and crashes with
/// "-[__NSDictionaryI __setObject:forKey:] unrecognized selector" (SYS §4.1).
struct IOReportChannel {
    let dict: CFDictionary
    let api: IOReportAPI

    private func string(_ u: Unmanaged<CFString>?) -> String { u.map { $0.takeUnretainedValue() as String } ?? "" }
    var group: String { string(api.group(dict)) }
    var subGroup: String { string(api.subGroup(dict)) }
    var name: String { string(api.name(dict)) }
    var unit: String { string(api.unit(dict)).trimmingCharacters(in: .whitespaces) }
    var integer: Int64 { api.simpleInteger(dict, 0) }

    /// State-format channels: number of states, their names and residency ticks (24 MHz ticks for "24Mticks" units).
    var stateCount: Int { Int(max(api.stateCount(dict), 0)) }
    func stateName(_ i: Int) -> String { string(api.stateName(dict, Int32(i))).trimmingCharacters(in: .whitespaces) }
    func residency(_ i: Int) -> Int64 { max(api.stateResidency(dict, Int32(i)), 0) }

    /// Energy channels → joules, honouring the unit label (mJ / µJ / nJ).
    var joules: Double {
        let v = Double(integer)
        switch unit {
        case "mJ": return v / 1e3
        case "uJ", "µJ": return v / 1e6
        case "nJ": return v / 1e9
        default: return v
        }
    }

    /// The channels of a sample, a delta or a channel list (`IOReportChannels` array), as raw CF objects.
    static func all(in container: CFDictionary, api: IOReportAPI) -> [IOReportChannel] {
        guard let array = channelArray(container) else { return [] }
        return (0..<CFArrayGetCount(array)).map {
            IOReportChannel(dict: unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: CFDictionary.self), api: api)
        }
    }

    static func channelArray(_ container: CFDictionary) -> CFArray? {
        guard let raw = CFDictionaryGetValue(container, Unmanaged.passUnretained(channelsKey).toOpaque()) else { return nil }
        return unsafeBitCast(raw, to: CFArray.self)
    }

    static var channelsKey: CFString { "IOReportChannels" as CFString }
}

/// One IOReport subscription. Each sample costs ~0.5–6 ms per reporting driver (PMGR is the expensive one), almost
/// independent of how many of its channels are subscribed. Not thread-safe: owned by `SoCSampler`.
///
/// Owns the subscription (+1 from `IOReportCreateSubscription`), released with this object. A live subscription holds
/// a kernel user client per reporting driver and ~50 KB, so one dropped unreleased (the CLPC flag switched off and on)
/// leaked both for good (measured on M4 Max: 20 GPU Stats subscriptions = 20 user clients, 0 once released; ~1,000
/// unreleased ones crash the process).
final class IOReportSubscription {
    let api: IOReportAPI
    private let sub: CFTypeRef
    private let subscribed: CFMutableDictionary

    /// `channels` is an `IOReportCopyChannelsInGroup`-shaped dictionary (or a hand-built one, CLPC).
    init?(api: IOReportAPI, channels: CFDictionary) {
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) else { return nil }
        var out: Unmanaged<CFMutableDictionary>?
        let s = api.createSubscription(nil, mutable, &out, 0, nil)?.takeRetainedValue()
        let subbed = out?.takeRetainedValue()
        guard let s, let subbed else { return nil }                  // whichever one came back is released here
        self.api = api; sub = s; subscribed = subbed
    }

    /// Subscribes the channels of `groups` that pass `keep(group, subGroup, name)`; nil when none is left.
    /// One `IOReportCopyAllChannels` call (~55–60 ms for ~12 k channels on M4 Max) replaces one
    /// `IOReportCopyChannelsInGroup` call per group: each of those costs the same ~55 ms because the library walks every
    /// reporting driver either way (measured: 8 group copies = 435 ms, the single listing + filter = 62 ms).
    convenience init?(api: IOReportAPI, groups: [String], keep: (_ group: String, _ subGroup: String, _ name: String) -> Bool) {
        guard let listing = Self.channelListing(api: api, groups: groups) else { return nil }
        let wanted = Set(groups)
        guard let selected = Self.filter(listing, api: api, keep: { channel in
            let group = channel.group
            return wanted.contains(group) && keep(group, channel.subGroup, channel.name)
        }) else { return nil }
        self.init(api: api, channels: selected)
    }

    private static func channelListing(api: IOReportAPI, groups: [String]) -> CFDictionary? {
        if let all = api.copyAllChannels?(0, 0)?.takeRetainedValue() { return all }
        return mergedChannels(api: api, groups: groups)       // fallback: merge the groups one by one
    }

    private static func mergedChannels(api: IOReportAPI, groups: [String]) -> CFDictionary? {
        var merged: CFMutableDictionary?
        for group in groups {
            guard let channels = api.copyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let merged { api.mergeChannels(merged, channels, nil) }
            else { merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) }
        }
        return merged
    }

    /// A copy of a channel list holding only the channels that pass `keep` (the original CF channel objects, not
    /// bridged copies). nil when nothing is left.
    private static func filter(_ channels: CFDictionary, api: IOReportAPI, keep: (IOReportChannel) -> Bool) -> CFDictionary? {
        guard let source = IOReportChannel.channelArray(channels),
              let copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) else { return nil }
        guard let kept = keptChannels(source, api: api, keep: keep), CFArrayGetCount(kept) > 0 else { return nil }
        CFDictionarySetValue(copy, Unmanaged.passUnretained(IOReportChannel.channelsKey).toOpaque(),
                             Unmanaged.passUnretained(kept).toOpaque())
        return copy
    }

    private static func keptChannels(_ source: CFArray, api: IOReportAPI,
                                     keep: (IOReportChannel) -> Bool) -> CFMutableArray? {
        guard let kept = withUnsafePointer(to: kCFTypeArrayCallBacks, { CFArrayCreateMutable(kCFAllocatorDefault, 0, $0) }) else { return nil }
        for index in 0..<CFArrayGetCount(source) {
            guard let raw = CFArrayGetValueAtIndex(source, index) else { continue }
            let channel = IOReportChannel(dict: unsafeBitCast(raw, to: CFDictionary.self), api: api)
            if keep(channel) { CFArrayAppendValue(kept, raw) }
        }
        return kept
    }

    var channelCount: Int { IOReportChannel.channelArray(subscribed).map(CFArrayGetCount) ?? 0 }
    func sample() -> CFDictionary? { api.createSamples(sub, subscribed, nil)?.takeRetainedValue() }
    func delta(from a: CFDictionary, to b: CFDictionary) -> CFDictionary? { api.createSamplesDelta(a, b, nil)?.takeRetainedValue() }
}

// MARK: DVFS frequency tables (IODeviceTree pmgr, public registry, no root)

struct DVFSTables: Sendable {
    var eCPU: [Double] = []      // MHz per active performance state, low → high
    var pCPU: [Double] = []
    var gpu: [Double] = []

    /// `voltage-states*` properties: 8-byte records (UInt32 frequency, UInt32 mV). M1–M3 CPU tables are in Hz, M4+ CPU
    /// tables in kHz, GPU tables always in Hz. Keys were renumbered on M5 (macmon v0.7 fix, MIT), so tables are recognised
    /// by shape: `*-sram` tables without an OFF entry are CPU tables (E = lowest max, P = highest max), tables that start
    /// with 0 Hz are GPU tables.
    static func load() -> DVFSTables {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &iterator) == KERN_SUCCESS else { return .init() }
        defer { IOObjectRelease(iterator) }
        var collector = Collector()
        collector.collect(iterator: iterator)
        return collector.tables()
    }

    private struct Collector {
        var cpuTables: [String: [Double]] = [:]
        var gpuTables: [String: [Double]] = [:]

        mutating func collect(iterator: io_iterator_t) {
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                collect(entry: entry)
            }
        }

        mutating func collect(entry: io_registry_entry_t) {
            for (key, value) in IOKitHelpers.properties(entry) where key.hasPrefix("voltage-states") {
                guard let data = value as? Data, let table = Self.table(data) else { continue }
                add(key: key, table: table)
            }
        }

        static func table(_ data: Data) -> (raw: [UInt32], mhz: [Double])? {
            guard data.count >= 16 else { return nil }
            let raw: [UInt32] = data.withUnsafeBytes { bytes in
                (0..<(bytes.count / 8)).map { bytes.loadUnaligned(fromByteOffset: $0 * 8, as: UInt32.self) }
            }
            let mhz = raw.map { $0 >= 100_000_000 ? Double($0) / 1e6 : Double($0) / 1e3 }
            return (raw, mhz)
        }

        mutating func add(key: String, table: (raw: [UInt32], mhz: [Double])) {
            if table.raw.first == 0, !key.hasSuffix("-sram") {
                gpuTables[key] = Array(table.mhz.dropFirst())                // drop the OFF (0 Hz) entry
                return
            }
            guard key.hasSuffix("-sram"), !table.raw.contains(where: { $0 <= 1 }) else { return }
            cpuTables[key] = table.mhz
        }

        func tables() -> DVFSTables {
            var result = DVFSTables()
            let byMax = cpuTables.values.filter { ($0.max() ?? 0) > 500 }.sorted { ($0.max() ?? 0) < ($1.max() ?? 0) }
            result.eCPU = byMax.first ?? []
            result.pCPU = byMax.last ?? []
            result.gpu = gpuTables["voltage-states9"] ?? gpuTables.values.max { $0.count < $1.count } ?? []
            return result
        }
    }
}

// MARK: SoC sampler

/// Samples CPU/GPU frequency + residency, SoC power and the SSD-controller temperature. Create once (≈ 60–70 ms, off
/// the main thread), then call `sample()` every 1–2 s from one actor (not thread-safe; owned by `SystemSampler`).
///
/// Power policy (SPEC §2.7): the PMGR "Energy Model" counters while they are live (macOS 14–26); on macOS 27 they freeze
/// (macmon issue #76) and are detected at runtime → CPU/ANE/DRAM become nil ("—"). `GPU Energy` (AGX driver) keeps
/// working and is always used. The AppleCLPC synthesized channels are used only behind the P2 flag
/// `advanced.experimentalCLPCPower`. PMP power histograms are never used (7 ms per sample, coarse).
final class SoCSampler {
    /// Energy Model channels Thermik reads; the rest of the ~330-channel group is filtered out of the subscription.
    private static let energyChannels: Set<String> = ["CPU Energy", "GPU Energy", "ANE", "DRAM"]
    private static let clpcDefaultsKey = "advanced.experimentalCLPCPower"
    /// Above this a reading is a post-freeze "catch-up" spike (one report saw 3,564 W): rejected.
    private static let saneWatts = 500.0

    private let api: IOReportAPI
    private let main: IOReportSubscription
    private let tables = DVFSTables.load()
    private var clpc: CLPCEnergy.State = .notCreated
    private var last: (main: CFDictionary, clpc: CFDictionary?, at: UInt64)?
    /// Index of the first active state (after IDLE / DOWN / OFF) per channel name: state names never change, so they
    /// are bridged once instead of ~450 CFString conversions per sample.
    private var firstActiveState: [String: Int] = [:]

    /// Energy Model freeze detection: CPU Energy Δ == 0 while a CPU cluster is > 1 % active, twice in a row → frozen.
    /// Sticky until the counter moves again.
    private var zeroWhileBusy = 0
    private(set) var energyModelFrozen = false

    private struct SampleWindow {
        var main: CFDictionary
        var delta: CFDictionary
        var clpc: CFDictionary?
        var previousCLPC: CFDictionary?
        var interval: Double
    }

    private struct ChannelReadings {
        var clusters: [DomainFrequency] = []
        var cores: [DomainFrequency] = []
        var gpu: DomainFrequency?
        var energy: [String: Double] = [:]
    }

    /// ≈ 60–70 ms on M4 Max (one channel listing + subscription), off the main thread.
    init?() {
        let groups = ["Energy Model", "CPU Stats", "GPU Stats", "ANS2"]
        guard let api = IOReportAPI.shared,
              let subscription = IOReportSubscription(api: api, groups: groups, keep: Self.keepChannel) else { return nil }
        self.api = api
        main = subscription
    }

    private static func keepChannel(_ group: String, _ subGroup: String, _ name: String) -> Bool {
        switch group {
        case "Energy Model": return energyChannels.contains(name)
        case "CPU Stats": return subGroup == "CPU Core Performance States"
            || (subGroup == "CPU Complex Performance States" && isCluster(name))
        case "GPU Stats": return subGroup == "GPU Performance States" && name == "GPUPH"
        // Only SSD-controller temperatures: the whole ANS2 group has ~420 channels (PCIe link statistics).
        case "ANS2": return subGroup.hasPrefix("MSP") && name.hasPrefix("Temperature")
        default: return false
        }
    }

    /// CPU clusters in "CPU Complex Performance States": ECPU, PCPU, PCPU1 (Ultra: ECPU1, PCPU2, …). ECPM / PCPM… are
    /// the cluster fabrics and are skipped.
    private static func isCluster(_ name: String) -> Bool {
        (name.hasPrefix("ECPU") || name.hasPrefix("PCPU")) && !name.contains("M")
    }

    var channelCount: Int { main.channelCount }

    /// Drops the baselines (after wake the first delta would span the whole sleep).
    func reset() { last = nil; zeroWhileBusy = 0 }

    /// nil on the first call (needs two samples), after `reset()`, or if sampling failed.
    func sample() -> SoCMetrics? {
        let clpcSubscription = synchronizedCLPC()
        guard let window = sampleWindow(clpcSubscription) else { return nil }
        let readings = readChannels(window)
        let ssd = ssdTemperature(in: window.main)
        let clpcWatts = clpcWatts(window, subscription: clpcSubscription)
        return SoCMetrics(interval: window.interval, clusters: readings.clusters, cores: readings.cores, gpu: readings.gpu,
                          power: power(energy: readings.energy, clusters: readings.clusters, clpc: clpcWatts),
                          ssdControllerTempC: ssd)
    }

    private func synchronizedCLPC() -> IOReportSubscription? {
        let enabled = UserDefaults.standard.bool(forKey: Self.clpcDefaultsKey)
        if enabled, case .notCreated = clpc { clpc = CLPCEnergy.subscription(api: api).map { .live($0) } ?? .unavailable }
        if !enabled, case .live = clpc { clpc = .notCreated }           // flag switched off: drop the subscription
        guard enabled, case .live(let subscription) = clpc else { return nil }
        return subscription
    }

    private func sampleWindow(_ clpcSubscription: IOReportSubscription?) -> SampleWindow? {
        guard let mainSample = main.sample() else { return nil }
        let clpcSample = clpcSubscription?.sample()
        let now = DispatchTime.now().uptimeNanoseconds
        defer { last = (mainSample, clpcSample, now) }
        guard let last, let delta = main.delta(from: last.main, to: mainSample) else { return nil }
        let interval = Double(now &- last.at) / 1e9
        guard interval > 0.05 else { return nil }
        return SampleWindow(main: mainSample, delta: delta, clpc: clpcSample, previousCLPC: last.clpc, interval: interval)
    }

    private func readChannels(_ window: SampleWindow) -> ChannelReadings {
        var readings = ChannelReadings()
        for channel in IOReportChannel.all(in: window.delta, api: api) { consume(channel, into: &readings, interval: window.interval) }
        return readings
    }

    private func consume(_ channel: IOReportChannel, into readings: inout ChannelReadings, interval: Double) {
        if channel.group == "Energy Model" { readings.energy[channel.name] = channel.joules / interval; return }
        if channel.group == "CPU Stats", channel.subGroup == "CPU Complex Performance States" {
            appendCluster(channel, into: &readings); return
        }
        if channel.group == "CPU Stats", channel.subGroup == "CPU Core Performance States" {
            appendCore(channel, into: &readings); return
        }
        if channel.group == "GPU Stats", channel.subGroup == "GPU Performance States" {
            readings.gpu = frequency(channel, name: channel.name, table: tables.gpu)
        }
    }

    private func appendCluster(_ channel: IOReportChannel, into readings: inout ChannelReadings) {
        let name = channel.name
        guard Self.isCluster(name) else { return }
        readings.clusters.append(frequency(channel, name: name, table: name.hasPrefix("E") ? tables.eCPU : tables.pCPU))
    }

    private func appendCore(_ channel: IOReportChannel, into readings: inout ChannelReadings) {
        let name = channel.name
        readings.cores.append(frequency(channel, name: name, table: name.hasPrefix("E") ? tables.eCPU : tables.pCPU))
    }

    /// The SSD-controller temperature is instantaneous: read the raw sample (the delta is garbage).
    private func ssdTemperature(in sample: CFDictionary) -> Double? {
        IOReportChannel.all(in: sample, api: api)
            .filter { $0.group == "ANS2" && $0.name.hasPrefix("Temperature") }
            .map(\.integer).filter { (1...150).contains($0) }.max().map(Double.init)
    }

    private func clpcWatts(_ window: SampleWindow, subscription: IOReportSubscription?) -> [String: Double]? {
        guard let subscription, let previous = window.previousCLPC, let current = window.clpc,
              let delta = subscription.delta(from: previous, to: current) else { return nil }
        var watts: [String: Double] = [:]
        for channel in IOReportChannel.all(in: delta, api: api) { watts[channel.name] = channel.joules / window.interval }
        return watts
    }

    private func power(energy em: [String: Double], clusters: [DomainFrequency], clpc: [String: Double]?) -> SoCPower {
        let gpuW = sane(em["GPU Energy"])                                  // AGX driver counter: works on macOS 27 too
        let busy = clusters.contains { $0.activePercent > 1 }
        let cpuRaw = em["CPU Energy"]
        updateEnergyModelFreeze(cpuRaw: cpuRaw, busy: busy)
        // A zero CPU delta while busy is never real, even before the freeze is confirmed.
        let energyModelLive = !energyModelFrozen && cpuRaw != nil && !(cpuRaw == 0 && busy)
        if energyModelLive { return energyModelPower(energy: em, cpuRaw: cpuRaw, gpuW: gpuW) }
        if let fallback = clpcPower(clpc, gpuW: gpuW) { return fallback }
        return SoCPower(cpuW: nil, gpuW: gpuW, aneW: nil, dramW: nil, source: gpuW == nil ? .unavailable : .energyModel)
    }

    private func updateEnergyModelFreeze(cpuRaw: Double?, busy: Bool) {
        if let cpuRaw, cpuRaw > 0 { zeroWhileBusy = 0; energyModelFrozen = false; return }
        guard busy || cpuRaw == nil else { return }
        zeroWhileBusy += 1
        if zeroWhileBusy >= 2 { energyModelFrozen = true }
    }

    private func energyModelPower(energy: [String: Double], cpuRaw: Double?, gpuW: Double?) -> SoCPower {
        SoCPower(cpuW: sane(cpuRaw), gpuW: gpuW, aneW: sane(energy["ANE"]), dramW: sane(energy["DRAM"]), source: .energyModel)
    }

    private func clpcPower(_ clpc: [String: Double]?, gpuW: Double?) -> SoCPower? {
        guard let clpc, let cpu = sane(clpc["CPU Energy"]), cpu > 0 else { return nil }
        return SoCPower(cpuW: cpu, gpuW: gpuW ?? sane(clpc["GPU Energy"]), aneW: sane(clpc["ANE"]), dramW: nil, source: .clpc)
    }

    private func sane(_ watts: Double?) -> Double? {
        watts.flatMap { $0 >= 0 && $0 < Self.saneWatts ? $0 : nil }
    }

    /// Residency-weighted average over the *active* states (after IDLE / DOWN / OFF). On M4 this is the REQUESTED DVFS
    /// state, not a measured clock (macmon #78): the UI labels it "≈". 0 MHz when the domain was never active.
    /// `table[i]` is the MHz of the i-th ACTIVE state (the DVFS tables have no idle entries).
    private func frequency(_ channel: IOReportChannel, name: String, table: [Double]) -> DomainFrequency {
        let count = channel.stateCount
        let first = firstActiveState(channel, name: name, count: count)
        let residency = residency(channel, count: count, first: first, table: table)
        return DomainFrequency(name: name, mhz: residency.active > 0 ? residency.weighted / residency.active : 0,
                               activePercent: residency.total > 0 ? residency.active / residency.total * 100 : 0)
    }

    private func firstActiveState(_ channel: IOReportChannel, name: String, count: Int) -> Int {
        if let cached = firstActiveState[name], cached <= count { return cached }
        let inactive: Set<String> = ["IDLE", "DOWN", "OFF"]
        let first = (0..<count).first { !inactive.contains(channel.stateName($0)) } ?? count
        firstActiveState[name] = first
        return first
    }

    private func residency(_ channel: IOReportChannel, count: Int, first: Int,
                           table: [Double]) -> (total: Double, active: Double, weighted: Double) {
        var total = 0.0, active = 0.0, weighted = 0.0
        for index in 0..<count {
            let ticks = Double(channel.residency(index))
            total += ticks
            guard index >= first else { continue }
            active += ticks
            let tableIndex = index - first
            if tableIndex < table.count { weighted += ticks * table[tableIndex] }
        }
        return (total, active, weighted)
    }
}

// MARK: macOS 27 CPU/ANE power workaround (EXPERIMENTAL, P2, off by default)
//
// Synthesized IOReport channels on the AppleCLPC driver, as introduced by macmon v0.9.0 (vladkens/macmon, MIT).
// The counter IDs are facts published in macmon's src/clpc.rs (which derived them for 27.0 (26A428) / 27.0.1 (26A434)).
// Fragile by nature: used only behind `advanced.experimentalCLPCPower`, gated on macOS 27, on the exact CLPC bundle id
// and on the < 500 W sanity check. Verified on M4 Max (AppleT6041CLPC): idle ≈ 3 W, 12-thread load ≈ 38 W (SYS §4.4).
enum CLPCEnergy {
    enum State {
        case notCreated
        case live(IOReportSubscription)
        case unavailable
    }

    /// (cpu, gpu, ane) low-32-bit keys per CLPC kext bundle. Full id = (index << 32) | key.
    static let keys: [String: (cpu: UInt64, gpu: UInt64, ane: UInt64)] = [
        "com.apple.driver.AppleT8103CLPCv3": (0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81),
        "com.apple.driver.AppleT6000CLPCv3": (0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8),
        "com.apple.driver.AppleT6002CLPC": (0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574),
        "com.apple.driver.AppleT8112CLPC": (0xb543_5137, 0x638d_9d52, 0xea08_9c36),
        "com.apple.driver.AppleT6020CLPC": (0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f),
        "com.apple.driver.AppleT6022CLPC": (0x76f5_fd21, 0x9062_4499, 0x3c09_7307),
        "com.apple.driver.AppleT8122CLPC": (0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f),
        "com.apple.driver.AppleT6030CLPC": (0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38),
        "com.apple.driver.AppleT6031CLPC": (0xd81e_0084, 0x1085_f98b, 0x313a_3be1),
        "com.apple.driver.AppleT6032CLPC": (0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25),
        "com.apple.driver.AppleT8132CLPC": (0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec),
        "com.apple.driver.AppleT6041CLPC": (0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c),   // M4 Max: verified here
        "com.apple.driver.AppleT8140CLPC": (0x9bf5_4436, 0xef70_589c, 0x569d_941b),
        "com.apple.driver.AppleT8142CLPC": (0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0),
        "com.apple.driver.AppleT6050CLPC": (0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59),
        "com.apple.driver.AppleT6050dCLPC": (0x18b3_010e, 0xedec_a11a, 0x188b_d883),
        "com.apple.driver.AppleT8152CLPC": (0x485d_4bfc, 0x1178_4654, 0x9380_c6bb),
    ]

    static func subscription(api: IOReportAPI) -> IOReportSubscription? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
              let bundle: String = IOKitHelpers.property(service, "CFBundleIdentifier"), let key = keys[bundle] else { return nil }
        let description = channelDescription(entryID: entryID, key: key)
        return IOReportSubscription(api: api, channels: description as CFDictionary)
    }

    private static func channelDescription(entryID: UInt64, key: (cpu: UInt64, gpu: UInt64, ane: UInt64)) -> NSDictionary {
        let nJ: UInt64 = (3 << 56) | (118 << 32)                    // IOReport unit encoding for nanojoules
        let simple: UInt64 = 1 | (2 << 16) | (1 << 32)              // simple integer, power category, 1 element
        let channels = [
            channel("CPU Energy", 16, key.cpu, entryID: entryID, unit: nJ, simple: simple),
            channel("GPU Energy", 25, key.gpu, entryID: entryID, unit: nJ, simple: simple),
            channel("ANE", 24, key.ane, entryID: entryID, unit: nJ, simple: simple),
        ]
        return ["IOReportChannels": channels]
    }

    private static func channel(_ name: String, _ index: UInt64, _ key: UInt64,
                                entryID: UInt64, unit: UInt64, simple: UInt64) -> NSDictionary {
        ["DriverID": NSNumber(value: entryID), "DriverName": "AppleCLPC", "ChannelName": name,
         "IOReportGroupName": "CLPC", "IOReportSubGroupName": "Energy Counters",
         "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: unit)],
         "LegendChannel": [NSNumber(value: (index << 32) | key), NSNumber(value: simple), name]]
    }
}
