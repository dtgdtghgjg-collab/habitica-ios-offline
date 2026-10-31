//
//  OfflineScoreEngine.swift
//  Habitica
//
//  Scores a task without the network: mutates Realm optimistically and queues
//  the score so the server can replay it later.
//

import Foundation
import ReactiveSwift
import Habitica_Models
import Habitica_Database

struct OfflineTaskResponseQuest: TaskResponseQuestProtocol {
    var progressDelta: Float
    var collection: Int?
}

struct OfflineTaskResponseDrop: TaskResponseDropProtocol {
    var key: String?
    var type: String?
    var dialog: String?
}

struct OfflineTaskResponseTemp: TaskResponseTempProtocol {
    var quest: TaskResponseQuestProtocol?
    var drop: TaskResponseDropProtocol?
}

struct OfflineTaskResponse: TaskResponseProtocol {
    var delta: Float?
    var level: Int?
    var gold: Float?
    var experience: Float?
    var health: Float?
    var magic: Float?
    var temp: TaskResponseTempProtocol?
}

/// A value copy of the stats taken before a score.
///
/// `StatsProtocol` is a live Realm object, and the offline score writes the new
/// values into Realm before the caller's `on(value:)` runs. Reading the object
/// at that point would return the post-score numbers and every toast diff would
/// be zero, so the engine hands out this immutable snapshot instead.
struct OfflineStatsSnapshot {
    var health: Float
    var mana: Float
    var experience: Float
    var level: Int
    var toNextLevel: Float
    var gold: Float

    init(health: Float,
         mana: Float,
         experience: Float,
         level: Int,
         toNextLevel: Float,
         gold: Float) {
        self.health = health
        self.mana = mana
        self.experience = experience
        self.level = level
        self.toNextLevel = toNextLevel
        self.gold = gold
    }

    init(stats: StatsProtocol) {
        self.init(health: stats.health,
                  mana: stats.mana,
                  experience: stats.experience,
                  level: stats.level,
                  toNextLevel: stats.toNextLevel,
                  gold: stats.gold)
    }
}

final class OfflineScoreEngine {

    static let shared = OfflineScoreEngine()

    private let taskLocalRepository = TaskLocalRepository()
    private let userLocalRepository = UserLocalRepository()
    private let gameRepository = OfflineGameContentRepository()
    private let mutationRepository = OfflineMutationRepository()
    private let pendingRepository = PendingOperationRepository()

    private init() {}

    /// The stats before a score, used to compute the toast diffs.
    ///
    /// The snapshot is a value type: `score(task:direction:)` writes the new
    /// values into Realm before the returned signal delivers its value, so a
    /// live `StatsProtocol` object would already be post-score.
    func currentStats() -> OfflineStatsSnapshot? {
        guard let userID = OfflineState.shared.currentUserID,
              let user = userLocalRepository.getUserAsync(userID),
              let stats = user.stats else {
            return nil
        }
        return OfflineStatsSnapshot(stats: stats)
    }

    /// Scores a task locally and enqueues the operation.
    /// Returns the same shape as the API so callers can show their usual toasts.
    func score(task: TaskProtocol, direction: TaskScoringDirection) -> Signal<TaskResponseProtocol?, Never> {
        guard let taskID = task.id,
              let userID = OfflineState.shared.currentUserID,
              let localTask = taskLocalRepository.getEditableTask(id: taskID),
              let user = userLocalRepository.getUserAsync(userID),
              let stats = user.stats else {
            return Signal.empty
        }

        let computed = LocalComputedStats(gear: gameRepository.statBonuses(userID: userID),
                                          buffs: buffBonuses(stats: stats),
                                          habitClass: stats.habitClass)
        let input = LocalScoreInput(taskValue: localTask.value,
                                    taskType: localTask.type ?? "",
                                    taskPriority: localTask.priority,
                                    taskStreak: localTask.streak,
                                    counterUp: localTask.counterUp,
                                    counterDown: localTask.counterDown,
                                    checklistTotal: localTask.checklist.count,
                                    checklistCompleted: localTask.checklist.filter { $0.completed }.count,
                                    isGroupTask: localTask.isGroupTask,
                                    stats: LocalStats(health: stats.health,
                                                      mana: stats.mana,
                                                      experience: stats.experience,
                                                      gold: stats.gold,
                                                      level: stats.level,
                                                      points: stats.points,
                                                      strength: stats.strength,
                                                      intelligence: stats.intelligence,
                                                      constitution: stats.constitution,
                                                      perception: stats.perception),
                                    direction: direction,
                                    times: 1,
                                    cron: false,
                                    automaticAllocation: user.preferences?.automaticAllocation ?? false,
                                    computed: computed,
                                    quest: questContext(userID: userID, user: user),
                                    drops: dropContext(userID: userID, user: user, stats: stats),
                                    randomizer: LocalDeviceRandomizer(userID: userID))
        let outcome = LocalScoreCalculator.score(input)

        let taskUpdate = OfflineTaskScoreUpdate(taskID: taskID,
                                                value: outcome.value,
                                                completed: outcome.completed,
                                                streak: outcome.streak,
                                                counterUp: outcome.counterUp,
                                                counterDown: outcome.counterDown,
                                                historyAction: outcome.historyAction,
                                                historyValue: outcome.value,
                                                historyDate: Date(),
                                                isDue: localTask.isDue)
        let statsUpdate = OfflineUserStatsUpdate(health: outcome.stats.health,
                                                 mana: outcome.stats.mana,
                                                 experience: outcome.stats.experience,
                                                 gold: outcome.stats.gold,
                                                 level: outcome.stats.level,
                                                 points: outcome.stats.points,
                                                 toNextLevel: LocalScoreCalculator.toNextLevel(outcome.stats.level),
                                                 strength: outcome.stats.strength,
                                                 intelligence: outcome.stats.intelligence,
                                                 constitution: outcome.stats.constitution,
                                                 perception: outcome.stats.perception)

        mutationRepository.applyScore(userID: userID, taskUpdate: taskUpdate, statsUpdate: statsUpdate)
        applyDrops(outcome.drops, userID: userID)
        let questUpdate = applyQuest(outcome.quest, userID: userID, context: input.quest)
        applyAchievements(outcome.achievements, userID: userID)

        // Standalone mode is source-of-truth: queueing a score against the
        // server would let a later replay roll back locally earned progress.
        if !OfflineState.shared.isStandalone {
            pendingRepository.enqueue(type: .scoreTask,
                                      userID: userID,
                                      entityID: taskID,
                                      payload: ["direction": direction.rawValue])
            if questUpdate {
                pendingRepository.enqueue(type: .questProgress, userID: userID, entityID: "quest")
            }
        }

        OfflineState.shared.refreshPendingCount()

        let response = OfflineTaskResponse(delta: outcome.delta,
                                           level: outcome.stats.level,
                                           gold: outcome.stats.gold,
                                           experience: outcome.stats.experience,
                                           health: outcome.stats.health,
                                           magic: outcome.stats.mana,
                                           temp: tempResponse(drops: outcome.drops, quest: outcome.quest))
        return Signal(value: response)
    }

    // MARK: - Context

    private func buffBonuses(stats: StatsProtocol) -> OfflineStatBonuses {
        guard let buffs = stats.buffs else {
            return .zero
        }
        return OfflineStatBonuses(strength: Float(buffs.strength),
                                  intelligence: Float(buffs.intelligence),
                                  constitution: Float(buffs.constitution),
                                  perception: Float(buffs.perception))
    }

    private func questContext(userID: String, user: UserProtocol) -> LocalQuestContext? {
        guard let quest = user.party?.quest,
              quest.active,
              let key = quest.key,
              let definition = gameRepository.questDefinition(key: key),
              let progress = quest.progress else {
            return nil
        }

        // `members` can be empty in a partial payload; in that case the active
        // flag is the only signal we have.
        let members = quest.members
        let isOnQuest = members.isEmpty
            || members.contains { $0.userID == userID && $0.accepted }
        guard isOnQuest else {
            return nil
        }

        var collected = [String: Int]()
        for item in progress.collect {
            if let itemKey = item.key {
                collected[itemKey] = item.count
            }
        }

        return LocalQuestContext(isActive: !(user.preferences?.sleep ?? false),
                                 isOnQuest: true,
                                 definition: definition,
                                 state: LocalQuestProgressState(health: progress.health,
                                                                rage: progress.rage,
                                                                up: progress.up,
                                                                collectedItems: progress.collectedItems,
                                                                collected: collected),
                                 progressDown: 0)
    }

    private func dropContext(userID: String, user: UserProtocol, stats: StatsProtocol) -> LocalDropContext {
        let defaults = UserDefaults.standard
        let lastDropDate = defaults.object(forKey: Self.dropDateKey(userID: userID)) as? Date
        let lastDropCount = defaults.integer(forKey: Self.dropCountKey(userID: userID))
        let achievements = user.achievements

        return LocalDropContext(tables: gameRepository.dropTables(),
                                inventory: gameRepository.inventorySnapshot(userID: userID),
                                isSubscriber: user.purchased?.subscriptionPlan?.isActive ?? false,
                                contributorLevel: user.contributor?.level ?? 0,
                                rebirths: achievements?.rebirths ?? 0,
                                streakAchievements: achievements?.streak ?? 0,
                                playerLevel: stats.level,
                                dayStart: user.preferences?.dayStart ?? 0,
                                now: Date(),
                                state: LocalDropState(lastDropDate: lastDropDate,
                                                      lastDropCount: lastDropCount),
                                isFirstTask: !(achievements?.completedTask ?? false))
    }

    // MARK: - Persistence

    private func applyDrops(_ drops: LocalDropResult?, userID: String) {
        guard let drops = drops else {
            return
        }
        mutationRepository.applyDrops(userID: userID, items: drops.items)

        let defaults = UserDefaults.standard
        if let date = drops.state.lastDropDate {
            defaults.set(date, forKey: Self.dropDateKey(userID: userID))
        } else {
            defaults.removeObject(forKey: Self.dropDateKey(userID: userID))
        }
        defaults.set(drops.state.lastDropCount, forKey: Self.dropCountKey(userID: userID))
    }

    @discardableResult
    private func applyQuest(_ quest: LocalQuestOutcome?,
                            userID: String,
                            context: LocalQuestContext?) -> Bool {
        guard let quest = quest, let context = context,
              quest.progressDelta > 0 || quest.collection > 0 else {
            return false
        }
        let update = OfflineQuestProgressUpdate(health: quest.state.health,
                                                rage: quest.state.rage,
                                                progressUp: quest.state.up,
                                                collectedItems: quest.state.collectedItems,
                                                collected: quest.state.collected)
        mutationRepository.applyQuestProgress(userID: userID, update: update)

        // Standalone mode resolves the quest entirely on-device: killing the
        // boss or collecting every item grants the reward immediately.
        OfflineQuestManager.shared.completeIfNeeded(userID: userID,
                                                    definition: context.definition,
                                                    state: quest.state)
        return true
    }

    private func applyAchievements(_ achievements: LocalAchievementUpdate, userID: String) {
        guard achievements.isEmpty == false else {
            return
        }
        OfflineAchievementManager.shared.record(userID: userID,
                                            completedTask: achievements.completedTask,
                                            createdTask: achievements.createdTask,
                                            streakDelta: achievements.streakDelta)
    }

    // MARK: - Response

    private func tempResponse(drops: LocalDropResult?, quest: LocalQuestOutcome?) -> TaskResponseTempProtocol? {
        var questResponse: OfflineTaskResponseQuest?
        if let quest = quest {
            questResponse = OfflineTaskResponseQuest(progressDelta: quest.progressDelta,
                                                     collection: quest.collection > 0 ? quest.collection : nil)
        }

        var dropResponse: OfflineTaskResponseDrop?
        if let drop = drops?.items.first {
            dropResponse = OfflineTaskResponseDrop(key: drop.key,
                                                   type: drop.responseType,
                                                   dialog: drops?.dialog ?? drop.dialog)
        }

        guard questResponse != nil || dropResponse != nil else {
            return nil
        }
        return OfflineTaskResponseTemp(quest: questResponse, drop: dropResponse)
    }

    private static func dropDateKey(userID: String) -> String {
        return "offlineLastDropDate_\(userID)"
    }

    private static func dropCountKey(userID: String) -> String {
        return "offlineLastDropCount_\(userID)"
    }
}
