import AppKit
import XCTest
@testable import SnapTra_Translator

final class SelectedTextReplacementCoordinatorTests: XCTestCase {
    @MainActor
    func testHeldShortcutWaitsUntilEveryRelevantModifierIsReleased() async {
        var modifiers: NSEvent.ModifierFlags = [.option]
        var submittedTexts: [String] = []
        var completionCount = 0
        let request = makeRequest()
        let coordinator = makeCoordinator(
            request: request,
            currentModifiers: { modifiers },
            perform: { request, didDispatch in
                submittedTexts.append(request.translatedText)
                didDispatch()
                return .verified
            },
            onCompletion: { _, _ in completionCount += 1 }
        )

        XCTAssertTrue(coordinator.submit(request))
        XCTAssertEqual(coordinator.operation?.phase, .waitingForModifiers)
        XCTAssertTrue(submittedTexts.isEmpty)

        modifiers = [.shift]
        coordinator.modifiersDidChange()
        XCTAssertTrue(submittedTexts.isEmpty)

        modifiers = []
        coordinator.modifiersDidChange()
        await waitUntil { coordinator.operation == nil }

        XCTAssertEqual(submittedTexts, ["你好"])
        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testPersistentOverlayStartsImmediatelyAndConsumesGestureOnce() async {
        var consumeCount = 0
        var submittedTexts: [String] = []
        let request = makeRequest()
        let coordinator = makeCoordinator(
            request: request,
            consume: { consumeCount += 1 },
            perform: { request, didDispatch in
                submittedTexts.append(request.translatedText)
                didDispatch()
                return .verified
            }
        )

        XCTAssertTrue(coordinator.submit(request))
        XCTAssertFalse(coordinator.submit(request))
        await waitUntil { coordinator.operation == nil }

        XCTAssertEqual(consumeCount, 1)
        XCTAssertEqual(submittedTexts, ["你好"])
    }

    @MainActor
    func testCancellationWhileWaitingPreventsLaterReplacement() {
        var modifiers: NSEvent.ModifierFlags = [.option]
        var submissionCount = 0
        let request = makeRequest()
        let coordinator = makeCoordinator(
            request: request,
            currentModifiers: { modifiers },
            perform: { _, _ in
                submissionCount += 1
                return .verified
            }
        )

        XCTAssertTrue(coordinator.submit(request))
        coordinator.cancel()
        modifiers = []
        coordinator.modifiersDidChange()

        XCTAssertNil(coordinator.operation)
        XCTAssertEqual(submissionCount, 0)
    }

    @MainActor
    func testRequestThatStoppedMatchingDoesNotStart() async {
        var modifiers: NSEvent.ModifierFlags = [.option]
        var isCurrent = true
        var submissionCount = 0
        let request = makeRequest()
        let coordinator = makeCoordinator(
            request: request,
            currentModifiers: { modifiers },
            isCurrent: { _ in isCurrent },
            perform: { _, _ in
                submissionCount += 1
                return .verified
            }
        )

        XCTAssertTrue(coordinator.submit(request))
        isCurrent = false
        modifiers = []
        coordinator.modifiersDidChange()
        await waitUntil { coordinator.operation == nil }

        XCTAssertNil(coordinator.operation)
        XCTAssertEqual(submissionCount, 0)
    }

    @MainActor
    func testDispatchIsReportedBeforeReplacementCompletes() async {
        var dispatchCount = 0
        var completionCount = 0
        let request = makeRequest()
        let coordinator = makeCoordinator(
            request: request,
            perform: { _, didDispatch in
                didDispatch()
                try await Task.sleep(nanoseconds: 20_000_000)
                return .pasteDispatched
            },
            onPasteDispatched: { _ in dispatchCount += 1 },
            onCompletion: { _, _ in completionCount += 1 }
        )

        XCTAssertTrue(coordinator.submit(request))
        XCTAssertEqual(coordinator.operation?.phase, .replacing)
        await waitUntil { coordinator.operation?.phase == .pasteDispatched }
        XCTAssertEqual(dispatchCount, 1)
        XCTAssertEqual(completionCount, 0)

        await waitUntil { coordinator.operation == nil }
        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testCancellationAfterDispatchDoesNotRetryOrReportCompletion() async {
        var dispatchCount = 0
        var completionCount = 0
        var discardedCount = 0
        var performCount = 0
        let request = makeRequest()
        let coordinator = SelectedTextReplacementCoordinator(
            currentModifiers: { [] },
            consumeCurrentGesture: {},
            consumeCurrentRelease: {},
            isRequestCurrent: { _ in true },
            performReplacement: { _, didDispatch in
                performCount += 1
                didDispatch()
                try await Task.sleep(nanoseconds: 30_000_000)
                return .pasteDispatched
            },
            onPasteDispatched: { _ in dispatchCount += 1 },
            onCompletion: { _, _ in completionCount += 1 },
            onDiscardedCompletion: { _ in discardedCount += 1 }
        )

        XCTAssertTrue(coordinator.submit(request))
        await waitUntil { coordinator.operation?.phase == .pasteDispatched }
        coordinator.cancel()
        await waitUntil { discardedCount == 1 }

        XCTAssertEqual(performCount, 1)
        XCTAssertEqual(dispatchCount, 1)
        XCTAssertEqual(completionCount, 0)
        XCTAssertNil(coordinator.operation)
    }

    @MainActor
    func testModifiersAreReadAgainWhenQueuedNotificationArrives() {
        var modifiers: NSEvent.ModifierFlags = [.option]
        var submissionCount = 0
        let request = makeRequest()
        let coordinator = makeCoordinator(
            request: request,
            currentModifiers: { modifiers },
            perform: { _, _ in
                submissionCount += 1
                return .verified
            }
        )

        XCTAssertTrue(coordinator.submit(request))
        modifiers = [.command]
        coordinator.modifiersDidChange()

        XCTAssertEqual(coordinator.operation?.phase, .waitingForModifiers)
        XCTAssertEqual(submissionCount, 0)
    }

    @MainActor
    private func makeCoordinator(
        request: SelectedTextReplacementRequest,
        currentModifiers: @escaping @MainActor () -> NSEvent.ModifierFlags = { [] },
        consume: @escaping @MainActor () -> Void = {},
        isCurrent: @escaping @MainActor (SelectedTextReplacementRequest) -> Bool = { _ in true },
        perform: @escaping @MainActor (
            SelectedTextReplacementRequest,
            @escaping @MainActor () -> Void
        ) async throws -> SelectedTextReplacementOutcome,
        onPasteDispatched: @escaping @MainActor (SelectedTextReplacementRequest) -> Void = { _ in },
        onCompletion: @escaping @MainActor (
            SelectedTextReplacementRequest,
            Result<SelectedTextReplacementOutcome, Error>
        ) -> Void = { _, _ in }
    ) -> SelectedTextReplacementCoordinator {
        SelectedTextReplacementCoordinator(
            currentModifiers: currentModifiers,
            consumeCurrentGesture: consume,
            consumeCurrentRelease: {},
            isRequestCurrent: { isCurrent($0) && $0 == request },
            performReplacement: perform,
            onPasteDispatched: onPasteDispatched,
            onCompletion: onCompletion,
            onDiscardedCompletion: { _ in }
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    private func makeRequest() -> SelectedTextReplacementRequest {
        SelectedTextReplacementRequest(
            operationID: UUID(),
            session: SelectedTextReplacementSession(
                id: UUID(),
                contextID: UUID(),
                sourceProcessIdentifier: 42,
                sourceApplicationName: "Fixture",
                rawText: "Hello"
            ),
            lookupID: UUID(),
            sourceType: .native,
            translatedText: "你好"
        )
    }
}
