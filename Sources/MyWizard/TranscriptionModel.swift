import AVFoundation
import Combine
import Speech
import OSLog

@MainActor
final class TranscriptionModel: ObservableObject {
    @Published var calendarMeeting: CalendarMeeting? { didSet { snapshotMetadataRevision &+= 1 } }
    @Published var codexProject: CodexProject? { didSet { snapshotMetadataRevision &+= 1 } }
    let reader: TranscriptReader
    let displayTranslation = DisplayTranslation()
    private var cachedTranscript: String?
    // Export text is assembled only when requested, never for scrolling or
    // toolbar validation on every provisional recognition result.
    var transcript: String {
        if let cachedTranscript { return cachedTranscript }
        let text = SpeakerTranscript.plainText(paragraphs: exportParagraphs, names: speakerNames)
        cachedTranscript = text
        return text
    }
    @Published private(set) var hasExportContent = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isPaused = false
    @Published private(set) var captureInterruption: String?
    @Published private(set) var recoverableRecordings: [RecoveryCandidate] = []
    private var recoveryLease: RecordingLease?
    @Published private(set) var isTransitioning = false
    @Published private(set) var statusMessage: String? = "Ready"
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var paragraphs: [TranscriptParagraph] = []
    @Published private(set) var needsProcessing = false
    @Published private(set) var isProcessing = false
    @Published private(set) var recordings: [RecordedMeeting] = []
    private(set) var recordingStartedAt: Date?
    private var recording: MeetingRecording?
    private var pendingRecording: RecordedMeeting?
    private var pendingLiveTranscript: LiveTranscriptSnapshot?
    private var analysisTask: Task<MeetingAnalysis, Error>?
    private var exportProcessingID: UUID?
    private var exportProgressPercent = 0
    private let processor = MeetingProcessor()
    private let recordingRoot: URL
    @Published var errorMessage: String?
    @Published var speakerNames: [Int: String] = [:] {
        didSet {
            cachedTranscript = nil
            snapshotMetadataRevision &+= 1
            preferences.set(speakerNames[SpeakerIdentity.microphone] ?? "", forKey: "ownSpeakerName")
            persistVoiceNames()
            refreshTranscript()
        }
    }
    @Published private(set) var includesMicrophone: Bool {
        didSet { preferences.set(includesMicrophone, forKey: "includesMicrophone") }
    }
    @Published private(set) var isMicrophoneChanging = false
    private var microphoneActivationID: UUID?
    private var microphoneSwitchError: String?
    private var microphoneStartedAt = Date()
    @Published var cancelsMicrophoneEcho: Bool {
        didSet { preferences.set(cancelsMicrophoneEcho, forKey: "cancelsMicrophoneEcho") }
    }
    // Required processing, not user preferences. Legacy false values cannot
    // disable either stage, including on previously configured installations.
    let suppressesMicrophoneDuplicates = true
    let detectsSpeakers = true
    @Published var language: String {
        didSet {
            preferences.set(language, forKey: "transcriptionLanguage")
            if isPrewarmingEnabled && !isCapturing && !isTransitioning { prewarmTranscription() }
        }
    }
    @Published var readingLanguage: ReadingLanguage {
        didSet {
            preferences.set(readingLanguage.rawValue, forKey: "readingLanguage")
            stopReading()
        }
    }
    @Published var displayLanguage: ReadingLanguage {
        didSet {
            preferences.set(displayLanguage.rawValue, forKey: "displayLanguage")
            refreshTranscript()
        }
    }
    @Published private(set) var translationJob: ReadingTranslationJob?
    @Published private(set) var isReadingEnabled = false
    private(set) var completedReadingBatches = 0
    private var readingCursor = LiveReadingCursor()
    private var readingVoiceContinuity = ReadingVoiceContinuity()
    private var pendingReading: [TranscriptParagraph] = []
    private var followsCapture = false
    private var translationPlan: ReadingTranslationPlan?
    private var pendingTranslationJobs: [ReadingTranslationJob] = []
    private var translationTarget = ""

    @Published private(set) var rememberedVoices: [RememberedVoice] = []
    @Published private(set) var voiceMemoryMessage: String?
    private let voiceMemory: VoiceMemory
    private var currentVoiceIDs: [Int: UUID] = [:]
    private var autoNamedNumbers: Set<Int> = []
    private var voiceSamplesByNumber: [Int: [[Float]]] = [:]
    private var voiceLearningSuppressed = false
    private var forgottenVoiceNumbers: Set<Int> = []
    private var isApplyingVoiceName = false

    private let preferences: any PreferenceStore
    private let timeline: CaptureTimeline
    private let capture: SystemAudioCapture
    private let microphoneCapture: MicrophoneCapture
    private var preparedSpeech: PreparedSpeech?
    private var analyzer: SpeechAnalyzer?
    private let speechPreparation: StartupPreparation<PreparedSpeech>
    private let speakerDetector = SpeakerDetection()
    private var isPrewarmingEnabled = false
    private var speakerPrewarmTask: Task<Void, Never>?
    private static let startupLogger = Logger(subsystem: "com.yvancognasse.MyWizard", category: "Startup")
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var speakerTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var autosaver: TranscriptAutosave?
    private var sessionID: UUID?
    private var startupError: String?
    private var document = SpeakerTranscript() { didSet { cachedTranscript = nil } }
    private var snapshotMetadataRevision: UInt64 = 0
    private var transcriptRefreshTask: Task<Void, Never>?
    private var lastAudio: Date?
    private var lastSound: Date?
    private var lastResult: Date?
    private var startedAt = Date()

    var capturedFrameCounts: (system: Int64, microphone: Int64) {
        (capture.frameCount, microphoneCapture.frameCount)
    }

    // Current session only; recordingStartedAt may belong to an older session
    // retained in the same exported document and must not drive this counter.
    var activeRecordingStartedAt: Date? {
        isCapturing ? recording?.startedAt : nil
    }

    var unfilteredParagraphs: [TranscriptParagraph] { document.paragraphs }
    var exportParagraphs: [TranscriptParagraph] { document.deduplicatedParagraphs }

    init(preferences: any PreferenceStore = UserDefaults.standard, reader: TranscriptReader = TranscriptReader(), recordingRoot: URL = RecordedMeeting.root,
         systemCaptureFactory: (@MainActor (CaptureTimeline) -> SystemAudioCapture)? = nil,
         voiceMemoryURL: URL = VoiceMemory.defaultURL) {
        voiceMemory = VoiceMemory(url: voiceMemoryURL)
        rememberedVoices = voiceMemory.voices
        voiceMemoryMessage = voiceMemory.loadError
        speechPreparation = StartupPreparation(discard: { prepared in
            await prepared.close()
        })
        self.recordingRoot = recordingRoot
        let timeline = CaptureTimeline()
        self.timeline = timeline
        self.capture = systemCaptureFactory?(timeline) ?? SystemAudioCapture(timeline: timeline)
        self.microphoneCapture = MicrophoneCapture(timeline: timeline)
        self.preferences = preferences
        self.reader = reader
        includesMicrophone = preferences.object(forKey: "includesMicrophone") as? Bool ?? true
        // Voice processing can silence another simultaneous microphone client.
        // Keep it opt-in; preserve an explicitly saved preference.
        cancelsMicrophoneEcho = preferences.object(forKey: "cancelsMicrophoneEcho") as? Bool ?? false
        preferences.removeObject(forKey: "suppressesMicrophoneDuplicates")
        preferences.removeObject(forKey: "detectSpeakers")
        let savedLanguage = preferences.string(forKey: "transcriptionLanguage")
        language = TranscriptionLanguage(rawValue: savedLanguage ?? "")?.rawValue
            ?? TranscriptionLanguage.french.rawValue
        readingLanguage = ReadingLanguage(rawValue: preferences.string(forKey: "readingLanguage") ?? "") ?? .original
        displayLanguage = ReadingLanguage(rawValue: preferences.string(forKey: "displayLanguage") ?? "") ?? .original
        preferences.removeObject(forKey: "readingSpeedLevel")
        preferences.removeObject(forKey: "readingSpeed")
        preferences.removeObject(forKey: "automaticReadingSpeed")
        speakerNames[SpeakerIdentity.microphone] = preferences.string(forKey: "ownSpeakerName") ?? "Yvan Cognasse"
        preferences.set(speakerNames[SpeakerIdentity.microphone], forKey: "ownSpeakerName")
        reader.onFinished = { [weak self] success in
            guard let self else { return }
            if success { self.completedReadingBatches += 1; self.pumpReading() } else { self.stopReading() }
        }
    }

    // Slot numbers belong to this capture; persistent voice IDs never replace
    // transcript IDs. Explicit names always take precedence over recognition.
    func receiveSpeakerSnapshot(_ snapshot: SpeakerSnapshot) {
        document.updateSpeakers(snapshot)
        if let warning = snapshot.voiceMemoryWarning { voiceMemoryMessage = warning }
        for slot in snapshot.voiceEmbeddings.keys.sorted() {
            guard let number = document.speakerNumber(forSlot: slot),
                  currentVoiceIDs[number] == nil, !voiceLearningSuppressed, !forgottenVoiceNumbers.contains(number),
                  let samples = snapshot.voiceEmbeddings[slot], samples.count >= 2 else { continue }
            voiceSamplesByNumber[number] = samples
            do {
                let assigned = Set(currentVoiceIDs.values)
                if let match = voiceMemory.match(samples, excluding: assigned) {
                    // A manual correction creates a separate template rather than
                    // renaming another person's stored profile on a false match.
                    let explicit = (speakerNames[number] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !explicit.isEmpty && match.name.isEmpty {
                        try voiceMemory.rename(match.id, to: explicit)
                        currentVoiceIDs[number] = match.id
                    } else if !explicit.isEmpty && explicit != match.name {
                        if let voice = try voiceMemory.remember(samples, name: explicit) { currentVoiceIDs[number] = voice.id }
                    } else {
                        currentVoiceIDs[number] = match.id
                        if explicit.isEmpty && !match.name.isEmpty {
                            autoNamedNumbers.insert(number)
                            isApplyingVoiceName = true
                            speakerNames[number] = match.name
                            isApplyingVoiceName = false
                        }
                    }
                } else if (!voiceMemory.hasPlausibleMatch(samples) || !(speakerNames[number] ?? "").isEmpty),
                          let voice = try voiceMemory.remember(samples, name: speakerNames[number] ?? "") {
                    currentVoiceIDs[number] = voice.id
                }
                rememberedVoices = voiceMemory.voices
                if let message = voiceMemory.loadError { voiceMemoryMessage = message }
            } catch { voiceMemoryMessage = "Voices could not be saved: \(error.localizedDescription)" }
        }
    }

    private func persistVoiceNames() {
        guard !isApplyingVoiceName else { return }
        do {
            for (number, id) in Array(currentVoiceIDs) {
                let name = (speakerNames[number] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if autoNamedNumbers.contains(number),
                   voiceMemory.voices.first(where: { $0.id == id })?.name != name,
                   let samples = voiceSamplesByNumber[number] {
                    if let corrected = try voiceMemory.remember(samples, name: name) {
                        currentVoiceIDs[number] = corrected.id
                        autoNamedNumbers.remove(number)
                    }
                } else {
                    try voiceMemory.rename(id, to: name)
                }
            }
            rememberedVoices = voiceMemory.voices
        } catch { voiceMemoryMessage = "Speaker names could not be remembered: \(error.localizedDescription)" }
    }

    func forgetSavedVoice(_ id: UUID) {
        do {
            try voiceMemory.forget(id)
            let numbers = currentVoiceIDs.filter { $0.value == id }.map(\.key)
            forgottenVoiceNumbers.formUnion(numbers)
            for number in numbers { currentVoiceIDs.removeValue(forKey: number) }
            rememberedVoices = voiceMemory.voices
        } catch { voiceMemoryMessage = "Saved voice could not be deleted: \(error.localizedDescription)" }
    }

    func forgetSavedVoices() {
        do {
            try voiceMemory.forgetAll()
            // Do not immediately relearn the voices from this open transcript.
            voiceLearningSuppressed = true
            currentVoiceIDs = [:]
            rememberedVoices = []
            voiceMemoryMessage = nil
        } catch { voiceMemoryMessage = "Saved voices could not be deleted: \(error.localizedDescription)" }
    }

    func toggleCapture() async {
        guard !isTransitioning, isCapturing || !isMicrophoneChanging else { return }
        guard isCapturing || !needsProcessing else {
            errorMessage = "Prepare or recover the recorded meeting before starting a new session. Its audio is preserved."
            return
        }
        isTransitioning = true
        defer { isTransitioning = false }
        if isCapturing { await stop() } else { await start() }
    }

    func setMicrophoneEnabled(_ enabled: Bool) async {
        guard !isTransitioning, !isMicrophoneChanging, enabled != includesMicrophone else { return }
        guard isCapturing, !isPaused, let id = sessionID, let recording else {
            includesMicrophone = enabled
            return
        }
        isMicrophoneChanging = true
        microphoneSwitchError = nil
        defer { isMicrophoneChanging = false }
        if !enabled {
            microphoneActivationID = nil // Ignore errors from the old input tap.
            await microphoneCapture.stop()
            includesMicrophone = false
            return
        }
        do {
            guard await MicrophoneAuthorization.request() else {
                throw TranscriptionError.message("Allow MyWizard in System Settings → Privacy & Security → Microphone.")
            }
            guard sessionID == id, isCapturing else { return }
            try await recording.enableMicrophone()
            guard sessionID == id, isCapturing else { return }
            try await startMicrophone(recording: recording, session: id)
            guard sessionID == id, isCapturing else {
                microphoneActivationID = nil
                await microphoneCapture.stop()
                return
            }
            if let message = microphoneSwitchError { throw TranscriptionError.message(message) }
            includesMicrophone = true
        } catch {
            microphoneActivationID = nil
            await microphoneCapture.stop()
            guard sessionID == id else { return }
            includesMicrophone = false
            errorMessage = "Microphone could not be enabled: \(error.localizedDescription) System recording continues."
        }
    }

    private func startMicrophone(recording: MeetingRecording, session: UUID) async throws {
        let activation = UUID()
        microphoneActivationID = activation
        microphoneStartedAt = Date()
        try await microphoneCapture.start(format: MeetingRecording.format, cancelsEcho: false,
                                          recording: recording, onError: { [weak self] message in
            Task { @MainActor in
                await self?.microphoneFailed(message, activation: activation, session: session)
            }
        })
    }

    private func microphoneFailed(_ message: String, activation: UUID, session: UUID) async {
        guard sessionID == session, microphoneActivationID == activation else { return }
        if !isCapturing { startupError = message; return }
        if isTransitioning { startupError = message; return }
        if isMicrophoneChanging { microphoneSwitchError = message; return }
        microphoneActivationID = nil
        await microphoneCapture.stop()
        includesMicrophone = false
        errorMessage = "Microphone stopped: \(message) System recording continues."
    }

    func clear() {
        guard !isCapturing, !isTransitioning, !needsProcessing else { return }
        stopReading()
        currentVoiceIDs = [:]
        autoNamedNumbers = []
        voiceSamplesByNumber = [:]
        voiceLearningSuppressed = false
        forgottenVoiceNumbers = []
        document.clear()
        calendarMeeting = nil
        codexProject = nil
        recoveryLease = nil
        displayTranslation.reset()
        recordings = [] // Files remain recoverable; clearing text never deletes audio.
        recordingStartedAt = nil
        // Start with fresh participant names while preserving the user's own name.
        speakerNames = speakerNames.filter { $0.key == SpeakerIdentity.microphone }
    }

    private func refreshTranscript() {
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        // The microphone belongs only in the saved document, including after
        // offline analysis. Never send it to the overlay or display translation.
        let latest = LiveSpeakerPresentation.smooth(document.cachedSystemDisplayParagraphs())
        if paragraphs != latest { paragraphs = latest }
        let hasContent = document.hasText
        if hasExportContent != hasContent { hasExportContent = hasContent }
        displayTranslation.update(latest, source: language, target: displayLanguage)
        if isReadingEnabled && followsCapture {
            pumpReading()
        }
    }

    // A single deadline coalesces bursts without postponing updates during
    // continuous speech. Data and read-aloud are always processed immediately.
    private func scheduleTranscriptRefresh() {
        guard transcriptRefreshTask == nil else { return }
        transcriptRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            self?.refreshTranscript()
        }
    }

    func receiveTranscript(_ words: [TimedText], isFinal: Bool, source: TranscriptSource = .systemAudio,
                           coalescingDisplay: Bool = false) {
        document.receive(words, isFinal: isFinal, source: source)
        if isReadingEnabled && followsCapture && isFinal && source == .systemAudio {
            pendingReading.append(contentsOf: readingCursor.takeFinalized(from: document.finalizedParagraphs))
        }
        if coalescingDisplay {
            scheduleTranscriptRefresh()
            if isReadingEnabled && followsCapture { pumpReading() }
        } else { refreshTranscript() }
    }

    func shutDown() async {
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        analysisTask?.cancel()
        stopReading()
        sessionID = nil
        await stop(finishing: false)
        speechPreparation.invalidate()
        speakerPrewarmTask?.cancel()
        recoveryLease = nil
    }

    func prepareExport() async -> Bool {
        guard !isCapturing, !isTransitioning else { return false }
        guard let meeting = pendingRecording, needsProcessing else { return hasExportContent }
        isTransitioning = true
        isProcessing = true
        errorMessage = nil
        let processingID = UUID()
        exportProcessingID = processingID
        exportProgressPercent = 0
        statusMessage = "Preparing transcription export… 0%"
        defer { isTransitioning = false; isProcessing = false; analysisTask = nil; exportProcessingID = nil }
        let processor = self.processor
        let snapshot = pendingLiveTranscript
        let task = Task { [weak self] in
            // Retry snapshot persistence too if Stop encountered a disk error.
            if let snapshot { try meeting.saveLiveTranscript(snapshot) }
            return try await processor.analyze(meeting) { [weak self] percent in
            Task { @MainActor in
                guard let self, self.isProcessing, self.exportProcessingID == processingID,
                      self.pendingRecording?.id == meeting.id, percent >= self.exportProgressPercent else { return }
                self.exportProgressPercent = percent
                self.statusMessage = "Preparing transcription export… \(min(99, percent))%"
            }
        } }
        analysisTask = task
        do {
            let result = try await task.value
            guard !task.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            document.replaceCurrentSession(with: result)
            var complete = meeting
            complete.manifest.state = "analyzed"
            try complete.saveManifest()
            if let index = recordings.firstIndex(where: { $0.id == complete.id }) { recordings[index] = complete }
            pendingRecording = nil
            pendingLiveTranscript = nil
            needsProcessing = false
            refreshTranscript()
            statusMessage = "Transcription ready to export… 100%"
            return true
        } catch {
            statusMessage = "Processing did not finish. Audio preserved in \(meeting.directory.path)"
            if !(error is CancellationError) { errorMessage = "\(error.localizedDescription)\n\(statusMessage!)" }
            return false
        }
    }

    func cancelProcessing() { analysisTask?.cancel() }

    // A document can retain several sessions. Keep its earliest recording
    // start even after successful export removes the underlying audio files.
    func recordingBegan(at date: Date) {
        recordingStartedAt = recordingStartedAt.map { min($0, date) } ?? date
    }

    func recover(_ url: URL) throws {
        guard !isCapturing, !isTransitioning, !needsProcessing else {
            throw TranscriptionError.message("Finish the current session before recovering another recording.")
        }
        var meeting = try RecordedMeeting.load(url)
        let lease = try RecordingLease(directory: url)
        let snapshot = try meeting.loadLiveTranscript()
        if TranscriptionLanguage(rawValue: meeting.manifest.language) != nil { language = meeting.manifest.language }
        errorMessage = nil
        meeting.manifest.detectSpeakers = true
        recordingBegan(at: meeting.manifest.created)
        currentVoiceIDs = [:]
        autoNamedNumbers = []
        voiceSamplesByNumber = [:]
        voiceLearningSuppressed = false
        forgottenVoiceNumbers = []
        document.beginSession(detectsSpeakers: detectsSpeakers,
            language: meeting.manifest.language, reservesOwnSpeaker: true)
        document.replaceCurrentSession(with: snapshot.addingMicrophone([]))
        for (number, name) in snapshot.names { speakerNames[number] = name }
        pendingLiveTranscript = snapshot
        calendarMeeting = snapshot.calendarMeeting
        codexProject = snapshot.codexProject
        needsProcessing = true
        refreshTranscript()
        pendingRecording = meeting
        recordings.append(meeting)
        recoveryLease = lease
        recoverableRecordings.removeAll { $0.id == meeting.id }
        statusMessage = "Recording recovered. Choose Prepare export to analyze it."
    }

    func recordingsRemoved(_ ids: Set<UUID>) {
        recordings.removeAll { ids.contains($0.id) }
        recoveryLease = nil
        recoverableRecordings.removeAll { ids.contains($0.id) }
    }

    var exportText: String {
        let heading = calendarMeeting.map { "Meeting: \($0.title)\n\n" } ?? ""
        return heading + transcript
    }

    private func liveSnapshot() -> LiveTranscriptSnapshot {
        var snapshot = document.liveSnapshot(names: speakerNames)
        snapshot.calendarMeeting = calendarMeeting
        snapshot.codexProject = codexProject
        return snapshot
    }

    func scanRecoverableRecordings() async {
        do {
            let root = recordingRoot
            let candidates = try await Task.detached(priority: .utility) {
                try RecoveryCandidate.discover(in: root)
            }.value
            let retained = Set(recordings.map(\.id))
            recoverableRecordings = candidates.filter { !retained.contains($0.id) }
        } catch { errorMessage = "Cannot check unfinished meetings: \(error.localizedDescription)" }
    }

    func retryInterruptedCapture() async {
        guard isCapturing, isPaused, captureInterruption != nil,
              !isTransitioning, !isMicrophoneChanging else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        guard let recording, let id = sessionID else { return }
        statusMessage = "Resuming audio capture…"
        startupError = nil
        do {
            if includesMicrophone {
                guard await MicrophoneAuthorization.request() else {
                    throw TranscriptionError.message("Allow microphone access, or turn the microphone off before resuming.")
                }
                try await recording.enableMicrophone()
                try await startMicrophone(recording: recording, session: id)
            }
            guard sessionID == id else { throw CancellationError() }
            try capture.resume()
            if let startupError { throw TranscriptionError.message(startupError) }
            isPaused = false
            captureInterruption = nil
            lastAudio = nil
            lastSound = nil
            startedAt = Date()
            lastResult = nil
            statusMessage = "Listening — waiting for system audio…"
        } catch {
            capture.pause()
            microphoneActivationID = nil
            await microphoneCapture.stop()
            statusMessage = "Audio interrupted — check the audio device and choose Retry audio."
            captureInterruption = error.localizedDescription
        }
    }

    private func pauseCapture(reason: String) async {
        guard isCapturing, !isPaused else { return }
        isPaused = true
        captureInterruption = reason
        stopReading()
        capture.pause()
        microphoneActivationID = nil
        await microphoneCapture.stop()
        audioLevel = 0
        statusMessage = "Audio interrupted — check your output device, then choose Retry audio."
    }

    private func audioDeviceChanged(_ message: String, session id: UUID) async {
        guard sessionID == id else { return }
        if isTransitioning { startupError = message; return }
        guard isCapturing, !isPaused else { return }
        isTransitioning = true
        await pauseCapture(reason: message)
        isTransitioning = false
    }

    func toggleReading() async {
        guard !isPaused else { return }
        if isReadingEnabled || reader.isReading || translationJob != nil { stopReading(); return }
        guard !isTransitioning, !paragraphs.isEmpty || isCapturing else { return }
        beginReading(followCapture: isCapturing)
    }

    func beginReading(followCapture: Bool) {
        refreshTranscript()
        do { try capture.setOriginalAudioMuted(true) }
        catch { reader.errorMessage = error.localizedDescription; return }
        completedReadingBatches = 0
        reader.errorMessage = nil
        reader.resetVoiceAssignments()
        readingVoiceContinuity = ReadingVoiceContinuity()
        readingCursor = LiveReadingCursor(startingAt: document.currentReadingStart)
        isReadingEnabled = true
        followsCapture = followCapture
        pendingReading = readingCursor.takeNew(from: document.finalizedParagraphs)
        if pendingReading.isEmpty {
            pendingReading = readingCursor.takeProvisional(from: document.provisionalSystemParagraphs)
        }
        pumpReading()
    }

    private func pumpReading() {
        guard isReadingEnabled, !reader.isReading, translationJob == nil else { return }
        if pendingReading.isEmpty && followsCapture {
            pendingReading = readingCursor.takeProvisional(from: document.provisionalSystemParagraphs)
        }
        guard !pendingReading.isEmpty else {
            if !followsCapture { stopReading() }
            return
        }
        // Translate and synthesize a short first block, not the whole backlog.
        // Keep the remainder queued, with its speaker/language/source intact.
        var first = pendingReading.removeFirst()
        let chunks = TranscriptReader.chunks(first.text, limit: 180)
        if chunks.count > 1 {
            var remainder = first
            remainder.text = chunks.dropFirst().joined()
            pendingReading.insert(remainder, at: 0)
            first.text = chunks[0]
        }
        first = readingVoiceContinuity.prepare(first, next: pendingReading.first)
        let batch = [first]
        guard readingLanguage != .original else {
            reader.read(paragraphs: batch, language: language, preservingVoiceAssignments: true)
            return
        }
        let target = readingLanguage.rawValue
        let plan = ReadingTranslationPlan(paragraphs: batch, fallbackSource: language, target: target)
        guard !plan.jobs.isEmpty else {
            reader.read(paragraphs: plan.paragraphs, language: target, preservingVoiceAssignments: true)
            return
        }
        translationPlan = plan
        translationTarget = target
        pendingTranslationJobs = plan.jobs
        translationJob = pendingTranslationJobs.removeFirst()
    }

    func stopReading() {
        do { try capture.setOriginalAudioMuted(false) }
        catch {
            reader.errorMessage = error.localizedDescription
            // Destroy the tap if restoring its playback behavior fails.
            // This also makes capture failure visible instead of leaving audio muted.
            let id = sessionID
            Task { [weak self] in
                guard let self, let id else { return }
                await self.failed("Original audio could not be restored. Listening was stopped.", session: id)
            }
        }
        isReadingEnabled = false
        followsCapture = false
        pendingReading = []
        readingCursor = LiveReadingCursor()
        readingVoiceContinuity = ReadingVoiceContinuity()
        translationJob = nil
        translationPlan = nil
        pendingTranslationJobs = []
        reader.stop()
        reader.resetVoiceAssignments()
    }

    func translationCompleted(id: UUID, result: Result<[String], Error>) {
        guard let job = translationJob, job.id == id else { return }
        do {
            guard var plan = translationPlan else { return }
            try plan.apply(result.get(), job: job)
            translationPlan = plan
            if !pendingTranslationJobs.isEmpty {
                translationJob = pendingTranslationJobs.removeFirst()
            } else {
                translationJob = nil
                translationPlan = nil
                reader.read(paragraphs: plan.paragraphs, language: translationTarget, preservingVoiceAssignments: true)
            }
        } catch {
            stopReading()
            if !(error is CancellationError) {
                reader.errorMessage = "Translation could not finish. \(error.localizedDescription)"
            }
        }
    }

    // No audio device, input stream or results consumer is opened by warmup.
    func prewarmTranscription() {
        guard !isCapturing else { return }
        isPrewarmingEnabled = true
        let selectedLanguage = language
        speechPreparation.warm(key: selectedLanguage) { downloads in
            try await PreparedSpeech.load(language: selectedLanguage, downloads: downloads)
        }
        if speakerPrewarmTask == nil {
            speakerPrewarmTask = Task { [speakerDetector] in
                defer { speakerPrewarmTask = nil }
                do { try await speakerDetector.preload() }
                catch { Self.startupLogger.debug("Speaker warmup deferred: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private func start() async {
        let startupTime = ProcessInfo.processInfo.systemUptime
        prewarmTranscription()
        let id = UUID()
        sessionID = id
        startupError = nil
        isPaused = false
        captureInterruption = nil
        errorMessage = nil
        lastAudio = nil
        lastSound = nil
        lastResult = nil
        audioLevel = 0
        timeline.reset()
        currentVoiceIDs = [:]
        autoNamedNumbers = []
        voiceSamplesByNumber = [:]
        voiceLearningSuppressed = false
        forgottenVoiceNumbers = []
        document.beginSession(detectsSpeakers: detectsSpeakers, language: language, reservesOwnSpeaker: true)
        statusMessage = "Preparing local transcription…"

        do {
            if includesMicrophone, !(await MicrophoneAuthorization.request()) {
                throw TranscriptionError.message("Allow MyWizard in System Settings > Privacy & Security > Microphone, or turn off Include microphone in Preferences to use system audio only.")
            }
            let selectedLanguage = language
            guard let prepared = try await speechPreparation.take(key: selectedLanguage, load: { [weak self] downloads in
                try await PreparedSpeech.load(language: selectedLanguage, downloads: downloads) { [weak self] message in
                    self?.statusMessage = message
                }
            }) else { throw TranscriptionError.message("The speech model could not be prepared.") }
            self.preparedSpeech = prepared
            let transcriber = prepared.transcriber
            let format = prepared.format
            let analyzer = prepared.analyzer
            Self.startupLogger.info("Apple ready after \(ProcessInfo.processInfo.systemUptime - startupTime, privacy: .public)s from Start")
            self.analyzer = analyzer
            guard sessionID == id else { throw CancellationError() }
            let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
            input = continuation
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.sessionID == id else { return }
                        let attributed = result.text
                        let words = attributed.runs.map { run in
                            let range = run.audioTimeRange ?? result.range
                            return TimedText(text: String(attributed[run.range].characters),
                                             start: range.start.seconds, end: range.end.seconds)
                        }
                        if self.lastResult == nil {
                            Self.startupLogger.info("First text after \(ProcessInfo.processInfo.systemUptime - startupTime, privacy: .public)s from Start")
                        }
                        self.lastResult = Date()
                        self.receiveTranscript(self.timeline.alignWords(words, source: .systemAudio), isFinal: result.isFinal,
                                               coalescingDisplay: true)
                    }
                } catch {
                    await self?.failed(error.localizedDescription, session: id)
                }
            }
            try await analyzer.start(inputSequence: sequence)
            // Live words and speaker identities are preserved in the export.
            var speakerInput: AsyncStream<[Float]>.Continuation?
            let detector = speakerDetector
            statusMessage = "Loading live speaker identification (first use may download)…"
            do {
                try await detector.prepare()
                Self.startupLogger.info("Speakers ready after \(ProcessInfo.processInfo.systemUptime - startupTime, privacy: .public)s from Start")
                guard sessionID == id else { throw CancellationError() }
                let (samples, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingOldest(40))
                speakerInput = continuation
                speakerTask = Task { [weak self] in
                    defer { continuation.finish() }
                    do {
                        for await chunk in samples {
                            try Task.checkCancellation()
                            guard let snapshot = try await detector.process(chunk) else { continue }
                            guard let self, self.sessionID == id else { return }
                            self.receiveSpeakerSnapshot(self.timeline.alignSystemSpeakers(snapshot))
                            self.scheduleTranscriptRefresh()
                        }
                    } catch {
                        guard !Task.isCancelled, let self, self.sessionID == id else { return }
                        self.errorMessage = "Live speaker identification stopped: \(error.localizedDescription). Recording continues; uncertain speakers will remain unknown in the export."
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errorMessage = "Live speaker identification is unavailable: \(error.localizedDescription). Recording continues; uncertain speakers will remain unknown in the export."
            }
            let recording = try MeetingRecording(language: language, microphone: includesMicrophone,
                detectSpeakers: detectsSpeakers, root: recordingRoot) { [weak self] message in
                    Task { @MainActor in await self?.failed(message, session: id) }
                }
            self.recording = recording
            let autosaver = TranscriptAutosave(directory: recording.directory)
            self.autosaver = autosaver
            autosaveTask = Task { [weak self] in
                var reportedFailure = false
                while !Task.isCancelled {
                    guard let self, self.sessionID == id else { return }
                    // Capture value-semantic inputs on MainActor; assembly and
                    // encoding run on the writer actor and only when dirty.
                    do {
                        try await autosaver.save(document: self.document, names: self.speakerNames,
                            calendarMeeting: self.calendarMeeting, codexProject: self.codexProject,
                            metadataRevision: self.snapshotMetadataRevision)
                        reportedFailure = false
                    }
                    catch {
                        guard self.sessionID == id, !Task.isCancelled else { return }
                        if !reportedFailure {
                            self.errorMessage = "Automatic transcript backup failed: \(error.localizedDescription). Recording continues; MyWizard will retry."
                            reportedFailure = true
                        }
                    }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            // Live timestamps and recorded CAF samples need the same zero,
            // including startup delays before the first capture callback.
            timeline.reset(origin: recording.hostTimeOrigin)
            recordingBegan(at: recording.startedAt)
            reader.recording = recording
            if includesMicrophone {
                statusMessage = "Recording microphone; transcription will run after Stop…"
                try await startMicrophone(recording: recording, session: id)
            }
            guard sessionID == id else { throw CancellationError() }
            if let startupError { throw TranscriptionError.message(startupError) }
            statusMessage = "Starting system audio capture…"
            try await capture.start(format: format, continuation: continuation, speakerInput: speakerInput,
                                    recording: recording, onSpeakerError: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    self.speakerTask?.cancel()
                    self.errorMessage = message
                }
            }, onDeviceChange: { [weak self] message in
                Task { @MainActor in await self?.audioDeviceChanged(message, session: id) }
            }, onLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.sessionID == id, !self.isPaused else { return }
                    self.lastAudio = Date()
                    self.audioLevel = level
                    if level > 0.025 { self.lastSound = Date() }
                }
            }, onError: { [weak self] message in
                Task { @MainActor in await self?.failed(message, session: id) }
            })
            guard sessionID == id else { throw CancellationError() }
            if let startupError { throw TranscriptionError.message(startupError) }
            Self.startupLogger.info("Capture ready after \(ProcessInfo.processInfo.systemUptime - startupTime, privacy: .public)s from Start")
            isCapturing = true
            if isReadingEnabled { try capture.setOriginalAudioMuted(true) }
            startedAt = Date()
            statusMessage = "Listening — waiting for system audio…"
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.sessionID == id else { return }
                    self.updateAudioStatus()
                }
            }
        } catch is CancellationError {
            await stop(finishing: false)
        } catch {
            await stop(finishing: false)
            statusMessage = "Cannot transcribe: \(error.localizedDescription)"
            errorMessage = statusMessage
        }
    }

    private func failed(_ message: String, session id: UUID) async {
        guard sessionID == id else { return }
        // Preserve errors during startup rather than overwriting them with "listening".
        if !isCapturing {
            startupError = message
            return
        }
        guard !isTransitioning else { startupError = message; return }
        isTransitioning = true
        await stop(finishing: false)
        statusMessage = "Transcription interrupted: \(message)"
        errorMessage = statusMessage
        isTransitioning = false
    }

    private func stop(finishing: Bool = true) async {
        // Keep exactly the visible result, including its provisional tail,
        // before cancellation can deliver late text or speaker revisions.
        refreshTranscript()
        let snapshot = liveSnapshot()
        sessionID = nil
        microphoneActivationID = nil
        stopReading()
        reader.recording = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        let finalAutosaver = autosaver
        autosaver = nil
        monitorTask?.cancel()
        monitorTask = nil
        speakerTask?.cancel()
        speakerTask = nil
        await capture.stop()
        await microphoneCapture.stop()
        input?.finish()
        input = nil
        resultsTask?.cancel()
        if let preparedSpeech { await preparedSpeech.close() }
        else if let analyzer { await analyzer.cancelAndFinishNow() }
        preparedSpeech = nil
        if let recording {
            let saved = await recording.finish()
            recordings.append(saved)
            pendingRecording = saved
            pendingLiveTranscript = snapshot
            do {
                if let finalAutosaver { try await finalAutosaver.finish(snapshot) }
                else { try saved.saveLiveTranscript(snapshot) }
            }
            catch { startupError = "Cannot save the live transcript: \(error.localizedDescription). Retry export before closing MyWizard." }
            needsProcessing = true
            if let failure = saved.manifest.failure { startupError = failure }
        }
        recording = nil
        sessionID = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        isCapturing = false
        isPaused = false
        captureInterruption = nil
        followsCapture = false
        pumpReading()
        audioLevel = 0
        statusMessage = startupError.map { "Transcription interrupted: \($0)" } ?? "Stopped."
        if finishing, startupError != nil { errorMessage = statusMessage }
        if finishing { prewarmTranscription() }
    }

    private func updateAudioStatus() {
        guard !isPaused, !isTransitioning else { return }
        let now = Date()
        if includesMicrophone, !isMicrophoneChanging, now.timeIntervalSince(microphoneStartedAt) > 15,
           microphoneCapture.frameCount == 0, let id = sessionID, let activation = microphoneActivationID {
            Task { await self.microphoneFailed("No microphone audio was received. Check the input device in System Settings > Sound.", activation: activation, session: id) }
            return
        }
        guard let lastAudio, now.timeIntervalSince(lastAudio) < 3 else {
            audioLevel = 0
            statusMessage = "Waiting for system audio. Play spoken content; if no text appears, check Audio Recording permission."
            return
        }
        guard let lastSound, now.timeIntervalSince(lastSound) < 3 else {
            statusMessage = "Silence detected — play some spoken content."
            return
        }
        if now.timeIntervalSince(lastResult ?? startedAt) > 12 {
            statusMessage = "Audio received, but no speech recognized recently. Check the selected language."
        } else {
            statusMessage = includesMicrophone ? "System transcription live • Microphone recorded for final export" : "System transcription live • Audio recorded for final export"
        }
    }
}

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}
