import XCTest
@testable import JAASNotes

/// Autosave timing, checked through the recorded sleep schedule. Nothing waits on real time.
@MainActor
final class AutosaveScheduleTests: XCTestCase {
    func testAnEditSchedulesAutosaveAfterTheQuietPeriod() async throws {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let fixture = try await SaveFixture.makeFixture(in: self, clock: { clock.now }, sleep: { try await recorder.sleep($0) })

        fixture.model.updateDraft(for: fixture.noteID, body: "x")
        await recorder.waitForCalls(1)

        let delays = await recorder.delays
        XCTAssertEqual(delays, [.milliseconds(500)])
        let saved = await fixture.model.flushPendingDrafts()
        XCTAssertTrue(saved)
        XCTAssertFalse(fixture.model.isDirty(fixture.noteID))
    }

    func testContinuousTypingIsSavedAtLeastEveryTwoSeconds() async throws {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let fixture = try await SaveFixture.makeFixture(in: self, clock: { clock.now }, sleep: { try await recorder.sleep($0) })

        fixture.model.updateDraft(for: fixture.noteID, body: "a")
        clock.now.addTimeInterval(1)
        fixture.model.updateDraft(for: fixture.noteID, body: "ab")
        clock.now.addTimeInterval(1.5)
        fixture.model.updateDraft(for: fixture.noteID, body: "abc")
        await recorder.waitForCalls(3)

        // Two and a half seconds have passed since the first unsaved edit, so the third edit saves immediately.
        let delays = await recorder.delays
        XCTAssertEqual(delays, [.milliseconds(500), .milliseconds(500), .zero])
    }
}
