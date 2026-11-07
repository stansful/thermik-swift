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
        try validateWrite(key, bytes, info: info)
        let block = writeBlock(key, bytes, info: info)
        let output = try perform(block)
        guard output.result == 0 else { throw SMCError.firmware(output.result, key: key) }
    }

    private func validateWrite(_ key: FourCC, _ bytes: [UInt8], info: SMCKeyInfo) throws {
        guard info.isWritable else { throw SMCError.notWritable(key) }
        guard bytes.count == Int(info.size), bytes.count <= 32 else {
            throw SMCError.sizeMismatch(key: key, expected: Int(info.size), actual: bytes.count)
        }
    }

    private func writeBlock(_ key: FourCC, _ bytes: [UInt8], info: SMCKeyInfo) -> SMCParamBlock {
        var block = SMCParamBlock()
        block.key = key
        block.dataSize = info.size
        block.command = SMCCommand.writeKey.rawValue
        block.setPayload(bytes)
        return block
    }
}
