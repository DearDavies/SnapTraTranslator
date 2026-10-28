import Foundation

nonisolated struct SelectedTextReplacementSession: Equatable, Sendable {
    let id: UUID
    let contextID: UUID?
    let sourceProcessIdentifier: pid_t
    let sourceApplicationName: String
    let rawText: String
}

struct SelectedTextReplacementRequest: Equatable {
    let operationID: UUID
    let session: SelectedTextReplacementSession
    let lookupID: UUID
    let sourceType: SentenceTranslationSource.SourceType
    let translatedText: String
}

enum SelectedTextReplacementPhase: Equatable {
    case waitingForModifiers
    case replacing
    case pasteDispatched
}

struct SelectedTextReplacementOperation: Equatable {
    let request: SelectedTextReplacementRequest
    var phase: SelectedTextReplacementPhase
}

nonisolated enum SelectedTextReplacementOutcome: Equatable, Sendable {
    case verified
    case pasteDispatched
}

nonisolated enum SelectedTextReplacementFailure: Error, Equatable, Sendable {
    case unsupportedChannel
    case accessibilityRequired
    case targetUnavailable
    case targetNotEditable
    case sourceChanged
    case selectionChanged
    case clipboardBusy
    case clipboardChanged
    case focusTimedOut
    case modifiersStillPressed
    case eventCreationFailed

    var localizationKey: String {
        switch self {
        case .unsupportedChannel:
            return "Text replacement is unavailable in this version."
        case .accessibilityRequired:
            return "Enable Accessibility access to replace selected text."
        case .targetUnavailable:
            return "Unable to verify the original selection. Select it and translate again."
        case .targetNotEditable:
            return "The original selection is not editable."
        case .sourceChanged, .selectionChanged:
            return "The original text or selection changed. Select it again."
        case .clipboardBusy:
            return "Clipboard is busy. Try again."
        case .clipboardChanged:
            return "Clipboard changed. Try again."
        case .focusTimedOut:
            return "Unable to restore the original input focus."
        case .modifiersStillPressed:
            return "Release the shortcut keys and try again."
        case .eventCreationFailed:
            return "Unable to send the replacement."
        }
    }
}

nonisolated enum SelectedTextReplacementPolicy {
    enum CandidateRelationship {
        case sameElement
        case insideFocusedElement
        case containsFocusedElement
        case unrelated
    }

    static func canBindCandidate(
        relationship: CandidateRelationship
    ) -> Bool {
        switch relationship {
        case .sameElement, .insideFocusedElement, .containsFocusedElement:
            return true
        case .unrelated:
            return false
        }
    }

    static func shouldShowButton(
        supportsChannel: Bool,
        isSelectedTextResult: Bool,
        isTranslationComplete: Bool
    ) -> Bool {
        supportsChannel
            && isSelectedTextResult
            && isTranslationComplete
    }

    static func canCaptureSelection(
        supportsChannel: Bool = true,
        isFrontmostApplication: Bool,
        isFocusedElement: Bool,
        isSameWindow: Bool,
        isSecure: Bool,
        range: NSRange,
        rawText: String
    ) -> Bool {
        supportsChannel
            && isFrontmostApplication
            && isFocusedElement
            && isSameWindow
            && !isSecure
            && range.location != NSNotFound
            && range.location >= 0
            && range.length > 0
            && range.length <= Int.max - range.location
            && range.length == rawText.utf16.count
            && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isEditableTarget(
        enabled: Bool?,
        isSecure: Bool,
        selectedTextIsSettable: Bool,
        valueIsSettable: Bool
    ) -> Bool {
        enabled != false
            && !isSecure
            && (selectedTextIsSettable || valueIsSettable)
    }

    static func selectionTextMatches(
        rawText: String,
        rangeText: String?,
        selectedText: String?,
        currentRange: NSRange?,
        expectedRange: NSRange
    ) -> Bool {
        guard currentRange == expectedRange else { return false }
        guard rangeText == nil || rangeText == rawText else { return false }
        guard selectedText == nil || selectedText == rawText else { return false }
        return rangeText != nil || selectedText != nil
    }

    static func targetStillMatches(
        expectedProcessIdentifier: pid_t,
        currentProcessIdentifier: pid_t?,
        isSameWindow: Bool,
        isSameFocusedElement: Bool,
        currentRange: NSRange?,
        expectedRange: NSRange,
        currentRawText: String?,
        expectedRawText: String
    ) -> Bool {
        currentProcessIdentifier == expectedProcessIdentifier
            && isSameWindow
            && isSameFocusedElement
            && currentRange == expectedRange
            && currentRawText == expectedRawText
    }

    static func shouldRestorePasteboard(currentChangeCount: Int, ownedChangeCount: Int) -> Bool {
        currentChangeCount == ownedChangeCount
    }
}
