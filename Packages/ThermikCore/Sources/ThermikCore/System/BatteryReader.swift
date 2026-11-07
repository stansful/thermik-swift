// BatteryReader.swift — Thermik (MIT).
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
        guard let current = readCurrent() else { return nil }
        let context = ReadContext(service: service, pack: pack, banks: banks)
        return context.snapshot(current: IOKitHelpers.signedInt(current))
    }

    /// A missing current reading can mean the driver re-registered: look the nodes up again once.
    private func readCurrent() -> NSNumber? {
        guard resolve() else { return nil }
        if let current = IOKitHelpers.property(service, "CurrentCapacity", as: NSNumber.self) { return current }
        releaseHandles()
        guard resolve() else { return nil }
        return IOKitHelpers.property(service, "CurrentCapacity", as: NSNumber.self)
    }

    /// Apple Silicon reports `CurrentCapacity` / `MaxCapacity` in percent (Max = 100); Intel reports both in mAh.
    static func chargePercent(current: Int?, max: Int?) -> Int? {
        guard let current else { return nil }
        guard let max, max > 100 else { return min(Swift.max(current, 0), 100) }
        return Int((Double(current) / Double(max) * 100).rounded())
    }

    private final class ReadContext {
        let service: io_service_t
        let packData: NSDictionary?
        let cells: [Int]
        var rootCache: [String: Any?] = [:]
        var rootDataCache: NSDictionary??

        init(service: io_service_t, pack: io_registry_entry_t, banks: [io_registry_entry_t]) {
            self.service = service
            packData = pack == 0 ? nil : IOKitHelpers.property(pack, "BatteryData", as: NSDictionary.self)
            cells = banks.compactMap { bank in
                IOKitHelpers.property(bank, "BatteryData", as: NSDictionary.self).flatMap { IOKitHelpers.signedInt($0["CellVoltage"]) }
            }
        }

        func snapshot(current: Int?) -> BatterySnapshot {
            let external = bool("ExternalConnected")
            let adapter = adapter(external: external)
            let telemetry = root("PowerTelemetryData") as? NSDictionary
            let charger = root("ChargerData") as? NSDictionary
            return makeSnapshot(current: current, external: external, adapter: adapter, telemetry: telemetry, charger: charger)
        }

        func makeSnapshot(current: Int?, external: Bool, adapter: PowerAdapterInfo?,
                          telemetry: NSDictionary?, charger: NSDictionary?) -> BatterySnapshot {
            BatterySnapshot(
                cycleCount: int("CycleCount"), designCycleCount: int("DesignCycleCount9C"), designCapacity_mAh: int("DesignCapacity"),
                rawMaxCapacity_mAh: int("AppleRawMaxCapacity", "FullChargeCapacity"), nominalChargeCapacity_mAh: int("NominalChargeCapacity"),
                rawCurrentCapacity_mAh: int("AppleRawCurrentCapacity", "RemainingCapacity"), chargePercent: percent(current: current),
                temperatureC: int("Temperature", "VirtualTemperature").map { Double($0) / 100 }, voltage_mV: int("Voltage", "AppleRawBatteryVoltage"), // centi-°C
                amperage_mA: int("InstantAmperage", "Amperage"), isCharging: bool("IsCharging"), externalConnected: external, fullyCharged: bool("FullyCharged"),
                minutesToEmpty: minutes("AvgTimeToEmpty"), minutesToFull: minutes("AvgTimeToFull"),
                permanentFailureStatus: int("PermanentFailureStatus"), notChargingReason: IOKitHelpers.signedInt(charger?["NotChargingReason"]),
                cellVoltages_mV: cells, adapter: adapter, systemPowerIn_mW: IOKitHelpers.signedInt(telemetry?["SystemPowerIn"]),
                systemLoad_mW: IOKitHelpers.signedInt(telemetry?["SystemLoad"]), batteryPower_mW: IOKitHelpers.signedInt(telemetry?["BatteryPower"]))
        }

        /// IOPS' DesignCycleCount (300) is a legacy value; DesignCycleCount9C is used by the snapshot above.
        func percent(current: Int?) -> Int? {
            BatteryReader.chargePercent(current: current, max: IOKitHelpers.signedInt(root("MaxCapacity")))
        }

        func root(_ key: String) -> Any? {
            if let cached = rootCache[key] { return cached }
            let value: Any? = IOKitHelpers.property(service, key, as: AnyObject.self)
            rootCache[key] = .some(value)
            return value
        }

        func rootData(_ key: String) -> Any? {
            if rootDataCache == nil { rootDataCache = .some(root("BatteryData") as? NSDictionary) }
            return rootDataCache??[key]
        }

        func int(_ keys: String...) -> Int? {
            for key in keys {
                let value = IOKitHelpers.signedInt(packData?[key]) ?? IOKitHelpers.signedInt(root(key)) ?? IOKitHelpers.signedInt(rootData(key))
                if let value { return value }
            }
            return nil
        }

        func bool(_ key: String) -> Bool { (root(key) as? NSNumber)?.boolValue ?? false }
        func minutes(_ key: String) -> Int? { int(key).flatMap { $0 == 65535 || $0 < 0 ? nil : $0 } } // 65535 = calculating

        func adapter(external: Bool) -> PowerAdapterInfo? {
            guard external, let details = root("AdapterDetails") as? NSDictionary, details.count > 0 else { return nil }
            return PowerAdapterInfo(name: details["Name"] as? String,
                                    watts: IOKitHelpers.signedInt(details["Watts"]),
                                    voltage_mV: IOKitHelpers.signedInt(details["AdapterVoltage"]),
                                    current_mA: IOKitHelpers.signedInt(details["Current"]),
                                    isWireless: (details["IsWireless"] as? NSNumber)?.boolValue ?? false)
        }
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
        for child in IOKitHelpers.children(entry) { visit(child) }
    }

    private func visit(_ child: io_registry_entry_t) {
        switch IOKitHelpers.className(child) {
        case "AppleSmartBatteryPack":
            if pack == 0 { pack = child; walk(child); return }
        case "AppleSmartBatteryBank":
            banks.append(child); return                           // cells below a bank carry no voltage
        default:
            break
        }
        IOObjectRelease(child)
    }

    private func releaseHandles() {
        for b in banks { IOObjectRelease(b) }
        banks = []
        if pack != 0 { IOObjectRelease(pack); pack = 0 }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }
}
