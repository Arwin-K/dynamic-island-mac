import Foundation
@testable import DynamicIsland4Mac

/// Hook payloads in `Fixtures/`, shaped exactly as each tool's hooks reference documents them.
enum Fixture {
    private final class Token {}

    static func raw(_ name: String) -> [String: Any] {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { fatalError("Missing fixture \(name).json") }
        return object
    }
}
