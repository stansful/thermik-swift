// HIDSensorProvider.swift — Thermik (MIT). OWNER: Unit 1. READ-ONLY IOHIDEventSystem temperature reader (SPEC §2.5.2/5).
//
// Facts used (SENS §3, verified on M4 Max / macOS 27):
//  * only the FULL client (`IOHIDEventSystemClientCreate`, private SPI declared in CThermikSPI) returns events; the
//    public simple client enumerates the same services but `IOHIDServiceClientCopyEvent` returns NULL on it;
//  * temperature services match PrimaryUsagePage 0xff00 (kHIDPage_AppleVendor) / PrimaryUsage 5 (TemperatureSensor);
//    the value is `IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature = 15))`
//    (constants from Apple's open-source IOHIDFamily, APSL 2.0);
//  * PMU services appear twice (two registry entries, same Product + LocationID, values differ by ≤ 1.6 °C):
//    they are merged by (Product, LocationID) with the mean of the instances, then per Product;
//  * `als-temp` returns NaN (no event) and power sensors on 0xff08 are implausible: neither is used;
//  * a full pass over 46 services costs ≈ 54 ms, so the sampler reads HID at most every 5 s and only the
//    products that were requested.
// Every call is failure-tolerant: a missing SPI result simply yields no value (R8).
import Foundation
import IOKit
import CThermikSPI

/// One HID temperature service instance (diagnostics / discovery).
package struct HIDServiceInfo: Sendable, Hashable {
    package let product: String
    /// For SMC-backed services this is an internal FourCC ('TP1b', 'TG0B'); 0 for others.
    package let locationID: UInt32
    package let registryID: UInt64

    package var locationFourCC: String {
        let b = [24, 16, 8, 0].map { UInt8((locationID >> UInt32($0)) & 0xFF) }
        return b.allSatisfy { (0x20...0x7E).contains($0) } ? String(decoding: b, as: UTF8.self) : ""
    }
}

/// Owns one full IOHIDEventSystemClient. Not Sendable: confined to the `SensorSampler` actor (or to one probe task).
package final class HIDSensorReader {
    package enum Kind {
        case temperature
        var usagePage: Int { 0xff00 }                 // kHIDPage_AppleVendor
        var usage: Int { 5 }                          // kHIDUsage_AppleVendor_TemperatureSensor
        var eventType: Int64 { 15 }                   // kIOHIDEventTypeTemperature
        var field: UInt32 { UInt32(eventType) << 16 } // IOHIDEventFieldBase(type)
    }

    private let client: IOHIDEventSystemClient
    private let kind: Kind
    /// Product → its service instances (several per product: duplicated PMU dispatchers, 6 gas-gauge cells).
    private var services: [String: [(info: HIDServiceInfo, service: IOHIDServiceClient)]] = [:]

    package init?(kind: Kind) {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        client = c
        self.kind = kind
        let matching = ["PrimaryUsagePage": kind.usagePage, "PrimaryUsage": kind.usage] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(c, matching)
        refresh()
    }

    /// Re-enumerate services (after wake; services can also appear late after boot). Cheap (≈ 2 ms).
    package func refresh() {
        let list = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        var byProduct: [String: [(info: HIDServiceInfo, service: IOHIDServiceClient)]] = [:]
        for s in list {
            guard let product = IOHIDServiceClientCopyProperty(s, "Product" as CFString) as? String,
                  !product.isEmpty else { continue }
            let loc = (IOHIDServiceClientCopyProperty(s, "LocationID" as CFString) as? NSNumber)?.uint32Value ?? 0
            let rid = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value ?? 0
            byProduct[product, default: []].append((HIDServiceInfo(product: product, locationID: loc, registryID: rid), s))
        }
        services = byProduct
    }

    /// Product names currently present (one entry per product, whatever the instance count).
    package var products: Set<String> { Set(services.keys) }

    /// Every service instance (probe output).
    package var serviceInfos: [HIDServiceInfo] { services.values.flatMap { $0.map(\.info) } }

    /// One value per requested product: mean per (Product, LocationID) over instances with a finite value, then the
    /// mean across LocationIDs. Products without any finite reading are omitted.
    package func read(products wanted: some Sequence<String>) -> [String: Double] {
        var out: [String: Double] = [:]
        for product in wanted {
            guard let instances = services[product] else { continue }
            var perLocation: [UInt32: (sum: Double, n: Int)] = [:]
            for (info, service) in instances {
                guard let v = value(service), v.isFinite else { continue }
                let acc = perLocation[info.locationID] ?? (0, 0)
                perLocation[info.locationID] = (acc.sum + v, acc.n + 1)
            }
            guard !perLocation.isEmpty else { continue }
            let means = perLocation.values.map { $0.sum / Double($0.n) }
            out[product] = means.reduce(0, +) / Double(means.count)
        }
        return out
    }

    /// Raw per-instance readings (probe snapshot / discovery). NaN is kept so the probe can show it.
    package func readAllInstances() -> [(HIDServiceInfo, Double)] {
        services.values.flatMap { $0 }.compactMap { (info, s) in value(s).map { (info, $0) } }
    }

    private func value(_ service: IOHIDServiceClient) -> Double? {
        guard let event = IOHIDServiceClientCopyEvent(service, kind.eventType, 0, 0) else { return nil }
        return IOHIDEventGetFloatValue(event, kind.field)
    }
}
