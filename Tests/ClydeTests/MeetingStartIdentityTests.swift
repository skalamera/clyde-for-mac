import Foundation
import Testing
@testable import Clyde

/// Meeting identity across start attempts. Starts are driven through the real AppModel flow with
/// the microphone-permission step stubbed, so no permission prompt, audio, or network is used.
/// The stub records what the meeting context looked like at the moment permissions were asked.
@MainActor
@Suite(.serialized) struct MeetingStartIdentityTests {
    static func event(_ id: String, _ title: String, startOffset: TimeInterval, recurring: String? = nil) -> CalendarEvent {
        let start = Date().addingTimeInterval(startOffset)
        return CalendarEvent(
            id: id, iCalUID: "\(id)@test", title: title, start: start, end: start.addingTimeInterval(3600),
            allDay: false, organizer: nil,
            attendees: [CalendarAttendee(email: "person@\(id).example", displayName: "Person \(id)", responseStatus: nil, isSelf: false)],
            recurringEventId: recurring, description: nil
        )
    }

    // MARK: CRIT-41

    @Test func failedStartDoesNotLeaveItsEventForTheNextManualStart() async {
        let model = AppModel()
        let eventA = Self.event("routing-check-event-a", "Customer A Onboarding", startOffset: -5 * 3600)
        let eventB = Self.event("routing-check-event-b", "Customer B Kickoff", startOffset: -60)
        model.seedForTesting(notes: [], calendarEvents: [eventB])

        let seen = Recorded()
        model.requestMicrophoneAccess = { [unowned model] in
            seen.values.append(model.meetingContext.calendarEventContext)
            return false                          // e.g. a TCC grant that didn't persist
        }

        // 1. Start from event A fails before the meeting becomes active.
        model.pendingMeetingStart = .fromCalendar(eventA)
        await model.confirmPendingMeetingStart(userContext: "")
        #expect(model.isMeetingActive == false)

        // 2. Hours later, a manual start while B is happening.
        model.pendingMeetingStart = .manual
        await model.confirmPendingMeetingStart(userContext: "")

        #expect(seen.values.count == 2)
        let manualStartContext = seen.values.last ?? ""
        #expect(!manualStartContext.contains("Customer A Onboarding"), "the failed start's event leaked into the next meeting")
        #expect(manualStartContext.contains("Customer B Kickoff"), "the manual start should match the event happening now")
    }

    @Test func failedStartClearsTheEventContextItSet() async {
        let model = AppModel()
        let eventA = Self.event("routing-check-event-a", "Customer A Onboarding", startOffset: -5 * 3600)
        model.seedForTesting(notes: [], calendarEvents: [])
        model.requestMicrophoneAccess = { false }

        model.pendingMeetingStart = .fromCalendar(eventA)
        await model.confirmPendingMeetingStart(userContext: "")

        // Chat is usable outside meetings and reads this context.
        #expect(model.meetingContext.calendarEventContext.isEmpty)
        #expect(model.meetingContext.priorMeetingContext.isEmpty)
    }
}

@MainActor
final class Recorded {
    var values: [String] = []
}
