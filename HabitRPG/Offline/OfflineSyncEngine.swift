//
//  OfflineSyncEngine.swift
//  Habitica
//
//  Replays the offline write queue against the API, in order, with backoff.
//

import Foundation
import UIKit
import ReactiveSwift
import Habitica_Models
import Habitica_API_Client
import Habitica_Database

private enum ReplayResult {
    case success
    case retry(String, TimeInterval)
    case drop(String)
}

/// Swallows the error alerts that would otherwise pop up for every request the
/// replay makes. The outcome is reported back through the call's signals.
private final class SilentNetworkErrorHandler: NetworkErrorHandler {
    let disposable = ScopedDisposable(CompositeDisposable())
    let errorMessages: [ErrorMessage]? = nil

    func handle(error: NetworkError, messages: [String]) {
        logger.log("Offline sync request failed: \(error.localizedDescription)")
    }
}

final class OfflineSyncEngine {

    static let shared = OfflineSyncEngine()

    private let pendingRepository = PendingOperationRepository()
    private let mutationRepository = OfflineMutationRepository()
    private let taskLocalRepository = TaskLocalRepository()
    private let userRepository = UserRepository()
    private let disposable = ScopedDisposable(CompositeDisposable())

    private var isFlushing = false
    private var retryTimer: DispatchWorkItem?
    private var hasStarted = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        if let userID = OfflineState.shared.currentUserID {
            mutationRepository.resetInFlightState(userID: userID)
        }

        disposable.inner.add(NetworkMonitor.shared.isOnline.producer
            .skipRepeats()
            .startWithValues { [weak self] isOnline in
                if isOnline {
                    self?.flushIfPossible()
                }
            })

        disposable.inner.add(NotificationCenter.default.reactive
            .notifications(forName: UIApplication.didBecomeActiveNotification)
            .observeValues { [weak self] _ in
                self?.flushIfPossible()
            })

        disposable.inner.add(NotificationCenter.default.reactive
            .notifications(forName: PendingOperationRepository.didChangeNotification)
            .observeValues { [weak self] _ in
                self?.flushIfPossible()
            })

        scheduleRetry(after: 15)
        flushIfPossible()
    }

    // MARK: - Queueing

    func enqueueCreate(task: TaskProtocol) {
        enqueue(type: .createTask, task: task)
    }

    func enqueueUpdate(task: TaskProtocol) {
        enqueue(type: .updateTask, task: task)
    }

    func enqueueDelete(task: TaskProtocol) {
        guard let userID = OfflineState.shared.currentUserID, let taskID = task.id else {
            return
        }
        pendingRepository.enqueue(type: .deleteTask, userID: userID, entityID: taskID)
        OfflineState.shared.refreshPendingCount()
    }

    func enqueueMove(task: TaskProtocol, toPosition: Int) {
        guard let userID = OfflineState.shared.currentUserID, let taskID = task.id else {
            return
        }
        pendingRepository.enqueue(type: .moveTask,
                                  userID: userID,
                                  entityID: taskID,
                                  payload: ["position": String(toPosition)])
        OfflineState.shared.refreshPendingCount()
    }

    func enqueueCron() {
        guard let userID = OfflineState.shared.currentUserID else {
            return
        }
        pendingRepository.enqueue(type: .runCron, userID: userID)
        OfflineState.shared.refreshPendingCount()
    }

    func enqueueTag(_ tag: TagProtocol, isNew: Bool) {
        guard let userID = OfflineState.shared.currentUserID else {
            return
        }
        let type: PendingOperationType = isNew ? .createTag : .updateTag
        pendingRepository.enqueue(type: type, userID: userID, entityID: tag.id)
        OfflineState.shared.refreshPendingCount()
    }

    func enqueueDeleteTag(_ tag: TagProtocol) {
        guard let userID = OfflineState.shared.currentUserID else {
            return
        }
        pendingRepository.enqueue(type: .deleteTag, userID: userID, entityID: tag.id)
        OfflineState.shared.refreshPendingCount()
    }

    private func enqueue(type: PendingOperationType, task: TaskProtocol) {
        guard let userID = OfflineState.shared.currentUserID else {
            return
        }
        pendingRepository.enqueue(type: type, userID: userID, entityID: task.id)
        OfflineState.shared.refreshPendingCount()
    }

    // MARK: - Flushing

    func flushIfPossible() {
        guard !OfflineState.shared.isStandalone,
              NetworkMonitor.shared.isOnlineNow,
              !isFlushing,
              let userID = OfflineState.shared.currentUserID else {
            return
        }
        let operations = pendingRepository.snapshots(userID: userID)
        guard operations.isEmpty == false else {
            return
        }

        isFlushing = true
        OfflineState.shared.isSyncing.value = true

        replay(operations)
    }

    private func replay(_ operations: [PendingOperationSnapshot]) {
        var remaining = operations

        func step() {
            guard let operation = remaining.first else {
                finishFlush(reachedServer: true)
                return
            }
            remaining.removeFirst()

            replay(operation) { [weak self] result in
                guard let self = self else {
                    return
                }
                switch result {
                case .success:
                    self.pendingRepository.delete(operationID: operation.id)
                    step()
                case .retry(let message, let delay):
                    self.pendingRepository.recordFailure(operationID: operation.id,
                                                        error: message,
                                                        retryDelay: delay)
                    self.finishFlush(reachedServer: false)
                case .drop(let message):
                    logger.log("Dropping offline operation \(operation.type.rawValue): \(message)")
                    self.pendingRepository.delete(operationID: operation.id)
                    step()
                }
            }
        }

        step()
    }

    private func finishFlush(reachedServer: Bool) {
        isFlushing = false
        OfflineState.shared.isSyncing.value = false
        OfflineState.shared.refreshPendingCount()

        if reachedServer {
            OfflineState.shared.lastSyncDate.value = Date()
            // Pull the authoritative state once the queue is drained.
            if let userID = OfflineState.shared.currentUserID,
               pendingRepository.pendingCount(userID: userID) == 0 {
                userRepository.retrieveUser(withTasks: true).observeCompleted {}
            }
            scheduleRetry(after: 60)
        } else {
            scheduleRetry(after: 20)
        }
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retryTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else {
                return
            }
            self.flushIfPossible()
            if let userID = OfflineState.shared.currentUserID,
               self.pendingRepository.pendingCount(userID: userID) > 0 {
                self.scheduleRetry(after: 60)
            }
        }
        retryTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    // MARK: - Replay

    private func replay(_ operation: PendingOperationSnapshot, completion: @escaping (ReplayResult) -> Void) {
        let previousHandler = AuthenticatedCall.errorHandler
        AuthenticatedCall.errorHandler = SilentNetworkErrorHandler()
        let restoreHandler = {
            AuthenticatedCall.errorHandler = previousHandler
        }

        switch operation.type {
        case .createTask:
            replayTask(operation, isCreate: true, completion: finish(completion, restoreHandler))
        case .updateTask:
            replayTask(operation, isCreate: false, completion: finish(completion, restoreHandler))
        case .deleteTask:
            replayDeleteTask(operation, completion: finish(completion, restoreHandler))
        case .scoreTask:
            replayScore(operation, completion: finish(completion, restoreHandler))
        case .moveTask:
            replayMove(operation, completion: finish(completion, restoreHandler))
        case .createTag, .updateTag:
            replayTag(operation, isCreate: operation.type == .createTag, completion: finish(completion, restoreHandler))
        case .deleteTag:
            replayDeleteTag(operation, completion: finish(completion, restoreHandler))
        case .runCron:
            replayCron(completion: finish(completion, restoreHandler))
        case .scoreChecklist:
            // Checklist scoring is folded into an updateTask when offline.
            restoreHandler()
            completion(.success)
        case .questProgress:
            // Quest progress is recalculated by the server from the replayed
            // scores; this marker only exists so the UI can show a pending
            // quest change.
            restoreHandler()
            completion(.success)
        }
    }

    private func finish(_ completion: @escaping (ReplayResult) -> Void,
                        _ restoreHandler: @escaping () -> Void) -> (ReplayResult) -> Void {
        return { result in
            restoreHandler()
            completion(result)
        }
    }

    private func replayTask(_ operation: PendingOperationSnapshot,
                            isCreate: Bool,
                            completion: @escaping (ReplayResult) -> Void) {
        guard let taskID = operation.entityID,
              let task = taskLocalRepository.getEditableTask(id: taskID) else {
            // The task was deleted locally while the queue was waiting.
            completion(.success)
            return
        }

        let call: ResponseObjectCall<TaskProtocol, APITask>
        if isCreate {
            call = CreateTaskCall(task: task)
        } else {
            call = UpdateTaskCall(task: task)
        }

        observeObjectCall(call) { [weak self] result, returnedTask in
            if case .success = result, let returnedTask = returnedTask {
                returnedTask.isNewTask = false
                returnedTask.isSynced = true
                if let returnedID = returnedTask.id, returnedID != taskID {
                    // The server assigned its own id: drop the local row and
                    // retarget anything still queued for it.
                    self?.pendingRepository.remapEntity(oldID: taskID, newID: returnedID, userID: operation.userID)
                    self?.taskLocalRepository.deleteTask(task)
                }
                self?.taskLocalRepository.save(userID: operation.userID, task: returnedTask)
            }
            completion(result)
        }
    }

    private func replayDeleteTask(_ operation: PendingOperationSnapshot, completion: @escaping (ReplayResult) -> Void) {
        guard let taskID = operation.entityID else {
            completion(.success)
            return
        }
        let shim = PreviewTask()
        shim.id = taskID

        let call = DeleteTaskCall(task: shim)
        observeEmptyCall(call) { [weak self] result in
            if case .success = result, let task = self?.taskLocalRepository.getEditableTask(id: taskID) {
                self?.taskLocalRepository.deleteTask(task)
            }
            completion(result)
        }
    }

    private func replayScore(_ operation: PendingOperationSnapshot, completion: @escaping (ReplayResult) -> Void) {
        guard let taskID = operation.entityID,
              let directionValue = operation.payload["direction"],
              let direction = TaskScoringDirection(rawValue: directionValue),
              let task = taskLocalRepository.getEditableTask(id: taskID) else {
            completion(.success)
            return
        }

        let call = ScoreTaskCall(task: task, direction: direction)
        observeObjectCall(call) { [weak self] result, response in
            if case .success = result,
               let response = response,
               let userID = OfflineState.shared.currentUserID {
                self?.mutationRepository.applyServerScoreStats(userID: userID, response: response)
            }
            completion(result)
        }
    }

    private func replayMove(_ operation: PendingOperationSnapshot, completion: @escaping (ReplayResult) -> Void) {
        guard let taskID = operation.entityID,
              let position = Int(operation.payload["position"] ?? ""),
              let task = taskLocalRepository.getEditableTask(id: taskID) else {
            completion(.success)
            return
        }

        let call = MoveTaskCall(task: task, toPosition: position)
        var statusCode: Int?
        var connectionError: NSError?
        call.httpResponseSignal.observeValues { statusCode = $0.statusCode }
        call.errorSignal.observeValues { connectionError = $0 }

        var received = false
        call.arraySignal.observeValues { [weak self] taskOrder in
            received = true
            if let order = taskOrder, let taskType = task.type {
                self?.taskLocalRepository.updateTaskOrder(taskType: taskType, order: order)
            }
        }
        call.arraySignal.observeCompleted {
            completion(received ? .success : Self.classify(statusCode: statusCode, error: connectionError))
        }
    }

    private func replayTag(_ operation: PendingOperationSnapshot,
                           isCreate: Bool,
                           completion: @escaping (ReplayResult) -> Void) {
        guard let tagID = operation.entityID,
              let tag = taskLocalRepository.getEditableTag(id: tagID) else {
            completion(.success)
            return
        }

        let call: ResponseObjectCall<TagProtocol, APITag>
        if isCreate {
            call = CreateTagCall(tag: tag)
        } else {
            call = UpdateTagCall(tag: tag)
        }

        observeObjectCall(call) { [weak self] result, returnedTag in
            if case .success = result, let returnedTag = returnedTag {
                if let returnedID = returnedTag.id, returnedID != tagID {
                    self?.pendingRepository.remapEntity(oldID: tagID, newID: returnedID, userID: operation.userID)
                    if let oldTag = self?.taskLocalRepository.getEditableTag(id: tagID) {
                        self?.taskLocalRepository.deleteTag(oldTag)
                    }
                }
                self?.taskLocalRepository.save(userID: operation.userID, tag: returnedTag)
            }
            completion(result)
        }
    }

    private func replayDeleteTag(_ operation: PendingOperationSnapshot, completion: @escaping (ReplayResult) -> Void) {
        guard let tagID = operation.entityID else {
            completion(.success)
            return
        }
        let shim = PreviewTag()
        shim.id = tagID

        let call = DeleteTagCall(tag: shim)
        observeEmptyCall(call, completion: completion)
    }

    private func replayCron(completion: @escaping (ReplayResult) -> Void) {
        observeEmptyCall(RunCronCall(), completion: completion)
    }

    // MARK: - Helpers

    private func observeObjectCall<T: Any, C: Decodable>(_ call: ResponseObjectCall<T, C>,
                                                         completion: @escaping (ReplayResult, T?) -> Void) {
        var statusCode: Int?
        var connectionError: NSError?
        call.httpResponseSignal.observeValues { statusCode = $0.statusCode }
        call.errorSignal.observeValues { connectionError = $0 }

        var received = false
        call.objectSignal.observeValues { value in
            received = true
            completion(.success, value)
        }
        call.objectSignal.observeCompleted {
            if !received {
                completion(Self.classify(statusCode: statusCode, error: connectionError), nil)
            }
        }
    }

    /// Used for calls that only report success or failure (`DeleteTaskCall`,
    /// `DeleteTagCall`, `RunCronCall`).
    private func observeEmptyCall<T: Any, C: Decodable>(_ call: ResponseObjectCall<T, C>,
                                                        completion: @escaping (ReplayResult) -> Void) {
        var statusCode: Int?
        var connectionError: NSError?
        call.httpResponseSignal.observeValues { statusCode = $0.statusCode }
        call.errorSignal.observeValues { connectionError = $0 }

        var received = false
        call.objectSignal.observeValues { _ in received = true }
        call.objectSignal.observeCompleted {
            completion(received ? .success : Self.classify(statusCode: statusCode, error: connectionError))
        }
    }

    private static func classify(statusCode: Int?, error: NSError?) -> ReplayResult {
        if let error = error, error.isConnectionError {
            NetworkMonitor.shared.reportConnectionFailure()
            return .retry(error.localizedDescription, 5)
        }
        if let statusCode = statusCode {
            if statusCode == 429 || statusCode >= 500 {
                return .retry("server returned \(statusCode)", 30)
            }
            if statusCode >= 400 {
                return .drop("server returned \(statusCode)")
            }
        }
        if let error = error {
            return .retry(error.localizedDescription, 15)
        }
        return .retry("no response", 15)
    }
}
