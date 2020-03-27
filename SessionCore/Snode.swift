
internal struct Snode : Hashable, CustomStringConvertible {
    internal let address: String
    internal let port: UInt16

    internal enum Method : String {
        case getStats = "get_stats"
        case getSwarm = "get_snodes_for_pubkey"
        case getMessages = "retrieve"
        case sendMessage = "store"
    }

    internal var description: String { return "\(address):\(port)" }
}
