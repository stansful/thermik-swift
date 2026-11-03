// thermik-probe — manual verification CLI (NOT a test target).
// Every subcommand is READ-ONLY on real hardware. Fan-write logic is exercised only against fakes (`fans sim`).
// Build & run:  swift run --package-path Packages/ThermikCore thermik-probe <command> [args]
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

switch command {
case "smc":         await Probe.smc(rest)
case "sensors":     await Probe.sensors(rest)
case "system":      await Probe.system(rest)
case "fans":        await Probe.fans(rest)
case "helper":      await Probe.helper(rest)
case "alerts":      await Probe.alerts(rest)
case "log":         await Probe.log(rest)
case "diagnostics": await Probe.diagnostics(rest)
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
