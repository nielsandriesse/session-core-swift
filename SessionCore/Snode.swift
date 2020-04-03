
/// A Loki Service Node as described in [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf).
internal struct Snode : Hashable, CustomStringConvertible {
    internal let address: String
    internal let port: UInt16
    internal let publicKeySet: KeySet

    internal struct KeySet : Hashable {
        let ed25519Key: String
        let x25519Key: String
    }

    internal enum Method : String {
        case getStats = "get_stats"
        case getSwarm = "get_snodes_for_pubkey"
        case getMessages = "retrieve"
        case sendMessage = "store"
    }

    internal var description: String { return "\(address):\(port)" }
}
