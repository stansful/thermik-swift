// SMCSensorProvider.swift — Thermik (MIT). OWNER: Unit 1. READ-ONLY SMC side of the sensor sampler (SPEC §2.5.2/§2.5.3).
//
// Wraps one `SMCConnection` (ThermikSMC: thread-safe, read path only — the app links no SMC write code).
// Measured on M4 Max / macOS 27 (SENS §2.6): enumerating 3512 keys + key info of the ≈ 400 `T*` keys ≈ 11 ms;
// one key read ≈ 0.16–0.25 ms (IOKit mailbox round trip), so a tick reads only what the request names.
// Confined to the `SensorSampler` actor; the probe uses its own instance.
import Foundation
import ThermikSMC

package final class SMCSensorProvider {
    package let connection: SMCConnection
    /// `#KEY` (3512 on M4 Max).
    package private(set) var keyCount = 0
    /// Every key name, from index enumeration at discovery (presence checks without round trips).
    package private(set) var allKeys: Set<FourCC> = []
    /// Temperature candidates in enumeration order with their key info.
    package private(set) var temperatureKeys: [(key: FourCC, info: SMCKeyInfo)] = []
    /// Power keys present on this Mac (subset of PSTR, PDTR, PPBR, PHPC, PCPC).
    package private(set) var powerKeys: Set<FourCC> = []

    package static let powerCandidates: [FourCC] = ["PSTR", "PDTR", "PPBR", "PHPC", "PCPC"]

    package init() throws { connection = try SMCConnection() }

    /// Enumerates `#KEY` once and keeps the temperature candidates (§2.5.2 step 2): `T*` keys of type `flt `, `ioft`
    /// or any 2-byte fixed-point `spXY` / `fpXY`. Excludes integer indices such as `TVDi`/`TVMi`/`TVVi` (si32).
    package func discover() throws {
        keyCount = try connection.keyCount()
        let keys = try connection.allKeys()
        allKeys = Set(keys)
        temperatureKeys = keys.compactMap { k in
            guard k.rawValue >> 24 == UInt32(UInt8(ascii: "T")), let info = try? connection.keyInfo(k),
                  info.isReadable, Self.isTemperatureType(info) else { return nil }
            return (k, info)
        }
        powerKeys = Set(Self.powerCandidates.filter { allKeys.contains($0) })
    }

    package static func isTemperatureType(_ info: SMCKeyInfo) -> Bool {
        if info.type == .flt { return info.size == 4 }
        if info.type == .ioft { return info.size == 8 }
        let c = Array(info.type.description)
        guard info.size == 2, c.count == 4, c[0] == "s" || c[0] == "f", c[1] == "p",
              c[2].hexDigitValue != nil, c[3].hexDigitValue != nil else { return false }
        return true
    }

    /// One decoded reading (nil when the key is missing / unreadable / not numeric). Errors other than a lost
    /// connection are swallowed per key (§2.5.3: "failures on a single key are omitted").
    package enum ReadResult {
        case value(Double, bytes: [UInt8])
        case failed
        case connectionLost
    }

    package func read(_ key: FourCC) -> ReadResult {
        do {
            let (info, bytes) = try connection.readRaw(key)
            guard let v = SMCCodec.decode(bytes, as: info).doubleValue else { return .failed }
            return .value(v, bytes: bytes)
        } catch let e as SMCError where e.isConnectionLost {
            return .connectionLost
        } catch {
            return .failed
        }
    }

    /// Reads `keys` in order. On a lost connection (sleep/wake, SMC restart): reconnect once, retry that key once,
    /// then give up for the rest of this pass (§2.5.3). `body` receives every successfully decoded value.
    /// Returns false when the pass was abandoned.
    @discardableResult
    package func readPass(_ keys: [FourCC], _ body: (FourCC, Double, [UInt8]) -> Void) -> Bool {
        var reconnected = false
        for k in keys {
            switch read(k) {
            case .value(let v, let b): body(k, v, b)
            case .failed: continue
            case .connectionLost:
                guard !reconnected else { return false }
                reconnected = true
                guard (try? connection.reconnect()) != nil else { return false }
                switch read(k) {
                case .value(let v, let b): body(k, v, b)
                case .failed: continue
                case .connectionLost: return false
                }
            }
        }
        return true
    }

    /// `PSTR`, `PDTR`, `PPBR`, `PHPC` (W, flt on Apple Silicon); Intel has `PCPC` (CPU package) instead of `PHPC`.
    package func power() -> PowerValues {
        var w: [FourCC: Double] = [:]
        readPass(Self.powerCandidates.filter { powerKeys.contains($0) }) { k, v, _ in
            if v.isFinite, abs(v) < 2_000 { w[k] = v }
        }
        return PowerValues(systemTotalW: w["PSTR"], dcInW: w["PDTR"], batteryW: w["PPBR"], socW: w["PHPC"] ?? w["PCPC"])
    }

    /// Re-open if the connection was lost while asleep. A cheap probe read decides.
    package func reopenIfNeeded() {
        do { _ = try connection.keyCount() }
        catch let e as SMCError where e.isConnectionLost { try? connection.reconnect() }
        catch {}
    }
}
