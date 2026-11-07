// Probe+SMC.swift — Read-only SMC dump / key reads (attribute-aware decoding).
import Foundation
import ThermikSMC

extension Probe {
    static func smc(_ args: [String]) async {
        do {
            let smc = try SMCConnection()
            if args.first == "read", args.count > 1 {
                readKeys(args[1], smc: smc)
            } else {
                try dumpKeys(smc: smc)
            }
        } catch { print("SMC unavailable: \(error)") }
    }

    private static func readKeys(_ list: String, smc: SMCConnection) {
        for key in list.split(separator: ",").map({ FourCC(String($0)) }) {
            do {
                let (info, bytes) = try smc.readRaw(key)
                print("\(key)\t\(info.type)\t\(info.size)\t\(String(format: "%02x", info.attributes.rawValue))\t\(bytes.map { String(format: "%02x", $0) }.joined())\t\(SMCCodec.decode(bytes, as: info))")
            } catch { print("\(key)\tERROR \(error)") }
        }
    }

    private static func dumpKeys(smc: SMCConnection) throws {
        let keys = try smc.allKeys()
        print("# \(keys.count) keys")
        for key in keys {
            guard let (info, bytes) = try? smc.readRaw(key) else { print("\(key)\t-\tunreadable"); continue }
            print("\(key)\t\(info.type)\t\(info.size)\t\(String(format: "%02x", info.attributes.rawValue))\t\(SMCCodec.decode(bytes, as: info))")
        }
    }
}
