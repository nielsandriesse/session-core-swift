import PromiseKit

// See the "Onion Requests" section of [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf) for more information.

extension SnodeAPI {
    /// - Note: Must only be modified from `workQueue`.
    private static var guardSnodes: Set<Snode> = []
    /// - Note: Must only be modified from `workQueue`.
    private static var paths: Set<Path> = []

    private static var reliableSnodePool: Set<Snode> {
        let unreliableSnodes = Set(failureCount.keys)
        return snodePool.subtracting(unreliableSnodes)
    }

    // MARK: Settings
    private static let pathCount: UInt = 2 // A main path and a backup path for the case where the target snode is in the main path

    /// The number of snodes (including the guard snode) in a path.
    private static var pathSize: UInt {
        guard case let .onion(layerCount) = mode else { preconditionFailure("Unexpected mode: \(mode).") }
        return layerCount
    }

    private static var guardSnodeCount: UInt { return pathCount } // One per path

    // MARK: Path
    private typealias Path = [Snode]

    // MARK: Onion Building Result
    internal typealias OnionBuildingResult = (guardSnode: Snode, finalEncryptionResult: EncryptionResult, targetSnodeSymmetricKey: Data)

    // MARK: Private API
    /// Tests the given snode. The returned promise errors out if the snode is faulty; the promise is fulfilled otherwise.
    private static func testSnode(_ snode: Snode) -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        let queue = DispatchQueue.global() // No need to block the work queue for this
        queue.async {
            let url = "\(snode.address):\(snode.port)/get_stats/v1"
            let timeout: TimeInterval = 6 // Use a shorter timeout for testing
            HTTP.execute(.get, url, timeout: timeout).done(on: queue) { json in
                guard let version = json["version"] as? String else { return seal.reject(Error.missingSnodeVersion) }
                if version >= "2.0.0" {
                    seal.fulfill(())
                } else {
                    SCLog("Unsupported snode version: \(version).")
                    seal.reject(Error.unsupportedSnodeVersion(version))
                }
            }.catch(on: queue) { error in
                seal.reject(error)
            }
        }
        return promise
    }

    /// Finds `guardSnodeCount` guard snodes to use for path building. The returned promise errors out with `Error.insufficientSnodes`
    /// if not enough (reliable) snodes are available.
    private static func getGuardSnodes() -> Promise<Set<Snode>> {
        if guardSnodes.count >= guardSnodeCount {
            return Promise<Set<Snode>> { $0.fulfill(guardSnodes) }
        } else {
            SCLog("Populating guard snode cache.")
            return getRandomSnode().then(on: workQueue) { _ -> Promise<Set<Snode>> in // Just used to populate the snode pool
                var unusedSnodes = reliableSnodePool // Sync on workQueue
                guard unusedSnodes.count >= guardSnodeCount else { throw Error.insufficientSnodes }
                func getGuardSnode() -> Promise<Snode> {
                    // randomElement() uses the system's default random generator, which is cryptographically secure
                    guard let candidate = unusedSnodes.randomElement() else { return Promise<Snode> { $0.reject(Error.insufficientSnodes) } }
                    unusedSnodes.remove(candidate) // All used snodes should be unique
                    SCLog("Testing guard snode: \(candidate).")
                    // Loop until a reliable guard snode is found
                    return testSnode(candidate).map(on: workQueue) { candidate }.recover(on: workQueue) { _ in getGuardSnode() }
                }
                let promises = (0..<guardSnodeCount).map { _ in getGuardSnode() }
                return when(fulfilled: promises).map(on: workQueue) { guardSnodes in
                    let guardSnodesAsSet = Set(guardSnodes)
                    SnodeAPI.guardSnodes = guardSnodesAsSet
                    return guardSnodesAsSet
                }
            }
        }
    }

    /// Builds and returns `pathCount` paths. The returned promise errors out with `Error.insufficientSnodes`
    /// if not enough (reliable) snodes are available.
    private static func buildPaths() -> Promise<Set<Path>> {
        SCLog("Building onion request paths.")
        return getRandomSnode().then(on: workQueue) { _ -> Promise<Set<Path>> in // Just used to populate the snode pool
            return getGuardSnodes().map(on: workQueue) { guardSnodes in
                var unusedSnodes = reliableSnodePool.subtracting(guardSnodes)
                let pathSnodeCount = guardSnodeCount * pathSize - guardSnodeCount
                guard unusedSnodes.count >= pathSnodeCount else { throw Error.insufficientSnodes }
                // Don't test path snodes as this would reveal the user's IP to them
                return Set(guardSnodes.map { guardSnode in
                    let result = [ guardSnode ] + (0..<(pathSize - 1)).map { _ in
                        // randomElement() uses the system's default random generator, which is cryptographically secure
                        let pathSnode = unusedSnodes.randomElement()! // Safe because of the minSnodeCount check above
                        unusedSnodes.remove(pathSnode) // All used snodes should be unique
                        return pathSnode
                    }
                    SCLog("Built new onion request path: \(getPrettifiedDescription(result)).")
                    return result
                })
            }
        }
    }

    /// Returns a `Path` to be used for building an onion request. Builds new paths as needed.
    private static func getPath(excluding snode: Snode) -> Promise<Path> {
        guard pathSize >= 1 else { preconditionFailure("Can't build path of size zero.") }
        // randomElement() uses the system's default random generator, which is cryptographically secure
        if paths.count >= pathCount {
            return Promise<Path> { seal in
                seal.fulfill(paths.filter { !$0.contains(snode) }.randomElement()!)
            }
        } else {
            return buildPaths().map(on: workQueue) { paths in
                let path = paths.filter { !$0.contains(snode) }.randomElement()!
                SnodeAPI.paths = paths
                return path
            }
        }
    }

    // MARK: Internal API
    internal static func dropPath(containing snode: Snode) {
        paths = paths.filter { !$0.contains(snode) }
    }

    /// Builds an onion around `payload` and returns the result.
    internal static func buildOnion(around payload: JSON, targetedAt snode: Snode) -> Promise<OnionBuildingResult> {
        var guardSnode: Snode!
        var targetSnodeSymmetricKey: Data! // Needed by invoke(_:on:associatedWith:parameters:) to decrypt the response sent back by the target snode
        var encryptionResult: EncryptionResult!
        return getPath(excluding: snode).then(on: workQueue) { path -> Promise<EncryptionResult> in
            guardSnode = path.first!
            // Encrypt in reverse order, i.e. the target snode first
            return encrypt(payload, forTargetSnode: snode).then(on: workQueue) { r -> Promise<EncryptionResult> in
                targetSnodeSymmetricKey = r.symmetricKey
                // Recursively encrypt the layers of the onion (again in reverse order)
                encryptionResult = r
                var path = path
                var rhs = snode
                func addLayer() -> Promise<EncryptionResult> {
                    if path.isEmpty {
                        return Promise<EncryptionResult> { $0.fulfill(encryptionResult) }
                    } else {
                        let lhs = path.removeLast()
                        return SnodeAPI.encryptHop(from: lhs, to: rhs, using: encryptionResult).then(on: workQueue) { r -> Promise<EncryptionResult> in
                            encryptionResult = r
                            rhs = lhs
                            return addLayer()
                        }
                    }
                }
                return addLayer()
            }
        }.map(on: workQueue) { _ in (guardSnode, encryptionResult, targetSnodeSymmetricKey) }
    }
}
