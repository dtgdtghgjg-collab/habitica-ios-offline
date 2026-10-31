//
//  OfflineGameModels.swift
//  Habitica Database
//
//  Plain value types the offline game engine needs from the content database.
//
//  The Realm content objects (`RealmGear`, `RealmQuest`, `RealmFood`, ...) are
//  internal to this framework, so the app target cannot read them directly.
//  These structs are the public, value-typed view of everything the offline
//  scoring needs: equipment bonuses, drop tables and quest definitions.
//

import Foundation

/// Flat bonus to the four stats, already summed over every equipped item.
///
/// Habitica adds the bonus of an equipped item twice when the item belongs to
/// the player's class (once as a "gear" bonus, once as a "class" bonus), so a
/// warrior's warrior-only sword contributes `2 * strength` here.
public struct OfflineStatBonuses {

    public var strength: Float
    public var intelligence: Float
    public var constitution: Float
    public var perception: Float

    public static let zero = OfflineStatBonuses(strength: 0,
                                                intelligence: 0,
                                                constitution: 0,
                                                perception: 0)

    public init(strength: Float, intelligence: Float, constitution: Float, perception: Float) {
        self.strength = strength
        self.intelligence = intelligence
        self.constitution = constitution
        self.perception = perception
    }

    public var isEmpty: Bool {
        return strength == 0 && intelligence == 0 && constitution == 0 && perception == 0
    }
}

/// One entry of a drop table: the content key plus the localized name used in
/// the "You found ..." toast.
public struct OfflineDropItemDefinition {

    public let key: String
    public let text: String

    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}

/// The three droppable item pools.
public struct OfflineDropTables {

    public let food: [OfflineDropItemDefinition]
    public let eggs: [OfflineDropItemDefinition]
    /// All droppable hatching potions. The rarity buckets are applied by the
    /// drop generator, because they are part of the drop rules, not content.
    public let potions: [OfflineDropItemDefinition]

    public static let empty = OfflineDropTables(food: [], eggs: [], potions: [])

    public init(food: [OfflineDropItemDefinition],
                eggs: [OfflineDropItemDefinition],
                potions: [OfflineDropItemDefinition]) {
        self.food = food
        self.eggs = eggs
        self.potions = potions
    }

    public var isEmpty: Bool {
        return food.isEmpty && eggs.isEmpty && potions.isEmpty
    }
}

/// Everything the local quest engine needs to know about the active quest.
public struct OfflineQuestDefinition {

    public let key: String
    public let bossHealth: Float
    public let bossStrength: Float
    public let bossDefense: Float
    public let rageValue: Float
    /// Item key -> how many the party has to collect.
    public let collectTargets: [String: Int]
    /// Gold and experience granted to the player when the quest is completed.
    public let dropGold: Int
    public let dropExperience: Int
    /// Items (gear, eggs, potions, food, ...) granted on completion.
    public let dropItems: [OfflineQuestRewardItem]

    public init(key: String,
                bossHealth: Float,
                bossStrength: Float,
                bossDefense: Float,
                rageValue: Float,
                collectTargets: [String: Int],
                dropGold: Int = 0,
                dropExperience: Int = 0,
                dropItems: [OfflineQuestRewardItem] = []) {
        self.key = key
        self.bossHealth = bossHealth
        self.bossStrength = bossStrength
        self.bossDefense = bossDefense
        self.rageValue = rageValue
        self.collectTargets = collectTargets
        self.dropGold = dropGold
        self.dropExperience = dropExperience
        self.dropItems = dropItems
    }

    public var isBossQuest: Bool {
        return bossHealth > 0
    }

    public var isCollectionQuest: Bool {
        return collectTargets.isEmpty == false
    }
}

/// One entry of a quest completion reward.
public struct OfflineQuestRewardItem {
    /// `ItemType.rawValue`: "eggs", "hatchingPotions", "food", "quests", ...
    public let type: String
    public let key: String
    public let text: String
    public let count: Int

    public init(type: String, key: String, text: String, count: Int) {
        self.type = type
        self.key = key
        self.text = text
        self.count = count
    }
}

/// One purchasable piece of equipment, as cached in the content database.
public struct OfflineGearDefinition {
    public let key: String
    public let text: String
    public let value: Float
    public let type: String
    public let habitClass: String?
    public let specialClass: String?
    public let twoHanded: Bool
    public let strength: Int
    public let intelligence: Int
    public let constitution: Int
    public let perception: Int
    /// Level at which the item unlocks; `0` means "always available".
    public let requiredLevel: Int

    public init(key: String,
                text: String,
                value: Float,
                type: String,
                habitClass: String?,
                specialClass: String?,
                twoHanded: Bool,
                strength: Int,
                intelligence: Int,
                constitution: Int,
                perception: Int,
                requiredLevel: Int = 0) {
        self.key = key
        self.text = text
        self.value = value
        self.type = type
        self.habitClass = habitClass
        self.specialClass = specialClass
        self.twoHanded = twoHanded
        self.strength = strength
        self.intelligence = intelligence
        self.constitution = constitution
        self.perception = perception
        self.requiredLevel = requiredLevel
    }

    /// The player's class can use the item, or the item is class-agnostic.
    public func isAvailable(forClass habitClass: String?) -> Bool {
        guard let itemClass = self.habitClass, itemClass.isEmpty == false else {
            return true
        }
        if itemClass == "armoire" || itemClass == "special" {
            return true
        }
        return itemClass == habitClass
    }
}

/// One purchasable consumable (egg, hatching potion, food, quest scroll).
public struct OfflineItemDefinition {
    public let key: String
    public let text: String
    public let value: Float

    public init(key: String, text: String, value: Float) {
        self.key = key
        self.text = text
        self.value = value
    }
}

/// The part of the inventory the drop rules look at.
public struct OfflineInventorySnapshot {

    /// `false` triggers Habitica's "first drops": a guaranteed egg and potion.
    public let hasEggsOrPotions: Bool
    /// `false` makes the very first drop food, so a new player can feed a pet.
    public let hasFood: Bool

    public init(hasEggsOrPotions: Bool, hasFood: Bool) {
        self.hasEggsOrPotions = hasEggsOrPotions
        self.hasFood = hasFood
    }

    public static let empty = OfflineInventorySnapshot(hasEggsOrPotions: false, hasFood: false)
}
