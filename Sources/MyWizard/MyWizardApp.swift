import AppKit
import SwiftUI

@main
struct MyWizardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MyWizard") { appDelegate.showAboutPanel() }
            }
            CommandGroup(replacing: .appSettings) { }
            CommandGroup(replacing: .help) {
                Button("MyWizard Help") { appDelegate.showHelpPanel() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var model: TranscriptionModel?
    private var isQuitting = false
    private var quitConfirmedForCurrentRecording = false
    private var quitConfirmationPanel: NSPanel?
    private var helpPanel: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["MYWIZARD_AUDIO_STARTUP_CLIENT"] == "1" {
            Task {
                do { try await AudioStartupCheck.runClient(); exit(EXIT_SUCCESS) }
                catch { print("AUDIO STARTUP CLIENT FAILED: \(error)"); exit(EXIT_FAILURE) }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_AUDIO_STARTUP_CHECK"] == "1" {
            Task {
                do { try await AudioStartupCheck.run(); exit(EXIT_SUCCESS) }
                catch { print("AUDIO STARTUP CHECK FAILED: \(error)"); exit(EXIT_FAILURE) }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_SPEAKER_NAMING_PREVIEW"] == "1" {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SpeakerNamingPreview()))
            window.title = "Speaker naming check"
            window.isReleasedWhenClosed = false
            window.center()
            helpPanel = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Isolated help preview: no meeting model, audio capture or model downloads.
        if ProcessInfo.processInfo.environment["MYWIZARD_HELP_PREVIEW"] == "1" {
            showHelpPanel()
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_MEETING_CONTROLS_CHECK"] == "1" {
            Task {
                do { try await MeetingControlsCheck.run(); exit(EXIT_SUCCESS) }
                catch { print("MEETING CONTROLS CHECK FAILED: \(error)"); exit(EXIT_FAILURE) }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_LOCALE_CHECK"] == "1" {
            Task {
                do { try await SpeechLocaleCheck.run(); exit(EXIT_SUCCESS) }
                catch { print("SPEECH LOCALE CHECK FAILED: \(error)"); exit(EXIT_FAILURE) }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_STARTUP_CHECK"] == "1" {
            Task {
                do { try await StartupCheck.run(); exit(EXIT_SUCCESS) }
                catch { print("STARTUP CHECK FAILED: \(error)"); exit(EXIT_FAILURE) }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_WHISPER_PREVIEW_AUDIO"] != nil {
            Task {
                do { try await WhisperPrototypeCheck.run(); exit(EXIT_SUCCESS) }
                catch { print("WHISPER COMPARISON FAILED: \(error)"); exit(EXIT_FAILURE) }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_TAP_CHECK"] == "1" {
            Task { @MainActor in
                do {
                    try await SystemAudioTapCheck.run()
                    exit(EXIT_SUCCESS)
                } catch {
                    print("SYSTEM AUDIO TAP CHECK FAILED: \(error)")
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_ECHO_CHECK"] == "1" {
            Task { @MainActor in
                do {
                    try await MicrophoneEchoCheck.run()
                    exit(EXIT_SUCCESS)
                } catch {
                    print("ECHO CHECK FAILED: \(error)")
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_MICROPHONE_CHECK"] == "1" {
            Task { @MainActor in
                do {
                    try await MicrophoneCaptureCheck.run()
                    exit(EXIT_SUCCESS)
                } catch {
                    print("MICROPHONE CAPTURE CHECK FAILED: \(error)")
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if ProcessInfo.processInfo.environment["MYWIZARD_AUDIO_ISOLATION_CHECK"] == "1" {
            Task { @MainActor in
                do {
                    try await AudioIsolationCheck.run()
                    exit(EXIT_SUCCESS)
                } catch {
                    print("AUDIO ISOLATION FAILED: \(error)")
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        var preferences: any PreferenceStore = UserDefaults.standard
        var recordingRoot = RecordedMeeting.root
        // Opt-in isolated UI test. Never redirects the user's regular exports.
        if let root = ProcessInfo.processInfo.environment["MYWIZARD_WORKFLOW_CHECK_DIRECTORY"] {
            preferences = MemoryPreferences()
            preferences.set(root, forKey: "defaultTranscriptDirectory")
            preferences.set("en-US", forKey: "transcriptionLanguage")
            preferences.set("Test microphone", forKey: "ownSpeakerName")
            recordingRoot = URL(fileURLWithPath: root).appendingPathComponent("Recordings")
        }
        let model = TranscriptionModel(preferences: preferences, recordingRoot: recordingRoot)
        self.model = model
        let view = Group {
            if ProcessInfo.processInfo.environment["MYWIZARD_PIPELINE_CHECK"] == "1" {
                PipelineCheck()
            } else if ProcessInfo.processInfo.environment["MYWIZARD_LIVE_READING_CHECK"] == "1" {
                LiveReadingCheck()
            } else if ProcessInfo.processInfo.environment["MYWIZARD_TRANSLATION_CHECK"] == "1" {
                ReadingTranslationCheck()
            } else {
                OverlayView(model: model, preferences: preferences) { [weak self] in
                    self?.hidePanel()
                }
            }
        }
        .environment(\.locale, Locale(identifier: "en"))
        let panel = TranscriptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 620),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "MyWizard"
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.minSize = NSSize(width: 900, height: 360)
        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        if !panel.setFrameUsingName("MyWizardOverlay") { panel.center() }
        panel.setContentSize(NSSize(width: max(panel.frame.width, 900), height: max(panel.frame.height, 360)))
        // A saved overlay position can leave the new footer below the screen.
        // Keep the restored full view inside the current desktop work area.
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            var frame = panel.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            panel.setFrame(frame, display: false)
        }
        panel.setFrameAutosaveName("MyWizardOverlay")
        self.panel = panel
        showPanel()
        model.prewarmTranscription()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    private func showPanel() {
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    func showAboutPanel() {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "?"
        let date = info["MyWizardBuildDate"] as? String ?? "date unavailable"
        NSApp.orderFrontStandardAboutPanel(options: [
            .version: "\(date), bundle \(build)"
        ])
        NSApp.activate()
    }

    func showHelpPanel() {
        if let helpPanel {
            helpPanel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        do {
            let guide = try HelpGuide.load()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "MyWizard Help"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 520, height: 420)
            window.level = .floating
            window.contentView = NSHostingView(rootView: HelpView(guide: guide)
                .environment(\.locale, Locale(identifier: "en")))
            window.center()
            helpPanel = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } catch {
            let alert = NSAlert()
            alert.messageText = "MyWizard Help could not be opened"
            alert.informativeText = "The bundled guide is missing or unreadable. Please rebuild or reinstall MyWizard."
            alert.runModal()
        }
    }

    private func showQuitConfirmation() {
        if let quitConfirmationPanel, quitConfirmationPanel.isVisible {
            quitConfirmationPanel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let confirmation = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        confirmation.title = "MyWizard"
        confirmation.isReleasedWhenClosed = false
        confirmation.level = .floating
        confirmation.contentView = NSHostingView(rootView: QuitConfirmationView(
            icon: NSApp.applicationIconImage,
            onContinue: { [weak self] in self?.quitConfirmationPanel?.close() },
            onQuit: { [weak self] in
                self?.quitConfirmationPanel?.close()
                self?.quitConfirmedForCurrentRecording = true
                NSApp.terminate(nil)
            }
        ))
        if let panel {
            confirmation.setFrameOrigin(NSPoint(
                x: panel.frame.midX - confirmation.frame.width / 2,
                y: panel.frame.midY - confirmation.frame.height / 2
            ))
        } else {
            confirmation.center()
        }
        quitConfirmationPanel = confirmation
        confirmation.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        if model?.isCapturing == true && !quitConfirmedForCurrentRecording {
            showQuitConfirmation()
            return .terminateCancel
        }
        quitConfirmedForCurrentRecording = false
        isQuitting = true
        panel?.saveFrame(usingName: "MyWizardOverlay")
        // Closing must still work if a system capture/recognition service stalls.
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await model?.shutDown()
            deadline.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct QuitConfirmationView: View {
    let icon: NSImage
    let onContinue: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 68, height: 68)
            Text("MyWizard")
                .font(.system(size: 20, weight: .bold))
            Text("A call is being recorded. Quit MyWizard and stop the recording?")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Continue Recording", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                Button("Quit MyWizard", action: onQuit)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 410, height: 270)
        .onExitCommand(perform: onContinue)
    }
}

final class TranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
