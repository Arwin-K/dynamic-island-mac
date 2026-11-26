import Foundation

/// Decodes a `Codable` value from user-edited JSON without ever failing on a missing,
/// unknown or malformed key.
///
/// Why not plain `JSONDecoder`? Theme and preference files are edited by hand and shared
/// between app versions. A theme written for v0.1 must still load in v2.0 after we add
/// keys, and a typo in one color must not throw away the whole theme. So:
///
/// 1. Encode the defaults to a JSON tree.
/// 2. Deep-merge the user's tree on top (unknown keys are carried along and ignored by
///    `Codable`; missing keys come from the defaults).
/// 3. Decode. If a key has the wrong type or an invalid value, `DecodingError` tells us
///    its coding path: replace that value with the default at the same path (or drop it
///    if there is no default, e.g. inside a dictionary) and try again.
///
/// Every substitution is reported as a warning so Settings can show it.
enum TolerantDecoder {
    struct Result<T> {
        var value: T
        var warnings: [String]
    }

    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) -> Result<T> {
        var warnings: [String] = []
        let encoder = JSONEncoder()
        guard
            let defaultData = try? encoder.encode(defaults),
            let defaultTree = try? JSONSerialization.jsonObject(with: defaultData)
        else {
            return Result(value: defaults, warnings: ["Could not encode defaults"])
        }

        let userTree: Any
        do {
            userTree = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return Result(value: defaults, warnings: ["Invalid JSON: \(error.localizedDescription)"])
        }
        guard userTree is [String: Any] else {
            return Result(value: defaults, warnings: ["Top level must be a JSON object"])
        }

        var merged = deepMerge(defaultTree, userTree)
        let decoder = JSONDecoder()
        for _ in 0..<64 {
            do {
                let mergedData = try JSONSerialization.data(withJSONObject: merged)
                let value = try decoder.decode(T.self, from: mergedData)
                return Result(value: value, warnings: warnings)
            } catch let error as DecodingError {
                guard let path = codingPath(of: error), !path.isEmpty else {
                    warnings.append("Could not decode: \(error)")
                    return Result(value: defaults, warnings: warnings)
                }
                let keyPath = path.map { $0.intValue.map(String.init) ?? $0.stringValue }
                warnings.append("Ignored invalid value at \(keyPath.joined(separator: "."))")
                let before = merged
                if let fallback = value(at: keyPath, in: defaultTree) {
                    merged = setting(fallback, at: keyPath, in: merged)
                } else {
                    merged = removing(at: keyPath, in: merged)
                }
                // No default and nothing to remove (e.g. a required key missing inside a
                // dictionary entry): drop the whole entry rather than looping.
                if (try? JSONSerialization.data(withJSONObject: merged, options: .sortedKeys)) == (try? JSONSerialization.data(withJSONObject: before, options: .sortedKeys)), keyPath.count > 1 {
                    merged = removing(at: Array(keyPath.dropLast()), in: merged)
                }
            } catch {
                warnings.append("Could not decode: \(error.localizedDescription)")
                return Result(value: defaults, warnings: warnings)
            }
        }
        return Result(value: defaults, warnings: warnings + ["Too many invalid values; using defaults"])
    }

    // MARK: - Tree helpers

    static func deepMerge(_ base: Any, _ overlay: Any) -> Any {
        guard let baseDict = base as? [String: Any], let overlayDict = overlay as? [String: Any] else {
            return overlay
        }
        var result = baseDict
        for (key, value) in overlayDict {
            if let existing = result[key] {
                result[key] = deepMerge(existing, value)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func codingPath(of error: DecodingError) -> [CodingKey]? {
        switch error {
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return ctx.codingPath
        case .keyNotFound(let key, let ctx):
            return ctx.codingPath + [key]
        @unknown default:
            return nil
        }
    }

    private static func value(at path: [String], in tree: Any) -> Any? {
        var node: Any = tree
        for component in path {
            if let dict = node as? [String: Any], let next = dict[component] {
                node = next
            } else if let array = node as? [Any], let index = Int(component), array.indices.contains(index) {
                node = array[index]
            } else {
                return nil
            }
        }
        return node
    }

    private static func setting(_ newValue: Any, at path: [String], in tree: Any) -> Any {
        guard let head = path.first else { return newValue }
        let rest = Array(path.dropFirst())
        if var dict = tree as? [String: Any] {
            dict[head] = setting(newValue, at: rest, in: dict[head] ?? [String: Any]())
            return dict
        }
        if var array = tree as? [Any], let index = Int(head), array.indices.contains(index) {
            array[index] = setting(newValue, at: rest, in: array[index])
            return array
        }
        return tree
    }

    private static func removing(at path: [String], in tree: Any) -> Any {
        guard let head = path.first else { return tree }
        let rest = Array(path.dropFirst())
        if var dict = tree as? [String: Any] {
            if rest.isEmpty { dict.removeValue(forKey: head) } else if let child = dict[head] {
                dict[head] = removing(at: rest, in: child)
            }
            return dict
        }
        if var array = tree as? [Any], let index = Int(head), array.indices.contains(index) {
            if rest.isEmpty { array.remove(at: index) } else { array[index] = removing(at: rest, in: array[index]) }
            return array
        }
        return tree
    }
}
