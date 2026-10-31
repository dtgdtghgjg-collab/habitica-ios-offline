//
//  PendingOperationRepository.swift
//  Habitica Database
//
//  Persistent, ordered queue of offline writes.
//

import Foundation
import RealmSwift

public class PendingOperationRepository: BaseLocalRepository {

    /// Posted whenever the queue changes, so UI and the sync engine can react.
    public static let didChangeNotification = Notification.Name("PendingOperationRepositoryDidChange")

    // MARK: - Enqueue

    /// Adds an operation to the queue.
    ///
    /// Returns the id of the stored operation, or `nil` when the operation was
    /// dropped because it cancelled out an earlier one (a task created and
    /// deleted while offline never has to reach the server).
    @discardableResult
    public func enqueue(type: PendingOperationType,
                        userID: String,
                        entityID: String? = nil,
                        payload: [String: String] = [:]) -> String? {
        var storedID: String?
        updateCall { realm in
            let pending = realm.objects(RealmPendingOperation.self)
                .filter("userID == %@", userID)

            if let entityID = entityID {
                switch type {
                case .createTask, .updateTask:
                    // A create already carries the newest local state, so a
                    // following update is redundant.
                    if type == .updateTask,
                       pending.contains(where: {
                           $0.type == PendingOperationType.createTask.rawValue && $0.entityID == entityID
                       }) {
                        return
                    }
                    if let existing = pending.first(where: {
                        ($0.type == PendingOperationType.updateTask.rawValue || $0.type == PendingOperationType.createTask.rawValue)
                        && $0.entityID == entityID
                    }) {
                        existing.payload = Self.encode(payload: payload)
                        existing.createdAt = Date()
                        storedID = existing.id
                        return
                    }
                case .deleteTask:
                    let hasPendingCreate = pending.contains {
                        $0.type == PendingOperationType.createTask.rawValue && $0.entityID == entityID
                    }
                    let related = pending.filter { $0.entityID == entityID }
                    realm.delete(related)
                    if hasPendingCreate {
                        // The server never learned about this task.
                        return
                    }
                case .createTag, .updateTag:
                    if let existing = pending.first(where: {
                        $0.type == type.rawValue && $0.entityID == entityID
                    }) {
                        existing.payload = Self.encode(payload: payload)
                        existing.createdAt = Date()
                        storedID = existing.id
                        return
                    }
                case .deleteTag:
                    realm.delete(pending.filter { $0.entityID == entityID })
                case .questProgress:
                    // The quest progress itself is derived by the server from
                    // the replayed score operations, so one marker is enough.
                    if let existing = pending.first(where: { $0.type == type.rawValue }) {
                        existing.payload = Self.encode(payload: payload)
                        existing.createdAt = Date()
                        storedID = existing.id
                        return
                    }
                case .scoreTask, .scoreChecklist, .runCron, .moveTask:
                    break
                }
            }

            let operation = RealmPendingOperation()
            operation.id = UUID().uuidString
            operation.userID = userID
            operation.type = type.rawValue
            operation.entityID = entityID
            operation.payload = Self.encode(payload: payload)
            operation.createdAt = Date()
            operation.sequence = (pending.max(ofProperty: "sequence") ?? 0) + 1
            realm.add(operation)
            storedID = operation.id
        }
        postDidChange()
        return storedID
    }

    // MARK: - Read

    /// Value snapshots of the operations that are due to be replayed, oldest first.
    public func snapshots(userID: String, includeBackoff: Bool = false) -> [PendingOperationSnapshot] {
        guard let realm = getRealm() else {
            return []
        }
        realm.refresh()
        let backoffPredicate = includeBackoff
            ? NSPredicate(value: true)
            : NSPredicate(format: "nextAttemptAt == nil OR nextAttemptAt <= %@", Date())
        return realm.objects(RealmPendingOperation.self)
            .filter("userID == %@", userID)
            .filter(backoffPredicate)
            .sorted(byKeyPath: "sequence", ascending: true)
            .compactMap { PendingOperationSnapshot(operation: $0) }
    }

    /// Points queued operations for a locally created entity at the id the
    /// server assigned. A task created offline gets a client UUID; once the
    /// server answers with its own id, later scores and edits must target that
    /// one or they would be replayed against an unknown task.
    public func remapEntity(oldID: String, newID: String, userID: String) {
        guard oldID != newID else {
            return
        }
        updateCall { realm in
            let operations = realm.objects(RealmPendingOperation.self)
                .filter("userID == %@ AND entityID == %@", userID, oldID)
            for operation in operations {
                operation.entityID = newID
            }
        }
    }

    public func pendingCount(userID: String) -> Int {
        guard let realm = getRealm() else {
            return 0
        }
        realm.refresh()
        return realm.objects(RealmPendingOperation.self).filter("userID == %@", userID).count
    }

    public func hasOperation(type: PendingOperationType, userID: String, entityID: String? = nil) -> Bool {
        guard let realm = getRealm() else {
            return false
        }
        realm.refresh()
        var operations = realm.objects(RealmPendingOperation.self)
            .filter("userID == %@ AND type == %@", userID, type.rawValue)
        if let entityID = entityID {
            operations = operations.filter("entityID == %@", entityID)
        }
        return operations.isEmpty == false
    }

    // MARK: - Mutate

    public func delete(operationID: String) {
        updateCall { realm in
            if let operation = realm.object(ofType: RealmPendingOperation.self, forPrimaryKey: operationID) {
                realm.delete(operation)
            }
        }
        postDidChange()
    }

    public func recordFailure(operationID: String, error: String?, retryDelay: TimeInterval) {
        updateCall { realm in
            guard let operation = realm.object(ofType: RealmPendingOperation.self, forPrimaryKey: operationID) else {
                return
            }
            operation.attempts += 1
            operation.lastError = error
            operation.nextAttemptAt = Date(timeIntervalSinceNow: retryDelay)
        }
        postDidChange()
    }

    public func clear(userID: String) {
        updateCall { realm in
            realm.delete(realm.objects(RealmPendingOperation.self).filter("userID == %@", userID))
        }
        postDidChange()
    }

    // MARK: - Helpers

    private static func encode(payload: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
