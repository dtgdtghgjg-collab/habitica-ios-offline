//
//  LocalScoreCalculator.swift
//  Habitica
//
//  A Swift port of the parts of Habitica's scoring that change a single task
//  and the user's stats. It mirrors the server so that an optimistic offline
//  score looks the same as the authoritative one that arrives after the queue
//  is replayed.
//
//  Covered here:
//  * task value delta and streak/counter bookkeeping;
//  * critical hits (`LocalCrit`);
//  * gear, class and buff bonuses (`LocalComputedStats`, `LocalClassBonus`);
//  * experience, gold, mana and health;
//  * local loot drops (`LocalDropGenerator`);
//  * quest progress and achievements (`LocalQuestProgress`).
//

import Foundation
import Habitica_Models
import Habitica_Database

struct LocalStats {
    var health: Float
    var mana: Float
    var experience: Float
    var gold: Float
    var level: Int
    var points: Int
    var strength: Int
    var intelligence: Int
    var constitution: Int
    var perception: Int
}

struct LocalAchievementUpdate {
    var completedTask: Bool = false
    var streakDelta: Int = 0
    var createdTask: Bool = false

    var isEmpty: Bool {
        return !completedTask && !createdTask && streakDelta == 0
    }
}

struct LocalScoreInput {
    var taskValue: Float
    var taskType: String
    var taskPriority: Float
    var taskStreak: Int
    var counterUp: Int
    var counterDown: Int
    var checklistTotal: Int
    var checklistCompleted: Int
    var isGroupTask: Bool
    var stats: LocalStats
    var direction: TaskScoringDirection
    var times: Int
    var cron: Bool
    var automaticAllocation: Bool
    /// Gear, class and buff bonuses. `.none` keeps the old behaviour.
    var computed: LocalComputedStats = .none
    /// The active party quest, if the player is on one.
    var quest: LocalQuestContext?
    /// Drop tables, inventory and the daily drop counter.
    var drops: LocalDropContext?
    var randomizer: LocalRandomizing = LocalSystemRandomizer()
}

struct LocalScoreOutcome {
    var value: Float
    var delta: Float
    var stats: LocalStats
    var streak: Int
    var counterUp: Int
    var counterDown: Int
    var completed: Bool
    var historyAction: OfflineHistoryAction
    var leveledUp: Bool
    var critMultiplier: Float
    var quest: LocalQuestOutcome?
    var drops: LocalDropResult?
    var achievements: LocalAchievementUpdate
}

enum LocalScoreCalculator {

    static let maxTaskValue: Float = 21.27
    static let minTaskValue: Float = -47.27
    static let maxHealth: Float = 50
    static let maxLevel: Int = 100
    static let maxStatPoints: Int = 500

    private struct ComputedStats {
        var strength: Float
        var intelligence: Float
        var constitution: Float
        var perception: Float
        var maxMana: Float
    }

    // MARK: - Entry point

    static func score(_ input: LocalScoreInput) -> LocalScoreOutcome {
        var stats = input.stats
        var value = clamp(input.taskValue)
        var streak = input.taskStreak
        var counterUp = input.counterUp
        var counterDown = input.counterDown
        var completed = false
        var historyAction: OfflineHistoryAction = .none
        var delta: Float = 0
        var leveledUp = false
        var achievements = LocalAchievementUpdate()

        let computed = computedStats(stats, input.computed)
        let classBonus = LocalClassBonus(habitClass: input.computed.habitClass,
                                         strength: computed.strength,
                                         intelligence: computed.intelligence,
                                         constitution: computed.constitution,
                                         perception: computed.perception)
        let critMultiplier = input.direction == .up
            ? LocalCrit.roll(classBonus: classBonus, randomizer: input.randomizer)
            : 1
        let direction = input.direction

        switch input.taskType {
        case "habit":
            delta = changeTaskValue(&value, input: input, computed: computed, cron: input.cron)
            if delta > 0 {
                addPoints(&stats, input: input, classBonus: classBonus,
                          delta: delta, critMultiplier: critMultiplier)
            } else {
                subtractPoints(&stats, input: input, classBonus: classBonus, delta: delta)
            }
            gainMP(&stats, computed: computed,
                   amount: max(0.25, 0.0025 * computed.maxMana)
                       * (direction == .down ? -1 : 1)
                       * critMultiplier)
            historyAction = .append
            if direction == .up {
                counterUp += input.times
            } else {
                counterDown += input.times
            }

        case "daily":
            if input.cron {
                delta = changeTaskValue(&value, input: input, computed: computed, cron: true)
                subtractPoints(&stats, input: input, classBonus: classBonus, delta: delta)
                streak = 0
            } else {
                delta = changeTaskValue(&value, input: input, computed: computed, cron: false)
                if direction == .down {
                    delta = calculateDelta(value: input.taskValue, input: input,
                                           computed: computed, cron: false)
                }
                addPoints(&stats, input: input, classBonus: classBonus,
                          delta: delta, critMultiplier: critMultiplier)
                gainMP(&stats, computed: computed,
                       amount: max(1, 0.01 * computed.maxMana)
                           * (direction == .down ? -1 : 1)
                           * critMultiplier)
                if direction == .up {
                    streak += 1
                    if streak % 21 == 0 {
                        achievements.streakDelta += 1
                    }
                    completed = true
                    historyAction = .append
                } else {
                    if streak != 0 && streak % 21 == 0 {
                        achievements.streakDelta -= 1
                    }
                    streak -= 1
                    completed = false
                    historyAction = .removeLast
                }
            }

        case "todo":
            if input.cron {
                delta = changeTaskValue(&value, input: input, computed: computed, cron: true)
            } else {
                if direction == .up {
                    completed = true
                } else {
                    completed = false
                }
                delta = changeTaskValue(&value, input: input, computed: computed, cron: false)
                if direction == .down {
                    delta = calculateDelta(value: input.taskValue, input: input,
                                           computed: computed, cron: false)
                }
                addPoints(&stats, input: input, classBonus: classBonus,
                          delta: delta, critMultiplier: critMultiplier)
                let checklistMultiplier = max(Float(input.checklistCompleted), 1)
                gainMP(&stats, computed: computed,
                       amount: max(checklistMultiplier,
                                   0.01 * computed.maxMana * checklistMultiplier)
                           * (direction == .down ? -1 : 1)
                           * critMultiplier)
            }

        case "reward":
            delta = changeTaskValue(&value, input: input, computed: computed, cron: input.cron)
            stats.gold -= input.taskValue

        default:
            break
        }

        if input.taskType != "reward", input.cron == false, direction == .up {
            leveledUp = applyExperience(&stats, input: input, computed: computed)
        }
        stats.experience = max(0, stats.experience)
        stats.health = max(0, min(stats.health, maxHealth))
        stats.gold = max(0, stats.gold)

        // The server unlocks "completedTask" on the first upward score.
        if input.cron == false && direction == .up {
            achievements.completedTask = true
        }

        let drops = rollDrops(input: input, value: value, streak: streak,
                              perception: computed.perception,
                              critMultiplier: critMultiplier)
        let quest = applyQuest(input: input, delta: delta,
                               strength: computed.strength,
                               critMultiplier: critMultiplier,
                               collectionItemsFound: drops?.collectionItemFound == true ? 1 : 0)

        return LocalScoreOutcome(value: value,
                                 delta: delta,
                                 stats: stats,
                                 streak: streak,
                                 counterUp: counterUp,
                                 counterDown: counterDown,
                                 completed: completed,
                                 historyAction: historyAction,
                                 leveledUp: leveledUp,
                                 critMultiplier: critMultiplier,
                                 quest: quest,
                                 drops: drops,
                                 achievements: achievements)
    }

    // MARK: - Drops and quests

    private static func rollDrops(input: LocalScoreInput,
                                  value: Float,
                                  streak: Int,
                                  perception: Float,
                                  critMultiplier: Float) -> LocalDropResult? {
        guard input.direction == .up,
              let context = input.drops,
              context.isFirstTask == false else {
            return nil
        }
        return LocalDropGenerator.generate(taskValue: value,
                                           taskPriority: input.taskPriority,
                                           taskStreak: streak,
                                           checklistCompleted: input.checklistCompleted,
                                           perception: perception,
                                           critMultiplier: critMultiplier,
                                           context: context,
                                           randomizer: input.randomizer)
    }

    private static func applyQuest(input: LocalScoreInput,
                                   delta: Float,
                                   strength: Float,
                                   critMultiplier: Float,
                                   collectionItemsFound: Int) -> LocalQuestOutcome? {
        guard input.direction == .up,
              input.taskType != "reward",
              let context = input.quest else {
            return nil
        }
        return LocalQuestProgress.apply(context: context,
                                        taskType: input.taskType,
                                        delta: delta,
                                        critMultiplier: critMultiplier,
                                        strength: strength,
                                        collectionItemsFound: collectionItemsFound,
                                        randomizer: input.randomizer)
    }

    // MARK: - Task value

    private static func clamp(_ value: Float) -> Float {
        return min(max(value, minTaskValue), maxTaskValue)
    }

    /// y = 0.9747^x, capped between the min and max task value.
    private static func calculateDelta(value: Float, input: LocalScoreInput, computed: ComputedStats, cron: Bool) -> Float {
        let currentValue = clamp(value)
        var delta = pow(0.9747, Double(currentValue))
        if input.direction == .down {
            delta = -delta
        }
        var result = Float(delta)

        if input.checklistTotal > 0 {
            if input.direction == .down && input.taskType == "daily" && cron {
                let completedRatio = Float(input.checklistCompleted) / Float(input.checklistTotal)
                result *= (1 - completedRatio)
            }
            if input.taskType == "todo" && !cron {
                result *= (1 + Float(input.checklistCompleted))
            }
        }
        return result
    }

    /// Approximates the reverse delta so unchecking a task restores its value.
    private static func calculateReverseDelta(value: Float, input: LocalScoreInput) -> Float {
        let currentValue = clamp(value)
        var testValue = currentValue + Float(pow(0.9747, Double(currentValue)))

        for _ in 0..<100 {
            let calculated = testValue + Float(pow(0.9747, Double(testValue)))
            let difference = currentValue - calculated
            if abs(difference) < 0.00001 {
                break
            }
            if difference > 0 {
                testValue -= difference
            } else {
                testValue += difference
            }
        }

        var result = testValue - currentValue
        if input.checklistTotal > 0 && input.taskType == "todo" {
            result *= (1 + Float(input.checklistCompleted))
        }
        return result
    }

    private static func changeTaskValue(_ value: inout Float, input: LocalScoreInput, computed: ComputedStats, cron: Bool) -> Float {
        var total: Float = 0
        for _ in 0..<max(1, input.times) {
            let delta: Float
            if !cron && input.direction == .down {
                delta = calculateReverseDelta(value: value, input: input)
            } else {
                delta = calculateDelta(value: value, input: input, computed: computed, cron: cron)
            }
            if input.taskType != "reward" {
                value += delta
            }
            total += delta
        }
        return total
    }

    // MARK: - Stats

    /// `statsComputed`: base stat + gear + class bonus + buffs +
    /// `floor(capByLevel(level) / 2)`.
    private static func computedStats(_ stats: LocalStats, _ extra: LocalComputedStats) -> ComputedStats {
        let levelBonus = Float(cappedLevel(stats.level) / 2)
        let strength = Float(stats.strength) + extra.gear.strength + extra.buffs.strength + levelBonus
        let intelligence = Float(stats.intelligence) + extra.gear.intelligence + extra.buffs.intelligence + levelBonus
        let constitution = Float(stats.constitution) + extra.gear.constitution + extra.buffs.constitution + levelBonus
        let perception = Float(stats.perception) + extra.gear.perception + extra.buffs.perception + levelBonus
        return ComputedStats(strength: strength,
                             intelligence: intelligence,
                             constitution: constitution,
                             perception: perception,
                             maxMana: intelligence * 2 + 30)
    }

    private static func cappedLevel(_ level: Int) -> Int {
        return min(max(level, 0), maxLevel)
    }

    private static func addPoints(_ stats: inout LocalStats,
                                  input: LocalScoreInput,
                                  classBonus: LocalClassBonus,
                                  delta: Float,
                                  critMultiplier: Float) {
        let experience = delta
            * classBonus.experienceMultiplier
            * input.taskPriority
            * critMultiplier
            * 6
        stats.experience += experience.rounded()

        let goldModifier = delta
            * input.taskPriority
            * critMultiplier
            * classBonus.goldMultiplier
        if input.taskStreak > 0 {
            let currentStreak = input.direction == .down ? input.taskStreak - 1 : input.taskStreak
            let streakBonus = Float(currentStreak) / 100 + 1
            var afterStreak = goldModifier * streakBonus
            if abs(afterStreak - goldModifier) < 1 {
                afterStreak = input.direction == .down ? goldModifier - 1 : goldModifier + 1
            }
            stats.gold += input.direction == .down ? afterStreak.rounded(.down) : afterStreak.rounded(.up)
        } else {
            stats.gold += input.direction == .down ? goldModifier.rounded(.down) : goldModifier.rounded(.up)
        }
    }

    private static func subtractPoints(_ stats: inout LocalStats,
                                       input: LocalScoreInput,
                                       classBonus: LocalClassBonus,
                                       delta: Float) {
        if input.isGroupTask && input.taskType == "daily" {
            return
        }
        let healthModifier = delta
            * classBonus.damageTakenMultiplier
            * input.taskPriority
            * 2
        if healthModifier > -1 {
            stats.health -= 1
        } else {
            stats.health += healthModifier.rounded(.up)
        }
    }

    private static func gainMP(_ stats: inout LocalStats, computed: ComputedStats, amount: Float) {
        if amount < 0 {
            stats.mana += amount.rounded(.down)
        } else {
            stats.mana += amount.rounded(.up)
        }
        stats.mana = min(stats.mana, computed.maxMana)
        stats.mana = max(stats.mana, 0)
    }

    private static func applyExperience(_ stats: inout LocalStats, input: LocalScoreInput, computed: ComputedStats) -> Bool {
        var leveledUp = false
        var experienceToNextLevel = toNextLevel(stats.level)

        while stats.experience >= experienceToNextLevel && stats.level < maxLevel {
            stats.experience -= experienceToNextLevel
            stats.level += 1
            stats.health = maxHealth

            let allocated = stats.strength + stats.intelligence + stats.constitution + stats.perception
            if allocated < maxStatPoints && !input.automaticAllocation {
                stats.points = max(0, stats.level - allocated)
                if stats.points + allocated > maxStatPoints {
                    stats.points = maxStatPoints - allocated
                }
            }
            experienceToNextLevel = toNextLevel(stats.level)
            leveledUp = true
        }
        return leveledUp
    }

    static func toNextLevel(_ level: Int) -> Float {
        if level < 5 {
            return Float(25 * level)
        }
        if level == 5 {
            return 150
        }
        let squared = Double(level * level)
        return Float((((squared * 0.25) + Double(10 * level) + 139.75) / 10).rounded() * 10)
    }
}
