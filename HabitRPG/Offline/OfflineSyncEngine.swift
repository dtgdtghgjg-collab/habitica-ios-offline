//
//  OfflineSyncEngine.swift
//  Habitica
//
//  Fully offline: no server sync, no replay queue. Stub kept for compatibility.
//

import Foundation
import RealmSwift
import ReactiveSwift
import Habitica_Models
import Habitica_Database

final class OfflineSyncEngine {

    static let shared = OfflineSyncEngine()

    private init() {}

    func start() {
        // Fully offline: no sync, no retry timers.
    }

    func enqueueCreate(task: TaskProtocol) {}
    func enqueueUpdate(task: TaskProtocol) {}
    func enqueueDelete(task: TaskProtocol) {}
    func enqueueMove(task: TaskProtocol, toPosition: Int) {}
    func enqueueCron() {}
    func enqueueTag(_ tag: TagProtocol, isNew: Bool) {}
    func enqueueDeleteTag(_ tag: TagProtocol) {}
    func enqueueBuy(key: String, quantity: Int) {}
    func enqueueEquip(type: String, key: String) {}
    func enqueueHatch(egg: String, potion: String) {}
    func enqueueFeed(pet: String, food: String) {}
    func enqueuePurchase(purchaseType: String, key: String, quantity: Int, value: Int) {}
    func enqueuePurchaseQuest(key: String) {}

    func flushIfPossible() {
        // Fully offline: never flush to the server.
    }
}