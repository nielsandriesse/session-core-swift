
internal extension FixedWidthInteger {

    init?(fromBigEndianBytes bytes: [Byte]) {
        guard bytes.count == MemoryLayout<Self>.size else { return nil }
        self = bytes.reduce(0) { ($0 << 8) | Self($1) }
    }

    var bigEndianBytes: [Byte] {
        return withUnsafeBytes(of: bigEndian) { [Byte]($0) }
    }
}
