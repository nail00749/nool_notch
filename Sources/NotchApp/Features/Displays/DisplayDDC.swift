import Foundation

/// The bytes carried by IOAVService's DDC/CI transaction, without the I²C address.
enum DisplayDDC {
    static let brightness: UInt8 = 0x10

    struct Value: Equatable, Sendable {
        let current: UInt16
        let maximum: UInt16

        var normalized: Double { Double(current) / Double(maximum) }

        func rawValue(for normalized: Double) -> UInt16? {
            guard normalized.isFinite, maximum > 0 else { return nil }
            return UInt16((min(1, max(0, normalized)) * Double(maximum)).rounded())
        }
    }

    static func checksum<S: Sequence>(_ bytes: S, seed: UInt8) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    static func readPacket(code: UInt8 = brightness) -> [UInt8] {
        // IOAVService read-request convention, also used by MonitorControl's
        // Arm64DDC and m1ddc's prepareDDCRead (writes additionally seed 0x51).
        let bytes: [UInt8] = [0x82, 0x01, code]
        return bytes + [checksum(bytes, seed: 0x6e)]
    }

    static func writePacket(value: UInt16, code: UInt8 = brightness) -> [UInt8] {
        let bytes: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xff)]
        return bytes + [checksum(bytes, seed: 0x6e ^ 0x51)]
    }

    static func decode(_ bytes: [UInt8], code: UInt8 = brightness) -> Value? {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[3] == 0, bytes[4] == code, bytes[5] == 0,
              checksum(bytes, seed: 0x50) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return Value(current: current, maximum: maximum)
    }
}

/// EDID UUID and CoreGraphics display UUID are different identifiers. An EDID UUID
/// must only be supplied when it actually came from EDID metadata on both sides.
struct DisplayDDCIdentity: Equatable, Sendable {
    var edidUUID: String? = nil
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32

    private var normalizedEDID: String? {
        guard let value = edidUUID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.uppercased()
    }

    private func matches(_ other: Self) -> Bool {
        if let edid = normalizedEDID, let otherEDID = other.normalizedEDID { return edid == otherEDID }
        return hasSameFullNumericIdentity(as: other)
    }

    func hasSameFullNumericIdentity(as other: Self) -> Bool {
        vendor > 0 && product > 0 && serial > 0 && vendor == other.vendor
            && product == other.product && serial == other.serial
    }

    /// A candidate must identify one IOService and one online CG display. In
    /// particular, identical monitors with missing/repeated serials are rejected.
    static func uniqueMatch(for target: Self, candidates: [Self], onlineDisplays: [Self]) -> Int? {
        guard onlineDisplays.filter({ target.matches($0) }).count == 1 else { return nil }
        let matches = candidates.indices.filter { target.matches(candidates[$0]) }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Some DCP proxies and framebuffer metadata occupy sibling branches. That
/// association is safe only inside a completely inspected branch with a single
/// external proxy and one full, unambiguous metadata identity for the CG target.
enum DisplayDDCBranchAssociation {
    static func identity(for target: DisplayDDCIdentity, proxyID: UInt64,
                         externalProxyIDs: Set<UInt64>, metadata: [DisplayDDCIdentity],
                         isComplete: Bool) -> DisplayDDCIdentity? {
        guard isComplete, externalProxyIDs == [proxyID], target.vendor > 0,
              target.product > 0, target.serial > 0 else { return nil }
        let matches = metadata.filter { target.hasSameFullNumericIdentity(as: $0) }
        let distinct = matches.reduce(into: [DisplayDDCIdentity]()) { identities, identity in
            if !identities.contains(identity) { identities.append(identity) }
        }
        return distinct.count == 1 ? distinct[0] : nil
    }
}
