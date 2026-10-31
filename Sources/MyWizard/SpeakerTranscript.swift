import Foundation

enum TranscriptSource: Sendable, Hashable, Codable { case systemAudio, microphone }

enum SpeakerIdentity {
    // Separate identity, never displayed as a numbered remote speaker.
    static let microphone = 0

    static func heading(_ number: Int, names: [Int: String] = [:]) -> String {
        let name = names[number]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return number == microphone ? "Microphone" : "Speaker \(number)"
    }
}

struct TimedText: Sendable, Equatable, Codable {
    var text: String
    let start: Double
    let end: Double
    var source: TranscriptSource = .systemAudio
}

struct TranscriptParagraph: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    var text: String
    let speaker: Int?
    let hasSpeakerLabel: Bool
    var language: String? = nil
    var source: TranscriptSource = .systemAudio

    var canReadAloud: Bool { source != .microphone }

    func heading(names: [Int: String]) -> String {
        guard let speaker else { return "Speaker unknown" }
        return SpeakerIdentity.heading(speaker, names: names)
    }
}

private struct TranscriptTrack: Sendable {
    let source: TranscriptSource
    var committed: [TimedText] = []
    var volatile: [TimedText] = []
    // Normalize only new recognition results, never the full meeting per frame.
    var committedTokens: [MicrophoneDuplicateFilter.Token] = []
    var volatileTokens: [MicrophoneDuplicateFilter.Token] = []
    var clearedThrough = 0.0
    private(set) var committedCharacterCount = 0

    mutating func beginSession() {
        committed = []
        volatile = []
        committedTokens = []
        volatileTokens = []
        committedCharacterCount = 0
        clearedThrough = 0
    }

    mutating func clear() {
        for word in committed + volatile {
            clearedThrough = max(clearedThrough, word.end)
        }
        committed = []
        volatile = []
        committedTokens = []
        volatileTokens = []
        committedCharacterCount = 0
    }

    mutating func receive(_ incoming: [TimedText], isFinal: Bool) {
        let words = incoming.filter { $0.end > clearedThrough }.map { word in
            TimedText(text: word.text, start: word.start, end: word.end, source: source)
        }
        if isFinal {
            committedCharacterCount += words.reduce(0) { $0 + $1.text.count } + (words.isEmpty ? 0 : 1)
            committed.append(contentsOf: words)
            if !words.isEmpty { committed[committed.count - 1].text += " " }
            var finalizedWords = words
            if !finalizedWords.isEmpty { finalizedWords[finalizedWords.count - 1].text += " " }
            committedTokens.append(contentsOf: MicrophoneDuplicateFilter.tokens(finalizedWords))
            volatile = []
            volatileTokens = []
        } else {
            volatile = words
            volatileTokens = MicrophoneDuplicateFilter.tokens(words)
        }
    }
}

// Pure timestamp alignment, independent of either speech engine and the UI.
struct SpeakerTranscript: Sendable {
    private var archived: [TranscriptParagraph] = []
    private var archivedSystemCharacterCount = 0
    private var deduplicatedArchive: [TranscriptParagraph] = []
    private var finalExport: [TranscriptParagraph]?
    private var frozenDisplay: [TranscriptParagraph]?
    private var displayArchive: [TranscriptParagraph] = []
    private var systemTrack = TranscriptTrack(source: .systemAudio)
    private var microphoneTrack = TranscriptTrack(source: .microphone)
    private var intervals: [SpeakerInterval] = []
    private var slotNumbers: [Int: Int] = [:]
    private var nextNumber = 1
    private var sessionFirstNumber = 1
    private var reservesOwnSpeaker = false
    private var detectsSpeakers = false
    private var language: String?
    private var latestSystemFinalStart: Int?
    private var liveParagraphCache = LiveParagraphCache()
    private var systemWordsAreOrdered = true
    private(set) var revision: UInt64 = 0

    var hasText: Bool {
        if let finalExport { return !(archived + finalExport).isEmpty }
        return !archived.isEmpty || [systemTrack.committed, systemTrack.volatile,
            microphoneTrack.committed, microphoneTrack.volatile].contains { words in
                words.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
    }

    private var finalizedSystemCharacterCount: Int {
        archivedSystemCharacterCount + systemTrack.committedCharacterCount
    }

    // Start at the current provisional passage, or the most recent finalized
    // recognition result. Never use the last paragraph: a single speaker's
    // paragraph can contain the entire meeting.
    var currentReadingStart: Int {
        if systemTrack.volatile.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return finalizedSystemCharacterCount
        }
        return latestSystemFinalStart ?? finalizedSystemCharacterCount
    }

    mutating func beginSession(detectsSpeakers: Bool, language: String? = nil, reservesOwnSpeaker: Bool = false) {
        revision &+= 1
        displayArchive = systemDisplayParagraphs
        let filtered = deduplicatedParagraphs
        archived = paragraphs
        archivedSystemCharacterCount = archived.filter(\.canReadAloud).reduce(0) { $0 + $1.text.count }
        deduplicatedArchive = filtered
        finalExport = nil
        frozenDisplay = nil
        systemTrack.beginSession()
        microphoneTrack.beginSession()
        intervals = []
        slotNumbers = [:]
        latestSystemFinalStart = nil
        self.reservesOwnSpeaker = reservesOwnSpeaker
        sessionFirstNumber = nextNumber
        self.detectsSpeakers = detectsSpeakers
        self.language = language
        liveParagraphCache = LiveParagraphCache()
        systemWordsAreOrdered = true
    }

    mutating func clear() {
        revision &+= 1
        liveParagraphCache = LiveParagraphCache()
        systemWordsAreOrdered = true
        // Ignore late revisions of text the user has already cleared.
        archived = []
        archivedSystemCharacterCount = 0
        deduplicatedArchive = []
        finalExport = nil
        frozenDisplay = nil
        displayArchive = []
        systemTrack.clear()
        microphoneTrack.clear()
        intervals = []
        slotNumbers = [:]
        nextNumber = 1
        sessionFirstNumber = nextNumber
        latestSystemFinalStart = nil
    }

    mutating func receive(_ words: [TimedText], isFinal: Bool, source: TranscriptSource = .systemAudio) {
        revision &+= 1
        if source == .systemAudio {
            var previousStart = systemTrack.committed.last?.start ?? -.infinity
            for word in words where word.end > systemTrack.clearedThrough {
                if word.start < previousStart { systemWordsAreOrdered = false }
                previousStart = word.start
            }
            let accepted = words.contains { $0.end > systemTrack.clearedThrough }
            if isFinal, accepted {
                latestSystemFinalStart = finalizedSystemCharacterCount
            }
            systemTrack.receive(words, isFinal: isFinal)
        } else {
            microphoneTrack.receive(words, isFinal: isFinal)
        }
    }

    func speakerNumber(forSlot slot: Int) -> Int? { slotNumbers[slot] }

    mutating func updateSpeakers(_ snapshot: SpeakerSnapshot) {
        guard intervals != snapshot.intervals else { return }
        revision &+= 1
        let shared = zip(intervals, snapshot.intervals).prefix { $0.0 == $0.1 }.count
        let changedFrom = (intervals.dropFirst(shared) + snapshot.intervals.dropFirst(shared))
            .map(\.start).min() ?? 0
        liveParagraphCache.invalidate(from: changedFrom)
        intervals = snapshot.intervals
        for interval in intervals where slotNumbers[interval.slot] == nil {
            slotNumbers[interval.slot] = nextNumber
            nextNumber += 1
        }
    }

    mutating func replaceCurrentSession(with analysis: MeetingAnalysis) {
        revision &+= 1
        liveParagraphCache = LiveParagraphCache()
        systemWordsAreOrdered = true
        frozenDisplay = analysis.liveSystemParagraphs
        finalExport = nil
        systemTrack.beginSession()
        microphoneTrack.beginSession()
        intervals = []
        slotNumbers = [:]
        nextNumber = sessionFirstNumber
        receive(analysis.system, isFinal: true)
        receive(analysis.microphone, isFinal: true, source: .microphone)
        updateSpeakers(SpeakerSnapshot(intervals: analysis.intervals, processedThrough: analysis.system.last?.end ?? 0))
        if let numbers = analysis.speakerNumbers {
            slotNumbers = numbers
            nextNumber = max(nextNumber, (numbers.values.max() ?? 0) + 1)
        }
        finalExport = analysis.paragraphs?.enumerated().map { index, paragraph in
            TranscriptParagraph(id: index, text: paragraph.text, speaker: paragraph.speaker, hasSpeakerLabel: true,
                language: language, source: paragraph.speaker == SpeakerIdentity.microphone ? .microphone : .systemAudio)
        }
    }

    static func speakerSlot(for word: TimedText, intervals: [SpeakerInterval]) -> Int? {
        let bySlot = Dictionary(grouping: intervals, by: \.slot)
            .mapValues { $0.sorted { $0.start < $1.start } }
        return speakerSlot(for: word, bySlot: bySlot)
    }

    static func speakerSlots(for words: [TimedText], intervals: [SpeakerInterval]) -> [Int?] {
        let bySlot = Dictionary(grouping: intervals, by: \.slot)
            .mapValues { $0.sorted { $0.start < $1.start } }
        return words.map { speakerSlot(for: $0, bySlot: bySlot) }
    }

    var exportSpeakerAnchors: [ExportSpeakerAnchor] {
        intervals.compactMap { interval in
            guard let number = slotNumbers[interval.slot] else { return nil }
            return ExportSpeakerAnchor(number: number, start: interval.start, end: interval.end)
        }
    }

    var exportFirstSpeakerNumber: Int { sessionFirstNumber }

    var systemDisplayParagraphs: [TranscriptParagraph] {
        if let frozenDisplay { return joinedExport(frozenDisplay, archive: displayArchive) }
        return joinedExport(makeParagraphs(words: systemTrack.committed + systemTrack.volatile,
            includingArchive: false), archive: displayArchive)
    }

    // The reference path remains available for export snapshots and unusual
    // out-of-order recognition. The live UI normally touches only new words.
    mutating func cachedSystemDisplayParagraphs() -> [TranscriptParagraph] {
        guard frozenDisplay == nil, systemWordsAreOrdered else { return systemDisplayParagraphs }
        let bySlot = Dictionary(grouping: intervals, by: \.slot)
            .mapValues { $0.sorted { $0.start < $1.start } }
        let numbers = slotNumbers
        let detects = detectsSpeakers
        let current = liveParagraphCache.update(committed: systemTrack.committed,
            provisional: systemTrack.volatile, hasLabels: detectsSpeakers || reservesOwnSpeaker,
            language: language) { word in
                detects ? Self.speakerSlot(for: word, bySlot: bySlot).flatMap { numbers[$0] } : nil
            }
        return joinedExport(current, archive: displayArchive)
    }

    // Freeze the visible result, including the last provisional phrase. Export
    // never asks a second recognizer or diarizer to rewrite these words/labels.
    func liveSnapshot(names: [Int: String]) -> LiveTranscriptSnapshot {
        let words = (systemTrack.committed + systemTrack.volatile).sorted { $0.start < $1.start }
        let slots = Self.speakerSlots(for: words, intervals: intervals)
        var blocks: [LiveTranscriptBlock] = []
        for (word, slot) in zip(words, slots) {
            let speaker = detectsSpeakers ? slot.flatMap { slotNumbers[$0] } : nil
            let previous = blocks.last
            // Sentence/pause boundaries permit chronological insertion of a
            // whole microphone reply, never word-by-word alternation.
            let sentenceEnded = previous?.text.trimmingCharacters(in: .whitespacesAndNewlines).last
                .map { ".!?…".contains($0) } ?? false
            if let previous, previous.speaker == speaker, !sentenceEnded, word.start - previous.end < 0.8 {
                blocks[blocks.count - 1].text += word.text
                blocks[blocks.count - 1].end = max(previous.end, word.end)
            } else {
                blocks.append(.init(text: word.text, speaker: speaker, start: word.start, end: word.end))
            }
        }
        return LiveTranscriptSnapshot(words: words, blocks: blocks,
            display: makeParagraphs(words: words, includingArchive: false),
            intervals: intervals, speakerNumbers: slotNumbers, names: names)
    }

    private static func speakerSlot(for word: TimedText, bySlot: [Int: [SpeakerInterval]]) -> Int? {
        let duration = word.end - word.start
        guard duration > 0, duration.isFinite else { return nil }
        var scores: [Int: Double] = [:]
        // Each speaker's intervals are ordered and non-overlapping. Binary search
        // avoids scanning the entire meeting for every word on every UI update.
        for (slot, intervals) in bySlot {
            var lower = 0
            var upper = intervals.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if intervals[middle].end <= word.start { lower = middle + 1 }
                else { upper = middle }
            }
            var index = lower
            while index < intervals.count, intervals[index].start < word.end {
                let interval = intervals[index]
                scores[slot, default: 0] += max(0, min(word.end, interval.end) - max(word.start, interval.start))
                index += 1
            }
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= duration * 0.55 else { return nil }
        // Overlapping or ambiguous voices must not acquire a confident label.
        if ranked.count > 1, ranked[1].value > best.value * 0.6 { return nil }
        return best.key
    }

    var paragraphs: [TranscriptParagraph] {
        if let finalExport { return joinedExport(finalExport, archive: archived) }
        return makeParagraphs(words: systemTrack.committed + systemTrack.volatile
            + microphoneTrack.committed + microphoneTrack.volatile)
    }

    var finalizedParagraphs: [TranscriptParagraph] {
        if let finalExport { return joinedExport(finalExport, archive: archived) }
        return makeParagraphs(words: systemTrack.committed + microphoneTrack.committed)
    }

    var deduplicatedParagraphs: [TranscriptParagraph] {
        // Prepared exports have already filtered microphone echo. Never rebuild
        // their blocks by interleaving individual system and microphone words.
        if let finalExport { return joinedExport(finalExport, archive: deduplicatedArchive) }
        let system = systemTrack.committed + systemTrack.volatile
        let microphone = MicrophoneDuplicateFilter.filter(
            microphoneTrack.committed + microphoneTrack.volatile,
            reference: systemTrack.committedTokens + systemTrack.volatileTokens,
            input: microphoneTrack.committedTokens + microphoneTrack.volatileTokens)
        return makeParagraphs(words: system + microphone, archive: deduplicatedArchive)
    }

    var provisionalSystemParagraphs: [TranscriptParagraph] {
        if finalExport != nil { return [] }
        return makeParagraphs(words: systemTrack.volatile, includingArchive: false)
    }

    private func joinedExport(_ current: [TranscriptParagraph], archive: [TranscriptParagraph]) -> [TranscriptParagraph] {
        (archive + current).enumerated().map { index, paragraph in
            TranscriptParagraph(id: index, text: paragraph.text, speaker: paragraph.speaker,
                hasSpeakerLabel: paragraph.hasSpeakerLabel, language: paragraph.language, source: paragraph.source)
        }
    }

    private func makeParagraphs(words: [TimedText], includingArchive: Bool = true, archive: [TranscriptParagraph]? = nil) -> [TranscriptParagraph] {
        var result = includingArchive ? (archive ?? archived) : []
        let firstCurrent = result.count
        let bySlot = Dictionary(grouping: intervals, by: \.slot)
        for word in words.sorted(by: { $0.start == $1.start ? $0.source == .systemAudio && $1.source == .microphone : $0.start < $1.start }) {
            let isOwn = word.source == .microphone
            let slot = detectsSpeakers && !isOwn ? Self.speakerSlot(for: word, bySlot: bySlot) : nil
            let number = isOwn ? SpeakerIdentity.microphone : slot.flatMap { slotNumbers[$0] }
            if result.count > firstCurrent, result.last?.speaker == number, result.last?.source == word.source {
                result[result.count - 1].text += word.text
            } else {
                result.append(TranscriptParagraph(id: result.count, text: word.text,
                                                  speaker: number, hasSpeakerLabel: detectsSpeakers || reservesOwnSpeaker || isOwn,
                                                  language: language, source: word.source))
            }
        }
        return result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated().map { index, paragraph in
                TranscriptParagraph(id: index, text: paragraph.text, speaker: paragraph.speaker,
                                    hasSpeakerLabel: paragraph.hasSpeakerLabel, language: paragraph.language, source: paragraph.source)
            }
    }

    func plainText(names: [Int: String]) -> String {
        Self.plainText(paragraphs: paragraphs, names: names)
    }

    static func plainText(paragraphs: [TranscriptParagraph], names: [Int: String]) -> String {
        paragraphs.map {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return $0.hasSpeakerLabel ? "\($0.heading(names: names)):\n\(text)" : text
        }.joined(separator: "\n\n")
    }
}
