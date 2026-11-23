//
//  TaskRepository.swift
//  Habitica
//
//  Created by Phillip Thelen on 14.02.18.
//  Copyright © 2018 HabitRPG Inc. All rights reserved.
//

import Foundation
import ReactiveSwift
import Habitica_Models
import Habitica_Database
import RealmSwift

enum UserQuestStatus {
    case noQuest
    case questCollect
    case questBoss
    case questUnknown
}

class TaskRepository: BaseRepository<TaskLocalRepository> {
    
    static var currentUserQuestStatus: UserQuestStatus = .noQuest
    static var currentQuestKey: String?
    
    func retrieveTasks(dueOnDay: Date? = nil) -> Signal<[TaskProtocol]?, Never> {
        // Fully offline: tasks come from Realm only.
        return Signal.empty
    }
    
    func retrieveCompletedTodos() -> Signal<[TaskProtocol]?, Never> {
        // Fully offline: completed todos come from Realm only.
        return Signal.empty
    }
    
    func clearCompletedTodos() -> Signal<[TaskProtocol]?, Never> {
        // Fully offline: no server clear, completed todos stay in Realm.
        return Signal.empty
    }
    
    func getTasks(predicate: NSPredicate, sortKey: String = "order") -> SignalProducer<ReactiveResults<[TaskProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getTasks(userID: userID, predicate: predicate, sortKey: sortKey) ?? SignalProducer.empty
        })
    }
    
    func getTasks(type: TaskType) -> SignalProducer<ReactiveResults<[TaskProtocol]>, ReactiveSwiftRealmError> {
        var predicate = NSPredicate(format: "type == %@", type.rawValue)
        if type == .todo {
            predicate = NSPredicate(format: "type == 'todo' && completed == false")
        }
        return getTasks(predicate: predicate)
    }
    
    func getDueTasks() -> SignalProducer<ReactiveResults<[TaskProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getTasks(userID: userID,
                                                  predicate: NSPredicate(format: "(type == 'daily' && isDue == true) || (type == 'todo' && completed == false)"),
                                                  sortKey: "order") ?? SignalProducer.empty
        })
    }
    
    func getTags() -> SignalProducer<ReactiveResults<[TagProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getTags(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func save(_ tasks: [TaskProtocol], order: [String: [String]]) {
        localRepository.save(userID: currentUserId, tasks: tasks, order: order)
    }
    
    func save(task: TaskProtocol) {
        localRepository.save(userID: currentUserId, task: task)
    }
        
    func score(task: TaskProtocol, direction: TaskScoringDirection) -> Signal<TaskResponseProtocol?, Never> {
        if !task.isValid {
            return Signal.empty
        }
        UIImpactFeedbackGenerator.oneShotImpactOccurred(.light)

        // Fully offline: scoring is always local, never the server.
        let previousStats = OfflineScoreEngine.shared.currentStats()
        return OfflineScoreEngine.shared.score(task: task, direction: direction)
            .on(value: { [weak self] response in
                guard let response = response, let previousStats = previousStats else {
                    return
                }
                self?.handleScoreResponse(task: task,
                                          response: response,
                                          stats: nil,
                                          previousStats: previousStats,
                                          direction: direction,
                                          applyLocalUpdate: false)
            })
    }

    private func handleScoreResponse(task: TaskProtocol,
                                     response: TaskResponseProtocol,
                                     stats: StatsProtocol?,
                                     previousStats: OfflineStatsSnapshot,
                                     direction: TaskScoringDirection,
                                     applyLocalUpdate: Bool) {
        if !task.isValid {
            return
        }

        let healthDiff = (response.health ?? 0) - previousStats.health
        let magicDiff = (response.magic ?? 0) - previousStats.mana
        var expDiff = (response.experience ?? 0) - previousStats.experience
        if previousStats.level < (response.level ?? 0) {
            let levelUpView = HostingBottomSheetController(rootView: LevelupSheet(), prefersGrabberVisible: false)
            levelUpView.show()
            SoundManager.shared.play(effect: .levelUp)

            expDiff = previousStats.toNextLevel - previousStats.experience + (response.experience ?? 0)
        }
        let goldDiff = (response.gold ?? 0) - previousStats.gold
        let questDamage = (response.temp?.quest?.progressDelta ?? 0)

        // Offline scoring already wrote the optimistic task value; applying the
        // server delta on top of it would double count.
        if applyLocalUpdate, let taskId = task.id, let stats = stats {
            localRepository.update(taskID: taskId,
                                   userID: currentUserId ?? "",
                                   stats: stats,
                                   direction: direction,
                                   response: response)
        }
        if task.type == "reward" {
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            ToastManager.show(text: L10n.buyReward(task.text ?? "", formatter.string(from: NSNumber(value: task.value)) ?? ""), color: .green)
        } else if healthDiff + magicDiff + goldDiff + questDamage != 0 && (response.level ?? 0) > 0 {
            let questDamageToShow: Float = {
                switch TaskRepository.currentUserQuestStatus {
                case .questBoss:
                    return questDamage
                default:
                    return 0
                }
            }()

            let toastView = ToastView(healthDiff: healthDiff,
                                      magicDiff: magicDiff,
                                      expDiff: expDiff,
                                      goldDiff: goldDiff,
                                      questDamage: questDamageToShow,
                                      background: healthDiff >= 0 ? .green : .red)
            ToastManager.show(toast: toastView)
        }
        if let drop = response.temp?.drop {
            ToastManager.show(text: drop.dialog ?? "You found a \(drop.key ?? "")", color: .gray)
        }
        if TaskRepository.currentUserQuestStatus == .questCollect,
           let questItemsFound = response.temp?.quest?.collection,
           questItemsFound > 0 {
            ToastManager.show(text: questItemsFound == 1 ? L10n.oneQuestItemFound : L10n.questItemsFound(questItemsFound), color: .gray)
        }
    }
    
    func score(checklistItem: ChecklistItemProtocol, task: TaskProtocol) -> Signal<TaskProtocol?, Never> {
        // Fully offline: checklist items are scored locally only.
        localRepository.save(userID: currentUserId, task: task)
        return Signal<TaskProtocol?, Never> { observer, _ in
            observer.send(value: task)
            observer.sendCompleted()
        }
    }
    
    func getNewTask() -> TaskProtocol {
        return localRepository.getNewTask()
    }
    
    func getNewTag(id: String? = nil) -> TagProtocol {
        return localRepository.getNewTag(id: id)
    }
    
    func getNewChecklistItem() -> ChecklistItemProtocol {
        return localRepository.getNewChecklistItem()
    }
    
    func getNewReminder() -> ReminderProtocol {
        return localRepository.getNewReminder()
    }
    
    func getEditableTask(id: String) -> TaskProtocol? {
        return localRepository.getEditableTask(id: id)
    }
    
    func getEditableTag(id: String) -> TagProtocol? {
        return localRepository.getEditableTag(id: id)
    }
    
    func createTask(_ task: TaskProtocol) -> Signal<TaskProtocol?, Never> {
        // Fully offline: tasks are created locally only.
        return saveTaskOffline(task, isNew: true)
    }

    /// Stores a task locally and queues it for the next successful sync.
    @discardableResult
    private func saveTaskOffline(_ task: TaskProtocol, isNew: Bool) -> Signal<TaskProtocol?, Never> {
        // `task` is usually the Realm object the form just built, so touching
        // its properties is a Realm write and must happen inside a transaction.
        Self.markTaskForSync(task, isNew: isNew)
        localRepository.save(userID: currentUserId, task: task)
        if isNew {
            OfflineSyncEngine.shared.enqueueCreate(task: task)
            if let userID = currentUserId {
                OfflineMutationRepository().applyAchievements(userID: userID, createdTask: true)
            }
        } else {
            OfflineSyncEngine.shared.enqueueUpdate(task: task)
        }
        return Signal<TaskProtocol?, Never> { observer, _ in
            observer.send(value: task)
            observer.sendCompleted()
        }
    }

    /// Sets the sync flags on a task.
    ///
    /// Writing to a Realm-managed object outside a write transaction throws
    /// "Attempting to modify object outside of a write transaction", so the
    /// flags are applied inside one. Objects that are not managed yet (a fresh
    /// task built from the form) are written directly: Realm persists their
    /// values when they are added.
    private static func markTaskForSync(_ task: TaskProtocol, isNew: Bool) {
        applyRealmFlags(to: task) {
            task.isNewTask = isNew
            task.isSynced = false
            task.isSyncing = false
        }
    }

    /// Marks a task the server has accepted as created and synced.
    private static func markTaskSynced(_ task: TaskProtocol) {
        applyRealmFlags(to: task) {
            task.isNewTask = false
            task.isSynced = true
        }
    }

    /// Runs `apply` inside a write transaction when `task` is managed by Realm,
    /// and directly otherwise.
    private static func applyRealmFlags(to task: TaskProtocol, _ apply: () -> Void) {
        guard let object = task as? Object, let realm = object.realm else {
            apply()
            return
        }
        if realm.isInWriteTransaction {
            apply()
            return
        }
        try? realm.write {
            apply()
        }
    }

    func createChallengeTask(challengeID: String, task: TaskProtocol) -> Signal<TaskProtocol?, Never> {
        // Fully offline: no server challenges.
        return Signal.empty
    }
    
    func createTasks(_ tasks: [TaskProtocol]) -> Signal<[TaskProtocol]?, Never> {
        // Fully offline: tasks are created locally only.
        return Signal.empty
    }
    
    func updateTask(_ task: TaskProtocol) -> Signal<TaskProtocol?, Never> {
        // Fully offline: tasks are updated locally only.
        return saveTaskOffline(task, isNew: task.isNewTask)
    }
    
    func syncTask(_ task: TaskProtocol) -> Signal<TaskProtocol?, Never> {
        if task.isNewTask {
            return self.createTask(task)
        } else {
            return self.updateTask(task)
        }
        
    }
    
    func deleteTask(_ task: TaskProtocol) -> Signal<EmptyResponseProtocol?, Never> {
        if !task.isValid {
            return Signal.empty
        }
        // Fully offline: tasks are deleted locally only.
        localRepository.deleteTask(task)
        return Signal<EmptyResponseProtocol?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
    }
    
    func createTag(_ tag: TagProtocol) -> Signal<TagProtocol?, Never> {
        // Fully offline: tags are created locally only.
        if tag.id?.isEmpty == false {
            localRepository.save(userID: currentUserId, tag: tag)
        }
        return Signal<TagProtocol?, Never> { observer, _ in
            observer.send(value: tag)
            observer.sendCompleted()
        }
    }
    
    func updateTag(_ tag: TagProtocol) -> Signal<TagProtocol?, Never> {
        // Fully offline: tags are updated locally only.
        if !tag.isManaged {
            localRepository.save(userID: currentUserId, tag: tag)
        }
        return Signal<TagProtocol?, Never> { observer, _ in
            observer.send(value: tag)
            observer.sendCompleted()
        }
    }
    
    func deleteTag(_ tag: TagProtocol) -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: tags are deleted locally only.
        localRepository.deleteTag(tag)
        return Signal<EmptyResponseProtocol?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
    }
    
    func moveTask(_ task: TaskProtocol, toPosition: Int) -> Signal<[String]?, Never> {
        // Fully offline: task order changes locally only.
        fixTaskOrder(movedTask: task, toPosition: toPosition)
        return Signal<[String]?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
    }
    
    func fixTaskOrder(movedTask: TaskProtocol, toPosition: Int) {
        localRepository.fixTaskOrder(movedTask: movedTask, toPosition: toPosition)
    }
    
    func getReminders() -> SignalProducer<ReactiveResults<[ReminderProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getReminders(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func getChallengeTasks(id challengeID: String) -> SignalProducer<ReactiveResults<[TaskProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getTasks(userID: userID,
                                                  predicate: NSPredicate(format: "(challengeID == '\(challengeID)')"),
                                                  sortKey: "order") ?? SignalProducer.empty
        })
    }
    
    func unlinkAllTasks(challengeID: String, keepOption: String) -> Signal<[TaskProtocol]?, Never> {
        // Fully offline: no server challenges to unlink from.
        return Signal.empty
    }

    func unlinkOneTask(task: TaskProtocol, keepOption: String) -> Signal<[TaskProtocol]?, Never> {
        // Fully offline: no server challenges to unlink from.
        if keepOption == "remove" {
            localRepository.deleteTask(task)
        }
        return Signal.empty
    }
}
