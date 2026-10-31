import Foundation

// Production uses UserDefaults.standard. Tests and opt-in diagnostics use a
// fresh MemoryPreferences instance, so they never create preference plists.
protocol PreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStore {}

final class MemoryPreferences: PreferenceStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
