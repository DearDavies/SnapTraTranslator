import AppKit
import Combine
import Foundation

@MainActor
final class SelectedTextReplacementCoordinator: ObservableObject {
    @Published private(set) var operation: SelectedTextReplacementOperation?

    private var task: Task<Void, Never>?
    @Published private(set) var taskOperationID: UUID?
    private var taskSessionID: UUID?
    private var taskRequest: SelectedTextReplacementRequest?
    private let currentModifiers: @MainActor () -> NSEvent.ModifierFlags
    private let consumeCurrentGesture: @MainActor () -> Void
    private let consumeCurrentRelease: @MainActor () -> Void
    private let isRequestCurrent: @MainActor (SelectedTextReplacementRequest) -> Bool
    private let performReplacement: @MainActor (
        SelectedTextReplacementRequest,
        @escaping @MainActor () -> Void
    ) async throws -> SelectedTextReplacementOutcome
    private let onPasteDispatched: @MainActor (SelectedTextReplacementRequest) -> Void
    private let onCompletion: @MainActor (
        SelectedTextReplacementRequest,
        Result<SelectedTextReplacementOutcome, Error>
    ) -> Void
    private let onDiscardedCompletion: @MainActor (SelectedTextReplacementRequest) -> Void

    init(
        currentModifiers: @escaping @MainActor () -> NSEvent.ModifierFlags,
        consumeCurrentGesture: @escaping @MainActor () -> Void,
        consumeCurrentRelease: @escaping @MainActor () -> Void = {},
        isRequestCurrent: @escaping @MainActor (SelectedTextReplacementRequest) -> Bool,
        performReplacement: @escaping @MainActor (
            SelectedTextReplacementRequest,
            @escaping @MainActor () -> Void
        ) async throws -> SelectedTextReplacementOutcome,
        onPasteDispatched: @escaping @MainActor (SelectedTextReplacementRequest) -> Void,
        onCompletion: @escaping @MainActor (
            SelectedTextReplacementRequest,
            Result<SelectedTextReplacementOutcome, Error>
        ) -> Void,
        onDiscardedCompletion: @escaping @MainActor (SelectedTextReplacementRequest) -> Void = { _ in }
    ) {
        self.currentModifiers = currentModifiers
        self.consumeCurrentGesture = consumeCurrentGesture
        self.consumeCurrentRelease = consumeCurrentRelease
        self.isRequestCurrent = isRequestCurrent
        self.performReplacement = performReplacement
        self.onPasteDispatched = onPasteDispatched
        self.onCompletion = onCompletion
        self.onDiscardedCompletion = onDiscardedCompletion
    }

    @discardableResult
    func submit(_ request: SelectedTextReplacementRequest) -> Bool {
        guard operation == nil, task == nil, isRequestCurrent(request) else { return false }

        operation = SelectedTextReplacementOperation(
            request: request,
            phase: .waitingForModifiers
        )
        consumeCurrentGesture()
        modifiersDidChange()
        return true
    }

    @discardableResult
    func submitImmediately(_ request: SelectedTextReplacementRequest) -> Bool {
        guard operation == nil, task == nil, isRequestCurrent(request) else { return false }

        operation = SelectedTextReplacementOperation(
            request: request,
            phase: .replacing
        )
        consumeCurrentGesture()
        consumeCurrentRelease()
        startReplacement(for: request)
        return true
    }

    func modifiersDidChange() {
        guard let operation,
              operation.phase == .waitingForModifiers,
              currentModifiers().intersection(Self.relevantModifiers).isEmpty else {
            return
        }

        guard isRequestCurrent(operation.request) else {
            cancel()
            return
        }

        self.operation?.phase = .replacing
        consumeCurrentRelease()
        startReplacement(for: operation.request)
    }

    func cancel() {
        guard let previousOperation = operation else { return }
        operation = nil
        if previousOperation.phase != .pasteDispatched {
            task?.cancel()
        }
        if taskOperationID != previousOperation.request.operationID {
            onDiscardedCompletion(previousOperation.request)
        }
    }

    var isBusy: Bool {
        operation != nil || task != nil
    }

    var activeOperationID: UUID? {
        operation?.request.operationID ?? taskOperationID
    }

    var activeRequest: SelectedTextReplacementRequest? {
        operation?.request ?? taskRequest
    }

    func ownsContext(for sessionID: UUID) -> Bool {
        operation?.request.session.id == sessionID
            || taskSessionID == sessionID
    }

    private func startReplacement(for request: SelectedTextReplacementRequest) {
        guard task == nil else { return }

        taskOperationID = request.operationID
        taskSessionID = request.session.id
        taskRequest = request
        task = Task { [weak self] in
            guard let self else { return }
            guard operation?.request.operationID == request.operationID else {
                finishDiscardedTask(for: request)
                return
            }
            guard isRequestCurrent(request) else {
                operation = nil
                finishDiscardedTask(for: request)
                return
            }
            do {
                let outcome = try await performReplacement(request) { [weak self] in
                    guard let self,
                          self.operation?.request.operationID == request.operationID else {
                        return
                    }
                    self.operation?.phase = .pasteDispatched
                    self.onPasteDispatched(request)
                }
                guard taskOperationID == request.operationID else {
                    finishDiscardedTask(for: request)
                    return
                }
                guard operation?.request.operationID == request.operationID else {
                    finishDiscardedTask(for: request)
                    return
                }
                operation = nil
                onCompletion(request, .success(outcome))
                clearTask(for: request)
            } catch {
                guard taskOperationID == request.operationID else {
                    finishDiscardedTask(for: request)
                    return
                }
                let wasDispatched = operation?.request.operationID == request.operationID
                    && operation?.phase == .pasteDispatched
                let shouldReportCompletion = operation?.request.operationID == request.operationID
                operation = nil
                if shouldReportCompletion {
                    onCompletion(
                        request,
                        wasDispatched ? .success(.pasteDispatched) : .failure(error)
                    )
                } else {
                    onDiscardedCompletion(request)
                }
                clearTask(for: request)
            }
        }
    }

    private func finishDiscardedTask(for request: SelectedTextReplacementRequest) {
        onDiscardedCompletion(request)
        clearTask(for: request)
    }

    private func clearTask(for request: SelectedTextReplacementRequest) {
        guard taskOperationID == request.operationID else { return }
        task = nil
        taskOperationID = nil
        taskSessionID = nil
        taskRequest = nil
    }

    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift,
        .function,
    ]
}
