// NVMeSMART.swift — Thermik (MIT). OWNER: Unit 2.
// NVMe SMART / Health log (log page 0x02) via the public NVMeSMARTLib.plugin CFPlugIn
// (SDK header IOKit/storage/nvme/NVMeSMARTLibExternal.h, imported through CThermikSPI; SYS §6.1).
// No root needed (verified on M4 Max / macOS 27.0.1, APPLE SSD AP1024Z). The drive SERIAL is never read (PII).
import CThermikSPI
import Foundation
import IOKit

enum NVMeSMARTReader {
    // The CFUUID macros of the header cannot be imported into Swift → defined by hand (same bytes as the SDK).
    // CFUUID constants are immutable, process-lifetime singletons → safe to share across threads.
    nonisolated(unsafe) private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)!   // kIOCFPlugInInterfaceID
    // CFUUID constant (immutable, process lifetime) → safe to share.
    nonisolated(unsafe) private static let smartUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)!   // kIONVMeSMARTUserClientTypeID
    // CFUUID constant (immutable, process lifetime) → safe to share.
    nonisolated(unsafe) private static let smartInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)!   // kIONVMeSMARTInterfaceID

    /// ~4 ms per drive including the plug-in setup. Poll every 60 s: SSD temperature changes slowly.
    /// Drives without the SMART user client (external USB/Thunderbolt enclosures) are simply not listed.
    static func readAll() -> [NVMeHealth] {
        let match = [kIOPropertyMatchKey: [kIOPropertyNVMeSMARTCapableKey: true]] as NSDictionary
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match as CFDictionary, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [NVMeHealth] = []
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            if let h = read(service: svc) { out.append(h) }
        }
        return out
    }

    private static func read(service svc: io_service_t) -> NVMeHealth? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(svc, smartUserClientTypeID, plugInInterfaceID, &plugin, &score) == kIOReturnSuccess,
              let plugin, let pv = plugin.pointee?.pointee else { return nil }
        defer { _ = pv.Release(plugin) }
        var raw: LPVOID?
        guard pv.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterfaceID), &raw) == S_OK, let raw else { return nil }
        let smart = raw.assumingMemoryBound(to: UnsafeMutablePointer<IONVMeSMARTInterface>.self)
        defer { _ = smart.pointee.pointee.Release(raw) }
        let iface = smart.pointee.pointee

        var d = NVMeSMARTData()
        guard iface.SMARTReadData(raw, &d) == kIOReturnSuccess else { return nil }

        var model: String?, firmware: String?
        let identify = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        defer { identify.deallocate() }
        if iface.GetIdentifyData(raw, identify, 0) == kIOReturnSuccess {
            let c = identify.assumingMemoryBound(to: NVMeIdentifyControllerStruct.self).pointee
            model = text(c.MODEL_NUMBER)
            firmware = text(c.FW_REVISION)
            // c.SERIAL_NUMBER is deliberately never touched (PII).
        }
        let bsd = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "BSD Name" as CFString, nil,
                                                  IOOptionBits(kIORegistryIterateRecursively)) as? String
        // 128-bit counters are imported as (lo, hi) tuples; hi is 0 for any realistic drive.
        // One data unit = 1000 × 512 bytes (NVMe 1.4 §5.14.1.2). Temperature is the composite value in kelvin.
        return NVMeHealth(bsdName: bsd, model: model, firmware: firmware,
                          temperatureC: Int(d.TEMPERATURE) - 273,
                          criticalWarning: d.CRITICAL_WARNING,
                          availableSparePercent: Int(d.AVAILABLE_SPARE),
                          availableSpareThresholdPercent: Int(d.AVAILABLE_SPARE_THRESHOLD),
                          percentageUsed: Int(d.PERCENTAGE_USED),
                          dataReadBytes: Double(d.DATA_UNITS_READ.0) * 512_000,
                          dataWrittenBytes: Double(d.DATA_UNITS_WRITTEN.0) * 512_000,
                          powerCycles: d.POWER_CYCLES.0,
                          powerOnHours: d.POWER_ON_HOURS.0,
                          unsafeShutdowns: d.UNSAFE_SHUTDOWNS.0,
                          mediaErrors: d.MEDIA_ERRORS.0,
                          errorLogEntries: d.NUM_ERROR_INFO_LOG_ENTRIES.0)
    }

    /// Fixed-width, space-padded ASCII field of the Identify Controller structure.
    private static func text<T>(_ field: T) -> String? {
        let s = withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
