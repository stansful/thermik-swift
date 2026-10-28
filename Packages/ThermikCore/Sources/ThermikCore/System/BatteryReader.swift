// BatteryReader.swift — Thermik (MIT). OWNER: Unit 2.
// AppleSmartBattery gauge read from the IORegistry (no root, no SMC; SYS §2.1–2.3, verified on M4 Max / macOS 27.0.1).
import Foundation
import IOKit

/// Reads `AppleSmartBattery` and its children. Stateful (caches the registry handles), not thread-safe:
/// owned by `SystemSampler`.
///
/// Layout on macOS 26/27: the root node lost `DesignCapacity`, `AppleRawMaxCapacity`, `NominalChargeCapacity`,
/// `AppleRawCurrentCapacity`, `Temperature` and `PermanentFailureStatus`; the full gauge now lives in the child
/// `AppleSmartBatteryPack › BatteryData` and per-cell values in `AppleSmartBatteryBank › BatteryData`. Each key is
/// therefore looked up in the order **pack BatteryData → root → root BatteryData** (older macOS: root only).
final class BatteryReader {
    private var service: io_service_t = 0
    private var pack: io_registry_entry_t = 0
    private var banks: [io_registry_entry_t] = []
    /// Desktops have no AppleSmartBattery: re-check at most every 60 s instead of on every tick.
    private var lastMiss: ContinuousClock.Instant?

    deinit { releaseHandles() }

    /// ~0.3–0.4 ms. nil on desktops.
    ///
    /// Root keys are fetched one by one (`IORegistryEntryCreateCFProperty`, ~5 µs each) instead of copying the whole
    /// 51-property node with its large nested dictionaries (~300 µs on M4 Max / macOS 27).
    func read() -> BatterySnapshot? {
        guard resolve() else { return nil }
        var current = IOKitHelpers.property(service, "CurrentCapacity", as: NSNumber.self)
        if current == nil {                                 // driver re-registered (rare): look the nodes up again
            releaseHandles()
            guard resolve() else { return nil }
            current = IOKitHelpers.property(service, "CurrentCapacity", as: NSNumber.self)
            guard current != nil else { return nil }
        }
        var rootCache: [String: Any?] = [:]
        func root(_ k: String) -> Any? {
            if let cached = rootCache[k] { return cached }
            let v: Any? = IOKitHelpers.property(service, k, as: AnyObject.self)
            rootCache[k] = .some(v)
            return v
        }
        var rootDataCache: NSDictionary??
        func rootData(_ k: String) -> Any? {
            if rootDataCache == nil { rootDataCache = .some(root("BatteryData") as? NSDictionary) }
            return rootDataCache??[k]
        }
        let packData: NSDictionary? = pack == 0 ? nil : IOKitHelpers.property(pack, "BatteryData", as: NSDictionary.self)
        let cells: [Int] = banks.compactMap { bank in
            IOKitHelpers.property(bank, "BatteryData", as: NSDictionary.self).flatMap { IOKitHelpers.signedInt($0["CellVoltage"]) }
        }

        func int(_ keys: String...) -> Int? {
            for k in keys {
                if let v = IOKitHelpers.signedInt(packData?[k]) ?? IOKitHelpers.signedInt(root(k)) ?? IOKitHelpers.signedInt(rootData(k)) {
                    return v
                }
            }
            return nil
        }
        func bool(_ k: String) -> Bool { (root(k) as? NSNumber)?.boolValue ?? false }
        func minutes(_ k: String) -> Int? { int(k).flatMap { $0 == 65535 || $0 < 0 ? nil : $0 } }   // 65535 = calculating

        let external = bool("ExternalConnected")
        var adapter: PowerAdapterInfo?
        if external, let ad = root("AdapterDetails") as? NSDictionary, ad.count > 0 {
            adapter = PowerAdapterInfo(name: ad["Name"] as? String,
                                       watts: IOKitHelpers.signedInt(ad["Watts"]),
                                       voltage_mV: IOKitHelpers.signedInt(ad["AdapterVoltage"]),
                                       current_mA: IOKitHelpers.signedInt(ad["Current"]),
                                       isWireless: (ad["IsWireless"] as? NSNumber)?.boolValue ?? false)
        }
        let telemetry = root("PowerTelemetryData") as? NSDictionary
        let charger = root("ChargerData") as? NSDictionary

        return BatterySnapshot(
            cycleCount: int("CycleCount"),
            designCycleCount: int("DesignCycleCount9C"),           // IOPS' DesignCycleCount (300) is a legacy value
            designCapacity_mAh: int("DesignCapacity"),
            rawMaxCapacity_mAh: int("AppleRawMaxCapacity", "FullChargeCapacity"),
            nominalChargeCapacity_mAh: int("NominalChargeCapacity"),
            rawCurrentCapacity_mAh: int("AppleRawCurrentCapacity", "RemainingCapacity"),
            chargePercent: Self.chargePercent(current: IOKitHelpers.signedInt(current),
                                              max: IOKitHelpers.signedInt(root("MaxCapacity"))),
            temperatureC: int("Temperature", "VirtualTemperature").map { Double($0) / 100 },   // centi-°C
            voltage_mV: int("Voltage", "AppleRawBatteryVoltage"),
            amperage_mA: int("InstantAmperage", "Amperage"),
            isCharging: bool("IsCharging"),
            externalConnected: external,
            fullyCharged: bool("FullyCharged"),
            minutesToEmpty: minutes("AvgTimeToEmpty"),
            minutesToFull: minutes("AvgTimeToFull"),
            permanentFailureStatus: int("PermanentFailureStatus"),
            notChargingReason: IOKitHelpers.signedInt(charger?["NotChargingReason"]),
            cellVoltages_mV: cells,
            adapter: adapter,
            systemPowerIn_mW: IOKitHelpers.signedInt(telemetry?["SystemPowerIn"]),
            systemLoad_mW: IOKitHelpers.signedInt(telemetry?["SystemLoad"]),
            batteryPower_mW: IOKitHelpers.signedInt(telemetry?["BatteryPower"]))
    }

    /// Apple Silicon reports `CurrentCapacity` / `MaxCapacity` in percent (Max = 100); Intel reports both in mAh.
    static func chargePercent(current: Int?, max: Int?) -> Int? {
        guard let current else { return nil }
        guard let max, max > 100 else { return min(Swift.max(current, 0), 100) }
        return Int((Double(current) / Double(max) * 100).rounded())
    }

    // MARK: Registry handles

    private func resolve() -> Bool {
        if service != 0 { return true }
        if let lastMiss, lastMiss.duration(to: .now) < .seconds(60) { return false }
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { lastMiss = .now; return false }
        lastMiss = nil
        walk(service)
        return true
    }

    /// AppleSmartBattery › AppleSmartBatteryPack › AppleSmartBatteryBank ×N (› AppleSmartBatteryCell). Retains the
    /// pack and bank entries; releases everything else.
    private func walk(_ entry: io_registry_entry_t) {
        for child in IOKitHelpers.children(entry) {
            switch IOKitHelpers.className(child) {
            case "AppleSmartBatteryPack":
                if pack == 0 { pack = child; walk(child); continue }
            case "AppleSmartBatteryBank":
                banks.append(child); continue                 // cells below a bank carry no voltage
            default:
                break
            }
            IOObjectRelease(child)
        }
    }

    private func releaseHandles() {
        for b in banks { IOObjectRelease(b) }
        banks = []
        if pack != 0 { IOObjectRelease(pack); pack = 0 }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }
}
