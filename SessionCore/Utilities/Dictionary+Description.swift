
internal extension Dictionary {
    
    var prettifiedDescription: String {
        return "[ " + map { key, value in
            let keyDescription = String(describing: key)
            let valueDescription = String(describing: value) // TODO: Call prettifiedDescription on value if it's an array of CustomStringConvertibles or a dictionary
            let maxLength = 40
            let truncatedValueDescription = valueDescription.count > maxLength ? valueDescription.prefix(maxLength) + "..." : valueDescription
            return keyDescription + " : " + truncatedValueDescription
        }.joined(separator: ", ") + " ]"
    }
}
