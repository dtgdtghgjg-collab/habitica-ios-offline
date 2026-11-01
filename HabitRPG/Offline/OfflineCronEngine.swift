//
//  OfflineCronEngine.swift
//  Habitica
//
//  Runs the daily rollover locally while the app has no connection, so the
//  player still sees a fresh set of dailies in the morning. The server cron is
//  queued as well and reconciles the authoritative values later.
//

import Foundation
import UIKit
import ReactiveSwift
import Habitica_Models
import Habitica_Database

final class OfflineCronEngine {

    static let shared = OfflineCronEngine()

    private let taskLocalRepository = TaskLocalRepository()
    private let userLocalRepository = UserLocalRepository()
    private let gameRepository = OfflineGameContentRepository()
    private let mutationRepository = OfflineMutationRepository()
    private let disposable = ScopedDisposable(CompositeDisposable())
    private var hasStarted = false

    private init() {}

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        runIfNeeded()

        disposable.inner.add(NotificationCenter.default.reactive
            .notifications(forName: UIApplication.didBecomeActiveNotification)
            .observeValues { [weak self] _ in
                self?.runIfNeeded()
            })

        disposable.inner.add(NetworkMonitor.shared.isOnline.producer
            .skipRepeats()
            .startWithValues { [weak self] isOnline in
                if !isOnline {
                    self?.runIfNeeded()
                }
            })
    }

    private var lastCronKey: String {
        return "offlineLastCron_\(OfflineState.shared.currentUserID ?? "")"
    }

    /// Call on launch, on foreground and when connectivity drops.
    func runIfNeeded() {
        guard OfflineState.shared.isOffline,
              let userID = OfflineState.shared.currentUserID,
              let user = userLocalRepository.getUserAsync(userID),
              let stats = user.stats else {
            return
        }

        let dayStart = user.preferences?.dayStart ?? 0
        let now = Date()
        let defaults = UserDefaults.standard
        let lastCron = defaults.object(forKey: lastCronKey) as? Date

        guard let previousCron = lastCron ?? user.lastCron else {
            // First launch with no reference point: adopt "now" and wait for
            // the next rollover instead of inventing damage.
            defaults.set(now, forKey: lastCronKey)
            return
        }

        let missedDays = habiticaDaysBetween(previousCron, and: now, dayStart: dayStart)
        guard missedDays > 0 else {
            return
        }

        let dailies = taskLocalRepository.getTasksAsync(userID: userID,
                                                        predicate: NSPredicate(format: "type == 'daily'"),
                                                        sortKey: "order") ?? []
        let uncompletedDailies = dailies.filter { !$0.completed && !$0.isGroupTask }

        // Apply at most a week of damage; the server is the source of truth for
        // anything longer.
        for _ in 0..<min(missedDays, 7) {
            applyCronDamage(tasks: uncompletedDailies, userID: userID, stats: stats, user: user)
        }

        mutationRepository.resetDailiesForNewDay(userID: userID)
        OfflineSyncEngine.shared.enqueueCron()

        defaults.set(now, forKey: lastCronKey)
    }

    private func applyCronDamage(tasks: [TaskProtocol],
                                 userID: String,
                                 stats: StatsProtocol,
                                 user: UserProtocol) {
        var currentStats = LocalStats(health: stats.health,
                                      mana: stats.mana,
                                      experience: stats.experience,
                                      gold: stats.gold,
                                      level: stats.level,
                                      points: stats.points,
                                      strength: stats.strength,
                                      intelligence: stats.intelligence,
                                      constitution: stats.constitution,
                                      perception: stats.perception)

        // Gear and buffs reduce cron damage through CON, exactly as they do
        // when the server runs cron.
        let computed = LocalComputedStats(gear: gameRepository.statBonuses(userID: userID),
                                          buffs: OfflineStatBonuses(strength: Float(stats.buffs?.strength ?? 0),
                                                                    intelligence: Float(stats.buffs?.intelligence ?? 0),
                                                                    constitution: Float(stats.buffs?.constitution ?? 0),
                                                                    perception: Float(stats.buffs?.perception ?? 0)),
                                          habitClass: stats.habitClass)

        for task in tasks {
            guard let taskID = task.id else {
                continue
            }
            let input = LocalScoreInput(taskValue: task.value,
                                        taskType: task.type ?? "",
                                        taskPriority: task.priority,
                                        taskStreak: task.streak,
                                        counterUp: task.counterUp,
                                        counterDown: task.counterDown,
                                        checklistTotal: task.checklist.count,
                                        checklistCompleted: task.checklist.filter { $0.completed }.count,
                                        isGroupTask: task.isGroupTask,
                                        stats: currentStats,
                                        direction: .down,
                                        times: 1,
                                        cron: true,
                                        automaticAllocation: user.preferences?.automaticAllocation ?? false,
                                        computed: computed)
            let outcome = LocalScoreCalculator.score(input)
            currentStats = outcome.stats

            let taskUpdate = OfflineTaskScoreUpdate(taskID: taskID,
                                                    value: outcome.value,
                                                    completed: false,
                                                    streak: outcome.streak,
                                                    counterUp: outcome.counterUp,
                                                    counterDown: outcome.counterDown,
                                                    historyAction: .none,
                                                    historyValue: outcome.value,
                                                    historyDate: Date(),
                                                    isDue: false)
            mutationRepository.applyScore(userID: userID, taskUpdate: taskUpdate, statsUpdate: nil)
        }

        let statsUpdate = OfflineUserStatsUpdate(health: currentStats.health,
                                                 mana: currentStats.mana,
                                                 experience: currentStats.experience,
                                                 gold: currentStats.gold,
                                                 level: currentStats.level,
                                                 points: currentStats.points,
                                                 toNextLevel: LocalScoreCalculator.toNextLevel(currentStats.level),
                                                 strength: currentStats.strength,
                                                 intelligence: currentStats.intelligence,
                                                 constitution: currentStats.constitution,
                                                 perception: currentStats.perception)
        mutationRepository.applyScore(userID: userID, taskUpdate: nil, statsUpdate: statsUpdate)
    }

    // MARK: - Day maths

    private func habiticaDaysBetween(_ from: Date, and to: Date, dayStart: Int) -> Int {
        let calendar = Calendar.current
        let fromStart = habiticaDayStart(for: from, dayStart: dayStart, calendar: calendar)
        let toStart = habiticaDayStart(for: to, dayStart: dayStart, calendar: calendar)
        let components = calendar.dateComponents([.day], from: fromStart, to: toStart)
        return max(0, components.day ?? 0)
    }

    private func habiticaDayStart(for date: Date, dayStart: Int, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let shifted = calendar.date(byAdding: .hour, value: dayStart, to: startOfDay) ?? startOfDay
        if date < shifted {
            return calendar.date(byAdding: .day, value: -1, to: shifted) ?? shifted
        }
        return shifted
    }
}
