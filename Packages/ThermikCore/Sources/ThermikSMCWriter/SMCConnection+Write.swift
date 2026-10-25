// SMCConnection+Write.swift — Thermik (MIT). HELPER ONLY: the single SMC write entry point (command 6).
// Callers must go through FanWriteSequencer, which enforces a key allow-list. Belt and braces:
// refuses to even attempt a write unless running as root (non-root writes fail in the kernel anyway
// with kIOReturnNotPrivileged), so a dev process / probe can never write by accident.
import Foundation
import ThermikSMC

extension SMCConnection: SMCReadWriting {
    public func writeRaw(_ key: FourCC, _ bytes: [UInt8]) throws {
        guard geteuid() == 0 else { throw SMCError.notPrivileged(key: key) }
        let info = try keyInfo(key)
        guard info.isWritable else { throw SMCError.notWritable(key) }
        guard bytes.count == Int(info.size), bytes.count <= 32 else {
            throw SMCError.sizeMismatch(key: key, expected: Int(info.size), actual: bytes.count)
        }
        var b = SMCParamBlock()
        b.key = key
        b.dataSize = info.size
        b.command = SMCCommand.writeKey.rawValue
        b.setPayload(bytes)
        let o = try perform(b)
        guard o.result == 0 else { throw SMCError.firmware(o.result, key: key) }
    }
}
