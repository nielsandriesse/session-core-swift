import CryptoSwift
import PromiseKit

internal extension Message {

    // MARK: Proof of Work Calculation
    /// A modified version of [Bitmessage's Proof of Work Implementation](https://bitmessage.org/wiki/Proof_of_work).
    static func calculatePoW(ttl: UInt64, destination: String, data: String) -> (timestamp: UInt64, base64EncodedNonce: String)? {
        let nonceSize = 8
        // Get millisecond timestamp
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // timeIntervalSince1970 has millisecond level precision
        // Construct payload
        let payloadAsString = String(timestamp) + String(ttl) + destination + data
        let payload = payloadAsString.bytes
        // Calculate target
        let numerator = UInt64.max
        let difficulty = UInt64(SnodeAPI.powDifficulty)
        let totalSize = UInt64(payload.count + nonceSize)
        let ttlInSeconds = ttl / 1000
        let denominator = difficulty * (totalSize + (ttlInSeconds * totalSize) / UInt64(UInt16.max))
        let target = numerator / denominator
        // Calculate proof of work
        var currentValue = UInt64.max
        let payloadHash = payload.sha512()
        var nonce = [Byte](repeating: 0, count: nonceSize)
        while currentValue > target {
            nonce = nonce.adding(1)
            let hash = (nonce + payloadHash).sha512()
            guard let value = UInt64([Byte](hash[0..<nonceSize])) else { return nil }
            currentValue = value
        }
        // Encode as base 64
        let base64EncodedNonce = nonce.toBase64()!
        // Return
        return (timestamp, base64EncodedNonce)
    }

    /// See [Bitmessage's Proof of Work Implementation](https://bitmessage.org/wiki/Proof_of_work) for more information.
    func calculatePoW() -> Promise<Message> {
        var copy = self
        return Promise<Message> { seal in
            DispatchQueue.global().async {
                guard let (timestamp, base64EncodedNonce) = Message.calculatePoW(ttl: copy.ttl, destination: copy.destination, data: copy.data) else { return seal.reject(SnodeAPI.Error.proofOfWorkCalculationFailed) }
                copy.timestamp = timestamp
                copy.nonce = base64EncodedNonce
                seal.fulfill(copy)
            }
        }
    }
}

// MARK: Convenience
private typealias Byte = UInt8

private extension UInt64 {

    /// Assumes `bytes` is big endian.
    init?(_ bytes: [Byte]) {
        guard bytes.count <= MemoryLayout<UInt64>.size else { return nil }
        self = bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private extension MutableCollection where Element == Byte {

    /// Assumes `self` represents a big endian number.
    ///
    /// - Note: Can overflow.
    func adding(_ amount: Int) -> Self {
        var result = self
        var amountRemaining = amount
        for index in result.indices.reversed() {
            guard amountRemaining > 0 else { break }
            let sum = Int(result[index]) + amountRemaining
            let (quotient, remainder) = sum.quotientAndRemainder(dividingBy: 256)
            result[index] = Byte(remainder)
            amountRemaining = quotient
        }
        return result
    }
}
