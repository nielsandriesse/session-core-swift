
internal extension UInt64 {

    init?(fromBigEndianBytes bytes: [Byte]) {
        guard bytes.count == MemoryLayout<UInt64>.size else { return nil }
        self = bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    var bigEndianBytes: [Byte] {
        var result = [Byte](repeating: 0, count: MemoryLayout<UInt64>.size)
        var amountRemaining = self
        for index in result.indices.reversed() {
            let (quotient, remainder) = amountRemaining.quotientAndRemainder(dividingBy: 256)
            result[index] = Byte(remainder)
            guard quotient != 0 else { break }
            amountRemaining = quotient
        }
        return result
    }
}
