import CryptoSwift
import PromiseKit

// TODO: Make snodePool, swarmCache and powDifficulty thread safe?

/// See [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf) for more information.
public enum SnodeAPI {
    /// All snode related errors must be handled on this queue to avoid race conditions maintaining e.g. failure counts.
    fileprivate static let errorHandlingQueue = DispatchQueue(label: "SnodeAPI.errorHandlingQueue")
    fileprivate static let seedNodePool: Set<String> = [ "http://storage.seed1.loki.network:22023", "http://storage.seed2.loki.network:38157", "http://149.56.148.124:38157" ]
    fileprivate static var swarmCache: [String:Set<Snode>] = [:]

    /// - Note: Must only be modified from `SnodeAPI.errorHandlingQueue` to avoid race conditions.
    internal static var failureCount: [Snode:UInt] = [:]
    /// - Note: Changing this on the fly is not recommended.
    internal static var mode: Mode = .onion(layerCount: 1)
    internal static var snodePool: Set<Snode> = []
    internal static let workQueue = DispatchQueue(label: "SnodeAPI.workQueue", qos: .userInitiated)

    // MARK: Settings
    private static let minimumSnodeCount: UInt = 2
    private static let targetSnodeCount: UInt = 3

    fileprivate static let failureThreshold: UInt = 2

    internal static let maxRetryCount: UInt = 4
    internal static var powDifficulty: UInt = 1

    // MARK: Mode
    internal enum Mode {
        /// Use onion requests as described in [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf).
        case onion(layerCount: UInt)
        /// Use plain HTTP requests. This mode provides no additional privacy.
        case plain
    }

    // MARK: Error
    public enum Error : LocalizedError {
        case clockOutOfSync
        case insufficientSnodes
        case keyPairGenerationFailed
        case missingSnodeVersion
        case proofOfWorkCalculationFailed
        case randomDataGenerationFailed
        case sharedSecretGenerationFailed
        case snodePoolUpdatingFailed
        case unsupportedSnodeVersion(String)

        public var errorDescription: String? {
            switch self {
            case .clockOutOfSync: return "Your clock is out of sync with the service node network."
            case .insufficientSnodes: return "Couldn't find enough service nodes to build a path."
            case .keyPairGenerationFailed: return "Couldn't generate a key pair."
            case .missingSnodeVersion: return "Missing service node version."
            case .proofOfWorkCalculationFailed: return "Failed to calculate proof of work."
            case .randomDataGenerationFailed: return "Couldn't generate random data."
            case .sharedSecretGenerationFailed: return "Couldn't generate a shared secret."
            case .snodePoolUpdatingFailed: return "Failed to update service node pool."
            case .unsupportedSnodeVersion(let version): return "Unsupported service node version: \(version)."
            }
        }
    }

    // MARK: Internal API
    internal static func invoke(_ method: Snode.Method, on snode: Snode, associatedWith hexEncodedPublicKey: String, parameters: JSON) -> Promise<JSON> {
        let url = "\(snode.address):\(snode.port)/storage_rpc/v1"
        SCLog("Invoking \(method.rawValue) on \(snode) with \(getPrettifiedDescription(parameters)).")
        let parameters: JSON = [ "method" : method.rawValue, "params" : parameters ]
        switch mode {
        case .onion:
        let (promise, seal) = Promise<JSON>.pending()
        workQueue.async {
            let payload: JSON = [ "method" : method.rawValue, "params" : parameters ]
            buildOnion(around: payload, targetedAt: snode).done(on: workQueue) { intermediate in
                let guardSnode = intermediate.guardSnode
                let url = "\(guardSnode.address):\(guardSnode.port)/onion_req"
                let finalEncryptionResult = intermediate.finalEncryptionResult
                let onion = finalEncryptionResult.ciphertext
                let parameters: JSON = [
                    "ciphertext" : onion.base64EncodedString(),
                    "ephemeral_key" : finalEncryptionResult.ephemeralPublicKey.toHexString()
                ]
                let targetSnodeSymmetricKey = intermediate.targetSnodeSymmetricKey
                HTTP.execute(.post, url, parameters: parameters).done(on: workQueue) { json in
                    guard let base64EncodedIVAndCiphertext = json["result"] as? String,
                        let ivAndCiphertext = Data(base64Encoded: base64EncodedIVAndCiphertext) else { return seal.reject(HTTP.Error.invalidJSON) }
                    let iv = ivAndCiphertext[0..<Int(ivSize)]
                    let ciphertext = ivAndCiphertext[Int(ivSize)...]
                    do {
                        let gcm = GCM(iv: iv.bytes, tagLength: Int(gcmTagSize), mode: .combined)
                        let aes = try AES(key: targetSnodeSymmetricKey.bytes, blockMode: gcm, padding: .pkcs7)
                        let data = Data(try aes.decrypt(ciphertext.bytes))
                        do {
                            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? JSON else { return seal.reject(HTTP.Error.invalidJSON) }
                            seal.fulfill(json)
                        } catch (let error) {
                            seal.reject(error)
                        }
                    } catch (let error) {
                        seal.reject(error)
                    }
                }.catch(on: workQueue) { error in
                    seal.reject(error)
                }
            }.catch(on: workQueue) { error in
                seal.reject(error)
            }
        }
        // TODO: Onion request error handling
        return promise
        case .plain: return HTTP.execute(.post, url, parameters: parameters).handlingErrorsIfNeeded(for: snode, associatedWith: hexEncodedPublicKey)
        }
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
                    guard let address = rawSnode["public_ip"] as? String, let port = rawSnode["storage_port"] as? Int,
                        let ed25519PublicKey = rawSnode["pubkey_ed25519"] as? String, let x25519PublicKey = rawSnode["pubkey_x25519"] as? String else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    guard address != "0.0.0.0" else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    return Snode(address: "https://\(address)", port: UInt16(port), publicKeySet: Snode.KeySet(ed25519Key: ed25519PublicKey, x25519Key: x25519PublicKey))
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
                    guard let address = rawSnode["ip"] as? String, let portAsString = rawSnode["port"] as? String, let port = UInt16(portAsString),
                        let ed25519PublicKey = rawSnode["pubkey_ed25519"] as? String, let x25519PublicKey = rawSnode["pubkey_x25519"] as? String else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    guard address != "0.0.0.0" else {
                        SCLog("Failed to parse snode from: \(rawSnode).")
                        return nil
                    }
                    return Snode(address: "https://\(address)", port: port, publicKeySet: Snode.KeySet(ed25519Key: ed25519PublicKey, x25519Key: x25519PublicKey))
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
private extension Promise {

    func handlingErrorsIfNeeded(for snode: Snode, associatedWith hexEncodedPublicKey: String) -> Promise<T> {
        return recover(on: SnodeAPI.errorHandlingQueue) { error -> Promise<T> in
            guard case HTTP.Error.httpRequestFailed(_, _, let statusCode, let json) = error else { throw error }
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
