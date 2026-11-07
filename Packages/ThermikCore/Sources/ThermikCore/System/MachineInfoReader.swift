// MachineInfoReader.swift — Thermik (MIT).
// Model identifier, marketing name, chip, CPU tiers / topology and GPU (SYS §8). ~1.5–5 ms, no root, read once.
import Foundation
import IOKit

enum MachineInfoReader {
    static func read() -> MachineInfo {
        let arm = (SysctlReader.int("hw.optional.arm64") ?? 0) == 1
        let levels = performanceLevels()
        let product = productInfo()
        let model = SysctlReader.string("hw.model").flatMap(nonEmpty) ?? "Mac"
        let marketing = product.marketing ?? intelMarketingName(model, language: preferredLanguage())
        let gpus = GPUReader.read()
        return makeInfo(model: model, marketing: marketing, product: product, arm: arm, levels: levels, gpus: gpus)
    }

    private static func performanceLevels() -> [PerfLevel] {
        let count = max(SysctlReader.int("hw.nperflevels") ?? 0, 0) // M5/M6 may add a third tier: never assume 2
        return (0..<count).map { i in
            let prefix = "hw.perflevel\(i)."
            return PerfLevel(name: SysctlReader.string(prefix + "name") ?? "Level \(i)",
                             logicalCPUs: SysctlReader.int(prefix + "logicalcpu") ?? 0,
                             physicalCPUs: SysctlReader.int(prefix + "physicalcpu") ?? 0,
                             l2CacheBytes: SysctlReader.int(prefix + "l2cachesize"))
        }
    }

    /// Apple Silicon: IODeviceTree:/product › product-name "MacBook Pro (16-inch, Nov 2024)", product-soc-name.
    private static func productInfo() -> (marketing: String?, soc: String?) {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return (nil, nil) }
        defer { IOObjectRelease(product) }
        return (IOKitHelpers.deviceTreeStrings(product, "product-name").first.flatMap(nonEmpty),
                IOKitHelpers.deviceTreeStrings(product, "product-soc-name").first.flatMap(nonEmpty))
    }

    /// Dual-GPU Intel Macs show both model names.
    private static func makeInfo(model: String, marketing: String?, product: (marketing: String?, soc: String?),
                                 arm: Bool, levels: [PerfLevel], gpus: [GPUUtilization]) -> MachineInfo {
        let names = gpus.compactMap(\.model).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            modelIdentifier: model, marketingName: marketing,
            boardID: SysctlReader.string("hw.target").flatMap(nonEmpty) ?? platformBoardID(),
            chip: product.soc ?? SysctlReader.string("machdep.cpu.brand_string").flatMap(nonEmpty) ?? "Unknown", isAppleSilicon: arm,
            isTranslated: (SysctlReader.int("sysctl.proc_translated") ?? 0) == 1, osVersion: osVersion(v),
            memoryBytes: UInt64(max(SysctlReader.int("hw.memsize") ?? 0, 0)),
            logicalCPUs: SysctlReader.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount, perfLevels: levels,
            cpuTopology: cpuTopology(), gpuName: names.isEmpty ? nil : names.joined(separator: " + "), gpuCores: gpus.lazy.compactMap(\.coreCount).first)
    }

    private static func osVersion(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(SysctlReader.string("kern.osversion") ?? "?"))"
    }

    /// Apple Silicon: logical CPU id → cluster type ("E" / "P" / …) and cluster id from IODeviceTree:/cpus. Empty on Intel.
    static func cpuTopology() -> [CPUCoreInfo] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        let out = IOKitHelpers.children(cpus, plane: kIODeviceTreePlane).compactMap { child -> CPUCoreInfo? in
            defer { IOObjectRelease(child) }
            return coreInfo(child)
        }
        return out.sorted { $0.id < $1.id }
    }

    private static func coreInfo(_ entry: io_registry_entry_t) -> CPUCoreInfo? {
        guard let id = integer(IOKitHelpers.property(entry, "logical-cpu-id", as: AnyObject.self)) else { return nil }
        return CPUCoreInfo(id: id,
                           type: IOKitHelpers.deviceTreeStrings(entry, "cluster-type").first.flatMap(nonEmpty) ?? "?",
                           cluster: integer(IOKitHelpers.property(entry, "logical-cluster-id", as: AnyObject.self)) ?? -1)
    }

    // MARK: Intel marketing names

    /// 1. Apple's localized `SIMachineAttributes.plist` (a plain-plist *resource* of a system framework; Intel models up to
    ///    ~2018, ru/en). 2. Bundled `models-intel.json` (2017–2020 models, from Apple's public "Identify your Mac model"
    ///    support pages). nil → the UI shows the model identifier.
    static func intelMarketingName(_ model: String, language: String) -> String? {
        let base = "/System/Library/PrivateFrameworks/ServerInformation.framework/Versions/A/Resources/"
        for dir in language == "en" ? ["en.lproj"] : ["\(language).lproj", "en.lproj"] {
            guard let d = NSDictionary(contentsOfFile: base + dir + "/SIMachineAttributes.plist") as? [String: Any],
                  let entry = d[model] as? [String: Any], let loc = entry["_LOCALIZABLE_"] as? [String: Any],
                  let name = (loc["marketingModel"] as? String).flatMap(nonEmpty) else { continue }
            return name
        }
        return BundledModelNames.lookup(model, language: language)
    }

    /// "ru" or "en": the app's own localization first (Bundle.main), then the system's preferred language.
    static func preferredLanguage() -> String {
        let lang = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return lang.hasPrefix("ru") ? "ru" : "en"
    }

    /// Intel: `IOPlatformExpertDevice › board-id` (a model-level id such as "Mac-937A206F2EE63C01", not PII).
    private static func platformBoardID() -> String? {
        let pe = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard pe != 0 else { return nil }
        defer { IOObjectRelease(pe) }
        return IOKitHelpers.deviceTreeStrings(pe, "board-id").first.flatMap(nonEmpty)
    }

    /// Device-tree integers are published either as CFNumber or as little-endian CFData.
    private static func integer(_ any: AnyObject?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        guard let d = any as? Data, !d.isEmpty, d.count <= 8 else { return nil }
        return d.reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// `Resources/ModelNames/models-intel.json` (schema 1): `{ "models": { "MacBookPro16,1": { "en": …, "ru": … } } }`.
/// Loaded lazily, only on Intel (Apple Silicon names come from the device tree).
private enum BundledModelNames {
    private struct File: Decodable {
        var schema: Int
        var models: [String: [String: String]]
    }

    private static let table: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "models-intel", withExtension: "json", subdirectory: "ModelNames")
                ?? Bundle.module.url(forResource: "models-intel", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.schema == 1 else { return [:] }
        return file.models
    }()

    static func lookup(_ model: String, language: String) -> String? {
        guard let names = table[model] else { return nil }
        return names[language] ?? names["en"]
    }
}
