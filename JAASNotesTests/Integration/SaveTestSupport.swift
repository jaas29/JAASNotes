import Foundation
import XCTest
@testable import JAASNotes

/// Wraps a real store and injects write failures or pauses `updateNote` at a controllable point.
/// Lets save tests run in a fixed order without timing-based sleeps.
actor FaultyNoteStore: NoteStore {
    private let base: NoteStore
    private var failuresRemaining = 0
    private var shouldPauseNextUpdate = false
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: NoteStore) {
        self.base = base
    }

    func failNextUpdates(_ count: Int) {
        failuresRemaining = count
    }

    /// The next `updateNote` stops before writing and waits for `resumeUpdate()`.
    func pauseNextUpdate() {
        shouldPauseNextUpdate = true
    }

    /// Returns once an update has reached its pause point.
    func waitUntilUpdateIsPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resumeUpdate() {
        // Clear the paused state here, not after the parked call wakes, so a caller that checks right away
        // sees the store as no longer paused.
        isPaused = false
        let waiters = resumeWaiters
        resumeWaiters = []
        waiters.forEach { $0.resume() }
    }

    func updateNote(id: UUID, expectedRevision: Int64, title: String, bodyPlainText: String) async throws -> NoteSnapshot {
        if shouldPauseNextUpdate {
            shouldPauseNextUpdate = false
            isPaused = true
            let waiters = pauseWaiters
            pauseWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw LibraryError.saveFailed("Injected write failure.")
        }
        return try await base.updateNote(id: id, expectedRevision: expectedRevision, title: title, bodyPlainText: bodyPlainText)
    }

    func initializeLibraryIfNeeded() async throws -> LibraryMetadataSnapshot {
        try await base.initializeLibraryIfNeeded()
    }

    func folders() async throws -> [FolderSnapshot] {
        try await base.folders()
    }

    func activeNotes(inFolder folderID: UUID?) async throws -> [NoteSnapshot] {
        try await base.activeNotes(inFolder: folderID)
    }

    func createNote(inFolder folderID: UUID, title: String, bodyPlainText: String) async throws -> NoteSnapshot {
        try await base.createNote(inFolder: folderID, title: title, bodyPlainText: bodyPlainText)
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    /// Read and written only from the main actor in these tests.
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }
}

/// Records autosave delays and holds each one, so the test can check the schedule without waiting.
actor SleepRecorder {
    private(set) var delays: [Duration] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async throws {
        delays.append(duration)
        let ready = countWaiters.filter { $0.count <= delays.count }
        countWaiters.removeAll { $0.count <= delays.count }
        ready.forEach { $0.continuation.resume() }
        // Hold until the test finishes. Cancellation from a newer edit ends the sleep.
        try await Task.sleep(for: .seconds(3600))
    }

    func waitForCalls(_ count: Int) async {
        if delays.count >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }
}

/// Shared setup for save tests: a temporary library, a fault-injecting store, and one note selected for editing.
@MainActor
enum SaveFixture {
    /// Holds an autosave for the life of a test, so only explicit flushes save.
    static let holdSleep: LibraryModel.Sleeper = { _ in try await Task.sleep(for: .seconds(3600)) }

    struct Fixture {
        let model: LibraryModel
        let faulty: FaultyNoteStore
        let base: LibraryRepository
        let noteID: UUID
    }

    /// A fresh library directory per test, removed when the test ends.
    static func makeLocation(in testCase: XCTestCase) -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        testCase.addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        return LibraryLocation(rootURL: root)
    }

    static func makeFixture(
        in testCase: XCTestCase,
        clock: @escaping LibraryModel.Clock = { Date() },
        sleep: @escaping LibraryModel.Sleeper = holdSleep
    ) async throws -> Fixture {
        let location = makeLocation(in: testCase)
        let container = try await CoreDataStack.openContainer(at: location)
        let base = LibraryRepository(container: container)
        let faulty = FaultyNoteStore(base: base)
        let model = LibraryModel(clock: clock, sleep: sleep)
        await model.load(store: faulty)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        return Fixture(model: model, faulty: faulty, base: base, noteID: noteID)
    }
}
