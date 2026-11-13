import EventKit
import Combine
import SwiftUI

struct CalendarMeeting: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
    let invitees: [String]

    /// Presentation only: keep the calendar title unchanged for TXT exports and filenames.
    var contextLabel: String {
        let startLabel = start.formatted(date: .abbreviated, time: .shortened)
        let endLabel = end.formatted(
            date: Calendar.current.isDate(start, inSameDayAs: end) ? .omitted : .abbreviated,
            time: .shortened)
        return "Meeting: \(title) · \(startLabel) – \(endLabel)"
    }

    static func names(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let name = VoiceMemory.displayName(value)
            return !name.isEmpty && seen.insert(VoiceMemory.nameKey(name)).inserted ? name : nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Starts within five minutes take precedence over an earlier ongoing event.
    // Otherwise prefer the most recently started active event, then a just-ended
    // event. Equal best candidates require an explicit choice.
    static func current(in meetings: [CalendarMeeting], at now: Date, tolerance: TimeInterval = 300) -> CalendarMeeting? {
        let valid = meetings.filter { $0.start < $0.end }
        let starting = valid.filter { abs($0.start.timeIntervalSince(now)) <= tolerance && $0.end > now }
        if !starting.isEmpty { return uniqueClosest(starting, distance: { abs($0.start.timeIntervalSince(now)) }) }
        let active = valid.filter { $0.start <= now && now < $0.end }
        if !active.isEmpty { return uniqueClosest(active, distance: { now.timeIntervalSince($0.start) }) }
        let ended = valid.filter { $0.end <= now && now.timeIntervalSince($0.end) <= tolerance }
        return uniqueClosest(ended, distance: { now.timeIntervalSince($0.end) })
    }

    private static func uniqueClosest(_ meetings: [CalendarMeeting], distance: (CalendarMeeting) -> TimeInterval) -> CalendarMeeting? {
        let ranked = meetings.sorted { distance($0) < distance($1) }
        guard let first = ranked.first,
              ranked.count == 1 || abs(distance(first) - distance(ranked[1])) > 1 else { return nil }
        return first
    }

}

@MainActor
final class CalendarMeetings: ObservableObject {
    @Published private(set) var meetings: [CalendarMeeting] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let store = EKEventStore()

    func load(day: Date) async {
        guard !isLoading else { return }
        isLoading = true
        meetings = []
        error = nil
        defer { isLoading = false }
        do {
            let start = Calendar.current.startOfDay(for: day)
            guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
            meetings = try await read(from: start, to: end)

        } catch {
            self.error = "Cannot read Apple Calendar: \(error.localizedDescription)"
        }
    }

    func currentCandidates(at now: Date) async -> CalendarLookupResult {
        do {
            let meetings = try await read(from: now.addingTimeInterval(-300), to: now.addingTimeInterval(300))
            return CalendarLookupResult(meetings: meetings)
        } catch {
            return CalendarLookupResult(meetings: [], message: error.localizedDescription)
        }
    }

    private func read(from start: Date, to end: Date) async throws -> [CalendarMeeting] {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try await store.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw TranscriptionError.message("Calendar access is unavailable. Choose Calendar and allow access in System Settings → Privacy & Security → Calendars → MyWizard. Recording continues without a calendar event.")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }.map { event in
            let people = (event.attendees ?? []) + (event.organizer.map { [$0] } ?? [])
            return CalendarMeeting(id: "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)",
                title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled meeting",
                start: event.startDate, end: event.endDate, calendar: event.calendar.title,
                invitees: CalendarMeeting.names(people.compactMap { person in
                    person.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? (person.url.scheme?.lowercased() == "mailto"
                            ? String(person.url.absoluteString.dropFirst(7)).removingPercentEncoding : nil)
                }))
        }.sorted { $0.start < $1.start }
    }

}

struct CalendarLookupResult: Sendable {
    var meetings: [CalendarMeeting]
    var message: String? = nil
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct CalendarMeetingPicker: View {
    @ObservedObject var model: TranscriptionModel
    @StateObject private var calendar = CalendarMeetings()
    @State private var day = Date()
    @State private var refreshID = UUID()
    @Environment(\.dismiss) private var dismiss

    private let eventColors: [Color] = [.blue, .teal, .purple, .orange, .pink, .indigo]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a calendar meeting").font(.headline)
            HStack {
                DatePicker("Date", selection: $day, displayedComponents: .date)
                    .disabled(calendar.isLoading)
                Button("Refresh") { refreshID = UUID() }.disabled(calendar.isLoading)
            }
            Text("Start automatically looks for a meeting within five minutes. Choose an event here to override it, or Remove meeting to record without one. Invited names are suggestions; known voices can identify matching participants.")
                .font(.caption).foregroundStyle(.secondary)
            if calendar.isLoading { ProgressView("Reading calendars…") }
            if let error = calendar.error {
                Text(error).foregroundStyle(.red).font(.callout)
            } else if !calendar.isLoading && calendar.meetings.isEmpty {
                Text("No timed events on this date. Check that your work calendar is visible in Apple Calendar.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(calendar.meetings.enumerated()), id: \.element.id) { index, meeting in
                        let color = eventColors[index % eventColors.count]
                        Button {
                            model.calendarMeeting = meeting
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.title).font(.headline)
                                Text("\(meeting.start.formatted(date: .omitted, time: .shortened)) – \(meeting.end.formatted(date: .omitted, time: .shortened)) · \(meeting.calendar)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(meeting.invitees.isEmpty ? "No invitee names available" : meeting.invitees.joined(separator: ", "))
                                    .font(.caption).lineLimit(2)
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .padding(.leading, 6)
                            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
                            }
                            .overlay(alignment: .leading) {
                                Capsule().fill(color).frame(width: 4).padding(.vertical, 10).padding(.leading, 7)
                                    .accessibilityHidden(true)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                if model.calendarMeeting != nil {
                    Button("Remove meeting") { model.calendarMeeting = nil; dismiss() }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 520, height: 440)
        .task(id: "\(Calendar.current.startOfDay(for: day))|\(refreshID)") { await calendar.load(day: day) }
    }
}
