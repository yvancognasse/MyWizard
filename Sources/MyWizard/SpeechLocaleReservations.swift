import Foundation
import Speech

protocol SpeechLocaleInventory: Sendable {
    var maximum: Int { get }
    func reserved() async -> [Locale]
    func reserve(_ locale: Locale) async throws -> Bool
    func release(_ locale: Locale) async -> Bool
}

struct AppleSpeechLocaleInventory: SpeechLocaleInventory {
    var maximum: Int { AssetInventory.maximumReservedLocales }
    func reserved() async -> [Locale] { await AssetInventory.reservedLocales }
    func reserve(_ locale: Locale) async throws -> Bool { try await AssetInventory.reserve(locale: locale) }
    func release(_ locale: Locale) async -> Bool { await AssetInventory.release(reservedLocale: locale) }
}

// Reservations persist independently of analyzer instances. Keep idle models
// cached, but free an idle reservation before allocating beyond Apple's limit.
// Pins cover warm engines, capture and file analysis, including cancellation.
actor SpeechLocaleReservations {
    static let shared = SpeechLocaleReservations(inventory: AppleSpeechLocaleInventory())
    struct Lease: Sendable { let id: UUID }
    private let inventory: any SpeechLocaleInventory
    private var backingReservations: [String: Set<String>] = [:]
    private var active: [UUID: Locale] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(inventory: any SpeechLocaleInventory) { self.inventory = inventory }

    func acquire(_ locale: Locale, allowsEviction: Bool = true) async throws -> Lease? {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        var reserved = await inventory.reserved()
        let reservedKeys = Set(reserved.map(Self.key))
        let backing = backingReservations[Self.key(locale)] ?? []
        let knownVariant = !backing.isEmpty && backing.isSubset(of: reservedKeys)
        if !reserved.contains(where: { Self.same($0, locale) }) && !knownVariant {
            // Speculative warmup must not install or evict languages.
            guard allowsEviction else { return nil }
            let maximum = inventory.maximum
            guard maximum > 0 else { throw unavailable(locale, reserved: reserved) }
            while reserved.count >= maximum {
                guard let unused = reserved.first(where: { candidate in
                    // Apple's inventory may return a variant of the requested
                    // locale. Protect the whole language family while in use.
                    !active.values.contains { Self.family($0) == Self.family(candidate) }
                }) else { throw unavailable(locale, reserved: reserved) }
                _ = await inventory.release(unused)
                let remaining = await inventory.reserved()
                guard remaining.count < reserved.count else { throw unavailable(locale, reserved: remaining) }
                reserved = remaining
                try Task.checkCancellation()
            }
            _ = try await inventory.reserve(locale)
            // reserve(fr-CH), for example, can return a backing asset locale
            // such as fr_FR. Remember the confirmed relationship for warmup;
            // never replace the locale configured on the actual transcriber.
            let actual = await inventory.reserved()
            let added = Set(actual.map(Self.key)).subtracting(reserved.map(Self.key))
            backingReservations[Self.key(locale)] = added.isEmpty
                ? Set(actual.filter { Self.family($0) == Self.family(locale) }.map(Self.key)) : added
        }
        try Task.checkCancellation()
        let lease = Lease(id: UUID())
        active[lease.id] = locale
        return lease
    }

    func end(_ lease: Lease) { active.removeValue(forKey: lease.id) }

    private func unavailable(_ locale: Locale, reserved: [Locale]) -> TranscriptionError {
        let names = reserved.map { $0.identifier.replacingOccurrences(of: "_", with: "-") }.joined(separator: ", ")
        return .message("Apple could not make room for \(locale.identifier) (limit: \(inventory.maximum) speech languages). Finish any current transcription and retry, or choose an already reserved language: \(names).")
    }

    private static func same(_ a: Locale, _ b: Locale) -> Bool {
        key(a) == key(b)
    }
    private static func key(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
    private static func family(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }
    private func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func unlock() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
