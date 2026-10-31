import Foundation
import Testing
@testable import MyWizard

struct SpeechLocaleReservationsTests {
    actor Inventory: SpeechLocaleInventory {
        nonisolated let maximum: Int
        var locales: [Locale]
        var removed: [String] = []
        var allocations = 0
        let aliases: [String: String]
        var noOpRelease: Bool
        init(_ names: [String], maximum: Int = 5, noOpRelease: Bool = false, aliases: [String: String] = [:]) {
            locales = names.map(Locale.init(identifier:))
            self.maximum = maximum
            self.noOpRelease = noOpRelease
            self.aliases = aliases
        }
        func reserved() -> [Locale] { locales }
        func reserve(_ locale: Locale) async throws -> Bool {
            await Task.yield() // Expose actor reentrancy/racing acquisitions.
            let asset = aliases[locale.identifier].map(Locale.init(identifier:)) ?? locale
            if locales.contains(asset) { return false }
            guard locales.count < maximum else { throw Failure.full }
            allocations += 1
            locales.append(asset)
            return true
        }
        func release(_ locale: Locale) -> Bool {
            removed.append(locale.identifier)
            if !noOpRelease { locales.removeAll { $0 == locale } }
            return true
        }
        enum Failure: Error { case full }
    }

    @Test func sixthLanguageReplacesAnIdleReservationAndKeepsExactRegion() async throws {
        let inventory = Inventory(["en-US", "de-DE", "it-IT", "es-ES", "fr-FR"])
        let manager = SpeechLocaleReservations(inventory: inventory)
        let lease = try #require(try await manager.acquire(Locale(identifier: "fr-CH")))
        let reserved = await inventory.reserved()
        #expect(reserved.count == 5)
        #expect(reserved.contains(Locale(identifier: "fr-CH")))
        #expect(await inventory.removed.count == 1)
        await manager.end(lease)
    }

    @Test func existingLocaleAndWarmupDoNotConsumeOrEvictSlots() async throws {
        let inventory = Inventory(["fr_CH"], maximum: 1)
        let manager = SpeechLocaleReservations(inventory: inventory)
        let lease = try #require(try await manager.acquire(Locale(identifier: "fr-CH"), allowsEviction: false))
        #expect(try await manager.acquire(Locale(identifier: "de-DE"), allowsEviction: false) == nil)
        #expect(await inventory.allocations == 0)
        #expect(await inventory.removed.isEmpty)
        await manager.end(lease)
    }

    @Test func activeLanguagesAreProtectedUntilTheirLastUserFinishes() async throws {
        let inventory = Inventory(["fr-FR"], maximum: 1)
        let manager = SpeechLocaleReservations(inventory: inventory)
        let first = try #require(try await manager.acquire(Locale(identifier: "fr-FR")))
        let second = try #require(try await manager.acquire(Locale(identifier: "fr_FR")))
        await manager.end(first)
        await #expect(throws: (any Error).self) { try await manager.acquire(Locale(identifier: "de-DE")) }
        #expect(await inventory.removed.isEmpty)
        await manager.end(second)
        #expect(try await manager.acquire(Locale(identifier: "de-DE")) != nil)
    }

    @Test func failedReleaseStopsWithoutAllocatingOrLooping() async throws {
        let inventory = Inventory(["en-US"], maximum: 1, noOpRelease: true)
        let manager = SpeechLocaleReservations(inventory: inventory)
        await #expect(throws: (any Error).self) { try await manager.acquire(Locale(identifier: "fr-CH")) }
        #expect(await inventory.removed.count == 1)
        #expect(await inventory.allocations == 0)
    }

    @Test func regionalLocaleReusesConfirmedBackingAssetDuringWarmup() async throws {
        let inventory = Inventory(["en-US", "fr-FR"], maximum: 2, aliases: ["fr-CH": "fr-FR"])
        let manager = SpeechLocaleReservations(inventory: inventory)
        let first = try #require(try await manager.acquire(Locale(identifier: "fr-CH")))
        await manager.end(first)
        let warm = try #require(try await manager.acquire(Locale(identifier: "fr-CH"), allowsEviction: false))
        #expect(await inventory.allocations == 0)
        #expect(await inventory.removed.count == 1)
        #expect(await inventory.reserved() == [Locale(identifier: "fr-FR")])
        await manager.end(warm)
    }

    @Test func concurrentRequestsStayWithinTheLimit() async throws {
        let inventory = Inventory([], maximum: 1)
        let manager = SpeechLocaleReservations(inventory: inventory)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for name in ["fr-CH", "en-US", "de-DE", "it-IT"] {
                group.addTask { (try? await manager.acquire(Locale(identifier: name))) != nil }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(await inventory.reserved().count == 1)
        #expect(await inventory.allocations == 1)
    }
}
