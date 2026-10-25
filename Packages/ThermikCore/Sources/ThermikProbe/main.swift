// thermik-probe — manual verification CLI (NOT a test target). OWNER: Unit 0 (dispatcher only, frozen).
// Every subcommand is READ-ONLY on real hardware. Fan-write logic is exercised only against fakes (`fans sim`).
// Build & run:  swift run --package-path Packages/ThermikCore thermik-probe <command> [args]
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

switch command {
case "smc":         await Probe.smc(rest)          // Unit 0: dump / read keys (read-only)
case "sensors":     await Probe.sensors(rest)      // Unit 1: groups | snapshot | bench | discover | watch
case "system":      await Probe.system(rest)       // Unit 2: all | battery | load | ioreport | smart | boot | pmset
case "fans":        await Probe.fans(rest)         // Unit 3: profile | snapshot | dryrun | sim | inspect
case "helper":      await Probe.helper(rest)       // Unit 4: selftest (anonymous XPC listener + MockFanController)
case "alerts":      await Probe.alerts(rest)       // Unit 6: replay synthetic series through AlertEngine
case "log":         await Probe.log(rest)          // Unit 6: write a sample CSV into a given directory
case "diagnostics": await Probe.diagnostics(rest)  // Unit 6: print DiagnosticItems from live slow data
default:
    print("""
    thermik-probe <command>
      smc dump | smc read KEY[,KEY…]       raw SMC (read-only)
      sensors groups|snapshot|bench|discover|watch [seconds]
      system all|battery|load|ioreport|smart|boot|pmset
      fans profile|snapshot|dryrun|sim|inspect
      helper selftest
      alerts replay
      log write <dir>
      diagnostics
    """)
}

/// Namespace; each unit implements its function in its own Probe+<Unit>.swift file.
enum Probe {}
