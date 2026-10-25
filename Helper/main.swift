// main.swift — Thermik privileged helper (root LaunchDaemon). Unit 0 STUB; OWNER: Unit 4.
// Unit 4 replaces this with the real entry point (SPEC §2.6.5): root check, HelperService, PeerValidator,
// NSXPCListener(machServiceName:), signal handlers, PowerObserver, dispatchMain().
import Foundation
import ThermikHelperShared
import ThermikSMC
import ThermikSMCWriter

print("thermik-helper \(ThermikHelper.protocolVersion): not implemented yet (Unit 4)")
exit(0)
