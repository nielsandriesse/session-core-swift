import CryptoSwift
import PromiseKit

/// See [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf) for more information.
public enum SnodeAPI {
    private static let seedNodePool: Set<String> = [
        "https://storage.seed1.loki.network", "https://storage.seed3.loki.network", "https://public.loki.foundation"
    ]
    /// - Note: Must only be modified from `SnodeAPI.queue`.
    private static var swarmCache: [String:Set<Snode>] = [:]

    internal static let queue = DispatchQueue(label: "SnodeAPI.queue", qos: .userInitiated)
    /// - Note: Must only be modified from `SnodeAPI.queue`.
    internal static var failureCount: [Snode:UInt] = [:]
    /// - Note: Changing this on the fly is not recommended.
    internal static var mode: Mode = .onion(layerCount: 3)
    /// - Note: Must only be modified from `SnodeAPI.queue`.
    internal static var snodePool: Set<Snode> = []

    // MARK: Settings
    private static let failureThreshold: UInt = 2
    private static let minimumSnodeCount: UInt = 2
    private static let targetSnodeCount: UInt = 3

    internal static let maxRetryCount: UInt = 4
    internal static var powDifficulty: UInt = 1

    // MARK: Mode
    internal enum Mode {
        /// Use onion requests as described in [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf).
        case onion(layerCount: UInt)
        /// Use plain HTTP requests. This mode provides no privacy.
        case plain
    }

    // MARK: Error
    public enum Error : LocalizedError {
        case clockOutOfSync
        case httpRequestFailedAtTargetSnode(verb: HTTP.Verb, url: String, statusCode: UInt, json: JSON)
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
            case .httpRequestFailedAtTargetSnode(let verb, let url, let statusCode, let json):
                return "\(verb.rawValue) request to \(url) failed at target service node with status code: \(statusCode) (\(getPrettifiedDescription(json)))."
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
        SCLog("Invoking \(method.rawValue) on \(snode) with \(getPrettifiedDescription(parameters)).")
        let url = "\(snode.address):\(snode.port)/storage_rpc/v1"
        let parameters: JSON = [ "method" : method.rawValue, "params" : parameters ]
        switch mode {
        case .onion:
        let (promise, seal) = Promise<JSON>.pending()
        var guardSnode: Snode!
        queue.async {
            buildOnion(around: parameters, targetedAt: snode).done(on: queue) { intermediate in
                guardSnode = intermediate.guardSnode
                let url = "\(guardSnode.address):\(guardSnode.port)/onion_req"
                let finalEncryptionResult = intermediate.finalEncryptionResult
                let onion = finalEncryptionResult.ciphertext
                let parameters: JSON = [
                    "ciphertext" : onion.base64EncodedString(),
                    "ephemeral_key" : finalEncryptionResult.ephemeralPublicKey.toHexString()
                ]
                let targetSnodeSymmetricKey = intermediate.targetSnodeSymmetricKey
                HTTP.execute(.post, url, parameters: parameters).done(on: queue) { json in
                    guard let base64EncodedIVAndCiphertext = json["result"] as? String,
                        let ivAndCiphertext = Data(base64Encoded: base64EncodedIVAndCiphertext) else { return seal.reject(HTTP.Error.invalidJSON) }
                    let iv = ivAndCiphertext[0..<Int(ivSize)]
                    let ciphertext = ivAndCiphertext[Int(ivSize)...]
                    do {
                        // These settings should match those in SnodeAPI+OnionRequestEncryption
                        let gcm = GCM(iv: iv.bytes, tagLength: Int(gcmTagSize), mode: .combined)
                        let aes = try AES(key: targetSnodeSymmetricKey.bytes, blockMode: gcm, padding: .noPadding)
                        let data = Data(try aes.decrypt(ciphertext.bytes))
                        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? JSON,
                            let bodyAsString = json["body"] as? String, let bodyAsData = bodyAsString.data(using: .utf8),
                            let body = try JSONSerialization.jsonObject(with: bodyAsData, options: []) as? JSON,
                            let statusCode = json["status"] as? Int else { return seal.reject(HTTP.Error.invalidJSON) }
                        guard 200...299 ~= statusCode else { return seal.reject(Error.httpRequestFailedAtTargetSnode(verb: .post, url: url, statusCode: UInt(statusCode), json: body)) }
                        seal.fulfill(body)
                    } catch {
                        seal.reject(error)
                    }
                }.catch(on: queue) { error in
                    seal.reject(error)
                }
            }.catch(on: queue) { error in
                seal.reject(error)
            }
        }
        promise.catch(on: queue) { error in
            guard case HTTP.Error.httpRequestFailed(_, _, _, _) = error else { return }
            dropPath(containing: guardSnode) // A snode in the path is bad; retry with a different path
        }
        let _ = promise.recover(on: queue) { error -> Promise<JSON> in
            guard case Error.httpRequestFailedAtTargetSnode(_, _, let statusCode, let json) = error else { throw error }
            try SnodeAPI.handleError(withStatusCode: statusCode, json: json, for: snode, associatedWith: hexEncodedPublicKey)
            throw error
        }
        return promise
        case .plain:
        let promise =  HTTP.execute(.post, url, parameters: parameters)
        let _ = promise.recover(on: queue) { error -> Promise<JSON> in
            guard case HTTP.Error.httpRequestFailed(_, _, let statusCode, let json) = error else { throw error }
            try SnodeAPI.handleError(withStatusCode: statusCode, json: json, for: snode, associatedWith: hexEncodedPublicKey)
            throw error
        }
        return promise
        }
    }

    internal static func getRandomSnode() -> Promise<Snode> {
        if snodePool.isEmpty {
            // randomElement() uses the system's default random generator, which is cryptographically secure
            let seedNode = seedNodePool.randomElement()!
            let url = "\(seedNode)/json_rpc"
            let parameters: JSON = [
                "method" : "get_n_service_nodes",
                "params" : [
                    "active_only" : true,
                    "fields" : [ "public_ip" : true, "storage_port" : true, "pubkey_ed25519" : true, "pubkey_x25519" : true ]
                ]
            ]
            return HTTP.execute(.post, url, parameters: parameters).map(on: queue) { json in
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
            return getRandomSnode().then(on: queue) { randomSnode in
                invoke(.getSwarm, on: randomSnode, associatedWith: hexEncodedPublicKey, parameters: parameters)
            }.map(on: queue) { json in
                // The response returned by invoking get_snodes_for_pubkey on a snode is different from that returned by
                // invoking get_n_service_nodes on a seed node, so unfortunately the parsing code below can't easily
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
        return getSwarm(for: hexEncodedPublicKey).map(on: queue) { Set($0.shuffled().prefix(Int(targetSnodeCount))) }
    }

    internal static func dropSnodeIfNeeded(_ snode: Snode, associatedWith hexEncodedPublicKey: String) {
        swarmCache[hexEncodedPublicKey]?.remove(snode)
    }
    
    // MARK: Public API
    public static func getMessages(for hexEncodedPublicKey: String) -> Promise<Set<Promise<JSON>>> {
        let (promise, seal) = Promise<Set<Promise<JSON>>>.pending()
        queue.async {
            getTargetSnodes(for: hexEncodedPublicKey).mapValues(on: queue) { snode in
                let parameters = [ "pubKey" : hexEncodedPublicKey ]
                return invoke(.getMessages, on: snode, associatedWith: hexEncodedPublicKey, parameters: parameters)
            }.map(on: queue) { promises in
                Set(promises)
            }.done(on: queue) { promises in
                seal.fulfill(promises)
            }.catch(on: queue) { error in
                seal.reject(error)
            }
        }
        return promise
    }

    public static func sendMessage(_ message: Message) -> Promise<Set<Promise<JSON>>> {
        let powPromise = message.calculatePoW()
        let destination = message.destination
        let (getTargetSnodesPromise, seal) = Promise<Set<Snode>>.pending()
        queue.async {
            attempt(maxRetryCount: maxRetryCount, recoveringOn: queue) {
                getTargetSnodes(for: destination)
            }.done(on: queue) { snodes in
                seal.fulfill(snodes)
            }.catch(on: queue) { error in
                seal.reject(error)
            }
        }
        return when(fulfilled: powPromise, getTargetSnodesPromise).map(on: queue) { messageWithPoW, snodes in
            let parameters = messageWithPoW.toJSON()
            return Set(snodes.map { snode in
                attempt(maxRetryCount: maxRetryCount, recoveringOn: queue) {
                    invoke(.sendMessage, on: snode, associatedWith: destination, parameters: parameters)
                }.map(on: queue) { json in
                    if let powDifficulty = json["difficulty"] as? Int {
                        guard powDifficulty != SnodeAPI.powDifficulty else { return json }
                        SCLog("Setting proof of work difficulty to \(powDifficulty).")
                        SnodeAPI.powDifficulty = UInt(powDifficulty)
                    } else {
                        SCLog("Failed to update proof of work difficulty from: \(json).")
                    }
                    return json
                }
            })
        }
    }

    // MARK: Error Handling
    private static func handleError(withStatusCode statusCode: UInt, json: JSON?, for snode: Snode, associatedWith hexEncodedPublicKey: String) throws {
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
    }
}
