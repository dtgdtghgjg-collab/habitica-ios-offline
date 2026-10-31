//
//  LocalDropGenerator.swift
//  Habitica
//
//  Local loot drops, ported from `website/common/script/fns/randomDrop.js`.
//
//  The generator is pure: it never touches Realm. It receives the content
//  tables, the player's inventory snapshot and the persisted daily counter,
//  and returns the items to add plus the new counter. `OfflineScoreEngine`
//  writes both.
//

import Foundation
import Habitica_Models
import Habitica_Database

/// Habitica limits how many items a player can receive per Habitica day.
struct LocalDropState {
    var lastDropDate: Date?
    var lastDropCount: Int

    static let empty = LocalDropState(lastDropDate: nil, lastDropCount: 0)
}

struct LocalDropContext {
    var tables: OfflineDropTables
    var inventory: OfflineInventorySnapshot
    var isSubscriber: Bool
    var contributorLevel: Int
    var rebirths: Int
    var streakAchievements: Int
    var playerLevel: Int
    var dayStart: Int
    var now: Date
    var state: LocalDropState
    /// `true` while `achievements.completedTask` is still unset. The server
    /// skips drops for the very first completed task.
    var isFirstTask: Bool
}

struct LocalDropResult {
    var items: [OfflineDroppedItem]
    var state: LocalDropState
    /// `_tmp.quest.collection`: the drop roll succeeded, which also counts as
    /// a collection-quest item.
    var collectionItemFound: Bool
    var dialog: String?
}

enum LocalDropGenerator {

    static func generate(taskValue: Float,
                         taskPriority: Float,
                         taskStreak: Int,
                         checklistCompleted: Int,
                         perception: Float,
                         critMultiplier: Float,
                         context: LocalDropContext,
                         randomizer: LocalRandomizing) -> LocalDropResult {
        guard context.tables.isEmpty == false else {
            return LocalDropResult(items: [],
                                   state: context.state,
                                   collectionItemFound: false,
                                   dialog: nil)
        }

        // A brand new player gets one egg and one potion before the normal
        // drop rules run, so they can hatch a pet.
        if context.inventory.hasEggsOrPotions == false {
            return firstDrops(context: context, randomizer: randomizer)
        }

        let chance = dropChance(taskValue: taskValue,
                                taskPriority: taskPriority,
                                taskStreak: taskStreak,
                                checklistCompleted: checklistCompleted,
                                perception: perception,
                                critMultiplier: critMultiplier,
                                context: context)

        // The first roll decides whether the drop also counts as a quest
        // collection item. The server does this before the daily cap check.
        let collectionItemFound = randomizer.roll() < chance

        let sameDay = LocalDayMath.isSameHabiticaDay(context.state.lastDropDate,
                                                     context.now,
                                                     dayStart: context.dayStart)
        let normalizedCount = sameDay ? context.state.lastDropCount : 0
        let dropMultiplier = context.isSubscriber ? 2 : 1
        let maxDropCount = dropMultiplier
            * (5 + Int((perception / 25).rounded(.down)) + context.contributorLevel)

        guard sameDay == false || normalizedCount < maxDropCount else {
            return LocalDropResult(items: [],
                                   state: LocalDropState(lastDropDate: context.state.lastDropDate,
                                                         lastDropCount: normalizedCount),
                                   collectionItemFound: collectionItemFound,
                                   dialog: nil)
        }

        // The second roll decides whether an item actually drops. A player who
        // has no food yet always gets food, without rolling (same as the server).
        let firstFoodDrop = context.inventory.hasFood == false
        guard firstFoodDrop || randomizer.roll() < chance else {
            return LocalDropResult(items: [],
                                   state: LocalDropState(lastDropDate: context.state.lastDropDate,
                                                         lastDropCount: normalizedCount),
                                   collectionItemFound: collectionItemFound,
                                   dialog: nil)
        }

        guard let drop = chooseItem(firstFoodDrop: firstFoodDrop,
                                    context: context,
                                    randomizer: randomizer) else {
            return LocalDropResult(items: [],
                                   state: LocalDropState(lastDropDate: context.state.lastDropDate,
                                                         lastDropCount: normalizedCount),
                                   collectionItemFound: collectionItemFound,
                                   dialog: nil)
        }

        let newState = LocalDropState(lastDropDate: context.now,
                                      lastDropCount: normalizedCount + 1)
        return LocalDropResult(items: [drop.item],
                               state: newState,
                               collectionItemFound: collectionItemFound,
                               dialog: drop.item.dialog)
    }

    // MARK: - Rules

    private static func dropChance(taskValue: Float,
                                   taskPriority: Float,
                                   taskStreak: Int,
                                   checklistCompleted: Int,
                                   perception: Float,
                                   critMultiplier: Float,
                                   context: LocalDropContext) -> Float {
        var chance = min(abs(taskValue - 21.27), 37.5) / 150 + 0.02
        chance *= taskPriority
        // New players get +75%, diminishing by 5% per level.
        chance *= 1 + max(0, 80 - (5 * Float(context.playerLevel))) / 100
        chance *= 1 + (Float(taskStreak) / 100)
        chance *= 1 + perception / 100
        chance *= 1 + (Float(context.contributorLevel) / 40)
        chance *= 1 + (Float(context.rebirths) / 20)
        chance *= 1 + (Float(context.streakAchievements) / 200)
        chance *= critMultiplier
        chance *= 1 + 0.5 * Float(checklistCompleted)
        return diminishingReturns(chance, max: 0.75)
    }

    /// A hyperbola that keeps a bonus from growing without bound.
    private static func diminishingReturns(_ bonus: Float, max maxValue: Float) -> Float {
        let halfway = maxValue / 2
        return maxValue * (bonus / (bonus + halfway))
    }

    private static func firstDrops(context: LocalDropContext,
                                   randomizer: LocalRandomizing) -> LocalDropResult {
        var items = [OfflineDroppedItem]()
        var parts = [String]()

        if let egg = randomizer.pick(context.tables.eggs) {
            items.append(OfflineDroppedItem(itemType: ItemType.eggs.rawValue,
                                            key: egg.key,
                                            text: egg.text,
                                            dialog: eggDialog(egg.text)))
            parts.append("a \(egg.text) Egg")
        }
        if let potion = randomizer.pick(context.tables.potions) {
            items.append(OfflineDroppedItem(itemType: ItemType.hatchingPotions.rawValue,
                                            key: potion.key,
                                            text: potion.text,
                                            dialog: potionDialog(potion.text)))
            parts.append("a \(potion.text) Hatching Potion")
        }

        guard items.isEmpty == false else {
            return LocalDropResult(items: [],
                                   state: context.state,
                                   collectionItemFound: false,
                                   dialog: nil)
        }

        let dialog: String
        if parts.count == 2 {
            dialog = "You've found \(parts[0]) and \(parts[1])!"
        } else {
            dialog = items[0].dialog
        }
        return LocalDropResult(items: items,
                               state: context.state,
                               collectionItemFound: false,
                               dialog: dialog)
    }

    private static func chooseItem(firstFoodDrop: Bool,
                                   context: LocalDropContext,
                                   randomizer: LocalRandomizing) -> (item: OfflineDroppedItem, type: ItemType)? {
        let rarity = randomizer.roll()

        if firstFoodDrop || rarity > 0.6 {
            if let food = randomizer.pick(context.tables.food) {
                return (OfflineDroppedItem(itemType: ItemType.food.rawValue,
                                           key: food.key,
                                           text: food.text,
                                           dialog: foodDialog(food.text)),
                        .food)
            }
        }
        if firstFoodDrop == false && rarity > 0.3 {
            if let egg = randomizer.pick(context.tables.eggs) {
                return (OfflineDroppedItem(itemType: ItemType.eggs.rawValue,
                                           key: egg.key,
                                           text: egg.text,
                                           dialog: eggDialog(egg.text)),
                        .eggs)
            }
        }

        let acceptableKeys = potionKeys(for: rarity)
        let pool = context.tables.potions.filter { acceptableKeys.contains($0.key) }
        let potion = randomizer.pick(pool.isEmpty ? context.tables.potions : pool)
        if let potion = potion {
            return (OfflineDroppedItem(itemType: ItemType.hatchingPotions.rawValue,
                                       key: potion.key,
                                       text: potion.text,
                                       dialog: potionDialog(potion.text)),
                    .hatchingPotions)
        }
        return nil
    }

    private static func potionKeys(for rarity: Float) -> Set<String> {
        if rarity < 0.02 {
            return ["Golden"]
        }
        if rarity < 0.09 {
            return ["Zombie", "CottonCandyPink", "CottonCandyBlue"]
        }
        if rarity < 0.18 {
            return ["Red", "Shade", "Skeleton"]
        }
        return ["Base", "White", "Desert"]
    }

    // MARK: - Dialogs

    private static func foodDialog(_ text: String) -> String {
        return "You've found \(text)!"
    }

    private static func eggDialog(_ text: String) -> String {
        return "You've found a \(text) Egg!"
    }

    private static func potionDialog(_ text: String) -> String {
        return "You've found a \(text) Hatching Potion!"
    }
}

/// Day maths shared by the offline cron and drop rules.
enum LocalDayMath {

    static func startOfHabiticaDay(for date: Date,
                                   dayStart: Int,
                                   calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let shifted = calendar.date(byAdding: .hour, value: dayStart, to: startOfDay) ?? startOfDay
        if date < shifted {
            return calendar.date(byAdding: .day, value: -1, to: shifted) ?? shifted
        }
        return shifted
    }

    static func isSameHabiticaDay(_ lhs: Date?,
                                  _ rhs: Date,
                                  dayStart: Int,
                                  calendar: Calendar = .current) -> Bool {
        guard let lhs = lhs else {
            return false
        }
        let left = startOfHabiticaDay(for: lhs, dayStart: dayStart, calendar: calendar)
        let right = startOfHabiticaDay(for: rhs, dayStart: dayStart, calendar: calendar)
        return calendar.isDate(left, inSameDayAs: right)
    }
}
