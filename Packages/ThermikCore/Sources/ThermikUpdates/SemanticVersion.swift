// Numeric SemVer comparison without integer overflow. Build metadata does not affect precedence.
import Foundation

struct SemanticVersion: Equatable, Comparable, Sendable {
    let display: String
    private let components: [String]
    private let prerelease: [String]?

    var isPrerelease: Bool { prerelease != nil }

    init?(_ raw: String) {
        guard !raw.isEmpty, raw.utf8.count <= 256 else { return nil }
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard !value.isEmpty else { return nil }
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2, !metadata[0].isEmpty else { return nil }
        if metadata.count == 2, !Self.validIdentifiers(metadata[1]) { return nil }
        let version = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = version[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy(Self.validNumber) else { return nil }
        var labels: [String]?
        if version.count == 2 {
            guard Self.validIdentifiers(version[1]) else { return nil }
            let identifiers = version[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ !Self.isNumber($0) || Self.validNumber($0) }) else { return nil }
            labels = identifiers.map(String.init)
        }
        display = value
        components = numbers.map(String.init)
        prerelease = labels
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) where left != right {
            return numberLess(left, right)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            for (l, r) in zip(left, right) where l != r {
                let ln = isNumber(l), rn = isNumber(r)
                if ln && rn { return numberLess(l, r) }
                if ln != rn { return ln }
                return l < r
            }
            return left.count < right.count
        }
    }

    private static func isNumber<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validNumber<S: StringProtocol>(_ value: S) -> Bool {
        isNumber(value) && (value.count == 1 || value.first != "0")
    }

    private static func validIdentifiers<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { identifier in
            !identifier.isEmpty && identifier.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }
        }
    }

    private static func numberLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
}
