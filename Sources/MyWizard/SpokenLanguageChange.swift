import Foundation

struct SpokenLanguageChange: Codable, Sendable, Equatable {
    let time: Double
    let language: String

    struct Segment: Equatable {
        let start: Double
        let end: Double
        let language: String
    }

    static func segments(initial: String, changes: [Self], duration: Double) throws -> [Segment] {
        guard duration.isFinite, duration >= 0 else { throw TranscriptionError.message("Invalid recording duration.") }
        var start = 0.0
        var language = initial
        var result: [Segment] = []
        for change in changes {
            guard change.time.isFinite, change.time >= start, TranscriptionLanguage(rawValue: change.language) != nil else {
                throw TranscriptionError.message("Invalid spoken-language history. Recorded audio is preserved.")
            }
            let end = min(duration, change.time)
            if end > start { result.append(.init(start: start, end: end, language: language)) }
            start = change.time
            language = change.language
        }
        if duration > start { result.append(.init(start: start, end: duration, language: language)) }
        return result
    }

    static func language(at time: Double, initial: String?, changes: [Self]) -> String? {
        changes.last(where: { $0.time <= time })?.language ?? initial
    }
}
