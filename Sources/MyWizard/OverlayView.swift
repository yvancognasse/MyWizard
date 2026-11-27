import AppKit
import SwiftUI

struct OverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onHide: () -> Void
    @ObservedObject var model: TranscriptionModel
    @ObservedObject private var reader: TranscriptReader
    @ObservedObject private var displayTranslation: DisplayTranslation
    @AppStorage("overlayTransparency") private var transparency = 0.15
    @AppStorage("overlayFontSize") private var fontSize = 19.0
    @State private var showsAppearance = false
    @State private var showsCalendar = false
    @State private var showsCodexProjects = false
    @StateObject private var projectExport = CodexProjectExport()
    @StateObject private var exporter: TranscriptExporter
    @State private var followsLiveTranscript = true
    @State private var isTranscriptAtBottom = true
    @State private var isUserScrollingTranscript = false
    @State private var transcriptContentSize = CGSize.zero
    @State private var transcriptPosition = ScrollPosition(edge: .bottom)
    @State private var speakerToRename: SpeakerSelection?
    @State private var showsSearch = false
    @State private var searchQuery = ""
    @State private var searchMatches: [TranscriptSearchMatch] = []
    @State private var searchIndex = 0
    @FocusState private var searchIsFocused: Bool

    private struct SpeakerSelection: Identifiable {
        let id: Int
        let paragraph: TranscriptParagraph
    }

    private var emptyTranscriptMessage: String {
        let language =
            model.displayLanguage == .original
            ? model.language : model.displayLanguage.rawValue
        switch ReadingTranslationPlan.baseLanguage(language) {
        case "fr": return "Le texte transcrit apparaîtra ici."
        case "de": return "Der transkribierte Text wird hier angezeigt."
        default: return "Transcribed text will appear here."
        }
    }

    init(
        model: TranscriptionModel, preferences: any PreferenceStore = UserDefaults.standard,
        onHide: @escaping () -> Void = {}
    ) {
        _exporter = StateObject(wrappedValue: TranscriptExporter(preferences: preferences))
        self.model = model
        self.reader = model.reader
        self.displayTranslation = model.displayTranslation
        self.onHide = onHide
    }

    var body: some View {
        let highlights = Dictionary(grouping: searchMatches, by: \.paragraphID)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            meetingContext
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if projectExport.summary != nil {
                    HStack(spacing: 10) {
                        Text(projectExport.summary ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(meetingContextDetails)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if projectExport.pendingSource != nil {
                            Button("Retry project copy") { projectExport.retry() }
                                .font(.caption).fixedSize()
                        }
                        if let project = projectExport.completedProject {
                            Button("Open in Codex") {
                                do {
                                    let link = try CodexProjectRegistration.deepLink(for: project)
                                    guard NSWorkspace.shared.open(link) else {
                                        throw TranscriptionError.message(
                                            "Codex could not be opened. Open or install Codex on this Mac and try again.")
                                    }
                                } catch { model.errorMessage = error.localizedDescription }
                            }
                            .font(.caption).fixedSize()
                            .help("Open Codex with \(project.name) selected")
                            .accessibilityLabel("Open \(project.name) in Codex")
                        }

                    }
                }
                if let message = model.calendarAssociationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let reason = model.captureInterruption {
                    HStack {
                        Text("Audio interrupted — check your output device. " + reason)
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        Button("Retry audio") {
                            Task { await model.retryInterruptedCapture() }
                        }
                        .disabled(model.isTransitioning || model.isMicrophoneChanging)
                        .help("Reconnect audio devices and continue this meeting after an interruption")
                    }
                }
                if !model.isCapturing && (model.isProcessing || model.needsProcessing) {
                    HStack {
                        Text(model.statusMessage ?? "Preparing recording…").font(.caption)
                        Spacer()
                        if model.isProcessing {
                            Button("Cancel processing") { model.cancelProcessing() }
                        } else {
                            Button("Prepare export") { Task { await prepareExport() } }
                        }
                    }
                }

                if showsSearch {
                    HStack(spacing: 8) {
                        TextField("Find in displayed transcript", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchIsFocused)
                            .onSubmit { moveSearch(1) }
                            .task { searchIsFocused = true }
                        Text(
                            searchMatches.isEmpty ? "0 results" : "\(searchIndex + 1) / \(searchMatches.count)"
                        )
                        .font(.caption).monospacedDigit().fixedSize()
                        Button {
                            moveSearch(-1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(searchMatches.isEmpty).accessibilityLabel("Previous search result")
                        Button {
                            moveSearch(1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(searchMatches.isEmpty).accessibilityLabel("Next search result")
                        Button("Done") { showsSearch = false }.keyboardShortcut(.escape, modifiers: [])
                    }
                }

                if model.displayLanguage != .original {
                    HStack {
                        Text(
                            displayTranslation.errorMessage
                                ?? (displayTranslation.isPending
                                    ? "Translating display… The latest translation stays visible."
                                    : "Displayed in \(model.displayLanguage.title). Saved transcript keeps the original text.")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        if displayTranslation.errorMessage != nil {
                            Button("Retry") { displayTranslation.retry() }
                        }
                    }
                }
                GeometryReader { geometry in
                    ScrollViewReader { scroll in
                        ScrollView(.vertical) {
                            // Rows change height and speaker boundaries during recognition.
                            // A lazy stack estimates offscreen heights; bottom scrolling
                            // then realizes different rows and changes that estimate again.
                            // Use exact geometry to avoid a layout/scroll feedback loop.
                            VStack(alignment: .leading, spacing: 0) {
                                if model.paragraphs.isEmpty {
                                    Text(emptyTranscriptMessage)
                                        .font(.system(size: fontSize, weight: .medium, design: .default))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ForEach(displayTranslation.paragraphs) { paragraph in
                                        VStack(alignment: .leading, spacing: 4) {
                                            if paragraph.hasSpeakerLabel {
                                                if let speaker = paragraph.speaker {
                                                    Button {
                                                        NSApplication.shared.activate()
                                                        speakerToRename = SpeakerSelection(id: speaker, paragraph: paragraph)
                                                    } label: {
                                                        Text(paragraph.heading(names: model.speakerNames))
                                                            .font(.system(size: max(12, fontSize * 0.75), weight: .semibold))
                                                            .foregroundStyle(speakerColor(speaker))
                                                            .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .help(
                                                        "Click to rename \(SpeakerIdentity.heading(speaker)) from this passage onward"
                                                    )
                                                    .disabled(model.isProcessing)
                                                    .accessibilityLabel(
                                                        "Rename \(SpeakerIdentity.heading(speaker)): \(paragraph.heading(names: model.speakerNames))"
                                                    )
                                                } else {
                                                    Text(paragraph.heading(names: model.speakerNames))
                                                        .font(.system(size: max(12, fontSize * 0.75), weight: .semibold))
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            SearchableTranscriptText(
                                                text: paragraph.text, matches: highlights[paragraph.id] ?? [],
                                                selected: selectedSearchID, fontSize: fontSize)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .shadow(
                                            color: Color(nsColor: .windowBackgroundColor).opacity(transparency), radius: 2
                                        )
                                        .padding(.bottom, 24)
                                        .id(paragraph.id)
                                        .task(id: selectedSearchID) {
                                            // Wait for the selected occurrence's nested
                                            // anchor to be laid out.
                                            guard let match = searchMatches.first(where: { $0.id == selectedSearchID }),
                                                match.paragraphID == paragraph.id
                                            else { return }
                                            await Task.yield()
                                            guard !Task.isCancelled, selectedSearchID == match.id else { return }
                                            scroll.scrollTo("search-result-\(match.id)", anchor: .top)
                                        }
                                    }
                                }
                            }
                            .onGeometryChange(for: CGSize.self) {
                                $0.size
                            } action: { size in
                                transcriptContentSize = size
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollPosition($transcriptPosition)
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        // Recognition and speaker corrections can shrink rows.
                        // Preserve the bottom edge during that relayout, rather than
                        // leaving the viewport at an obsolete (sometimes empty) offset.
                        .defaultScrollAnchor(followsLiveTranscript ? .bottom : nil, for: .sizeChanges)
                        .task(id: transcriptContentSize) {
                            // Follow measured content changes, never height estimates.
                            // The non-lazy stack gives one stable size for this revision.
                            await Task.yield()
                            guard !Task.isCancelled, followsLiveTranscript,
                                !isUserScrollingTranscript
                            else { return }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                transcriptPosition.scrollTo(edge: .bottom)
                            }
                        }
                        .onScrollPhaseChange { _, phase, _ in
                            isUserScrollingTranscript = phase == .interacting || phase == .decelerating
                            if isUserScrollingTranscript && !isTranscriptAtBottom {
                                followsLiveTranscript = false
                            }
                        }
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            // Re-enable live following as soon as the user returns
                            // to the newest line (with a small tolerance for
                            // fractional layout values).
                            geometry.contentOffset.y + geometry.containerSize.height
                                >= geometry.contentSize.height - 2
                        } action: { _, isAtBottom in
                            isTranscriptAtBottom = isAtBottom
                            if isAtBottom {
                                followsLiveTranscript = true
                            } else if isUserScrollingTranscript {
                                followsLiveTranscript = false
                            }
                        }
                        .onChange(of: displayTranslation.paragraphs) {
                            refreshSearch()
                        }
                        .onChange(of: selectedSearchID) {
                            guard
                                let match = searchMatches.indices.contains(searchIndex)
                                    ? searchMatches[searchIndex] : nil
                            else { return }
                            followsLiveTranscript = false
                            // Move to the paragraph; its row task then scrolls
                            // to the precise occurrence inside it.
                            scroll.scrollTo(match.paragraphID, anchor: .top)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !followsLiveTranscript && !isTranscriptAtBottom && !model.paragraphs.isEmpty {
                                Button {
                                    followsLiveTranscript = true
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                        transcriptPosition.scrollTo(edge: .bottom)
                                    }
                                } label: {
                                    Label("Jump to live", systemImage: "arrow.down")
                                }
                                .buttonStyle(.borderedProminent)
                                .help("Return to the latest transcript and resume automatic scrolling")
                                .accessibilityLabel("Jump to latest transcript")
                                .padding(12)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            if let message = model.languageChangeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .accessibilityLabel(message)
            }
            transcriptControls
            Divider()
            settingsBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .opacity(1 - transparency)
        }
        .background {
            if let job = displayTranslation.job {
                ReadingTranslationTask(job: job, complete: displayTranslation.completed)
                    .id(job.id)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            WindowResizeHandle()
                .frame(width: 20, height: 20)
                .padding(9)
        }
        .padding(8)
        .background {
            if let job = model.translationJob {
                ReadingTranslationTask(job: job, complete: model.translationCompleted)
                    .id(job.id)
            }
        }
        .preferredColorScheme(.light)
        .tint(Color(red: 0.0, green: 0.43, blue: 0.41))
        .sheet(isPresented: $showsCalendar) { CalendarMeetingPicker(model: model) }
        .sheet(isPresented: $showsCodexProjects) { CodexProjectPicker(model: model) }
        .sheet(item: $speakerToRename) { speaker in
            SpeakerNameEditor(
                speaker: speaker.id,
                currentName: speaker.paragraph.speakerName ?? model.speakerNames[speaker.id] ?? "",
                suggestions: model.calendarMeeting?.invitees ?? [],
                savedNames: model.rememberedVoices.map(\.name)
            ) { name in
                model.renameSpeaker(speaker.id, to: name, from: speaker.paragraph)
            }
        }
        .onChange(of: searchQuery) { refreshSearch(reset: true) }
        .onChange(of: model.isCapturing) {
            if model.isCapturing { projectExport.dismissCompletedCopy() }
        }
        .onChange(of: model.codexProject) {
            if model.codexProject != nil { projectExport.dismissCompletedCopy() }
        }
        .onChange(of: model.calendarMeeting) {
            if model.calendarMeeting != nil { projectExport.dismissCompletedCopy() }
        }
        .onChange(of: showsSearch) {
            if showsSearch {
                refreshSearch(reset: true)
                searchIsFocused = true
            } else {
                searchMatches = []
                searchIsFocused = false
            }
        }
        .alert(
            "MyWizard",
            isPresented: Binding(
                get: {
                    exporter.errorMessage != nil || model.errorMessage != nil || reader.errorMessage != nil
                },
                set: {
                    if !$0 {
                        exporter.errorMessage = nil
                        model.errorMessage = nil
                        reader.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                exporter.errorMessage = nil
                model.errorMessage = nil
                reader.errorMessage = nil
            }
        } message: {
            Text(exporter.errorMessage ?? model.errorMessage ?? reader.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("MyWizard")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .overlay { WindowDragHandle().accessibilityHidden(true) }
            if model.isCapturing || model.isTransitioning {
                HStack(spacing: 8) {
                    Circle().fill(model.captureInterruption == nil ? Color.red : Color.orange)
                        .frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(
                        model.isTransitioning
                            ? "Please wait…"
                            : (model.captureInterruption == nil ? "Recording" : "Audio interrupted")
                    )
                    .font(.callout)
                    if let startedAt = model.activeRecordingStartedAt {
                        RecordingDurationView(startedAt: startedAt)
                    }
                }
            }
            Button(
                model.isTransitioning
                    ? "Please wait…" : (model.isCapturing ? "Stop & Save…" : "Start recording")
            ) {
                Task {
                    let wasCapturing = model.isCapturing
                    await model.toggleCapture()
                    if wasCapturing && !model.isCapturing { await prepareExport() }
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(CaptureButtonStyle(isCapturing: model.isCapturing))
            .disabled(
                exporter.isPresenting || model.isTransitioning
                    || (!model.isCapturing && (model.needsProcessing || model.isMicrophoneChanging))
            )
            .help(model.statusMessage ?? "Start or stop transcription")
            .fixedSize()
            Menu {
                Button {
                    Task {
                        if model.isCapturing { await model.toggleCapture() }
                        await prepareExport()
                    }
                } label: {
                    Label("Save transcript…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(
                    (!model.hasExportContent && !model.needsProcessing) || exporter.isPresenting
                        || model.isTransitioning
                )
                .help("Stop recording, prepare the full transcript and save a text file (⌘S)")
                .accessibilityLabel("Save transcript")
                Button {
                    exporter.openExportDirectory()
                } label: {
                    Label("Open export folder", systemImage: "folder")
                }
                .help("Open the saved text files folder in Finder")
                .accessibilityLabel("Open export folder")
                Divider()
                Button {
                    model.calendarMeeting = nil
                    model.codexProject = nil
                    projectExport.dismiss()
                } label: {
                    Label("Clear meeting and project", systemImage: "xmark.circle")
                }
                .help(
                    "Clear the calendar meeting, Codex project and export notice. Keep the transcript and saved files."
                )
                .accessibilityLabel("Clear meeting and project")
                .disabled(
                    meetingContextSummary.isEmpty || model.isTransitioning || model.isProcessing
                        || exporter.isPresenting)
                Button(role: .destructive) {
                    model.clear()
                } label: {
                    Label("Clear transcript", systemImage: "trash")
                }
                .disabled(
                    !model.hasExportContent || model.isCapturing || model.isTransitioning
                        || model.needsProcessing
                )
                .help("Clear transcript")
                .accessibilityLabel("Clear transcript")
                Divider()
                Button("Hide MyWizard", systemImage: "minus", action: onHide)
                Button("Quit MyWizard", systemImage: "power") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions")
            .help("Save, open export folder, clear selections or transcript, hide, and quit")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var meetingContext: some View {
        HStack(spacing: 16) {
            Button {
                showsCalendar = true
            } label: {
                Label(model.calendarMeeting?.title ?? "Choose meeting", systemImage: "calendar")
                    .lineLimit(1).truncationMode(.tail)
            }
            .help(model.calendarMeeting?.title ?? "Choose a meeting from Apple Calendar")
            .accessibilityLabel("Choose calendar meeting")
            .disabled(model.isTransitioning || model.isProcessing)
            Spacer(minLength: 16)
            Button {
                showsCodexProjects = true
            } label: {
                Label(
                    model.codexProject.map { "Project: \($0.name)" } ?? "Choose project",
                    systemImage: "folder"
                )
                .lineLimit(1).truncationMode(.middle)
            }
            .help(
                model.codexProject.map { "Also export to \($0.name)/Notes" }
                    ?? "Also add the export to a Codex project"
            )
            .accessibilityLabel("Choose Codex project")
            .disabled(
                model.isTransitioning || model.isProcessing || exporter.isPresenting
                    || projectExport.pendingSource != nil)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .help(meetingContextDetails)
    }

    private var transcriptControls: some View {
        HStack(spacing: 16) {
            Picker("Spoken", selection: Binding(get: { model.language }, set: { model.selectSpokenLanguage($0) })) {
                ForEach(TranscriptionLanguage.allCases, id: \.rawValue) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .frame(maxWidth: 290)
            .help(
                "Choose from 30 local transcription variants, including while recording. The current language stays active until the new model is ready. Change between sentences; models may need to download. Reading and translation languages are selected separately in Settings. German (Switzerland) does not guarantee recognition of Swiss dialects."
            )
            .disabled(model.isTransitioning || model.isLanguageChanging || model.isPaused || readingIsBusy)
            if let message = model.languageChangeMessage {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(message)
                    .help(message)
            }
            Picker("Display", selection: $model.displayLanguage) {
                ForEach(ReadingLanguage.allCases, id: \.rawValue) { language in
                    Text(language.title).tag(language)
                }
            }
            .frame(maxWidth: 250)
            .help("Translate the displayed system transcript. Exports keep the source language.")
            Spacer(minLength: 0)
            Button {
                Task { await model.toggleReading() }
            } label: {
                Label(
                    readingIsBusy ? "Stop reading" : "Read aloud",
                    systemImage: readingIsBusy ? "stop.circle.fill" : "speaker.wave.2"
                )
                .foregroundStyle(readingIsBusy ? Color.red : Color.primary)
            }
            .disabled(
                (model.paragraphs.isEmpty && !model.isCapturing && !readingIsBusy) || model.isTransitioning
                    || model.isPaused
            )
            .help(
                readingIsBusy
                    ? "Stop reading and restore original audio."
                    : "Read or translate the current passage. During capture, original system audio is muted and new phrases follow automatically."
            )
            .accessibilityLabel(readingIsBusy ? "Stop reading" : "Read transcript")
            Button {
                NSApplication.shared.activate()
                showsSearch = true
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .font(.caption)
            .fixedSize()
        }
        .controlSize(.regular)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var settingsBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.setMicrophoneEnabled(!model.includesMicrophone) }
            } label: {
                Label(
                    model.isMicrophoneChanging
                        ? "Microphone: Changing…"
                        : (model.includesMicrophone ? "Microphone: On" : "Microphone: Off"),
                    systemImage: model.includesMicrophone ? "mic.fill" : "mic.slash.fill"
                )
                .foregroundStyle(model.includesMicrophone ? Color.red : Color.secondary)
            }
            .disabled(model.isTransitioning || model.isMicrophoneChanging)
            .accessibilityLabel(
                model.includesMicrophone ? "Turn off MyWizard microphone" : "Turn on MyWizard microphone"
            )
            .accessibilityValue(
                model.isMicrophoneChanging ? "Changing" : (model.includesMicrophone ? "On" : "Off")
            )
            .help(
                model.includesMicrophone
                    ? "Stop recording your microphone in MyWizard. Zoom is not muted. System recording continues."
                    : "Record your microphone in MyWizard, including during a session. Your words appear only in the TXT export. Zoom is unchanged."
            )
            Text("· Export only").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button {
                showsAppearance.toggle()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Appearance, background transparency, reading language and speakers")
            .popover(isPresented: $showsAppearance, arrowEdge: .top) {
                settingsContent
                    .preferredColorScheme(.light)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .padding(.trailing, 12)
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Appearance").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Background transparency")
                        Spacer()
                        Text("\(Int((transparency * 100).rounded())) %").monospacedDigit()
                    }
                    Slider(value: $transparency, in: 0...1, step: 0.05)
                        .accessibilityLabel("Background transparency")
                    Text("Text stays opaque and readable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Text size")
                        Spacer()
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                    }
                    Slider(value: $fontSize, in: 12...48, step: 1)
                        .accessibilityLabel("Text size")
                }
                Text("Resize the window using its edges or the bottom-right handle.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Text exports").font(.headline)
                Text(exporter.defaultDirectoryPath ?? exporter.suggestedDirectory?.path ?? "Documents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Folder…") {
                    showsAppearance = false
                    exporter.chooseDefaultDirectory()
                }
                .disabled(exporter.isPresenting)
                Text(
                    "All .txt exports are saved in this folder. Use Choose Folder… to change the destination before exporting."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text("Reading & translation").font(.headline)
                Picker("Read in", selection: $model.readingLanguage) {
                    ForEach(ReadingLanguage.allCases, id: \.rawValue) { language in
                        Text(language.title).tag(language)
                    }
                }
                Text(
                    "Choose a language to translate before reading. Original system audio is muted while reading is enabled; transcription continues. Stopping reading or capture restores the original sound."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Use Display below the transcript to translate the system transcript. Your microphone appears only in the exported text, never in the window. The latest translation stays visible while new text is translated. Saved text stays in the source language with speaker labels and automatic duplicate filtering. Both language choices are remembered."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "38 local translation variants, plus Original language. Models may download on first use. Same-language text is kept without dialect rewriting. Reading prefers installed regional voices and can reuse compatible voices. German output is standard German, not Swiss dialect."
                )
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Speakers").font(.headline)
                Text(
                    "Only named voices are saved on this Mac, with one profile per name. Rename a speaker to recognize them in future meetings. Clear speech is needed; uncertain matches keep a numbered label."
                )
                .font(.caption).foregroundStyle(.secondary)
                if !model.rememberedVoices.isEmpty {
                    Text("\(model.rememberedVoices.count) saved voices")
                        .font(.caption)
                    ForEach(model.rememberedVoices) { voice in
                        HStack {
                            Text(voice.name)
                                .font(.caption).textSelection(.enabled)
                            Spacer()
                            Button(role: .destructive) {
                                model.forgetSavedVoice(voice.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Forget voice: \(voice.name)")
                            .help("Forget this saved voice; current transcript names stay")
                        }
                    }
                }
                if let message = model.voiceMemoryMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Button("Forget saved voices", role: .destructive) { model.forgetSavedVoices() }
                    .disabled(model.rememberedVoices.isEmpty && model.voiceMemoryMessage == nil)
                    .help(
                        "Delete all saved voice profiles. Current transcript names stay; automatic learning resumes with the next recording."
                    )
                HStack {
                    Text("Microphone's name")
                        .font(.caption)
                        .frame(width: 110, alignment: .leading)
                    TextField(
                        "Your name",
                        text: Binding(
                            get: { model.speakerNames[SpeakerIdentity.microphone] ?? "" },
                            set: { model.speakerNames[SpeakerIdentity.microphone] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Microphone participant name")
                }
                .help(
                    "Microphone speech appears only in exports. Echo filtering is automatic but imperfect; headphones provide the best isolation. Other voices start at Speaker 1. Click a speaker in the transcript to rename it. Speaker identification can be delayed or incorrect, especially with overlapping voices."
                )
                Text("Used in exports only. Saved automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(speakerNumbers, id: \.self) { number in
                    HStack {
                        Text("Speaker \(number)").foregroundStyle(speakerColor(number))
                        SpeakerPreferenceNameField(currentName: model.speakerNames[number] ?? "") { name in
                            model.renameSpeaker(number, to: name)
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name for Speaker \(number)")
                        .disabled(model.isProcessing)
                    }
                }
            }
            .padding(18)
            .frame(width: 340)
        }
        .frame(width: 360, height: 580)
    }

    private var meetingContextSummary: String {
        [
            model.codexProject.map { "Project: \($0.name)" },
            model.calendarMeeting.map(\.contextLabel),
            projectExport.summary,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private var meetingContextDetails: String {
        [
            model.codexProject.map { "Project: \($0.name)" },
            model.calendarMeeting.map(\.contextLabel),
            projectExport.message,
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func prepareExport() async {
        // Resolve a failed additional copy before another export can replace its retry state.
        guard projectExport.pendingSource == nil else {
            model.errorMessage =
                "Retry the pending project copy or choose Clear meeting and project from the More menu before saving another transcript. Your current transcript is preserved."
            return
        }
        guard await model.prepareExport() else { return }
        let recordings = model.recordings
        let project = model.codexProject
        exporter.save(
            model.exportText, recordingStartedAt: model.recordingStartedAt,
            meetingTitle: model.calendarMeeting?.title
        ) { url in
            if let project { projectExport.add(url, to: project) }
            let result = RecordingCleanup.afterExport(recordings)
            model.recordingsRemoved(result.removed)
            model.clear()
            searchQuery = ""
            showsSearch = false
            followsLiveTranscript = true
            if !result.failures.isEmpty {
                model.errorMessage =
                    "Text saved, but some recordings could not be removed:\n"
                    + result.failures.joined(separator: "\n")
            }
        }
    }

    private var selectedSearchID: String? {
        searchMatches.indices.contains(searchIndex) ? searchMatches[searchIndex].id : nil
    }

    private func refreshSearch(reset: Bool = false) {
        guard showsSearch else { return }
        let previous = selectedSearchID
        searchMatches = TranscriptSearch.matches(searchQuery, in: displayTranslation.paragraphs)
        searchIndex =
            reset
            ? 0
            : (searchMatches.firstIndex { $0.id == previous }
                ?? min(searchIndex, max(0, searchMatches.count - 1)))
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            followsLiveTranscript = false
        }
    }

    private func moveSearch(_ direction: Int) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + direction + searchMatches.count) % searchMatches.count
    }

    private var speakerNumbers: [Int] {
        Array(Set(model.paragraphs.compactMap(\.speaker))).filter { $0 != SpeakerIdentity.microphone }
            .sorted()
    }

    private var readingIsBusy: Bool {
        model.isReadingEnabled || reader.isReading || model.translationJob != nil
    }

    private func speakerColor(_ speaker: Int?) -> Color {
        guard let speaker else { return .secondary }
        let colors: [Color] = [
            Color(red: 0.0, green: 0.38, blue: 0.39),
            Color(red: 0.35, green: 0.28, blue: 0.61),
            Color(red: 0.55, green: 0.29, blue: 0.12),
            Color(red: 0.18, green: 0.34, blue: 0.62),
        ]
        return colors[max(0, speaker) % colors.count]
    }
}

// Keep capture state visible even when another application is active.
struct CaptureButtonStyle: ButtonStyle {
    let isCapturing: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCapturing ? Color(red: 0.83, green: 0.12, blue: 0.16) : Color(red: 0.0, green: 0.43, blue: 0.41))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.55)
    }
}
