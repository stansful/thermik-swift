// Heuristics.swift — Thermik (MIT). OWNER: Unit 1. Descriptors for keys that no per-chip database describes (SPEC §3.3).
//
// Used (1) for every key of a Mac without `<platform>.json`, (2) for keys that a DB does not list (new firmware, other
// SKU of the same SoC), and (3) by `thermik-probe sensors discover`, which also runs the P1 detectors at the bottom.
// Key-name facts: Apple-Silicon prefixes verified on M4 Max (SENS §4.2); Intel conventions from VirtualSMC
// `SMCSensorKeys.txt` (BSD-3-Clause); per-generation hints from exelban/Stats `values.swift` (MIT) — facts only, and
// used only to NAME / GROUP keys, never as truth for which keys exist (the public tables disagree with hardware).
import Foundation
import ThermikSMC

package enum Heuristics {

    // MARK: Grouping (first match wins)

    /// SPEC §3.3 table. Case-sensitive prefixes: `Ts0P` (palm rest) ≠ `TS0P` (SSD proximity).
    static let appleSiliconRules: [(prefix: String, group: SensorGroup)] = [
        ("Tpx", .cpuAggregate), ("Tex", .cpuAggregate), ("TCM", .cpuAggregate), ("TCD", .cpuAggregate),
        ("Tp", .cpuPerformance), ("Te", .cpuEfficiency), ("Tg", .gpu), ("Tf", .socFabric),
        ("Ts0P", .enclosure), ("Ts1P", .enclosure), ("Tsx", .soc), ("Ts", .soc),
        ("Tm", .memory), ("TVM", .memory), ("TVm", .memory), ("TVh", .memory), ("TMVR", .memory),
        ("TB", .battery), ("TG0", .battery), ("TG1", .battery), ("TG2", .battery),
        ("TH", .storage), ("TN", .storage), ("TS0P", .storage),
        ("TW", .wireless), ("TR", .wireless),
        ("TaLT", .ports), ("TaRT", .ports), ("TaL", .airflow), ("TaR", .airflow), ("TaTP", .airflow),
        ("TAOL", .enclosure),
        ("TPD", .powerDelivery), ("TPMP", .powerDelivery), ("TPSP", .powerDelivery), ("TCHP", .powerDelivery),
        ("TSVR", .powerDelivery), ("TSWR", .powerDelivery), ("TSXR", .powerDelivery),
        ("TD", .board), ("TV", .virtual),
    ]

    /// Intel (VirtualSMC conventions): 2nd letter = component. `intel.json` names the common keys; this covers the rest.
    static let intelRules: [(prefix: String, group: SensorGroup)] = [
        ("TCG", .gpu),                                       // TCGC: integrated GPU (PECI)
        ("TC", .cpuPerformance), ("TG", .gpu), ("TM", .memory), ("TB", .battery), ("TH", .storage),
        ("TW", .wireless), ("Ts", .enclosure), ("TA", .enclosure), ("Tp", .powerDelivery), ("TN", .soc),
        ("TP", .soc), ("TI", .ports), ("TL", .board), ("Tm", .board), ("Th", .board),
    ]

    package static func group(forKey key: String, appleSilicon: Bool) -> SensorGroup {
        for (p, g) in (appleSilicon ? appleSiliconRules : intelRules) where key.hasPrefix(p) { return g }
        return .other
    }

    /// Roles that can be told from the name alone. Everything else is a `probe` until a detector says otherwise.
    static func role(forKey key: String, group: SensorGroup, appleSilicon: Bool) -> SensorRole {
        let c = Array(key)
        guard c.count == 4 else { return .probe }
        if appleSilicon {
            if key.hasPrefix("Tf"), c[3] == "6" { return .peakHold }          // Tf?6: running max since boot (SENS R11)
            if key == "TCMb" { return .average }
            if key == "TCMz" { return .maximum }
            if key.hasPrefix("Tpx") || key.hasPrefix("Tex") || key.hasPrefix("Tsx") { return .maximum }  // firmware aggregates
            // TCDX, TPDX, TRDX: legacy "X = max". Not in the indexed die families, where `Tp0X` is just probe index X.
            if c[3] == "X", c[2].isLetter, !["Tp", "Te", "Tg", "Tf", "Ts"].contains(String(key.prefix(2))) { return .maximum }
            return .probe
        }
        if c[3] == "X" || key == "TCXC" { return .maximum }                     // TCXC: package max (PECI)
        if key.hasPrefix("TC"), c[3] == "c" { return .duplicate }                // TC0c…: raw (uncooked) core copies
        return .probe
    }

    /// Groups whose heuristic keys are visible by default (§2.5.2 step 3): ambient-like, cannot mislead a headline.
    package static let safeGroups: Set<SensorGroup> = [.battery, .storage, .wireless, .enclosure, .airflow, .ports]

    /// Default visibility of a heuristic key. With a DB present only the safe groups are shown; without one (P0) the
    /// CPU/GPU probes are shown too, until the offset detector (P1, `discover`) has picked the calibrated keys.
    static func isVisible(group: SensorGroup, role: SensorRole, hasDatabase: Bool) -> Bool {
        if role.isNeverShown || role == .duplicate { return false }
        if safeGroups.contains(group) { return true }
        if hasDatabase { return false }
        return group == .cpuPerformance || group == .cpuEfficiency || group == .gpu
    }

    // MARK: Descriptors

    package static func descriptor(forSMCKey key: String, appleSilicon: Bool, hasDatabase: Bool, platform: String) -> SensorDescriptor {
        let hint = appleSilicon ? generationHint(platform: platform, key: key) : nil
        let group = hint?.group ?? group(forKey: key, appleSilicon: appleSilicon)
        let role = role(forKey: key, group: group, appleSilicon: appleSilicon)
        let known = wellKnownNames[key]
        let name = known?.en ?? "\(hint?.en ?? label(group).en) \(key)"
        let nameRu = known?.ru ?? "\(hint?.ru ?? label(group).ru) \(key)"
        // The die average / hotspot keep their meaning across generations (SENS §4.2): show them without a DB too.
        let wellKnownDie = !hasDatabase && appleSilicon && (key == "TCMb" || key == "TCMz")
        return SensorDescriptor(key: key, name: name, nameRu: nameRu, group: group, role: role, cluster: nil,
                                visible: wellKnownDie || isVisible(group: group, role: role, hasDatabase: hasDatabase),
                                invalidValues: nil)
    }

    /// HID product → descriptor (heuristic catalogs and the `*MTR*` die fallback, SENS §3.3).
    /// `dieFallback`: the chip has no SMC die keys, so HID die sensors are the CPU/GPU source and are shown.
    package static func descriptor(forHIDProduct product: String, dieFallback: Bool) -> SensorDescriptor {
        let n = trailingNumber(product)
        let suffix = n.map { " \($0)" } ?? ""
        let (group, role, en, ru): (SensorGroup, SensorRole, String, String)
        switch product {
        case let p where p.hasPrefix("pACC MTR"): (group, role, en, ru) = (.cpuPerformance, .probe, "P-cluster die\(suffix)", "P-кластер, кристалл\(suffix)")
        case let p where p.hasPrefix("eACC MTR"): (group, role, en, ru) = (.cpuEfficiency, .probe, "E-cluster die\(suffix)", "E-кластер, кристалл\(suffix)")
        case let p where p.hasPrefix("GPU MTR"):  (group, role, en, ru) = (.gpu, .probe, "GPU die\(suffix)", "ГП, кристалл\(suffix)")
        case let p where p.hasPrefix("SOC MTR"), let p where p.hasPrefix("PMGR SOC Die"):
            (group, role, en, ru) = (.soc, .probe, "SoC die\(suffix)", "Кристалл SoC\(suffix)")
        case let p where p.hasPrefix("ANE MTR"):  (group, role, en, ru) = (.soc, .probe, "Neural Engine\(suffix)", "Neural Engine\(suffix)")
        case let p where p.hasPrefix("ISP MTR"):  (group, role, en, ru) = (.soc, .probe, "Image processor\(suffix)", "Обработчик изображений\(suffix)")
        case let p where p.contains("tcal"):      (group, role, en, ru) = (.powerDelivery, .reference, "PMU calibration", "PMU, эталон")
        case let p where p.contains("tdie"):      (group, role, en, ru) = (.powerDelivery, .probe, "PMU die\(suffix)", "Кристалл PMU\(suffix)")
        case let p where p.contains("tdev"):      (group, role, en, ru) = (.powerDelivery, .probe, "PMU sensor\(suffix)", "Датчик PMU\(suffix)")
        case let p where p.hasPrefix("gas gauge"): (group, role, en, ru) = (.battery, .duplicate, "Battery gas gauge", "Контроллер АКБ")
        case let p where p.hasPrefix("NAND"):     (group, role, en, ru) = (.storage, .probe, "SSD NAND\(suffix)", "SSD NAND\(suffix)")
        default:                                  (group, role, en, ru) = (.other, .probe, product, product)
        }
        let isDie = [.cpuPerformance, .cpuEfficiency, .gpu].contains(group) || product.contains("SOC")
        return SensorDescriptor(key: "hid:\(product)", name: "\(en) (HID)", nameRu: "\(ru) (HID)", group: group, role: role,
                                cluster: nil, visible: dieFallback && isDie && !role.isNeverShown, invalidValues: nil)
    }

    /// True for HID die products that replace missing SMC die keys (M1/M2 layouts).
    static func isHIDDieProduct(_ product: String) -> Bool {
        ["pACC MTR", "eACC MTR", "GPU MTR", "SOC MTR", "PMGR SOC Die"].contains { product.hasPrefix($0) }
    }

    /// Chip has SMC die keys (the M3+ / M4 layout). Without them HID `*MTR*` products are the CPU/GPU source.
    package static func hasSMCDieKeys(_ keys: some Sequence<String>) -> Bool {
        keys.contains { $0.hasPrefix("Tp") || $0.hasPrefix("Te") || $0.hasPrefix("Tg") }
    }

    // MARK: Headline sets for heuristic catalogs (DB-format keys; §3.3 "Heuristic headline sets")

    /// `descriptors` are the present heuristic descriptors in inventory order (SMC and `hid:`).
    package static func headline(for descriptors: [SensorDescriptor], appleSilicon: Bool) -> [HeadlineSet: [String]] {
        func keys(_ f: (SensorDescriptor) -> Bool) -> [String] { descriptors.filter { !$0.role.isNeverShown && f($0) }.map(\.key) }
        func first(_ candidates: [String]) -> [String] {
            let present = Set(descriptors.map(\.key))
            return candidates.first { present.contains($0) }.map { [$0] } ?? []
        }
        var h: [HeadlineSet: [String]] = [:]
        if appleSilicon {
            let smc = { (d: SensorDescriptor) in !d.key.hasPrefix("hid:") }
            let hid = { (d: SensorDescriptor) in d.key.hasPrefix("hid:") && isHIDDieProduct(String(d.key.dropFirst(4))) }
            // CPU: P0 = every Tp/Te probe (P1 `discover` narrows it to calibrated keys); hinted groups as fallback.
            var cpu = keys { smc($0) && ($0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te")) && $0.group != .cpuAggregate && $0.role.feedsAverages }
            if cpu.isEmpty { cpu = keys { smc($0) && ($0.group == .cpuPerformance || $0.group == .cpuEfficiency) && $0.role.feedsAverages } }
            if cpu.isEmpty { cpu = keys { hid($0) && ($0.group == .cpuPerformance || $0.group == .cpuEfficiency) } }
            // P1: once the offset detector found calibrated keys (discover), average only the shown ones.
            let byKey = Dictionary(descriptors.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            func narrowed(_ set: [String]) -> [String] {
                guard set.contains(where: { byKey[$0]?.role == .calibrated }) else { return set }
                return set.filter { byKey[$0]?.visible == true }
            }
            cpu = narrowed(cpu)
            h[.cpu] = cpu
            let aggregates = keys { smc($0) && ($0.key.hasPrefix("Tpx") || $0.key.hasPrefix("Tex")) }
            h[.cpuHotspot] = aggregates.isEmpty ? cpu : aggregates
            var gpu = keys { smc($0) && $0.key.hasPrefix("Tg") && $0.role.feedsAverages }
            if gpu.isEmpty { gpu = keys { smc($0) && $0.group == .gpu && $0.role.feedsAverages } }
            if gpu.isEmpty { gpu = keys { hid($0) && $0.group == .gpu } }
            h[.gpu] = narrowed(gpu)
            var soc = first(["TCMb"])
            if soc.isEmpty { soc = keys { smc($0) && $0.key.hasPrefix("Ts") && $0.group == .soc && !$0.key.hasPrefix("Tsx") && $0.role.feedsAverages } }
            if soc.isEmpty { soc = keys { hid($0) && $0.group == .soc } }
            h[.soc] = soc
            h[.battery] = first(["TB0T"])
            h[.ssd] = first(["TH0x", "TH0a"])
            var memory = first(["TVMR"])
            if memory.isEmpty { memory = keys { smc($0) && $0.key.hasPrefix("Tm") && $0.role.feedsAverages } }
            h[.memory] = memory
        } else {
            // Intel without intel.json entries (should not happen: intel.json ships). Same chains as §3.4.
            let cores = keys { $0.key.count == 4 && $0.key.hasPrefix("TC") && $0.key.hasSuffix("C") && Array($0.key)[2].isNumber }
            h[.cpu] = cores.isEmpty ? first(["TC0P", "TC0D"]) : cores
            h[.cpuHotspot] = first(["TCXC"]).isEmpty ? (cores.isEmpty ? first(["TC0D"]) : cores) : ["TCXC"]
            h[.gpu] = first(["TG0P", "TG0D", "TCGC"])
            h[.memory] = first(["TM0P"]); h[.ssd] = first(["TH0P", "TH0x"]); h[.battery] = first(["TB0T"])
        }
        return h.filter { !$0.value.isEmpty }
    }

    // MARK: Names

    /// Generic group labels for heuristic names ("GPU Tg0A" / "ГП Tg0A"); RU follows the §4.12 glossary.
    static func label(_ g: SensorGroup) -> (en: String, ru: String) {
        switch g {
        case .cpuPerformance: return ("CPU P-cluster", "ЦП, P-кластер")
        case .cpuEfficiency:  return ("CPU E-cluster", "ЦП, E-кластер")
        case .cpuFabric:      return ("CPU fabric", "ЦП, шина")
        case .cpuAggregate:   return ("CPU aggregate", "ЦП, агрегат")
        case .gpu:            return ("GPU", "ГП")
        case .gpuAggregate:   return ("GPU aggregate", "ГП, агрегат")
        case .socFabric:      return ("SoC fabric", "SoC, шина")
        case .soc:            return ("SoC", "SoC")
        case .memory:         return ("Memory", "Память")
        case .battery:        return ("Battery", "Аккумулятор")
        case .storage:        return ("Storage", "Накопитель")
        case .wireless:       return ("Wireless", "Беспроводная связь")
        case .enclosure:      return ("Enclosure", "Корпус")
        case .airflow:        return ("Airflow", "Воздушный поток")
        case .ports:          return ("Port", "Порт")
        case .powerDelivery:  return ("Power", "Питание")
        case .board:          return ("Board", "Плата")
        case .virtual:        return ("Virtual", "Виртуальный")
        case .other:          return ("Sensor", "Датчик")
        }
    }

    /// Keys whose meaning is stable across Apple Silicon generations (SENS §4.2/§4.3: present in every public table
    /// and verified on M4 Max). Names match t6041.json.
    static let wellKnownNames: [String: (en: String, ru: String)] = [
        "TB0T": ("Battery", "Аккумулятор"), "TB1T": ("Battery cell 1", "Аккумулятор, ячейка 1"),
        "TB2T": ("Battery cell 2", "Аккумулятор, ячейка 2"), "TH0x": ("SSD (NAND)", "SSD (NAND)"),
        "TH0a": ("SSD NAND A", "SSD NAND A"), "TH0b": ("SSD NAND B", "SSD NAND B"), "TS0P": ("SSD proximity", "Рядом с SSD"),
        "TW0P": ("Wi-Fi / Bluetooth", "Wi-Fi / Bluetooth"), "Ts0P": ("Palm rest", "Упор для запястий"),
        "Ts1P": ("Palm rest 2", "Упор для запястий 2"), "TAOL": ("Ambient (outside lid)", "Окружающая среда (снаружи)"),
        "TaLP": ("Airflow left", "Воздушный поток слева"), "TaRF": ("Airflow right", "Воздушный поток справа"),
        "TaLT": ("Thunderbolt left", "Thunderbolt слева"), "TaRT": ("Thunderbolt right", "Thunderbolt справа"),
        "TCMb": ("SoC die average", "Кристалл SoC, среднее"), "TCMz": ("SoC die hotspot", "Кристалл SoC, пик"),
        "TCDX": ("SoC die aggregate", "Кристалл SoC, агрегат"), "TVMR": ("Memory", "Память"),
        "TMVR": ("Memory voltage regulator", "Регулятор питания памяти"),
        "TCHP": ("Charger proximity", "Рядом с зарядным контроллером"), "TPMP": ("PMU proximity", "Рядом с PMU"),
        "TPDX": ("PMU die max", "Кристалл PMU, максимум"), "TPSP": ("Power supply proximity", "Рядом с блоком питания"),
    ]

    /// Per-generation naming hints (Stats `values.swift`, MIT; facts only). Platform IDs are the commonly known
    /// ones (SPEC §3.3) — they only select a hint table, so a wrong ID merely loses a name.
    private struct Hint { let group: SensorGroup; let en: String; let ru: String }
    private static func generationHint(platform: String, key: String) -> Hint? {
        let p = Hint(group: .cpuPerformance, en: "P-core", ru: "P-ядро")
        let e = Hint(group: .cpuEfficiency, en: "E-core", ru: "E-ядро")
        let g = Hint(group: .gpu, en: "GPU", ru: "ГП")
        let table: [String: Hint]
        func map(_ keys: String, _ h: Hint) -> [String: Hint] {
            Dictionary(uniqueKeysWithValues: keys.split(separator: " ").map { (String($0), h) })
        }
        switch platform {
        case "t8103", "t6000", "t6001", "t6002":                       // M1 family
            table = map("Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b", p).merging(map("Tp09 Tp0T", e)) { a, _ in a }
                .merging(map("Tg05 Tg0D Tg0L Tg0T", g)) { a, _ in a }
        case "t8112", "t6020", "t6021", "t6022":                       // M2 family
            table = map("Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j", p).merging(map("Tp1h Tp1t Tp1p Tp1l", e)) { a, _ in a }
                .merging(map("Tg0f Tg0j", g)) { a, _ in a }
        case "t8122", "t6030", "t6031", "t6032", "t6034":              // M3 family: CPU/GPU probes live under Tf
            table = map("Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E", p)
                .merging(map("Te05 Te0L Te0P Te0S", e)) { a, _ in a }
                .merging(map("Tf14 Tf18 Tf19 Tf1A Tf24 Tf28 Tf29 Tf2A", g)) { a, _ in a }
        case "t8132":                                                  // M4 (base)
            table = map("Te08 Te09 Te0A Te0G Te0H Te0I", e)
        case "t8142":                                                  // M5
            table = map("Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K", Hint(group: .cpuPerformance, en: "Super core", ru: "Супер-ядро"))
                .merging(map("Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y", p)) { a, _ in a }
                .merging(map("Tg0U Tg0X Tg0d Tg0g Tg0j Tg1Y Tg1c Tg1g", g)) { a, _ in a }
        default: return nil
        }
        return table[key]
    }

    private static func trailingNumber(_ s: String) -> Int? {
        let digits = s.reversed().prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(String(digits.reversed()))
    }
}

// MARK: - P1 detectors (SPEC §3.3 item 3, SENS §7) — used by `thermik-probe sensors discover <seconds>`

/// Collects 1 Hz samples of raw bytes + decoded values and refines heuristic roles:
///  * static: raw bytes never change and |v| < 1 (or always invalid) → unused. Groups that power-gate on Apple
///    Silicon (P-cores, P-fabric, cluster aggregates) sit at (-4, x, 0) for minutes at idle, so for them the rule
///    needs the full 10-minute window of SENS §7;
///  * mirror: byte-identical to an earlier key in every sample (≥ 10 valid, and the series must change — two keys
///    that merely sit still, e.g. a whole power-gated cluster, are not mirrors) → duplicate (first key in FourCC
///    order is kept);
///  * offset-copy: for neighbouring keys a < b of one family, b − a constant within 0.02 °C over ≥ 20 samples where
///    both are valid while a itself moves by ≥ 0.2 °C (a constant offset between two static keys proves nothing)
///    → a = probe (hidden), b = calibrated (shown); a following neighbour that is ≥ b in every such sample →
///    hotspot (hidden). Run it under light load: a cluster that stays gated the whole window cannot be classified.
package struct HeuristicDetectors {
    package private(set) var samples = 0
    private var bytes: [String: [[UInt8]]] = [:]
    private var values: [String: [Double?]] = [:]   // nil = invalid / unread in that sample

    package init() {}

    package mutating func add(_ sample: [String: (bytes: [UInt8], value: Double?)], keys: [String]) {
        samples += 1
        for k in keys {
            let s = sample[k]
            bytes[k, default: []].append(s?.bytes ?? [])
            values[k, default: []].append(s?.value)
        }
    }

    /// Returns refined descriptors (same order). Keys that are not SMC keys pass through unchanged.
    package func refine(_ descriptors: [SensorDescriptor]) -> [SensorDescriptor] {
        guard samples > 0 else { return descriptors }
        var out = descriptors
        let index = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.key, $0) })
        func set(_ key: String, role: SensorRole, visible: Bool) {
            guard let i = index[key], !out[i].role.isNeverShown else { return }
            out[i].role = role; out[i].visible = visible
        }
        let smcKeys = out.map(\.key).filter { !$0.hasPrefix("hid:") && bytes[$0] != nil }.sorted { FourCC($0) < FourCC($1) }

        // Static / always invalid.
        var unused = Set<String>()
        for k in smcKeys {
            if let i = index[k], out[i].group.rejectsExact40, samples < 600 { continue }
            let b = bytes[k] ?? [], v = values[k] ?? []
            let isStatic = Set(b).count == 1
            let first = v.compactMap { $0 }.first
            if v.allSatisfy({ $0 == nil }) && isStatic { unused.insert(k) }
            else if isStatic, let f = first, abs(f) < 1 { unused.insert(k) }
        }
        unused.forEach { set($0, role: .unused, visible: false) }

        // Mirrors.
        var seen: [[[UInt8]]: String] = [:]
        var duplicates = Set<String>()
        if samples >= 10 {
            for k in smcKeys where !unused.contains(k) {
                let series = bytes[k] ?? []
                guard Set(series).count >= 2, (values[k] ?? []).compactMap({ $0 }).count >= 10 else { continue }
                if seen[series] != nil { duplicates.insert(k); set(k, role: .duplicate, visible: false) }
                else { seen[series] = k }
            }
        }

        // Offset copies within a family (first two characters), on the remaining keys in FourCC order.
        let live = smcKeys.filter { !unused.contains($0) && !duplicates.contains($0) }
        var i = 0
        while i + 1 < live.count {
            let a = live[i], b = live[i + 1]
            guard a.prefix(2) == b.prefix(2), let d = constantOffset(a, b), abs(d) > 0.05 else { i += 1; continue }
            set(a, role: .probe, visible: false)
            set(b, role: .calibrated, visible: true)
            if i + 2 < live.count, live[i + 2].prefix(2) == b.prefix(2), isAlwaysAtLeast(live[i + 2], b) {
                set(live[i + 2], role: .hotspot, visible: false)
                i += 3
            } else {
                i += 2
            }
        }
        return out
    }

    /// b − a if constant within 0.02 °C over ≥ 20 samples where both are valid and a moves by ≥ 0.2 °C.
    private func constantOffset(_ a: String, _ b: String) -> Double? {
        guard let va = values[a], let vb = values[b] else { return nil }
        let pairs = zip(va, vb).compactMap { x, y -> (Double, Double)? in
            guard let x, let y else { return nil }
            return (x, y)
        }
        let diffs = pairs.map { $0.1 - $0.0 }
        guard diffs.count >= 20, let lo = diffs.min(), let hi = diffs.max(), hi - lo <= 0.02,
              let aLo = pairs.map(\.0).min(), let aHi = pairs.map(\.0).max(), aHi - aLo >= 0.2 else { return nil }
        return (lo + hi) / 2
    }

    private func isAlwaysAtLeast(_ c: String, _ b: String) -> Bool {
        guard let vc = values[c], let vb = values[b] else { return false }
        let pairs = zip(vc, vb).compactMap { x, y -> (Double, Double)? in
            guard let x, let y else { return nil }
            return (x, y)
        }
        return pairs.count >= 20 && pairs.allSatisfy { $0.0 >= $0.1 }
    }
}
