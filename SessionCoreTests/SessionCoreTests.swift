import CryptoSwift
import PromiseKit
@testable import SessionCore
import XCTest

// TODO: Test error handling
// TODO: Test race condition handling

class SessionCoreTests : XCTestCase {
    private let maxRetryCount: UInt = 2 // Be a bit more stringent when testing
    private let testPublicKey = "0501da4723331eb54aaa9a6753a0a59f762103de63f1dc40879cb65a5b5f508814"
    // The TTL for a default Session message
    private let testTTL: UInt64 = 24 * 60 * 60 * 1000

    func testGetRandomSnode() {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error? = nil
        SnodeAPI.mode = .plain
        let _ = SnodeAPI.getRandomSnode().retryingIfNeeded(maxRetryCount: maxRetryCount).done(on: SnodeAPI.workQueue) { _ in
            semaphore.signal()
        }.catch(on: SnodeAPI.workQueue) {
            error = $0; semaphore.signal()
        }
        semaphore.wait()
        XCTAssert(error == nil)
    }

    func testGetSwarm() {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error? = nil
        SnodeAPI.mode = .plain
        let _ = SnodeAPI.getSwarm(for: testPublicKey).retryingIfNeeded(maxRetryCount: maxRetryCount).done(on: SnodeAPI.workQueue) { _ in
            semaphore.signal()
        }.catch(on: SnodeAPI.workQueue) {
            error = $0; semaphore.signal()
        }
        semaphore.wait()
        XCTAssert(error == nil)
    }

    func testGetTargetSnodes() {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error? = nil
        SnodeAPI.mode = .plain
        let _ = SnodeAPI.getTargetSnodes(for: testPublicKey).retryingIfNeeded(maxRetryCount: maxRetryCount).done(on: SnodeAPI.workQueue) { _ in
            semaphore.signal()
        }.catch(on: SnodeAPI.workQueue) {
            error = $0; semaphore.signal()
        }
        semaphore.wait()
        XCTAssert(error == nil)
    }

    func testGetMessages() {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error? = nil
        SnodeAPI.mode = .plain
        let _ = SnodeAPI.getMessages(for: testPublicKey).retryingIfNeeded(maxRetryCount: maxRetryCount).done(on: SnodeAPI.workQueue) { _ in
            semaphore.signal()
        }.catch(on: SnodeAPI.workQueue) {
            error = $0; semaphore.signal()
        }
        semaphore.wait()
        XCTAssert(error == nil)
    }

    func testSendMessage() {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error? = nil
        // A random 256 x 256 x 16 JPEG image generated at https://yulvil.github.io/gopherjs/02/
        let data = "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"
        let message = Message(destination: testPublicKey, data: data, ttl: testTTL)
        SnodeAPI.mode = .plain
        let _ = SnodeAPI.sendMessage(message).done(on: SnodeAPI.workQueue) { promises in // Retrying happens internally
            var isSuccessful = false
            let promiseCount = promises.count
            var errorCount = 0
            promises.forEach { promise in
                promise.done(on: SnodeAPI.workQueue) { _ in
                    guard !isSuccessful else { return } // Succeed as soon as the first promise succeeds
                    isSuccessful = true
                    semaphore.signal()
                }.catch(on: SnodeAPI.workQueue) {
                    errorCount = errorCount + 1;
                    guard errorCount == promiseCount else { return } // Only error out if all promises failed
                    error = $0; semaphore.signal()
                }
            }
        }.catch(on: SnodeAPI.workQueue) {
            error = $0; semaphore.signal()
        }
        semaphore.wait()
        XCTAssert(error == nil)
    }

    func testCalculatePoW() {
        // A random 512 x 512 x 32 JPEG image generated at https://yulvil.github.io/gopherjs/02/
        let data = "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"
        let _ = Message.calculatePow(ttl: testTTL, destination: testPublicKey, data: data)
    }

    func testSendOnionRequest() {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error? = nil
        SnodeAPI.mode = .onion(layerCount: 3)
        let _ = SnodeAPI.getSwarm(for: testPublicKey).retryingIfNeeded(maxRetryCount: maxRetryCount).done(on: SnodeAPI.workQueue) { _ in
            semaphore.signal()
        }.catch(on: SnodeAPI.workQueue) {
            error = $0; semaphore.signal()
        }
        semaphore.wait()
        XCTAssert(error == nil)
    }
}
