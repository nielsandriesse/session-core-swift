
public struct Message {
    /// The hex encoded public key of the receiver.
    let destination: String
    /// The content of the message.
    let data: String
    /// The time to live for the message in **milliseconds**.
    let ttl: UInt64
    /// The base 64 encoded proof of work.
    internal var nonce: String? = nil
    /// When proof of work was calculated.
    ///
    /// - Note: Expressed as milliseconds since 00:00:00 UTC on 1 January 1970.
    internal var timestamp: UInt64? = nil
    
    public init(destination: String, data: String, ttl: UInt64) {
        self.destination = destination
        self.data = data
        self.ttl = ttl
    }
    
    internal func toJSON() -> JSON {
        var result: JSON = [ "pubKey" : destination, "data" : data.description, "ttl" : ttl ]
        if let timestamp = timestamp, let nonce = nonce {
            result["timestamp"] = timestamp
            result["nonce"] = nonce
        }
        return result
    }
}
