import XCTest
@testable import SnapTra_Translator

final class SelectedTextReplacementTests: XCTestCase {
    @MainActor
    func testStaleScreenConfigurationIsRejectedBeforeAnyAXRead() async throws {
        let current = try XCTUnwrap(SelectedTextScreenConfiguration.capture())
        let primary = current.primaryDisplay
        let stale = SelectedTextScreenConfiguration(
            primaryDisplay: .init(id: primary.id, frame: primary.frame.offsetBy(dx: 0, dy: 1), scale: primary.scale),
            otherDisplays: current.otherDisplays
        )
        var messages: [String] = []
        let service = SelectedTextService(
            diagnostics: SelectedTextDiagnostics(isEnabled: true, sink: { messages.append($0) }),
            replacementEnabled: true
        )
        let snapshot = await service.currentSelectionSnapshot(request: SelectedTextProbeRequest(
            mouseLocation: .zero,
            frontmostApplicationProcessIdentifier: 42,
            sourceAppIdentifier: "test.app",
            screenConfiguration: stale
        ))

        XCTAssertNil(snapshot)
        XCTAssertTrue(messages.isEmpty, "stale configuration must be rejected before AX starts")
    }

    func testRelatedSelectionCandidatesDoNotDependOnMousePositionOrGeometry() {
        for relationship in [
            SelectedTextReplacementPolicy.CandidateRelationship.sameElement,
            .insideFocusedElement,
            .containsFocusedElement,
        ] {
            XCTAssertTrue(SelectedTextReplacementPolicy.canBindCandidate(relationship: relationship))
        }
        XCTAssertFalse(SelectedTextReplacementPolicy.canBindCandidate(relationship: .unrelated))
    }

    func testMarkerSelectionPreservesRawTextForFocusedEditorCapture() {
        let rawText = "  👩🏽‍💻hello\n"
        let contextID = UUID()
        var capturedText: String?
        var capturedRange: NSRange?
        let candidate = SelectedTextProbeCandidate(
            context: "contenteditable text child",
            debugSummary: { "test" },
            commitSelectionContext: { range, text, _ in
                capturedRange = range
                capturedText = text
                return contextID
            },
            selectedText: { nil },
            selectedRange: { nil },
            selectedTextMarkerRange: {
                SelectedTextProbeMarkerRange(
                    string: { rawText },
                    attributedString: { nil },
                    bounds: { CGRect(x: 10, y: 20, width: 120, height: 20) }
                )
            }
        )

        let snapshot = SelectedTextProbePolicy.snapshot(
            candidates: AnySequence([candidate]),
            sourceAppIdentifier: "test.app",
            sourceProcessIdentifier: 42,
            normalizeBounds: { $0 },
            diagnostics: SelectedTextDiagnostics(isEnabled: false)
        )

        XCTAssertEqual(snapshot?.text, "👩🏽‍💻hello")
        XCTAssertEqual(snapshot?.rawText, rawText)
        XCTAssertEqual(capturedText, rawText)
        XCTAssertEqual(capturedRange?.location, NSNotFound)
        XCTAssertEqual(snapshot?.replacementContextID, contextID)
    }

    func testSnapshotPassesExactRawTextAndRangeToReplacementContextCapture() {
        var commitCount = 0
        var committedRange: NSRange?
        var committedText: String?
        let candidate = SelectedTextProbeCandidate(
            context: "hovered editable field",
            debugSummary: { "test" },
            commitSelectionContext: { range, text, _ in
                commitCount += 1
                committedRange = range
                committedText = text
                return UUID()
            },
            selectedText: { " cat " },
            selectedRange: {
                SelectedTextProbeRange(
                    range: NSRange(location: 2, length: 5),
                    string: { " cat " },
                    bounds: { CGRect(x: 10, y: 20, width: 40, height: 12) }
                )
            },
            selectedTextMarkerRange: { nil }
        )

        let snapshot = SelectedTextProbePolicy.snapshot(
            candidates: AnySequence([candidate]),
            sourceAppIdentifier: "test.app",
            sourceProcessIdentifier: 42,
            normalizeBounds: { $0 },
            diagnostics: SelectedTextDiagnostics(isEnabled: false)
        )

        XCTAssertEqual(snapshot?.rawText, " cat ")
        XCTAssertNotNil(snapshot?.replacementContextID)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(committedRange, NSRange(location: 2, length: 5))
        XCTAssertEqual(committedText, " cat ")
    }

    func testSnapshotDoesNotCaptureReplacementContextWhenChannelDisablesIt() {
        var commitCount = 0
        let candidate = SelectedTextProbeCandidate(
            context: "hovered editable field",
            debugSummary: { "test" },
            commitSelectionContext: { _, _, _ in
                commitCount += 1
                return UUID()
            },
            selectedText: { "cat" },
            selectedRange: {
                SelectedTextProbeRange(
                    range: NSRange(location: 0, length: 3),
                    string: { "cat" },
                    bounds: { CGRect(x: 10, y: 20, width: 30, height: 12) }
                )
            },
            selectedTextMarkerRange: { nil }
        )

        let snapshot = SelectedTextProbePolicy.snapshot(
            candidates: AnySequence([candidate]),
            sourceAppIdentifier: "test.app",
            sourceProcessIdentifier: 42,
            normalizeBounds: { $0 },
            diagnostics: SelectedTextDiagnostics(isEnabled: false),
            allowsReplacementContext: false
        )

        XCTAssertEqual(snapshot?.rawText, "cat")
        XCTAssertNil(snapshot?.replacementContextID)
        XCTAssertEqual(commitCount, 0)
    }

    func testCaptureRequiresFrontmostFocusedNonSecureKnownSelection() {
        let range = NSRange(location: 2, length: 5)
        let text = " cat "

        XCTAssertTrue(SelectedTextReplacementPolicy.canCaptureSelection(
            isFrontmostApplication: true,
            isFocusedElement: true,
            isSameWindow: true,
            isSecure: false,
            range: range,
            rawText: text
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.canCaptureSelection(
            isFrontmostApplication: false,
            isFocusedElement: true,
            isSameWindow: true,
            isSecure: false,
            range: range,
            rawText: text
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.canCaptureSelection(
            isFrontmostApplication: true,
            isFocusedElement: false,
            isSameWindow: true,
            isSecure: false,
            range: range,
            rawText: text
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.canCaptureSelection(
            isFrontmostApplication: true,
            isFocusedElement: true,
            isSameWindow: false,
            isSecure: false,
            range: range,
            rawText: text
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.canCaptureSelection(
            isFrontmostApplication: true,
            isFocusedElement: true,
            isSameWindow: true,
            isSecure: true,
            range: range,
            rawText: text
        ))
    }

    func testCaptureRejectsUnknownEmptyAndLengthMismatchedSelections() {
        XCTAssertFalse(canCapture(range: NSRange(location: NSNotFound, length: 3), text: "cat"))
        XCTAssertFalse(canCapture(range: NSRange(location: -1, length: 3), text: "cat"))
        XCTAssertFalse(canCapture(range: NSRange(location: Int.max - 1, length: 3), text: "cat"))
        XCTAssertFalse(canCapture(range: NSRange(location: 0, length: 0), text: ""))
        XCTAssertFalse(canCapture(range: NSRange(location: 0, length: 2), text: "cat"))
        XCTAssertFalse(canCapture(range: NSRange(location: 0, length: 2), text: " \n"))
    }

    func testCaptureRejectsUnsupportedChannel() {
        let range = NSRange(location: 0, length: 3)
        let text = "cat"

        XCTAssertFalse(canCapture(range: range, text: text, supportsChannel: false))
    }

    func testMissingEnabledAttributeAllowsExplicitlyWritableText() {
        XCTAssertTrue(SelectedTextReplacementPolicy.isEditableTarget(
            enabled: nil,
            isSecure: false,
            selectedTextIsSettable: true,
            valueIsSettable: false
        ))
        XCTAssertTrue(SelectedTextReplacementPolicy.isEditableTarget(
            enabled: nil,
            isSecure: false,
            selectedTextIsSettable: false,
            valueIsSettable: true
        ))
    }

    func testDisabledReadOnlyAndSecureTargetsRemainIneligible() {
        XCTAssertFalse(SelectedTextReplacementPolicy.isEditableTarget(
            enabled: false,
            isSecure: false,
            selectedTextIsSettable: true,
            valueIsSettable: true
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.isEditableTarget(
            enabled: nil,
            isSecure: false,
            selectedTextIsSettable: false,
            valueIsSettable: false
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.isEditableTarget(
            enabled: true,
            isSecure: true,
            selectedTextIsSettable: true,
            valueIsSettable: true
        ))
    }

    func testMissingRangeStringUsesExactSelectedTextAndRange() {
        let range = NSRange(location: 8, length: 5)
        XCTAssertTrue(SelectedTextReplacementPolicy.selectionTextMatches(
            rawText: "hello",
            rangeText: nil,
            selectedText: "hello",
            currentRange: range,
            expectedRange: range
        ))
        XCTAssertTrue(SelectedTextReplacementPolicy.selectionTextMatches(
            rawText: "hello",
            rangeText: "hello",
            selectedText: nil,
            currentRange: range,
            expectedRange: range
        ))
    }

    func testConflictingOrMissingSelectionTextCannotConfirmTarget() {
        let range = NSRange(location: 8, length: 5)
        for (rangeText, selectedText) in [
            ("other", "hello"),
            ("hello", "other"),
            ("", "hello"),
            (nil, nil),
        ] as [(String?, String?)] {
            XCTAssertFalse(SelectedTextReplacementPolicy.selectionTextMatches(
                rawText: "hello",
                rangeText: rangeText,
                selectedText: selectedText,
                currentRange: range,
                expectedRange: range
            ))
        }
    }

    func testMatchingTextCannotSubstituteForChangedOrMissingRange() {
        let range = NSRange(location: 8, length: 5)
        for currentRange in [NSRange(location: 9, length: 5), nil] as [NSRange?] {
            XCTAssertFalse(SelectedTextReplacementPolicy.selectionTextMatches(
                rawText: "hello",
                rangeText: nil,
                selectedText: "hello",
                currentRange: currentRange,
                expectedRange: range
            ))
        }
    }

    func testRawTextAndUTF16LengthSupportEmojiAndCombiningSequences() {
        let text = "  👩🏽‍💻e\u{301}\n"
        XCTAssertTrue(canCapture(
            range: NSRange(location: 0, length: text.utf16.count),
            text: text
        ))
    }

    func testTargetMatchingRequiresSameProcessWindowElementRangeAndExactText() {
        let expectedRange = NSRange(location: 8, length: 5)
        XCTAssertTrue(matches(range: expectedRange, text: "hello"))
        XCTAssertFalse(matches(processIdentifier: 43, range: expectedRange, text: "hello"))
        XCTAssertFalse(matches(sameWindow: false, range: expectedRange, text: "hello"))
        XCTAssertFalse(matches(sameElement: false, range: expectedRange, text: "hello"))
        XCTAssertFalse(matches(range: NSRange(location: 9, length: 5), text: "hello"))
        XCTAssertFalse(matches(range: expectedRange, text: "hello "))
    }

    func testButtonVisibilityDependsOnlyOnChannelSelectedTextResultAndCompletion() {
        XCTAssertTrue(SelectedTextReplacementPolicy.shouldShowButton(
            supportsChannel: true, isSelectedTextResult: true, isTranslationComplete: true
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.shouldShowButton(
            supportsChannel: false, isSelectedTextResult: true, isTranslationComplete: true
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.shouldShowButton(
            supportsChannel: true, isSelectedTextResult: false, isTranslationComplete: true
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.shouldShowButton(
            supportsChannel: true, isSelectedTextResult: true, isTranslationComplete: false
        ))
    }

    func testPasteboardRestoreIsForbiddenAfterExternalClipboardChange() {
        XCTAssertTrue(SelectedTextReplacementPolicy.shouldRestorePasteboard(
            currentChangeCount: 10,
            ownedChangeCount: 10
        ))
        XCTAssertFalse(SelectedTextReplacementPolicy.shouldRestorePasteboard(
            currentChangeCount: 11,
            ownedChangeCount: 10
        ))
    }

    @MainActor
    func testPasteboardCoordinatorSerializesLeasesAndRejectsStaleRelease() {
        let coordinator = PasteboardCoordinator()
        let firstLease = try! XCTUnwrap(coordinator.acquire())

        XCTAssertNil(coordinator.acquire())
        coordinator.release(firstLease)

        let secondLease = try! XCTUnwrap(coordinator.acquire())
        coordinator.release(firstLease)
        XCTAssertNil(coordinator.acquire())

        coordinator.release(secondLease)
        XCTAssertNotNil(coordinator.acquire())
    }

    @MainActor
    func testPasteboardCoordinatorUsesInjectedPasteboard() throws {
        let pasteboardName = NSPasteboard.Name("SnapTraTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("backup", forType: .string))

        let coordinator = PasteboardCoordinator(pasteboard: pasteboard)
        let lease = try XCTUnwrap(coordinator.acquire())
        let snapshot = try XCTUnwrap(coordinator.capture(using: lease))
        let write = try XCTUnwrap(coordinator.write(
            "translated",
            using: lease,
            expectedChangeCount: snapshot.changeCount
        ))
        XCTAssertEqual(coordinator.changeCount, write.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "translated")

        XCTAssertTrue(coordinator.restore(snapshot, using: lease, ifChangeCount: write.changeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "backup")
        coordinator.release(lease)
    }

    private func canCapture(
        range: NSRange,
        text: String,
        supportsChannel: Bool = true
    ) -> Bool {
        SelectedTextReplacementPolicy.canCaptureSelection(
            supportsChannel: supportsChannel,
            isFrontmostApplication: true,
            isFocusedElement: true,
            isSameWindow: true,
            isSecure: false,
            range: range,
            rawText: text
        )
    }

    private func matches(
        processIdentifier: pid_t = 42,
        sameWindow: Bool = true,
        sameElement: Bool = true,
        range: NSRange,
        text: String
    ) -> Bool {
        SelectedTextReplacementPolicy.targetStillMatches(
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: processIdentifier,
            isSameWindow: sameWindow,
            isSameFocusedElement: sameElement,
            currentRange: range,
            expectedRange: NSRange(location: 8, length: 5),
            currentRawText: text,
            expectedRawText: "hello"
        )
    }

}
