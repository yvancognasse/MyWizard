# MyWizard

A local macOS 26+ meeting assistant with a floating transcript. Interface: English. Speech languages: 30 local transcription variants across Cantonese, Chinese, English, French, German, Italian, Japanese, Korean, Portuguese and Spanish. Supported models may require an initial download after Start.

## Build

```zsh
./build_app.sh
open .build/MyWizard.app
```

The build keeps the Apple Development signing identity stable and retains the previous signed bundle. Speech/audio/microphone permissions may be requested by macOS. Audio capture begins only after Start.

To create a compressed disk image for sharing:

```zsh
./build_dmg.sh
```

The DMG and its SHA-256 checksum are saved in `dist/`. It contains the signed app, an Applications shortcut and installation instructions. Use `./build_dmg.sh --skip-build` to package the already built app. The current app targets Apple Silicon and macOS 26 or later. Its Apple Development signature is not notarized; recipient Macs may block opening it. Public distribution without this restriction requires Developer ID signing and Apple notarization.

## Two-stage workflow (10.70)

Version 10.63 removes meeting markers, notes, counters, the ⌘B shortcut, event-log writing and event appendices in TXT exports. Old event files are ignored and left untouched when reading older recordings. Transcript search and audio-interruption recovery remain available.

Version 10.62 removes the conditional Reset button from Text exports and its explanatory text. Use Choose Folder… to change the export destination.

Version 10.70 removes the duplicate **Dismiss** button. The circled × is the single action for clearing both selections and the export notice/pending retry; it also works when only a copy notice remains. The compact context line remains, and clearing its selections or notice keeps the transcript and saved files.

Version 10.69 combines selected project, calendar meeting and project-copy status into a single compact line. Full details remain in its tooltip. **Dismiss** now clears both selections and the export notice/pending retry, preserving the transcript, recordings and saved files. It remains usable during capture and is disabled during export preparation and saving.

Version 10.68 fixes project registration: app-server `project/create` alone does not populate the desktop application's project cache. MyWizard now opens the desktop's `codex://new?path=…` folder-registration route and confirms success only by reading the actual desktop catalog. The desktop handles folder consent and names the project after the folder; it may show an empty composer but MyWizard sends no prompt. Existing roots are reused. The picker uses the desktop catalog exclusively, so service-only projects are no longer presented as registered desktop projects. No Codex settings/database writes are performed by MyWizard.

Version 10.67 adds **Clear meeting and project**, a circled × beside the project picker. It resets both current selections while preserving the transcript, audio, saved export destination, calendar events and Codex projects. It is disabled during export preparation, saving or a pending project-copy retry.

Version 10.66 colors project cards like Calendar and adds **Add project…** with a name and native folder chooser. Project list/create requests use the installed Codex CLI's local app-server protocol (experimental project API), without editing its databases or creating a chat. Existing project roots are reused. Failed/uncertain creations can be retried with the same idempotency key. If the service is unavailable, the picker falls back to its saved local project catalog with a notice. This integration requires the installed CLI's project protocol; it may need adaptation after a Codex update.

Version 10.65 adds an optional **Choose Codex project** picker beside Calendar. It reads the local desktop project list from `$CODEX_HOME/.codex-global-state.json` (default `~/.codex`), without modifying Codex settings. The normal TXT export remains in its configured folder; a second copy goes to the selected local project's `Notes` folder. Collisions get numbered filenames; failed copies retain the original and offer Retry or Dismiss. Cloud/remote projects and missing local roots are unavailable. The desktop storage schema is internal and may require adaptation after a Codex update. Selection is per meeting and is included in local transcript snapshots. No chat is created or project source uploaded.

Version 10.61 expands **Read in** and **Display in** to 38 local translation variants plus Original language, preserving existing saved choices. Translation requests and cache keys retain regional identifiers and distinguish Chinese scripts. Same-language/same-script text is kept without dialect rewriting. Reading prefers installed regional voices and falls back to compatible voices. Language pairs and voice availability remain checked by Apple.

Version 10.60 expands the transcription selector from 5 to 30 regional variants verified against Apple SpeechTranscriber on the target Mac. The selected language and region are preserved without silently substituting another regional model. The picker is wider for readable labels. Translation/read-aloud choices remain separate and unchanged.

Version 10.59 removes the manual Pause/Resume button and its ⇧⌘P shortcut. Device-change protection remains: an interrupted capture offers **Retry audio** only in its contextual message.

Version 10.58 adds **Help → MyWizard Help (⇧⌘H)**, an offline English guide with topic links, search, selectable text and native accessibility headings. In the Help window, ⌘F focuses topic search. Guide content lives in `App/Help/guide.json`; update it with every user-visible development as required by `AGENTS.md`. Packaging checks its `reviewedVersion` against the app version and bundles the guide automatically.

Version 10.57 adds explicit meeting selection from Apple Calendar, a title for TXT exports, and invited-person suggestions when renaming speakers. Calendar access is requested only when opening the calendar picker.

Version 10.56 removes the permanent status row and the recovery interface/launch proposal. Pause/Resume sits immediately after Start/Stop. Find sits immediately after the recording timer in the top row. The window is wider to keep these controls visible, and its minimum height returns to 260 points. Export progress/actions and audio-interruption guidance appear only when needed. Saved snapshots remain preserved.

Version 10.55 adds a permanently visible capture status and a second control row. **Pause / Resume (⇧⌘P)** stops both audio devices without ending the meeting. No system or microphone audio is captured while paused; original playback is restored and read-aloud is stopped. Resume reopens devices with fresh formats, preserving the recording folder, speech streams and speaker state. The elapsed counter and timestamps include pauses; the recordings contain matching silence gaps. A changed system output or tap format pauses both captures and shows a reason with guidance to reconnect/select the device and choose Resume. Failed resume attempts remain paused. Device notifications from a retired tap are ignored.

**Find (⌘F)** searches the currently displayed transcript, including translated text, ignoring case and accents. All occurrences are highlighted, the selected occurrence is orange, and Enter/⌘G/⇧⌘G navigate the results. Search pauses live following; Latest returns to the live transcript.

The recovery interface introduced in 10.55 was removed in 10.56; the following describes its earlier behavior. Recovery restores the last saved transcript and speaker names, then offers the existing Prepare export action. A crash can lose the final seconds since the last periodic snapshot; warnings remain visible. Folders without a usable snapshot remain visible with an explanation and Show files. Nothing is automatically recovered or deleted. Active writers and recovered meetings hold an OS file lease so another instance cannot recover the same files. Symbolic links are rejected. Older recordings remain supported.

Version 10.54 prepares the installed Apple speech engine and the speaker model concurrently when the window opens. Start joins any preparation already in progress. Warmup does not open audio devices or record anything; missing Apple language assets are downloaded only after Start. The speaker model stays loaded between meetings, with its speaker timeline and streaming buffers reset for each new session. Each Apple analyzer is used for one session only; Stop prepares a fresh one, and changing the speech language discards the old preparation. Warmup failures are retried at Start. Startup timing messages (Apple ready, speakers ready, capture ready and first text) are available in Console under subsystem `com.yvancognasse.MyWizard`, category `Startup`; they contain timings, not transcript text. The first cold launch or a model download can still take longer.

Version 10.53 shows a floating Latest button when the transcript is scrolled above the newest text. Clicking it returns to the bottom and resumes following incoming text.

Version 10.52 asks for confirmation before quitting during a recording. The native About panel displays the package date and bundle number together, for example `(05-10-2026, bundle 70)`.

Version 10.51 changes the Hide button to green with a white minus.

Version 10.50 adds a minus button immediately left of the red Quit button. The minus hides the floating window while MyWizard keeps running; click the wand icon in the menu bar or the app icon in the Dock to show it again. Quit still ends the app and stops capture.

Version 10.49 offers separate English (US) and English (UK) choices for speech transcription. The selected locale is saved and passed to Apple's live transcriber and microphone export. If Apple offers only the other English regional model, capture reports that the selected model is unavailable instead of silently switching. Display and reading translation still use English as one language.

Version 10.48 removes automatic speed adjustment after a live test. Spoken passages now use Apple's fixed default speech rate. There is no speed setting in Preferences.

Version 10.47 makes automatic reading speed permanent for live and saved transcript reading. The two speed controls were removed from Preferences, and obsolete manual-speed preferences are cleared on startup. The rate is recalculated for each new spoken passage from the remaining reading queue.

Version 10.46 introduced automatic reading speed during live transcription. Each new spoken passage uses the amount of queued system-audio text to select a rate between 1.0× and 1.75× the default Apple speech rate; it slows toward normal as the queue drains. Version 10.47 extends this behavior to saved text and removes the manual controls. Audio already rendered keeps its current rate.

1. **During the meeting:** record system audio and, if enabled, the microphone as separate synchronized tracks. Only system audio is transcribed, speaker-labeled and optionally translated/read aloud live. No microphone recognition runs during capture. The Apple live recognizer and streaming speaker model are unchanged. System voices start at Speaker 1; the microphone has a separate named identity (Yvan).
2. **After Stop or Save:** freeze the visible system text, including the provisional tail, and its speaker labels. Save this timestamped snapshot alongside the recording. **Never retranscribe system audio or rerun speaker identification.** Only echo-cleaned microphone audio is transcribed, using the same local **Apple SpeechTranscriber** engine as the live transcript. Residual time-aligned text duplicates are removed from microphone words only. Retained microphone phrases use the configured microphone name and are inserted chronologically between whole sentence/pause blocks, never interleaved word by word. Overlapping phrases are ordered by start time. System wording and known identities are unchanged; the window retains its original live paragraphs. Silent/disabled microphone exports skip recognition entirely.
3. **Export:** go directly to the compact filename box. After a successful TXT save, the transcript clears for the next meeting and the exported recording folders are automatically moved to the Trash, without a speaker-review or audio-retention dialog.

Version 10.44 keeps live read-aloud voice continuity over short (at most three words and 28 characters) system-audio fragments labelled Speaker unknown. Playback borrows the immediately following known voice when available, or the last known voice; a queued speaker change leaves the fragment neutral. The live overlay shows such a fragment under a speaker only when the known labels on both sides agree. The export also joins short, audible unknown fragments between known turns of the same speaker when no rival voice is detected. It preserves every recognized word, known speaker and microphone phrase; the new rule leaves standalone replies and ambiguous passages unknown. On the 2 October JJ EMEA Central Sales Call, a read-only checkpoint replay reduced unknown export paragraphs from 34 to 17. The assembled-export cache revision is 2, so previously prepared TXT text is rebuilt while cached microphone recognition can be reused. The source recording was not modified.

Version 10.45 halves each speed increase above Normal again: Normal 1.0×, Faster 1.0625×, Fast 1.125×, Very fast 1.1875× and Maximum 1.25× the default Apple speech rate. Saved selections keep the same label.

Version 10.44 introduced the previous speed increments. The Export terminology setting and its export-time substitutions have been removed.

Version 10.42 adds a saved Reading speed setting in Preferences → Reading & translation: Normal, Faster, Fast, Very fast, or Maximum. It changes Apple speech synthesis for original and translated speech. A change during playback applies to the next synthesized passage; already rendered audio finishes at its prior speed. The multipliers were reduced in version 10.44.

Version 10.41 additionally removes short residual playback phrases when strong acoustic evidence and ordered, time-aligned text agree, including a differently segmented proper name. It preserves the frozen system transcript and protected independent replies. On the 2 October 2026 Enterprise Architect Community recording, a read-only checkpoint replay reduced microphone words from 654 to 620; six marked genuine-speaking spans remained text-identical. Some short/numeric artifacts remain ambiguous. Speaker-unknown blocks on this recording could not be safely reassigned from the saved voice evidence and remain unknown. Set `MYWIZARD_EXPORT_TIMING=1` before launching the app to log stage and total preparation durations without meeting text. The export checkpoint revision is 3 to invalidate the prior assembled export. The original recording was not modified.

Version 10.40 adds an export-only residual-echo check. It combines the existing cancellation pass's per-second correlation/remaining-energy measurements with nearby time-aligned text matches. Whole-phrase system timestamps retain their uncertainty rather than inventing equal word timings. Different microphone phrases require stronger acoustic evidence than matching words; short replies, numbers and nearby unmatched objections are protected by this additional check. A brief cancellation lapse can be bridged only with exact text agreement, weak acoustic correspondence and stronger echo evidence on both sides. Bounded time windows and indexed word ranges avoid scanning the whole meeting per word. Evidence is saved in the export checkpoint; revision 2 invalidates earlier processing results. No additional recognition/model, capture device processing or changes to live text/speaker labels are introduced.

Validation on copies of the supplied recordings: the 17:27 video-only sample goes from 71 falsely attributed microphone tokens to zero, without changing system words or live paragraphs. The four labelled local interventions in the 16:53 sample remain text-identical. These are bounded regression results, not a guarantee of perfect separation: very quiet overlapping speech remains ambiguous, and protected short/numeric artifacts can still survive (including the older sample's “100 %”). Original recordings are untouched.

The isolated new text-context check measured 0.13 seconds for 12,000 repeated words across a simulated hour on this Mac (not the whole audio export). The 228-second real fixture's full offline export measured about 2.9 seconds with installed/warm models; this is not a universal speed guarantee. `MYWIZARD_PERFORMANCE_CHECK=1 swift test -c release --filter MicrophoneEchoContextTests` reproduces the context benchmark. `MicrophoneReplayTests` optionally accepts `MYWIZARD_MIC_REPLAY`, `MYWIZARD_MIC_EXPECT_SILENT=1` or labelled `MYWIZARD_MIC_REPLAY_EXPECTED_SPANS=start:end,...` to verify saved recordings on disposable copies without touching originals.

Version 10.39 added four stability/presentation changes without changing recognition or microphone filtering:

- Live text, provisional tail, names and speaker evidence are atomically saved in `live-transcript.json` about every five seconds, using a serialized background writer. Stop writes the authoritative final snapshot and rejects late periodic writes. Disk failures are reported once per failure episode and retried; recording continues. A crash can still lose changes since the last successful backup. No recovery button or additional audio retention is introduced.
- `export-checkpoint.json` stores completed echo reduction, microphone recognition and final assembly. Retry can skip finished stages, never an incomplete recognition. Cache validation includes the processing revision, recording ID, language, microphone choice, mute events and source file identity/size/modification/change timestamps. Final assembly also requires the same live snapshot digest; edited text can reuse audio stages. Changed/corrupt/missing cache data is not trusted, and cached echo requires the same cleaned file. Checkpoints remain with the recording and follow its existing post-export Trash cleanup.
- The echo-reduction pass also measures system activity before applying playback mute events, avoiding a separate system audio scan. An exact 20 ms collector handles uneven buffers and a system track longer than the microphone. Silent/disabled microphone sessions retain the standalone activity scan when needed.
- Unknown blocks containing only punctuation attach to the preceding system paragraph. A microphone interruption never receives system punctuation; leading punctuation with no preceding system text remains unchanged. No recognized words are removed or rewritten.

Version 10.37 groups consecutive paragraphs from the same known speaker, without rewriting their words or crossing another participant's turn. Unknown export blocks can acquire a label only from the saved voice intervals: at least 80% coverage with a 150 ms boundary tolerance, a single mapped identity and no competing voice nearby. Ambiguity stays unknown; live display and recognition remain unchanged.

Version 10.38 additionally discounts near-digital system silence when evaluating speaker coverage: word timestamps can include a long trailing or leading pause. This uses a bounded-memory 20 ms audio scan, not another transcription or diarization pass. At least 120 ms (and 10% of the word range) must remain audible, with 80% voice-interval coverage and no rival identity. Missing optional audio evidence leaves labels conservative. Short unknown runs (at most two seconds and six words) may also bridge two matching speaker turns only with saved voice evidence on both sides, pauses no longer than 400 ms and no competing/unmapped voice. Unbounded, conflicting and long gaps stay unknown; inferred bridges cannot propagate into adjacent gaps.

Microphone recognition can compact long near-silent gaps, retaining activity above 0.00005 peak amplitude, one second of context on each side and short intervening pauses. It is enabled only if at least 10 seconds and 30% of audio can be skipped. This deliberately keeps quiet responses and uncertain/noisy passages; it is not a microphone-versus-echo voice classifier. One temporary lossless file uses one recognizer, with results mapped back to the original recording clock. Empty recognition or a word crossing a cut triggers full-track fallback. The temporary file is removed on completion, error or cancellation; originals are untouched. Speed gains depend on actual silence, not merely on how little the microphone owner spoke.

Export preparation shows one global percentage, for example **Preparing transcription export… 42%**: echo reduction (0–20), microphone transcription (20–94), assembly/persistence (95–100). Recognition progress follows Apple's processed audio range. Repeated/late callbacks cannot move the percentage backwards. This is approximate work progress, not an ETA. The UI stays below 100% until transcript and metadata are ready for the filename dialog; 100% does not mean the TXT has been saved.

The microphone is never routed to the speakers. Hardware VoiceProcessingIO is not used by the normal recording workflow. The old acoustic-echo preference is retained for compatibility but does not enable device processing in this mode.

The microphone button beside **MyWizard** toggles MyWizard's own microphone capture, before or during recording. A red microphone is on; a crossed-out microphone is off. This never mutes Zoom or changes the system input device. Turning it off stops the microphone input engine while system recording continues. Turning it on requests microphone permission if necessary and reuses the same track, preserving earlier speech and silence gaps. A session started without the microphone can enable it later. An activation failure leaves system recording running. The choice is remembered; the header button is the only microphone on/off control (there is no duplicate in Preferences). Microphone speech remains export-only.

Your microphone words appear only in the exported text, under your saved name (or Microphone if blank), never a numbered speaker. They never appear in the window or its translation, even after final preparation. Other speaker identities are those of the live model, not guessed real names or new offline clusters. Names can be changed by clicking speaker headings or in Preferences. Unknown or ambiguous speech stays unknown. Speaker numbering remains distinct across retained sessions. The existing microphone-name preference is preserved; renaming Speaker 1 does not change it. Previously exported text files are not rewritten.

**Save (⌘S) during capture stops the session** and prepares the complete export. It no longer saves a partial live snapshot. Cancelling the filename box keeps the prepared text and recordings. A failed or cancelled analysis keeps the live text and original audio; use Prepare export to retry. A new session cannot start while the previous recording still needs processing.

## Temporary recordings

Recordings are local in:

```text
~/Library/Application Support/MyWizard/Recordings/<UUID>.mywizard/
```

Each folder contains a session manifest and separate 16 kHz mono, 16-bit lossless CAF files for system audio, microphone when enabled, and MyWizard playback when used. Stop also saves `live-transcript.json` with live words, blocks, labels and name mappings. Host-clock timing preserves track offsets and pauses. System/playback audio and original-system-mute intervals provide acoustic echo references, not a new system transcript. Legacy recordings without a live snapshot cannot use this new export and report an explicit error without deleting their audio.

Analysis uses these lossless originals directly. Normal TXT preparation no longer creates `meeting.mp4`: that derived AAC file was not used for transcription and was discarded after TXT export. Older MP4 files remain untouched; the standalone encoder is retained for compatibility/testing. No video is recorded. Original tracks, the cleaned microphone derivative and analysis remain available until successful export. Bounded background disk writes report failures instead of silently dropping audio.

After a successful TXT export, only the exact exported session folders are automatically moved to the Trash; the operation is recoverable through Finder. Cleanup failures are reported without affecting the saved TXT. Cancellation, failed saves and Clear do not delete unexported audio. Older recordings are not swept automatically. There is no automatic upload of meeting audio. Ensure participants know a recording is being made.

## Echo handling and accuracy

Delay search evaluates every sample offset rather than a coarse lag grid. Offline startup calibration protects the first words, and adaptive regularization plus an energy guard prevents local speech during reference pauses from destabilizing the filter.

Offline microphone processing uses synchronized system/playback references, bounded-memory adaptive filtering and conservative correlation checks, allowing up to 500 ms of acoustic delay. Strongly echo-only 100 ms windows are silenced before recognition and filtered afterward. Retained microphone speech is assigned to the configured microphone owner; this assumes only that person uses the microphone and is not biometric identification. Very quiet local speech beneath strong echo can still be lost, and difficult echo can remain. No other application's microphone access changes. Headphones provide the best isolation.

**Echo reduction is always active**, including for older installations where it was disabled. A conservative text/timestamp filter compares microphone recognition with frozen live system words, without changing system text. Identical simultaneous speech remains ambiguous. Originals are preserved until successful export. MyWizard playback is an acoustic reference, never intentionally added as a participant.

Version 10.36 compares complete microphone recognition before removing individual acoustic-echo tokens. Sustained, time-aligned echo passages also remove small internal recognition substitutions instead of leaving orphan words attributed to the microphone owner. Matching uses word time ranges, accounts for French elided articles and aligned truncated word endings, and protects unmatched numbers, short replies and negations. Longer independent interventions remain untouched. This remains a heuristic: unusual short overlapping interventions and residual echo can still be ambiguous. No "1, 2, 3" marker or meeting-specific time range is required by the application.

Version 10.37 also filters isolated matching remote words when acoustic echo covers at least half their duration and the same word overlaps in the system transcript. This additional rule excludes yes/no replies, objections and numbers; without both clues the word remains. The existing high-confidence acoustic rule is unchanged. Proper names, numbers and unresolved residual echo are not automatically rewritten or guessed.

Version 10.38 enables an export-only compact echo rule: six time-aligned matching words, at least 28 matching characters, 75% anchor density and at most six seconds. Small article/substitution gaps are tolerated; independent replies, numbers and objections retain their safeguards. Live filtering is unchanged. Recognition confidence is available only as an explicit replay diagnostic (`MYWIZARD_MIC_CONFIDENCE=1`), not as an automatic deletion threshold: low confidence also occurs on genuine microphone speech.

Validated on a disposable copy of the 1 October 16:53 recording: unknown export blocks decreased from 13 to 3; the seven-word video duplicate disappeared from the microphone track; the previously recognized text of all four marked local interventions was preserved exactly. System words and live display remained unchanged. The isolated microphone artifacts “Mal” and “100%” remain unresolved, and the already-degraded English system passage is not rewritten. This test demonstrates the bounded improvement, not perfect speaker attribution or verbatim audio accuracy. Original microphone/system file hashes were unchanged.

For read-only audio replay, set `MYWIZARD_MIC_REPLAY` to a saved `.mywizard` folder and `MYWIZARD_MIC_REPLAY_OUTPUT` to a diagnostics destination, then run `swift test -c release --filter MicrophoneReplayTests`. It works on a disposable copy, saves comparison files in a unique output subfolder, and checks that the live system transcript is unchanged. Optional `MYWIZARD_MIC_REPLAY_EXPECTED_SPANS` (comma-separated `start:end` seconds) verifies that human-labelled microphone interventions retain all their previously recognized text. These spans are test assertions, not inputs to the filtering algorithm.

Speaker identification is always active, regardless of old preferences. FluidAudio 0.15.7's streaming Sortformer labels live system audio; normal export preserves those labels without offline VBx processing. Identification is approximate, especially with overlap, very short turns and similar voices. First use may download/compile models from Hugging Face. Speech and translation models may also be downloaded from Apple; subsequent processing runs locally. No voice-name database or automatic real-person identification is used. Speaker renaming remains available.

## Display, translation and read-aloud

A compact **hh:mm:ss** elapsed-recording counter appears immediately to the right of the microphone button while recording. It uses the current session's start, continues when only the microphone is switched off, resets for each new recording and disappears after Stop. Its one-second timeline refreshes only the label, not the transcript. Hours do not wrap after 24 hours.

The header controls source speech language. Preferences separately controls **Display in** and **Read in**: 38 local translation variants plus Original language. These always use system speech only, including after processing. Text exports include microphone speech in the source language with names and automatic residual-duplicate filtering.

Display translation retains complete translated snapshots while recognition changes. Stable chunks are reused; obsolete provisional translations are evicted. New revisions are coalesced for 450 ms, without extra pauses between batches of one snapshot. Unicode-safe text chunking is linear.

Reading starts at the current passage, follows new system phrases and does not read speaker headings or microphone text. While reading during capture, original system audio is muted but remains captured; MyWizard playback is excluded from the system tap and recorded separately as a reference. Stop reading restores sound; Stop capture also stops reading. No system volume or default-device setting is changed. Capture-format changes interrupt the session with a visible reason and a contextual Retry audio action.

Click speaker headings to rename them, or change names in Preferences. Appearance settings, source/translation languages and export directory persist. Text size and transparency remain adjustable; scrolling manually pauses auto-follow, which resumes when you scroll back to the bottom. The floating Latest button returns to live following.

## Text export

The folder button at the top right opens the TXT export destination in Finder, including during recording. It uses the configured folder, or the last export folder/Documents when no default is configured. An unavailable configured folder is reported instead of silently opening another destination.

Preferences → Text exports selects the persistent TXT destination. The filename box uses the recording's start date and time (not Stop or export time), with an English month/local 24-hour name such as **Meeting Notes on 30 September 2026 23h24.txt**. If the document contains several sessions, the earliest start is used. Re-exporting retains that date after audio cleanup; Clear resets it for the next document. Existing regular TXT filenames in that directory complete as you type. The extension is added when missing. Existing files require explicit Replace confirmation; symbolic links, folders and path traversal are rejected.

TXT is UTF-8, retains session order and speaker names, and is written before automatic audio cleanup. A failed save never triggers audio deletion. Changing display translation never replaces the source-language export.

## Verification

Live transcript performance: finalized display paragraphs are cached, with affected suffixes rebuilt after speaker corrections. Export text is assembled on demand. Recognition and read-aloud stay immediate while live visual updates are coalesced over 80 ms. The transcript renders rows lazily; search still indexes the complete displayed transcript and realizes offscreen rows before scrolling to the exact occurrence. Periodic backups assemble snapshots on the writer actor and skip unchanged document/metadata revisions; final Stop snapshots remain authoritative.

Tests and opt-in app diagnostics use isolated in-memory preferences. They do not create UUID-named `MyWizard.*` or `MyWizardTests.*` preference files in `~/Library/Preferences`. Normal app preferences still use `UserDefaults.standard` and remain saved between launches. Existing files from earlier test runs are not removed automatically.

`swift test -c release` covers source separation, timestamps, speaker alignment, reading, translation, naming, exports, raw-track preservation, echo reduction, recovery, monotonic global progress under concurrent callbacks, cancellation and the standalone MP4 encoder.

`MYWIZARD_RECORDED_FIXTURES=/path/to/fixtures swift test -c release --filter RecordedMeetingTests` additionally analyzes synthetic `speaker-one.aiff` and `speaker-two.aiff` files, including remote-only speech with delayed/reverberant microphone echo and real local speech mixed with that echo. It checks whole-pipeline percentages, silent exports with/without microphone, failure of one parallel track, retained originals and the absence of an unused MP4. Add `MYWIZARD_RECORDED_SPEAKERS=1` to exercise offline speaker identification (model download on first use). These tests use temporary recordings and delete only their own test folders. Array tests cover 400 ms delays, filter convergence, weak independent speech and short interruptions. These checks do not substitute for an actual room/Zoom recording.

Run the signed app with `MYWIZARD_PIPELINE_CHECK=1` and `MYWIZARD_PIPELINE_FIXTURE=/path/to/synthetic-english.aiff` (containing “project” and “Friday”) for an opt-in hardware check. It verifies that microphone text is absent live and that export preserves the exact live system text/labels with microphone off/on. Diagnostic preferences and recording directories are isolated. Keep other playback stopped. Logs contain counts/timings, not microphone text. A ten-minute diagnostic deadline covers first-use models; it does not constrain normal meeting length.

`MYWIZARD_PERFORMANCE_CHECK=1 swift test -c release --filter TranscriptionPerformanceTests` measures long-meeting text work, not end-to-end model accuracy.

`MYWIZARD_MEETING_CONTROLS_CHECK=1 .build/MyWizard.app/Contents/MacOS/MyWizard` checks output-change recovery with real speech/speaker engines and simulated audio taps. A retry on healthy capture must have no effect. It verifies that paused capture accepts no samples, a failed resume stays paused, retry retains the same recording folder, and snapshots survive Stop. It opens no audio devices and uses isolated preferences and temporary files. Unit tests also cover paused timeline mapping, CAF silence gaps, accent/Unicode search and recovery leases. An actual AirPods/output switch remains a separate hardware validation.

`MYWIZARD_TAP_CHECK=1 .build/MyWizard.app/Contents/MacOS/MyWizard` verifies system PCM capture through mute/unmute and exclusion of MyWizard output. Legacy echo/device diagnostics are opt-in compatibility investigations, not the normal capture path.

Sources: [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) and [FluidAudio documentation](https://github.com/FluidInference/FluidAudio/tree/v0.15.7/Documentation).

## Microphone export and legacy comparison

Normal export uses Apple SpeechTranscriber for non-silent microphone audio and does not require Whisper. On the synthetic remote-only echo regression, Whisper produced a residual word while Apple returned no microphone speech and retained the independent local intervention. This is a bounded fixture result, not proof of perfect echo rejection in every room. All retained microphone words use `ownSpeakerName`; no energy-based cluster attribution is involved. `MYWIZARD_RECORDED_FIXTURES=/path/to/fixtures swift test -c release --filter LiveTranscriptExportTests` runs an isolated real-engine microphone check using `speaker-two.aiff` (containing “budget”) alongside deterministic snapshot, merge, failure and silence tests. It does not open capture devices. `recordedRemoteVoiceEchoDoesNotBecomeLocalSpeaker` additionally checks delayed/reverberant remote echo with and without simultaneous local speech.

The following command is an explicitly **legacy mixed-audio comparison**, not the normal export. It cannot reconstruct live text or remote names from an imported MP4. Set `MYWIZARD_WHISPER_COMPARE_APPLE=1` to add the older Apple offline baseline. These diagnostic engines remain available only for comparisons.

```zsh
MYWIZARD_WHISPER_PREVIEW_AUDIO="/absolute/path/meeting.mp4" \
MYWIZARD_WHISPER_PREVIEW_OUTPUT="/absolute/path/comparisons" \
MYWIZARD_WHISPER_PREVIEW_LANGUAGE=en-US \
MYWIZARD_WHISPER_PREVIEW_LAYOUT=system-microphone \
.build/MyWizard.app/Contents/MacOS/MyWizard
```

Use `system-microphone` only for a known two-track MyWizard MP4 (system first, microphone second). Single-track audio needs no layout argument. Unspecified multitrack input is rejected instead of silently dropping a track. A `.mywizard` folder can also be supplied. Audio preparation, echo reduction and analysis operate on private temporary copies, never the input. Both tracks retain their timeline. No devices are opened and no running app is stopped. Results go into a unique folder with comparison text/alignment files. The setup microphone name is read without changing preferences. No files are overwritten or uploaded.

The legacy comparison requires MyAssistant's installed `~/whisper.cpp/build/bin/whisper-cli` and `ggml-large-v3-turbo.bin`. It retains approximate offline alignment and source-energy labeling for investigation, but normal export never uses them. Simultaneous microphone speech, echo and fixed ten-minute Whisper chunk boundaries remain limitations of that comparison. Child-process stderr is drained continuously; cancellation terminates the child and removes only that invocation's temporary derivatives. The comparison's historical `05-Production-export.txt` filename refers to the former mixed pipeline, not the current live-text export.


### Apple Calendar meeting context

Use the calendar button to choose a timed event from any calendar synced with Apple Calendar. Access is requested only when opening the picker. MyWizard reads events locally through EventKit and never changes them. If access is denied, enable MyWizard in System Settings → Privacy & Security → Calendars and choose Refresh. Recording works without this permission.

The selected meeting title appears above the transcript, in the TXT heading and as the suggested export filename. Clicking a speaker to rename it offers the invited people (including the organizer) as suggestions; calendar invitations do not establish attendance or identify voices. Names absent from the synced event cannot be retrieved. Selection is explicit, including when meetings overlap. Choose another date or Refresh to reload events; all-day events are excluded. Clear removes the selection. The selected title and suggestions are stored with local transcript snapshots and restored on recording recovery. No Microsoft Graph connection is needed.

## Source repository

Private repository: [MyWizard](https://github.com/yvancognasse/MyWizard). This local folder remains the development/build checkout. Git history starts with the current imported source snapshot; earlier local builds are not reconstructed as historical commits.

After authorized changes, run the project checks and update documentation as required in `AGENTS.md`, then commit and push to `origin/main`. Changes reach GitHub when a push succeeds, not automatically on every file save. Generated applications, caches, logs and local secrets are excluded by `.gitignore`.

```sh
git pull --ff-only
# Make and verify the change
git add .
git commit -m "Describe the change"
git push origin main
```
