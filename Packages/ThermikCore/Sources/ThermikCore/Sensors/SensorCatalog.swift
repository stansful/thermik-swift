// SensorCatalog.swift — Thermik (MIT). OWNER: Unit 1. Per-chip DB ∩ hardware, plus heuristics (SPEC §2.5.2 step 3–7, §3.2).
//
// Lookup is by IORegistry `platform-name` ("t6041"); Intel loads `intel.json`. A DB entry whose key the hardware does not
// expose is skipped silently, so one file covers the 14", 16" and desktop variants of a SoC. Present keys the DB does
// not list get a heuristic descriptor (Heuristics.swift). Roles `peakHold`, `reference` and `unused` never enter the
// inventory — DB-described or heuristic — so `Tf06…Tf46` can never feed a maximum, an alert or the safety set.
//
// Headline key lists (schema 1, `headline` object) may use two conventions, needed by `intel.json` (§3.4 chains):
//  * `"|"` separates fallback tiers: the first tier with at least one present key wins
//    (`["TC#C", "|", "TC0P", "|", "TC0D"]` = the cores, else proximity, else die);
//  * `?` matches any character and `#` a decimal digit inside a 4-character SMC key (`TC#C` = TC0C…TC9C).
// Lists without either (all of t6041.json) are plain key lists.
import Foundation
import os
import ThermikSMC

package struct SensorCatalog: Sendable {
    /// What the hardware exposes (filled by the sampler, or by the probe's `discover`).
    package struct Hardware: Sendable {
        package var platform: String
        package var isAppleSilicon: Bool
        /// Present temperature candidates in `#KEY` enumeration order: key → SMC type ("flt ", "ioft", "sp78").
        package var smcTemperatureKeys: [(key: String, type: String)]
        package var hidProducts: Set<String>
        /// One read of the heuristic safe-group keys (optional): an exact 0 / NaN there means "not fitted on this SKU"
        /// (e.g. `TH1a/b` without a second SSD), so the key starts hidden instead of showing "—" forever.
        package var initialValues: [String: Double] = [:]

        package init(platform: String, isAppleSilicon: Bool, smcTemperatureKeys: [(key: String, type: String)],
                     hidProducts: Set<String>, initialValues: [String: Double] = [:]) {
            self.platform = platform; self.isAppleSilicon = isAppleSilicon; self.smcTemperatureKeys = smcTemperatureKeys
            self.hidProducts = hidProducts; self.initialValues = initialValues
        }
    }

    package let status: CatalogStatus
    package let database: ChipSensorDatabase?
    package let sensors: [Sensor]
    package let headline: [HeadlineSet: [SensorID]]
    package let safetySet: [SensorID]
    package let dieLayout: [DieLayoutPoint]
    package let fanNames: [String]?

    private static let log = Logger(subsystem: "app.thermik.Thermik", category: "sensors")

    // MARK: Database loading

    /// `Bundle.module` resource `<platform>.json` (resources are flattened; the subdirectory lookup is a fallback for
    /// toolchains that keep the folder). Returns nil when absent, unreadable or for another platform / schema.
    package static func loadDatabase(platform: String) -> ChipSensorDatabase? {
        guard !platform.isEmpty, platform.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        guard let url = Bundle.module.url(forResource: platform, withExtension: "json")
                ?? Bundle.module.url(forResource: platform, withExtension: "json", subdirectory: "SensorDB") else { return nil }
        do {
            let db = try JSONDecoder().decode(ChipSensorDatabase.self, from: Data(contentsOf: url))
            guard db.schema == 1, db.platform == platform else {
                log.error("sensor DB \(platform, privacy: .public): schema \(db.schema, privacy: .public) / platform mismatch, ignored")
                return nil
            }
            return db
        } catch {
            log.error("sensor DB \(platform, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Catalog file to try for an identity: `platform-name`, or `intel` on Intel Macs.
    package static func databaseName(for identity: ChipIdentity) -> String { identity.isAppleSilicon ? identity.platformName : "intel" }

    /// Collects the catalog inputs from an open SMC provider and the HID product list. Reads every undescribed
    /// safe-group key once (none on t6041) so keys not fitted on this SKU start hidden.
    package static func hardware(provider: SMCSensorProvider?, hidProducts: Set<String>, identity: ChipIdentity,
                                 database: ChipSensorDatabase?) -> Hardware {
        let platform = database?.platform ?? databaseName(for: identity)
        var hw = Hardware(platform: platform, isAppleSilicon: identity.isAppleSilicon,
                          smcTemperatureKeys: provider?.temperatureKeys.map { ($0.key.description, $0.info.type.description) } ?? [],
                          hidProducts: hidProducts)
        guard let provider else { return hw }
        let described = Set(database?.sensors.map(\.key) ?? [])
        let probe = provider.temperatureKeys.map(\.key).filter {
            !described.contains($0.description)
                && Heuristics.safeGroups.contains(Heuristics.group(forKey: $0.description, appleSilicon: identity.isAppleSilicon))
        }
        provider.readPass(probe) { k, v, _ in hw.initialValues[k.description] = v }
        return hw
    }

    /// Schema-1 draft for contributors (`thermik-probe sensors discover`): this catalog's descriptors and headline,
    /// `verified: false`. Curate it, run a ≤ 60 s load test, then ship it as `<platform>.json` (§3.2).
    package func draftDatabase(identity: ChipIdentity, descriptors: [SensorDescriptor]? = nil,
                               headline: [HeadlineSet: [String]]? = nil, note: String) -> ChipSensorDatabase {
        let h = headline ?? self.headline.mapValues { $0.map(Self.databaseKey) }
        return ChipSensorDatabase(schema: 1, platform: identity.isAppleSilicon ? identity.platformName : "intel",
                                  chip: identity.chipName, verified: false, observedOn: [identity.modelIdentifier], note: note,
                                  headline: Dictionary(uniqueKeysWithValues: h.map { ($0.key.rawValue, $0.value) }),
                                  sensors: descriptors ?? sensors.map(\.descriptor), dieLayout: nil, fanNames: nil, fanNamesRu: nil)
    }

    /// SensorID → DB key ("Tp01", "hid:PMU tdie1").
    package static func databaseKey(_ id: SensorID) -> String { id.source == .hid ? "hid:\(id.key)" : id.key }

    // MARK: Resolution

    /// `database == nil` → pure heuristics (unknown chip, or `discover`, which ignores the bundled DB on purpose).
    package init(database: ChipSensorDatabase?, hardware hw: Hardware) {
        self.database = database
        let smcType = Dictionary(hw.smcTemperatureKeys.map { ($0.key, $0.type) }, uniquingKeysWith: { a, _ in a })
        let hasDieKeys = Heuristics.hasSMCDieKeys(smcType.keys)
        var described = Set<String>()
        var chosen: [(SensorDescriptor, heuristic: Bool)] = []

        // 1. DB descriptors in DB order, present keys only.
        for d in database?.sensors ?? [] {
            guard described.insert(d.key).inserted else { continue }            // tolerate a duplicated DB key
            let present = d.key.hasPrefix("hid:") ? hw.hidProducts.contains(String(d.key.dropFirst(4))) : smcType[d.key] != nil
            if present && !d.role.isNeverShown { chosen.append((d, false)) }
        }
        // 2. Present SMC keys the DB does not describe, by key.
        let undescribed = hw.smcTemperatureKeys.map(\.key).filter { !described.contains($0) }.sorted { FourCC($0) < FourCC($1) }
        for key in undescribed {
            var d = Heuristics.descriptor(forSMCKey: key, appleSilicon: hw.isAppleSilicon, hasDatabase: database != nil,
                                          platform: hw.platform)
            if d.visible, let v = hw.initialValues[key], !v.isFinite || v == 0 { d.visible = false }
            if !d.role.isNeverShown { chosen.append((d, true)) }
        }
        // 3. HID products the DB does not describe: HID die sensors when the chip has no SMC die keys (M1/M2 layouts);
        //    with no DB at all, every product (hidden unless it is the die fallback).
        let dieFallback = hw.isAppleSilicon && !hasDieKeys
        for product in hw.hidProducts.sorted() where !described.contains("hid:\(product)") {
            guard database == nil || (dieFallback && Heuristics.isHIDDieProduct(product)) else { continue }
            let d = Heuristics.descriptor(forHIDProduct: product, dieFallback: dieFallback)
            if !d.role.isNeverShown { chosen.append((d, true)) }
        }

        // Ids must be unique: the app indexes the inventory by SensorID (a repeated #KEY entry would otherwise crash it).
        var ids = Set<SensorID>()
        chosen = chosen.filter { ids.insert(SensorID(databaseKey: $0.0.key)).inserted }
        sensors = chosen.map { d, heuristic in
            Sensor(id: SensorID(databaseKey: d.key), quantity: .temperature, descriptor: d,
                   smcType: d.key.hasPrefix("hid:") ? nil : smcType[d.key], isHeuristic: heuristic)
        }

        // 4. Headline sets.
        let inventoryKeys = chosen.map(\.0.key)
        var resolved: [HeadlineSet: [String]] = [:]
        if let db = database {
            for set in HeadlineSet.allCases {
                let keys = Self.resolve(db.headlineKeys(set), available: inventoryKeys)
                if !keys.isEmpty { resolved[set] = keys }
            }
            // A DB written for SMC die keys on a sibling without them: fall back to the heuristic HID die sets.
            if dieFallback {
                let h = Heuristics.headline(for: chosen.map(\.0), appleSilicon: true)
                for set in [HeadlineSet.cpu, .cpuHotspot, .gpu, .soc] where resolved[set] == nil { resolved[set] = h[set] }
            }
        } else {
            resolved = Heuristics.headline(for: chosen.map(\.0), appleSilicon: hw.isAppleSilicon)
        }
        let headline = resolved.compactMapValues { keys -> [SensorID]? in
            let ids = keys.map(SensorID.init(databaseKey:))
            return ids.isEmpty ? nil : ids
        }
        self.headline = headline

        // 5. Safety set: DB `safety`, else cpuHotspot ∪ gpu (26 keys on M4 Max).
        var safety = headline[.safety] ?? ((headline[.cpuHotspot] ?? []) + (headline[.gpu] ?? []))
        var seen = Set<SensorID>()
        safety = safety.filter { seen.insert($0).inserted }
        safetySet = safety

        let present = Set(inventoryKeys)
        dieLayout = (database?.dieLayout ?? []).filter { present.contains($0.key) }
        fanNames = database?.fanNames

        if let db = database {
            status = db.verified ? .verified(platform: db.platform) : .unverified(platform: db.platform)
        } else {
            status = .heuristic(platform: hw.platform)
        }
    }

    // MARK: Headline key expressions

    /// Expands tiers (`|`) and wildcards (`?` any character, `#` digit) against the inventory keys (inventory order).
    package static func resolve(_ entries: [String], available: [String]) -> [String] {
        var tiers: [[String]] = [[]]
        for e in entries { if e == "|" { tiers.append([]) } else { tiers[tiers.count - 1].append(e) } }
        let availableSet = Set(available)
        for tier in tiers {
            var out: [String] = []
            var seen = Set<String>()
            for pattern in tier {
                let matches: [String]
                if pattern.contains("?") || pattern.contains("#") {
                    matches = available.filter { matchesPattern($0, pattern) }
                } else {
                    matches = availableSet.contains(pattern) ? [pattern] : []
                }
                for m in matches where seen.insert(m).inserted { out.append(m) }
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    package static func matchesPattern(_ key: String, _ pattern: String) -> Bool {
        guard key.count == pattern.count, !key.hasPrefix("hid:") else { return false }
        return zip(key, pattern).allSatisfy { k, p in
            switch p {
            case "?": return true
            case "#": return k.isASCII && k.isNumber
            default: return k == p
            }
        }
    }
}
