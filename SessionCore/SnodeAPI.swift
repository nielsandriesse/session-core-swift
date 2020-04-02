import PromiseKit

// TODO: Make snodePool, swarmCache and powDifficulty thread safe?
// TODO: Onion routing

public enum SnodeAPI {
    /// All snode related errors must be handled on this queue to avoid race conditions maintaining e.g. failure counts.
    fileprivate static let errorHandlingQueue = DispatchQueue(label: "SnodeAPI.errorHandlingQueue")
    fileprivate static let seedNodePool: Set<String> = [ "http://storage.seed1.loki.network:22023", "http://storage.seed2.loki.network:38157", "http://149.56.148.124:38157" ]
    /// - Note: Must only be modified from `SnodeAPI.errorHandlingQueue` to avoid race conditions.
    fileprivate static var failureCount: [Snode:UInt] = [:]
    fileprivate static var snodePool: Set<Snode> = []
    fileprivate static var swarmCache: [String:Set<Snode>] = [:]

    internal static let workQueue = DispatchQueue(label: "SnodeAPI.workQueue")

    // MARK: Settings
    private static let minimumSnodeCount: UInt = 2
    private static let targetSnodeCount: UInt = 3

    fileprivate static let failureThreshold: UInt = 2

    internal static let maxRetryCount: UInt = 4
    internal static var powDifficulty: UInt = 1

    // MARK: Error
    public enum Error : LocalizedError {
        case clockOutOfSync
        case proofOfWorkCalculationFailed
        case snodePoolUpdatingFailed

        public var errorDescription: String? {
            switch self {
            case .clockOutOfSync: return "Your clock is out of sync with the service node network."
            case .proofOfWorkCalculationFailed: return "Failed to calculate proof of work."
            case .snodePoolUpdatingFailed: return "Failed to update service node pool."
            }
        }
    }
    // MARK: Internal API
    internal static func invoke(_ method: Snode.Method, on snode: Snode, associatedWith hexEncodedPublicKey: String, parameters: JSON) -> Promise<JSON> {
        let url = "\(snode.address):\(snode.port)/storage_rpc/v1"
        SCLog("Invoking \(method.rawValue) on \(snode) with \(parameters.prettifiedDescription).")
        let parameters: JSON = [ "method" : method.rawValue, "params" : parameters ]
        return HTTP.execute(.post, url, parameters: parameters).handlingErrorsIfNeeded(for: snode, associatedWith: hexEncodedPublicKey)
    }

    internal static func getRandomSnode() -> Promise<Snode> {
        if snodePool.isEmpty {
            // randomElement() uses the system's default random generator, which is cryptographically secure
            let seedNode = seedNodePool.randomElement()!
            let url = "\(seedNode)/json_rpc"
            let parameters: JSON = [
                "method" : "get_service_nodes",
                "params" : [
                    "active_only" : true,
                    "fields" : [ "public_ip" : true, "storage_port" : true ]
                ]
            ]
            return HTTP.execute(.post, url, parameters: parameters).map(on: workQueue) { json in
                guard let intermediate = json["result"] as? JSON,
                    let rawSnodes = intermediate["service_node_states"] as? [JSON] else { throw Error.snodePoolUpdatingFailed }
                snodePool = Set(rawSnodes.compactMap { rawSnode in
                    guard let address = rawSnode["public_ip"] as? String, let port = rawSnode["storage_port"] as? Int else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    guard address != "0.0.0.0" else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    return Snode(address: "https://\(address)", port: UInt16(port))
                })
                // randomElement() uses the system's default random generator, which is cryptographically secure
                return snodePool.randomElement()!
            }
        } else {
            return Promise<Snode> { seal in
                // randomElement() uses the system's default random generator, which is cryptographically secure
                seal.fulfill(snodePool.randomElement()!)
            }
        }
    }

    internal static func getSwarm(for hexEncodedPublicKey: String) -> Promise<Set<Snode>> {
        if let cachedSwarm = swarmCache[hexEncodedPublicKey], cachedSwarm.count >= minimumSnodeCount {
            return Promise<Set<Snode>> { $0.fulfill(cachedSwarm) }
        } else {
            let parameters: JSON = [ "pubKey" : hexEncodedPublicKey ]
            return getRandomSnode().then(on: workQueue) { randomSnode in
                invoke(.getSwarm, on: randomSnode, associatedWith: hexEncodedPublicKey, parameters: parameters)
            }.map(on: workQueue) { json in
                // The response returned by invoking get_snodes_for_pubkey on a snode is different from that returned by
                // invoking get_service_nodes on a seed node, so unfortunately the parsing code below can't easily
                // be unified with the parsing code in getRandomSnode()
                guard let rawSnodes = json["snodes"] as? [JSON] else {
                    SCLog("Failed to parse snodes from: \(json).")
                    return []
                }
                let swarm: Set<Snode> = Set(rawSnodes.compactMap { rawSnode in
                    guard let address = rawSnode["ip"] as? String, let portAsString = rawSnode["port"] as? String, let port = UInt16(portAsString) else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    guard address != "0.0.0.0" else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    return Snode(address: "https://\(address)", port: port)
                })
                swarmCache[hexEncodedPublicKey] = swarm
                return swarm
            }
        }
    }

    internal static func getTargetSnodes(for hexEncodedPublicKey: String) -> Promise<Set<Snode>> {
        // shuffled() uses the system's default random generator, which is cryptographically secure
        return getSwarm(for: hexEncodedPublicKey).map(on: workQueue) { Set($0.shuffled().prefix(Int(targetSnodeCount))) }
    }

    internal static func dropSnodeIfNeeded(_ snode: Snode, associatedWith hexEncodedPublicKey: String) {
        let swarm = swarmCache[hexEncodedPublicKey]
        if var swarm = swarm, let index = swarm.firstIndex(of: snode) {
            swarm.remove(at: index)
            swarmCache[hexEncodedPublicKey] = swarm
        }
    }
    
    // MARK: Public API
    public static func getMessages(for hexEncodedPublicKey: String) -> Promise<Set<Promise<JSON>>> {
        return getTargetSnodes(for: hexEncodedPublicKey).mapValues(on: workQueue) { snode in
            let parameters = [ "pubKey" : hexEncodedPublicKey ]
            return invoke(.getMessages, on: snode, associatedWith: hexEncodedPublicKey, parameters: parameters)
        }.map(on: workQueue) { Set($0) }
    }

    public static func sendMessage(_ message: Message) -> Promise<Set<Promise<JSON>>> {
        let destination = message.destination
        // TODO: Calculate proof of work and get target snodes simultaneously?
        return message.calculatePoW().then(on: workQueue) { messageWithPoW in
            return getTargetSnodes(for: destination).map(on: workQueue) { snodes in
                let parameters = messageWithPoW.toJSON()
                return Set(snodes.map { snode in
                    return invoke(.sendMessage, on: snode, associatedWith: destination, parameters: parameters).map(on: workQueue) { json in
                        if let powDifficulty = json["difficulty"] as? Int {
                            guard powDifficulty != SnodeAPI.powDifficulty else { return json }
                            SCLog("Setting proof of work difficulty to \(powDifficulty).")
                            SnodeAPI.powDifficulty = UInt(powDifficulty)
                        } else {
                            SCLog("Failed to update proof of work difficulty from: \(json).")
                        }
                        return json
                    }.retryingIfNeeded(maxRetryCount: maxRetryCount)
                })
            }.retryingIfNeeded(maxRetryCount: maxRetryCount)
        }
    }
}

// MARK: Snode Error Handling
internal extension Promise {

    func handlingErrorsIfNeeded(for snode: Snode, associatedWith hexEncodedPublicKey: String) -> Promise<T> {
        return recover(on: SnodeAPI.errorHandlingQueue) { error -> Promise<T> in
            guard case HTTP.Error.httpRequestFailed(let statusCode, let json) = error else { throw error }
            switch statusCode {
            case 0, 400, 500, 503:
                // The snode is unreachable
                let oldFailureCount = SnodeAPI.failureCount[snode] ?? 0
                let newFailureCount = oldFailureCount + 1
                SnodeAPI.failureCount[snode] = newFailureCount
                SCLog("Couldn't reach snode at: \(snode); setting failure count to \(newFailureCount).")
                if newFailureCount >= SnodeAPI.failureThreshold {
                    SCLog("Failure threshold reached for: \(snode); dropping it.")
                    SnodeAPI.dropSnodeIfNeeded(snode, associatedWith: hexEncodedPublicKey) // Remove it from the swarm cache associated with the given public key
                    SnodeAPI.snodePool.remove(snode) // Remove it from the random snode pool
                    SnodeAPI.failureCount[snode] = 0
                }
            case 406:
                SCLog("The user's clock is out of sync with the service node network.")
                throw SnodeAPI.Error.clockOutOfSync
            case 421:
                // The snode isn't associated with the given public key anymore
                SCLog("Invalidating swarm for: \(hexEncodedPublicKey).")
                SnodeAPI.dropSnodeIfNeeded(snode, associatedWith: hexEncodedPublicKey)
            case 432:
                // The proof of work difficulty is too low
                if let json = json, let powDifficulty = json["difficulty"] as? Int {
                    SCLog("Setting proof of work difficulty to \(powDifficulty).")
                    SnodeAPI.powDifficulty = UInt(powDifficulty)
                } else {
                    SCLog("Failed to update proof of work difficulty.")
                }
                break
            default: break
            }
            throw error
        }
    }
}
