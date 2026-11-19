import Foundation

/// Settings kept only in memory, for tests that write: a real suite leaves a plist behind in
/// ~/Library/Preferences even after its keys are removed.
final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    convenience init() { self.init(suiteName: "PenknifeTests.memory.\(UUID().uuidString)")! }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
