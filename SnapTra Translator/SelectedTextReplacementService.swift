import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class SelectedTextReplacementService {
    private let selectedTextService: SelectedTextService
    private let pasteboardCoordinator: PasteboardCoordinator
    private let waitForPasteVerificationInterval: @MainActor () async -> Void

    init(
        selectedTextService: SelectedTextService,
        pasteboardCoordinator: PasteboardCoordinator,
        waitForPasteVerificationInterval: @escaping @MainActor () async -> Void = {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    ) {
        self.selectedTextService = selectedTextService
        self.pasteboardCoordinator = pasteboardCoordinator
        self.waitForPasteVerificationInterval = waitForPasteVerificationInterval
    }

    func replace(
        session: SelectedTextReplacementSession,
        translatedText: String,
        allowsHeldModifiers: Bool = false,
        hideOverlay: @MainActor () -> Void,
        onPasteDispatched: @MainActor () -> Void
    ) async throws -> SelectedTextReplacementOutcome {
        guard DistributionChannel.supportsSelectedTextTranslation else {
            throw SelectedTextReplacementFailure.unsupportedChannel
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw SelectedTextReplacementFailure.accessibilityRequired
        }
        guard let contextID = session.contextID else {
            throw SelectedTextReplacementFailure.targetUnavailable
        }

        let processIdentifier = session.sourceProcessIdentifier
        let currentFrontmostProcess = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard currentFrontmostProcess == processIdentifier || currentFrontmostProcess == ownProcessIdentifier else {
            throw SelectedTextReplacementFailure.sourceChanged
        }

        guard ClipboardSelectionOperationGate.acquire() else {
            throw SelectedTextReplacementFailure.clipboardBusy
        }
        defer { ClipboardSelectionOperationGate.release() }

        guard let lease = pasteboardCoordinator.acquire() else {
            throw SelectedTextReplacementFailure.clipboardBusy
        }
        defer { pasteboardCoordinator.release(lease) }

        guard let backup = pasteboardCoordinator.capture(using: lease) else {
            throw SelectedTextReplacementFailure.clipboardBusy
        }
        var ownedChangeCount = backup.changeCount
        var didDispatchPaste = false
        var shouldRestorePasteboard = true
        defer {
            if shouldRestorePasteboard, !didDispatchPaste, ownedChangeCount != backup.changeCount {
                pasteboardCoordinator.restore(
                    backup,
                    using: lease,
                    ifChangeCount: ownedChangeCount
                )
            }
        }

        guard let sourceApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
            throw SelectedTextReplacementFailure.targetUnavailable
        }
        try Task.checkCancellation()
        hideOverlay()
        sourceApplication.activate(options: [])

        var targetIsFocused = false
        for _ in 0..<20 {
            try Task.checkCancellation()
            let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostProcessIdentifier != processIdentifier {
                if frontmostProcessIdentifier != ownProcessIdentifier {
                    throw SelectedTextReplacementFailure.sourceChanged
                }
                try await Task.sleep(nanoseconds: 25_000_000)
                continue
            }
            try await selectedTextService.validateReplacementTarget(
                contextID: contextID,
                frontmostProcessIdentifier: frontmostProcessIdentifier
            )
            targetIsFocused = true
            break
        }
        guard targetIsFocused else {
            throw SelectedTextReplacementFailure.focusTimedOut
        }

        guard allowsHeldModifiers
                || NSEvent.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty else {
            throw SelectedTextReplacementFailure.modifiersStillPressed
        }

        try await selectedTextService.validateReplacementTarget(
            contextID: contextID,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )

        guard pasteboardCoordinator.changeCount == backup.changeCount else {
            throw SelectedTextReplacementFailure.clipboardChanged
        }
        guard let write = pasteboardCoordinator.write(
            translatedText,
            using: lease,
            expectedChangeCount: backup.changeCount
        ) else {
            throw SelectedTextReplacementFailure.clipboardChanged
        }
        ownedChangeCount = write.changeCount
        guard write.succeeded else {
            throw SelectedTextReplacementFailure.eventCreationFailed
        }
        guard pasteboardCoordinator.changeCount == ownedChangeCount else {
            throw SelectedTextReplacementFailure.clipboardChanged
        }

        try Task.checkCancellation()
        try await selectedTextService.validateReplacementTarget(
            contextID: contextID,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              pasteboardCoordinator.changeCount == ownedChangeCount else {
            throw SelectedTextReplacementFailure.selectionChanged
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw SelectedTextReplacementFailure.eventCreationFailed
        }
        try await selectedTextService.validateReplacementTarget(
            contextID: contextID,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            throw SelectedTextReplacementFailure.sourceChanged
        }
        guard pasteboardCoordinator.changeCount == ownedChangeCount else {
            throw SelectedTextReplacementFailure.clipboardChanged
        }
        guard allowsHeldModifiers
                || NSEvent.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty else {
            throw SelectedTextReplacementFailure.modifiersStillPressed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        didDispatchPaste = true
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        onPasteDispatched()

        for _ in 0..<10 {
            if pasteboardCoordinator.changeCount != ownedChangeCount {
                shouldRestorePasteboard = false
                return .pasteDispatched
            }
            if await selectedTextService.replacementTextMatches(
                contextID: contextID,
                text: translatedText
            ) {
                pasteboardCoordinator.restore(
                    backup,
                    using: lease,
                    ifChangeCount: ownedChangeCount
                )
                return .verified
            }
            await waitForPasteVerificationInterval()
        }

        shouldRestorePasteboard = false
        return .pasteDispatched
    }

}
