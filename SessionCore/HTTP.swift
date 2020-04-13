import PromiseKit

public enum HTTP {
    private static let urlSession = URLSession(configuration: .ephemeral, delegate: urlSessionDelegate, delegateQueue: nil)
    private static let urlSessionDelegate = URLSessionDelegateImplementation()

    // MARK: Settings
    private static let timeout: TimeInterval = 10

    // MARK: URL Session Delegate Implementation
    private final class URLSessionDelegateImplementation : NSObject, URLSessionDelegate {

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Snode to snode communication uses self-signed certificates but clients can safely ignore this
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        }
    }

    // MARK: Verb
    public enum Verb : String {
        case get = "GET"
        case put = "PUT"
        case post = "POST"
        case delete = "DELETE"
    }

    // MARK: Error
    internal enum Error : LocalizedError {
        case generic
        case httpRequestFailed(verb: Verb, url: String, statusCode: UInt, json: JSON?)
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .generic: return "An error occurred."
            case .httpRequestFailed(let verb, let url, let statusCode, let json):
                let jsonDescription = json.map { getPrettifiedDescription($0) } ?? "no debugging info provided"
                return "\(verb.rawValue) request to \(url) failed with status code: \(statusCode) (\(jsonDescription))."
            case .invalidJSON: return "Invalid JSON."
            }
        }
    }

    // MARK: Main
    internal static func execute(_ verb: Verb, _ url: String, parameters: JSON? = nil, timeout: TimeInterval = HTTP.timeout) -> Promise<JSON> {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = verb.rawValue
        if let parameters = parameters {
            do {
                guard JSONSerialization.isValidJSONObject(parameters) else { return Promise(error: Error.invalidJSON) }
                request.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: [])
            } catch {
                return Promise(error: error)
            }
        }
        request.timeoutInterval = timeout
        let (promise, seal) = Promise<JSON>.pending()
        let task = urlSession.dataTask(with: request) { data, response, error in
            guard let data = data, let response = response as? HTTPURLResponse else {
                if let error = error {
                    SCLog("\(verb.rawValue) request to \(url) failed due to error: \(error).")
                } else {
                    SCLog("\(verb.rawValue) request to \(url) failed.")
                }
                // Override the actual error so that we can correctly catch failed requests in invoke(_:on:associatedWith:parameters:)
                return seal.reject(Error.httpRequestFailed(verb: verb, url: url, statusCode: 0, json: nil))
            }
            if let error = error {
                SCLog("\(verb.rawValue) request to \(url) failed due to error: \(error).")
                // Override the actual error so that we can correctly catch failed requests in invoke(_:on:associatedWith:parameters:)
                return seal.reject(Error.httpRequestFailed(verb: verb, url: url, statusCode: 0, json: nil))
            }
            let statusCode = UInt(response.statusCode)
            var json: JSON? = nil
            if let j = try? JSONSerialization.jsonObject(with: data, options: []) as? JSON {
                json = j
            } else if let result = String(data: data, encoding: .utf8) {
                json = [ "result" : result ]
            }
            guard 200...299 ~= statusCode else {
                let jsonDescription = json.map { getPrettifiedDescription($0) } ?? "no debugging info provided"
                SCLog("\(verb.rawValue) request to \(url) failed with status code: \(statusCode) (\(jsonDescription)).")
                return seal.reject(Error.httpRequestFailed(verb: verb, url: url, statusCode: statusCode, json: json))
            }
            if let json = json {
                seal.fulfill(json)
            } else {
                SCLog("Couldn't parse JSON returned by \(verb.rawValue) request to \(url).")
                seal.reject(Error.invalidJSON)
            }
        }
        task.resume()
        return promise
    }
}
