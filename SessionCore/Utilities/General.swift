
internal typealias Byte = UInt8

internal func getPrettifiedDescription(_ subject: Any) -> String {
    switch subject {
    case let array as Array<Any>:
        return "[ " + array.map { getPrettifiedDescription($0) }.joined(separator: ", ") + " ]"
    case let dictionary as Dictionary<AnyHashable, Any>:
        return "[ " + dictionary.map { key, value in
            let keyDescription = getPrettifiedDescription(key)
            let valueDescription = getPrettifiedDescription(value)
            return keyDescription + " : " + valueDescription
        }.joined(separator: ", ") + " ]"
    default: return String(describing: subject)
    }
}

public typealias JSON = [String:Any]

internal func SCLog(_ message: String) {
    print("[Session Core] \(message)")
}
