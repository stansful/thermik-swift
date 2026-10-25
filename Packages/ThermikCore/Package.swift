// swift-tools-version: 6.0
// Thermik — local package with ALL hardware and data logic (MIT).
// Library products without `type:` are linked STATICALLY into each consumer. This matters:
// an ad-hoc + hardened-runtime binary cannot dlopen another ad-hoc dylib (HELP §1, probe_lv).
import PackageDescription

let package = Package(
    name: "ThermikCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ThermikHelperShared", targets: ["ThermikHelperShared"]), // app + helper
        .library(name: "ThermikSMC", targets: ["ThermikSMC"]),                   // app + helper (READ-ONLY SMC)
        .library(name: "ThermikSMCWriter", targets: ["ThermikSMCWriter"]),       // HELPER ONLY (SMC writes)
        .library(name: "ThermikHelperCore", targets: ["ThermikHelperCore"]),     // HELPER ONLY (XPC service, lease, peer validation)
        .library(name: "ThermikCore", targets: ["ThermikCore"]),                 // app only
        .executable(name: "thermik-probe", targets: ["ThermikProbe"]),           // manual verification CLI
    ],
    targets: [
        // C shims: private HID SPI prototypes + public NVMe SMART header (not exported by Swift's IOKit module).
        .target(name: "CThermikSPI",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "ThermikHelperShared",
                linkerSettings: [.linkedFramework("Security")]),
        .target(name: "ThermikSMC",
                linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "ThermikSMCWriter",
                dependencies: ["ThermikSMC", "ThermikHelperShared"]),
        .target(name: "ThermikHelperCore",
                dependencies: ["ThermikSMCWriter", "ThermikSMC", "ThermikHelperShared"],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]),
        .target(name: "ThermikCore",
                dependencies: ["ThermikSMC", "ThermikHelperShared", "CThermikSPI"],
                resources: [.process("Resources")],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]),
        .executableTarget(name: "ThermikProbe",
                          dependencies: ["ThermikCore", "ThermikSMC", "ThermikSMCWriter", "ThermikHelperShared", "ThermikHelperCore"]),
    ],
    swiftLanguageModes: [.v6]
)
