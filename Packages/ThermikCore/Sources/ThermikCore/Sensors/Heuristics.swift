// Heuristics.swift — Thermik (MIT). Descriptors for keys that no per-chip database describes.
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
        if appleSilicon { return appleSiliconRole(forKey: key, characters: c) }
        return intelRole(forKey: key, characters: c)
    }

    private static func appleSiliconRole(forKey key: String, characters c: [Character]) -> SensorRole {
        if key.hasPrefix("Tf"), c[3] == "6" { return .peakHold }          // Tf?6: running max since boot (SENS R11)
        if key == "TCMb" { return .average }
        if key == "TCMz" { return .maximum }
        if key.hasPrefix("Tpx") || key.hasPrefix("Tex") || key.hasPrefix("Tsx") { return .maximum }  // firmware aggregates
        // TCDX, TPDX, TRDX: legacy "X = max". Not in the indexed die families, where `Tp0X` is just probe index X.
        if c[3] == "X", c[2].isLetter, !["Tp", "Te", "Tg", "Tf", "Ts"].contains(String(key.prefix(2))) { return .maximum }
        return .probe
    }

    private static func intelRole(forKey key: String, characters c: [Character]) -> SensorRole {
        if c[3] == "X" || key == "TCXC" { return .maximum }              // TCXC: package max (PECI)
        if key.hasPrefix("TC"), c[3] == "c" { return .duplicate }         // TC0c…: raw (uncooked) core copies
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
        let names = smcNames(forKey: key, hint: hint, group: group)
        // The die average / hotspot keep their meaning across generations (SENS §4.2): show them without a DB too.
        let wellKnownDie = !hasDatabase && appleSilicon && (key == "TCMb" || key == "TCMz")
        return SensorDescriptor(key: key, name: names.en, nameRu: names.ru, group: group, role: role, cluster: nil,
                                visible: wellKnownDie || isVisible(group: group, role: role, hasDatabase: hasDatabase),
                                invalidValues: nil)
    }

    private static func smcNames(forKey key: String, hint: Hint?, group: SensorGroup) -> (en: String, ru: String) {
        let generic = hint.map { (en: $0.en, ru: $0.ru) } ?? label(group)
        guard let known = wellKnownNames[key] else { return ("\(generic.en) \(key)", "\(generic.ru) \(key)") }
        return known
    }

    private typealias HIDDetails = (group: SensorGroup, role: SensorRole, en: String, ru: String)

    /// HID product → descriptor (heuristic catalogs and the `*MTR*` die fallback, SENS §3.3).
    /// `dieFallback`: the chip has no SMC die keys, so HID die sensors are the CPU/GPU source and are shown.
    package static func descriptor(forHIDProduct product: String, dieFallback: Bool) -> SensorDescriptor {
        let n = trailingNumber(product)
        let suffix = n.map { " \($0)" } ?? ""
        let details = hidDetails(product, suffix: suffix)
        let isDie = [.cpuPerformance, .cpuEfficiency, .gpu].contains(details.group) || product.contains("SOC")
        return SensorDescriptor(key: "hid:\(product)", name: "\(details.en) (HID)", nameRu: "\(details.ru) (HID)",
                                group: details.group, role: details.role, cluster: nil,
                                visible: dieFallback && isDie && !details.role.isNeverShown, invalidValues: nil)
    }

    private static func hidDetails(_ product: String, suffix: String) -> HIDDetails {
        if let details = dieDetails(product, suffix: suffix) { return details }
        if let details = pmuDetails(product, suffix: suffix) { return details }
        if let details = deviceDetails(product, suffix: suffix) { return details }
        return (.other, .probe, product, product)
    }

    private static func dieDetails(_ product: String, suffix: String) -> HIDDetails? {
        switch product {
        case let p where p.hasPrefix("pACC MTR"): return (.cpuPerformance, .probe, "P-cluster die\(suffix)", "P-кластер, кристалл\(suffix)")
        case let p where p.hasPrefix("eACC MTR"): return (.cpuEfficiency, .probe, "E-cluster die\(suffix)", "E-кластер, кристалл\(suffix)")
        case let p where p.hasPrefix("GPU MTR"): return (.gpu, .probe, "GPU die\(suffix)", "ГП, кристалл\(suffix)")
        case let p where p.hasPrefix("SOC MTR"), let p where p.hasPrefix("PMGR SOC Die"):
            return (.soc, .probe, "SoC die\(suffix)", "Кристалл SoC\(suffix)")
        case let p where p.hasPrefix("ANE MTR"): return (.soc, .probe, "Neural Engine\(suffix)", "Neural Engine\(suffix)")
        case let p where p.hasPrefix("ISP MTR"): return (.soc, .probe, "Image processor\(suffix)", "Обработчик изображений\(suffix)")
        default: return nil
        }
    }

    private static func pmuDetails(_ product: String, suffix: String) -> HIDDetails? {
        switch product {
        case let p where p.contains("tcal"): return (.powerDelivery, .reference, "PMU calibration", "PMU, эталон")
        case let p where p.contains("tdie"): return (.powerDelivery, .probe, "PMU die\(suffix)", "Кристалл PMU\(suffix)")
        case let p where p.contains("tdev"): return (.powerDelivery, .probe, "PMU sensor\(suffix)", "Датчик PMU\(suffix)")
        default: return nil
        }
    }

    private static func deviceDetails(_ product: String, suffix: String) -> HIDDetails? {
        switch product {
        case let p where p.hasPrefix("gas gauge"): return (.battery, .duplicate, "Battery gas gauge", "Контроллер АКБ")
        case let p where p.hasPrefix("NAND"): return (.storage, .probe, "SSD NAND\(suffix)", "SSD NAND\(suffix)")
        default: return nil
        }
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
        let builder = HeadlineBuilder(descriptors: descriptors)
        let headline = appleSilicon ? builder.appleSilicon() : builder.intel()
        return headline.filter { !$0.value.isEmpty }
    }

    private struct HeadlineBuilder {
        let descriptors: [SensorDescriptor]
        let byKey: [String: SensorDescriptor]

        init(descriptors: [SensorDescriptor]) {
            self.descriptors = descriptors
            byKey = Dictionary(descriptors.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }

        func keys(_ predicate: (SensorDescriptor) -> Bool) -> [String] {
            descriptors.filter { !$0.role.isNeverShown && predicate($0) }.map(\.key)
        }

        func first(_ candidates: [String]) -> [String] {
            let present = Set(descriptors.map(\.key))
            return candidates.first { present.contains($0) }.map { [$0] } ?? []
        }

        /// P1: once the offset detector found calibrated keys (discover), average only the shown ones.
        func narrowed(_ set: [String]) -> [String] {
            guard set.contains(where: { byKey[$0]?.role == .calibrated }) else { return set }
            return set.filter { byKey[$0]?.visible == true }
        }

        func appleSilicon() -> [HeadlineSet: [String]] {
            return [
                .cpu: narrowed(cpu()),
                .cpuHotspot: cpuHotspot(),
                .gpu: narrowed(gpu()),
                .soc: soc(),
                .battery: first(["TB0T"]),
                .ssd: first(["TH0x", "TH0a"]),
                .memory: memory(),
            ]
        }

        /// CPU: P0 = every Tp/Te probe (P1 `discover` narrows it to calibrated keys); hinted groups as fallback.
        private func cpu() -> [String] {
            var cpu = keys { isSMC($0) && ($0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te")) && $0.group != .cpuAggregate && $0.role.feedsAverages }
            if cpu.isEmpty { cpu = keys { isSMC($0) && ($0.group == .cpuPerformance || $0.group == .cpuEfficiency) && $0.role.feedsAverages } }
            if cpu.isEmpty { cpu = keys { isHIDDie($0) && ($0.group == .cpuPerformance || $0.group == .cpuEfficiency) } }
            return cpu
        }

        private func cpuHotspot() -> [String] {
            let aggregates = keys { isSMC($0) && ($0.key.hasPrefix("Tpx") || $0.key.hasPrefix("Tex")) }
            return aggregates.isEmpty ? narrowed(cpu()) : aggregates
        }

        private func gpu() -> [String] {
            var gpu = keys { isSMC($0) && $0.key.hasPrefix("Tg") && $0.role.feedsAverages }
            if gpu.isEmpty { gpu = keys { isSMC($0) && $0.group == .gpu && $0.role.feedsAverages } }
            if gpu.isEmpty { gpu = keys { isHIDDie($0) && $0.group == .gpu } }
            return gpu
        }

        private func soc() -> [String] {
            var soc = first(["TCMb"])
            if soc.isEmpty { soc = keys { isSMC($0) && $0.key.hasPrefix("Ts") && $0.group == .soc && !$0.key.hasPrefix("Tsx") && $0.role.feedsAverages } }
            if soc.isEmpty { soc = keys { isHIDDie($0) && $0.group == .soc } }
            return soc
        }

        private func memory() -> [String] {
            var memory = first(["TVMR"])
            if memory.isEmpty { memory = keys { isSMC($0) && $0.key.hasPrefix("Tm") && $0.role.feedsAverages } }
            return memory
        }

        /// Intel without intel.json entries (should not happen: intel.json ships). Same chains as §3.4.
        func intel() -> [HeadlineSet: [String]] {
            let cores = keys { $0.key.count == 4 && $0.key.hasPrefix("TC") && $0.key.hasSuffix("C") && Array($0.key)[2].isNumber }
            let hotspot = first(["TCXC"])
            return [
                .cpu: cores.isEmpty ? first(["TC0P", "TC0D"]) : cores,
                .cpuHotspot: hotspot.isEmpty ? (cores.isEmpty ? first(["TC0D"]) : cores) : hotspot,
                .gpu: first(["TG0P", "TG0D", "TCGC"]),
                .memory: first(["TM0P"]),
                .ssd: first(["TH0P", "TH0x"]),
                .battery: first(["TB0T"]),
            ]
        }

        private func isSMC(_ descriptor: SensorDescriptor) -> Bool {
            !descriptor.key.hasPrefix("hid:")
        }

        private func isHIDDie(_ descriptor: SensorDescriptor) -> Bool {
            descriptor.key.hasPrefix("hid:") && Heuristics.isHIDDieProduct(String(descriptor.key.dropFirst(4)))
        }
    }

    // MARK: Names

    /// Generic group labels for heuristic names ("GPU Tg0A" / "ГП Tg0A"); RU follows the §4.12 glossary.
    static func label(_ g: SensorGroup) -> (en: String, ru: String) {
        groupLabels[g] ?? ("Sensor", "Датчик")
    }

    private static let groupLabels: [SensorGroup: (en: String, ru: String)] = [
        .cpuPerformance: ("CPU P-cluster", "ЦП, P-кластер"),
        .cpuEfficiency: ("CPU E-cluster", "ЦП, E-кластер"),
        .cpuFabric: ("CPU fabric", "ЦП, шина"),
        .cpuAggregate: ("CPU aggregate", "ЦП, агрегат"),
        .gpu: ("GPU", "ГП"),
        .gpuAggregate: ("GPU aggregate", "ГП, агрегат"),
        .socFabric: ("SoC fabric", "SoC, шина"),
        .soc: ("SoC", "SoC"),
        .memory: ("Memory", "Память"),
        .battery: ("Battery", "Аккумулятор"),
        .storage: ("Storage", "Накопитель"),
        .wireless: ("Wireless", "Беспроводная связь"),
        .enclosure: ("Enclosure", "Корпус"),
        .airflow: ("Airflow", "Воздушный поток"),
        .ports: ("Port", "Порт"),
        .powerDelivery: ("Power", "Питание"),
        .board: ("Board", "Плата"),
        .virtual: ("Virtual", "Виртуальный"),
        .other: ("Sensor", "Датчик"),
    ]

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
    private static let pHint = Hint(group: .cpuPerformance, en: "P-core", ru: "P-ядро")
    private static let eHint = Hint(group: .cpuEfficiency, en: "E-core", ru: "E-ядро")
    private static let gHint = Hint(group: .gpu, en: "GPU", ru: "ГП")

    private static func generationHint(platform: String, key: String) -> Hint? {
        switch platform {
        case "t8103", "t6000", "t6001", "t6002": return m1Hints()[key]              // M1 family
        case "t8112", "t6020", "t6021", "t6022": return m2Hints()[key]              // M2 family
        case "t8122", "t6030", "t6031", "t6032", "t6034": return m3Hints()[key]     // M3 family: CPU/GPU probes under Tf
        case "t8132": return m4Hints()[key]                                        // M4 (base)
        case "t8142": return m5Hints()[key]                                        // M5
        default: return nil
        }
    }

    private static func hintMap(_ keys: String, _ hint: Hint) -> [String: Hint] {
        Dictionary(uniqueKeysWithValues: keys.split(separator: " ").map { (String($0), hint) })
    }

    private static func m1Hints() -> [String: Hint] {
        hintMap("Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b", pHint)
            .merging(hintMap("Tp09 Tp0T", eHint)) { a, _ in a }
            .merging(hintMap("Tg05 Tg0D Tg0L Tg0T", gHint)) { a, _ in a }
    }

    private static func m2Hints() -> [String: Hint] {
        hintMap("Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j", pHint)
            .merging(hintMap("Tp1h Tp1t Tp1p Tp1l", eHint)) { a, _ in a }
            .merging(hintMap("Tg0f Tg0j", gHint)) { a, _ in a }
    }

    private static func m3Hints() -> [String: Hint] {
        hintMap("Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E", pHint)
            .merging(hintMap("Te05 Te0L Te0P Te0S", eHint)) { a, _ in a }
            .merging(hintMap("Tf14 Tf18 Tf19 Tf1A Tf24 Tf28 Tf29 Tf2A", gHint)) { a, _ in a }
    }

    private static func m4Hints() -> [String: Hint] {
        hintMap("Te08 Te09 Te0A Te0G Te0H Te0I", eHint)
    }

    private static func m5Hints() -> [String: Hint] {
        hintMap("Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K", Hint(group: .cpuPerformance, en: "Super core", ru: "Супер-ядро"))
            .merging(hintMap("Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y", pHint)) { a, _ in a }
            .merging(hintMap("Tg0U Tg0X Tg0d Tg0g Tg0j Tg1Y Tg1c Tg1g", gHint)) { a, _ in a }
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
        var refinement = Refinement(descriptors: descriptors, samples: samples, bytes: bytes, values: values)
        refinement.apply()
        return refinement.descriptors
    }

    private struct Refinement {
        var descriptors: [SensorDescriptor]
        let samples: Int
        let bytes: [String: [[UInt8]]]
        let values: [String: [Double?]]
        let index: [String: Int]

        init(descriptors: [SensorDescriptor], samples: Int, bytes: [String: [[UInt8]]], values: [String: [Double?]]) {
            self.descriptors = descriptors
            self.samples = samples
            self.bytes = bytes
            self.values = values
            index = Dictionary(uniqueKeysWithValues: descriptors.enumerated().map { ($1.key, $0) })
        }

        mutating func apply() {
            let keys = smcKeys()
            let unused = markUnused(in: keys)
            let duplicates = markMirrors(in: keys, excluding: unused)
            let live = keys.filter { !unused.contains($0) && !duplicates.contains($0) }
            refineOffsets(live)
        }

        private func smcKeys() -> [String] {
            descriptors.map(\.key).filter { !$0.hasPrefix("hid:") && bytes[$0] != nil }.sorted { FourCC($0) < FourCC($1) }
        }

        private mutating func markUnused(in keys: [String]) -> Set<String> {
            var unused = Set<String>()
            for key in keys where !defersUnusedCheck(key) {
                if isUnused(key) { unused.insert(key) }
            }
            for key in unused { set(key, role: .unused, visible: false) }
            return unused
        }

        private func defersUnusedCheck(_ key: String) -> Bool {
            guard let i = index[key] else { return false }
            return descriptors[i].group.rejectsExact40 && samples < 600
        }

        private func isUnused(_ key: String) -> Bool {
            let b = bytes[key] ?? [], v = values[key] ?? []
            let isStatic = Set(b).count == 1
            let first = v.compactMap { $0 }.first
            let alwaysInvalid = v.allSatisfy { $0 == nil }
            let nearZero = first.map { abs($0) < 1 } ?? false
            return isStatic && (alwaysInvalid || nearZero)
        }

        private mutating func markMirrors(in keys: [String], excluding unused: Set<String>) -> Set<String> {
            var seen: [[[UInt8]]: String] = [:]
            var duplicates = Set<String>()
            guard samples >= 10 else { return duplicates }
            for key in keys where !unused.contains(key) {
                guard isDuplicateMirror(key, seen: &seen) else { continue }
                duplicates.insert(key)
                set(key, role: .duplicate, visible: false)
            }
            return duplicates
        }

        private func isDuplicateMirror(_ key: String, seen: inout [[[UInt8]]: String]) -> Bool {
            let series = bytes[key] ?? []
            guard Set(series).count >= 2, (values[key] ?? []).compactMap({ $0 }).count >= 10 else { return false }
            if seen[series] == nil {
                seen[series] = key
                return false
            }
            return true
        }

        /// Offset copies within a family (first two characters), on remaining keys in FourCC order.
        private mutating func refineOffsets(_ live: [String]) {
            var i = 0
            while i + 1 < live.count {
                i += refineOffsetFamily(live, at: i)
            }
        }

        private mutating func refineOffsetFamily(_ live: [String], at i: Int) -> Int {
            let a = live[i], b = live[i + 1]
            guard a.prefix(2) == b.prefix(2), let d = constantOffset(a, b), abs(d) > 0.05 else { return 1 }
            set(a, role: .probe, visible: false)
            set(b, role: .calibrated, visible: true)
            guard i + 2 < live.count else { return 2 }
            let c = live[i + 2]
            guard c.prefix(2) == b.prefix(2), isAlwaysAtLeast(c, b) else { return 2 }
            set(c, role: .hotspot, visible: false)
            return 3
        }

        private mutating func set(_ key: String, role: SensorRole, visible: Bool) {
            guard let i = index[key], !descriptors[i].role.isNeverShown else { return }
            descriptors[i].role = role
            descriptors[i].visible = visible
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
}
