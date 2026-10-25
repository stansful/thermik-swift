// Probe+SMC.swift — OWNER: Unit 0. Read-only SMC dump / key reads (attribute-aware decoding).
import Foundation
import ThermikSMC

extension Probe {
    static func smc(_ args: [String]) async {
        do {
            let smc = try SMCConnection()
            if args.first == "read", args.count > 1 {
                for k in args[1].split(separator: ",").map({ FourCC(String($0)) }) {
                    do {
                        let (i, b) = try smc.readRaw(k)
                        print("\(k)\t\(i.type)\t\(i.size)\t\(String(format: "%02x", i.attributes.rawValue))\t\(b.map { String(format: "%02x", $0) }.joined())\t\(SMCCodec.decode(b, as: i))")
                    } catch { print("\(k)\tERROR \(error)") }
                }
                return
            }
            let keys = try smc.allKeys()
            print("# \(keys.count) keys")
            for k in keys {
                guard let (i, b) = try? smc.readRaw(k) else { print("\(k)\t-\tunreadable"); continue }
                print("\(k)\t\(i.type)\t\(i.size)\t\(String(format: "%02x", i.attributes.rawValue))\t\(SMCCodec.decode(b, as: i))")
            }
        } catch { print("SMC unavailable: \(error)") }
    }
}
