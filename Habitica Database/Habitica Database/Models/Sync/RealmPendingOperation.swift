//
//  RealmPendingOperation.swift
//  Habitica Database
//
//  Persisted queue of writes that could not be sent to the server yet.
//

import Foundation
import RealmSwift

public enum PendingOperationType: String {
    case createTask
    case updateTask
    case deleteTask
    case scoreTask
    case scoreChecklist
    case questProgress
    case moveTask
    case createTag
    case updateTag
    case deleteTag
    case runCron

    /// Operations that change game state and must be replayed in the exact
    /// order the user performed them.
    public var isOrderSensitive: Bool {
        switch self {
        case .scoreTask, .scoreChecklist, .runCron:
            return true
        default:
            return false
        }
    }
}

/// A single write that is waiting to be replayed against the API.
///
/// `payload` is a small JSON dictionary. It never contains a full task: when an
/// operation is replayed the current local state is read from Realm, so a
/// coalesced queue always sends the newest version of an object.
public class RealmPendingOperation: Object {
    @objc public dynamic var id: String = ""
    @objc public dynamic var userID: String = ""
    @objc public dynamic var type: String = ""
    @objc public dynamic var entityID: String?
    @objc public dynamic var payload: String?
    @objc public dynamic var createdAt: Date = Date()
    @objc public dynamic var sequence: Int = 0
    @objc public dynamic var attempts: Int = 0
    @objc public dynamic var nextAttemptAt: Date?
    @objc public dynamic var lastError: String?

    public var operationType: PendingOperationType? {
        return PendingOperationType(rawValue: type)
    }

    public var payloadDictionary: [String: String] {
        guard let payload = payload, let data = payload.data(using: .utf8) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public override static func primaryKey() -> String? {
        return "id"
    }
}

/// A value snapshot of a queued operation.
///
/// The sync engine works with these instead of live `RealmPendingOperation`
/// objects: coalescing can delete a queued row at any moment (for example when
/// the user deletes a task that is still waiting to be uploaded), and touching
/// a deleted Realm object would crash.
public struct PendingOperationSnapshot {
    public let id: String
    public let userID: String
    public let type: PendingOperationType
    public let entityID: String?
    public let payload: [String: String]
    public let sequence: Int
    public let attempts: Int

    init?(operation: RealmPendingOperation) {
        guard let type = operation.operationType else {
            return nil
        }
        id = operation.id
        userID = operation.userID
        self.type = type
        entityID = operation.entityID
        payload = operation.payloadDictionary
        sequence = operation.sequence
        attempts = operation.attempts
    }
}
