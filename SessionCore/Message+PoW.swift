import CryptoSwift
import PromiseKit

// TODO: Clean

public extension Message {

    // MARK: Settings
    private static let nonceSize = 8

    // MARK: Proof of Work Calculation
    /// See [Bitmessage's Proof of Work Implementation](https://bitmessage.org/wiki/Proof_of_work) for more information.
    ///
    /// - Note: Exposed for testing purposes.
    static func calculatePow(ttl: UInt64, destination: String, data: String) -> (timestamp: UInt64, base64EncodedNonce: String) {
        // Get millisecond timestamp
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // timeIntervalSince1970 has millisecond level precision
        // Construct payload
        let payloadAsString = String(timestamp) + String(ttl) + destination + data
        let payload = payloadAsString.bytes
        // Calculate target
        let numerator = UInt64.max
        let difficulty = UInt64(SnodeAPI.powDifficulty)
        let totalSize = UInt64(payload.count + Message.nonceSize)
        let ttlInSeconds = ttl / 1000
        let denominator = difficulty * (totalSize + (ttlInSeconds * totalSize) / UInt64(UInt16.max))
        let target = numerator / denominator
        // Calculate proof of work
        var currentTrialValue = UInt64.max
        let initialHash = payload.sha512()
        var nonce = [Byte](repeating: 0, count: Message.nonceSize)
        while currentTrialValue > target {
            nonce = nonce.increment(by: 1)
            let newHash = (nonce + initialHash).sha512()
            currentTrialValue = UInt64([Byte](newHash[0..<8]))
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
                let (timestamp, base64EncodedNonce) = Message.calculatePow(ttl: copy.ttl, destination: copy.destination, data: copy.data)
                copy.timestamp = timestamp
                copy.nonce = base64EncodedNonce
                seal.fulfill(copy)
            }
        }
    }
}

private typealias Byte = UInt8

private extension MutableCollection where Element == Byte {

    func increment(by amount: Int) -> Self {
        var result = self
        var amountRemaining = amount
        for index in result.indices.reversed() {
            guard amountRemaining > 0 else { break }
            let sum = Int(result[index]) + amountRemaining
            result[index] = Byte(sum % 256)
            amountRemaining = sum / 256
        }
        return result
    }
}

private extension UInt64 {

    init(_ bytes: [Byte]) {
        precondition(bytes.count <= MemoryLayout<UInt64>.size)
        self = bytes.reduce(0) { current, byte in
            var new = current
            new = new << 8
            new = new | UInt64(byte)
            return new
        }
    }
}
