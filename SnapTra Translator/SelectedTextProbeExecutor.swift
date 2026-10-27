import AppKit
import CoreGraphics
import Dispatch
import Foundation

nonisolated struct SelectedTextScreenConfiguration: Equatable, Sendable {
    struct Display: Equatable, Sendable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
        let rotation: Double

        init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat, rotation: Double = 0) {
            self.id = id
            self.frame = frame
            self.scale = scale
            self.rotation = rotation
        }
    }

    @MainActor private static var currentRevision: UInt64 = 0

    let primaryDisplay: Display
    let otherDisplays: [Display]
    let revision: UInt64

    init(primaryDisplay: Display, otherDisplays: [Display] = [], revision: UInt64 = 0) {
        self.primaryDisplay = primaryDisplay
        self.otherDisplays = otherDisplays.sorted { $0.id < $1.id }
        self.revision = revision
    }

    @MainActor
    static func invalidate() {
        currentRevision &+= 1
    }

    @MainActor
    static func capture() -> SelectedTextScreenConfiguration? {
        var displays: [Display] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = number.uint32Value
            displays.append(Display(
                id: displayID,
                frame: screen.frame,
                scale: screen.backingScaleFactor,
                rotation: CGDisplayRotation(displayID)
            ))
        }
        // AppKit's first screen defines the global origin; NSScreen.main follows keyboard focus.
        guard let primaryDisplay = displays.first else { return nil }
        return SelectedTextScreenConfiguration(
            primaryDisplay: primaryDisplay,
            otherDisplays: Array(displays.dropFirst()),
            revision: currentRevision
        )
    }

    func accessibilityPoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplay.frame.maxY - point.y)
    }

    func appKitRect(from rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplay.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

nonisolated struct SelectedTextProbeRequest: Equatable, Sendable {
    let mouseLocation: CGPoint
    let accessibilityPoint: CGPoint
    let frontmostApplicationProcessIdentifier: pid_t?
    let sourceAppIdentifier: String?
    let screenConfiguration: SelectedTextScreenConfiguration

    init(
        mouseLocation: CGPoint,
        frontmostApplicationProcessIdentifier: pid_t?,
        sourceAppIdentifier: String?,
        screenConfiguration: SelectedTextScreenConfiguration
    ) {
        self.mouseLocation = mouseLocation
        self.accessibilityPoint = screenConfiguration.accessibilityPoint(from: mouseLocation)
        self.frontmostApplicationProcessIdentifier = frontmostApplicationProcessIdentifier
        self.sourceAppIdentifier = sourceAppIdentifier
        self.screenConfiguration = screenConfiguration
    }

    @MainActor
    static func capture(mouseLocation: CGPoint) -> SelectedTextProbeRequest? {
        guard let screenConfiguration = SelectedTextScreenConfiguration.capture() else { return nil }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        return SelectedTextProbeRequest(
            mouseLocation: mouseLocation,
            frontmostApplicationProcessIdentifier: frontmostApplication?.processIdentifier,
            sourceAppIdentifier: frontmostApplication?.bundleIdentifier,
            screenConfiguration: screenConfiguration
        )
    }

    @MainActor
    var hasCurrentScreenConfiguration: Bool {
        screenConfiguration == SelectedTextScreenConfiguration.capture()
    }

    func normalizedScreenRect(_ rect: CGRect) -> CGRect {
        screenConfiguration.appKitRect(from: rect)
    }
}

nonisolated final class SelectedTextProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    fileprivate func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

nonisolated final class SelectedTextProbeExecutor: @unchecked Sendable {
    static let shared = SelectedTextProbeExecutor()

    private let queue: DispatchQueue

    init(label: String = "app.snaptra.selected-text-probe") {
        queue = DispatchQueue(
            label: label,
            qos: .userInitiated
        )
    }

    func execute<Result: Sendable>(
        onDiscardedResult: @escaping @Sendable (Result) -> Void = { _ in },
        _ operation: @escaping @Sendable (SelectedTextProbeCancellation) throws -> Result
    ) async throws -> Result {
        let cancellation = SelectedTextProbeCancellation()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.checkCancellation()
                        let result = try operation(cancellation)
                        do {
                            try cancellation.checkCancellation()
                        } catch {
                            onDiscardedResult(result)
                            throw error
                        }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

nonisolated struct SelectedTextDiagnostics: @unchecked Sendable {
    private let isEnabled: Bool
    private let sink: (String) -> Void

    init(
        isEnabled: Bool,
        sink: @escaping (String) -> Void = { print("[SelectedText] \($0)") }
    ) {
        self.isEnabled = isEnabled
        self.sink = sink
    }

    func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        sink(message())
    }

    static var system: SelectedTextDiagnostics {
#if DEBUG
        SelectedTextDiagnostics(isEnabled: true)
#else
        SelectedTextDiagnostics(isEnabled: false)
#endif
    }
}

nonisolated struct SelectedTextProbeObservation: Equatable, Sendable {
    static let softBudgetNanoseconds: UInt64 = 120_000_000

    let durationNanoseconds: UInt64

    var exceededSoftBudget: Bool {
        durationNanoseconds > Self.softBudgetNanoseconds
    }
}

nonisolated enum SelectedTextProbeSoftBudget {
    static func observe<Result>(
        _ result: Result,
        durationNanoseconds: UInt64,
        observer: (SelectedTextProbeObservation) -> Void
    ) -> Result {
        observer(
            SelectedTextProbeObservation(
                durationNanoseconds: durationNanoseconds
            )
        )
        return result
    }
}

nonisolated struct SelectedTextProbeRange {
    let range: NSRange
    let string: () -> String?
    let bounds: () -> CGRect?
}

nonisolated struct SelectedTextProbeMarkerRange {
    let string: () -> String?
    let attributedString: () -> NSAttributedString?
    let bounds: () -> CGRect?
}

nonisolated struct SelectedTextProbeCandidate {
    let context: String
    let debugSummary: () -> String
    let commitSelectionContext: (NSRange, String, SelectedTextProbeRange?) -> UUID?
    let selectedText: () -> String?
    let selectedRange: () -> SelectedTextProbeRange?
    let selectedTextMarkerRange: () -> SelectedTextProbeMarkerRange?

    init(
        context: String,
        debugSummary: @escaping () -> String,
        commitSelectionContext: @escaping (NSRange, String, SelectedTextProbeRange?) -> UUID? = { _, _, _ in nil },
        selectedText: @escaping () -> String?,
        selectedRange: @escaping () -> SelectedTextProbeRange?,
        selectedTextMarkerRange: @escaping () -> SelectedTextProbeMarkerRange?
    ) {
        self.context = context
        self.debugSummary = debugSummary
        self.commitSelectionContext = commitSelectionContext
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.selectedTextMarkerRange = selectedTextMarkerRange
    }
}

nonisolated enum SelectedTextProbePolicy {
    static func snapshot(
        candidates: AnySequence<SelectedTextProbeCandidate>,
        sourceAppIdentifier: String?,
        sourceProcessIdentifier: pid_t? = nil,
        normalizeBounds: (CGRect) -> CGRect,
        diagnostics: SelectedTextDiagnostics = .system,
        isCancelled: () -> Bool = { false },
        allowsReplacementContext: Bool = true
    ) -> SelectedTextSnapshot? {
        for candidate in candidates {
            guard !isCancelled() else { return nil }

            diagnostics.log("\(candidate.context) \(candidate.debugSummary())")

            guard !isCancelled() else { return nil }
            let directRawText = candidate.selectedText()
            let directText = normalized(directRawText)

            guard !isCancelled() else { return nil }
            let range = candidate.selectedRange()
            let selectedRange = range?.range
                ?? NSRange(
                    location: NSNotFound,
                    length: directText?.utf16.count ?? 0
                )
            let hasKnownRange = isKnown(selectedRange)

            if let directText, hasKnownRange {
                let rawText = directRawText ?? directText
                return makeSnapshot(
                    text: directText,
                    rawText: rawText,
                    selectedRange: selectedRange,
                    bounds: nil,
                    sourceAppIdentifier: sourceAppIdentifier,
                    sourceProcessIdentifier: sourceProcessIdentifier,
                    replacementContextID: allowsReplacementContext
                        ? candidate.commitSelectionContext(selectedRange, rawText, range)
                        : nil
                )
            }

            var resolvedText = directText
            var resolvedRawText = directRawText
            if resolvedText == nil, let range {
                guard !isCancelled() else { return nil }
                let rangeRawText = range.string()
                resolvedRawText = rangeRawText
                resolvedText = normalized(rangeRawText)
                if let resolvedText, hasKnownRange {
                    let rawText = rangeRawText ?? resolvedText
                    return makeSnapshot(
                        text: resolvedText,
                        rawText: rawText,
                        selectedRange: selectedRange,
                        bounds: nil,
                        sourceAppIdentifier: sourceAppIdentifier,
                        sourceProcessIdentifier: sourceProcessIdentifier,
                        replacementContextID: allowsReplacementContext
                            ? candidate.commitSelectionContext(selectedRange, rawText, range)
                            : nil
                    )
                }
            }

            guard !isCancelled() else { return nil }
            let markerRange = candidate.selectedTextMarkerRange()

            if resolvedText == nil, let markerRange {
                guard !isCancelled() else { return nil }
                resolvedRawText = markerRange.string()
                resolvedText = normalized(resolvedRawText)

                if resolvedText == nil {
                    guard !isCancelled() else { return nil }
                    resolvedRawText = markerRange.attributedString()?.string
                    resolvedText = normalized(resolvedRawText)
                }
            }

            guard let resolvedText else {
                diagnostics.log("\(candidate.context) no selected text value")
                continue
            }

            var resolvedBounds: CGRect?
            if !hasKnownRange {
                if let range {
                    guard !isCancelled() else { return nil }
                    resolvedBounds = normalizedBounds(
                        range.bounds(),
                        normalizeBounds: normalizeBounds
                    )
                }

                if resolvedBounds == nil, let markerRange {
                    guard !isCancelled() else { return nil }
                    resolvedBounds = normalizedBounds(
                        markerRange.bounds(),
                        normalizeBounds: normalizeBounds
                    )
                }
            }

            guard !isCancelled() else { return nil }
            let rawText = resolvedRawText ?? resolvedText
            return makeSnapshot(
                text: resolvedText,
                rawText: rawText,
                selectedRange: NSRange(
                    location: selectedRange.location,
                    length: selectedRange.location == NSNotFound
                        ? resolvedText.utf16.count
                        : selectedRange.length
                ),
                bounds: resolvedBounds,
                sourceAppIdentifier: sourceAppIdentifier,
                sourceProcessIdentifier: sourceProcessIdentifier,
                replacementContextID: allowsReplacementContext
                    ? candidate.commitSelectionContext(selectedRange, rawText, range)
                    : nil
            )
        }

        return nil
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func isKnown(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.length > 0
    }

    private static func normalizedBounds(
        _ bounds: CGRect?,
        normalizeBounds: (CGRect) -> CGRect
    ) -> CGRect? {
        guard let bounds else { return nil }
        let normalized = normalizeBounds(bounds)
        guard normalized.width > 0, normalized.height > 0 else { return nil }
        return normalized
    }

    private static func makeSnapshot(
        text: String,
        rawText: String,
        selectedRange: NSRange,
        bounds: CGRect?,
        sourceAppIdentifier: String?,
        sourceProcessIdentifier: pid_t?,
        replacementContextID: UUID? = nil
    ) -> SelectedTextSnapshot {
        SelectedTextSnapshot(
            text: text,
            selectedRange: selectedRange,
            bounds: bounds,
            sourceAppIdentifier: sourceAppIdentifier,
            rawText: rawText,
            sourceProcessIdentifier: sourceProcessIdentifier,
            replacementContextID: replacementContextID
        )
    }
}
