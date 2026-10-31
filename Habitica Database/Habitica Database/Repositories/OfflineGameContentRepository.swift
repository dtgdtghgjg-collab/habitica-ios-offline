//
//  OfflineGameContentRepository.swift
//  Habitica Database
//
//  Read-only access to the cached content (gear, quests, drops) for the offline
//  game engine. Everything here is synchronous: the engine runs inside a single
//  score and cannot wait for a ReactiveSwift producer.
//

import Foundation
import Habitica_Models
import RealmSwift

public class OfflineGameContentRepository: BaseLocalRepository {

    /// Content keys that Habitica allows to drop. The server keeps these lists
    /// in `content.eggs.drops` and `content.hatching-potions.drops`; the iOS
    /// content payload does not carry the flag, so the keys live here.
    public static let droppableEggKeys: Set<String> = [
        "Wolf", "TigerCub", "PandaCub", "LionCub", "Fox",
        "FlyingPig", "Dragon", "Cactus", "BearCub"
    ]

    public static let droppablePotionKeys: Set<String> = [
        "Base", "White", "Desert",
        "Red", "Shade", "Skeleton",
        "Zombie", "CottonCandyPink", "CottonCandyBlue",
        "Golden"
    ]

    // MARK: - Equipment

    /// Sums the stat bonuses of every equipped item, applying the class bonus
    /// twice for gear that belongs to the player's class.
    public func statBonuses(userID: String) -> OfflineStatBonuses {
        guard let realm = getRealm() else {
            return .zero
        }
        realm.refresh()
        guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
              let outfit = user.realmItems?.realmGear?.realmEquipped else {
            return .zero
        }

        let habitClass = user.realmStats?.habitClass
        let equippedKeys = [outfit.back, outfit.body, outfit.armor, outfit.eyewear,
                            outfit.headAccessory, outfit.head, outfit.weapon, outfit.shield]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }

        var bonuses = OfflineStatBonuses.zero
        for key in equippedKeys {
            guard let gear = realm.object(ofType: RealmGear.self, forPrimaryKey: key) else {
                continue
            }
            // Habitica adds the item's bonus once as a gear bonus and once more
            // as a class bonus when the item matches the player's class.
            let multiplier: Float = isClassGear(gear, habitClass: habitClass) ? 2 : 1
            bonuses.strength += Float(gear.strength) * multiplier
            bonuses.intelligence += Float(gear.intelligence) * multiplier
            bonuses.constitution += Float(gear.constitution) * multiplier
            bonuses.perception += Float(gear.perception) * multiplier
        }
        return bonuses
    }

    private func isClassGear(_ gear: RealmGear, habitClass: String?) -> Bool {
        guard let habitClass = habitClass, habitClass.isEmpty == false else {
            return false
        }
        return gear.habitClass == habitClass || gear.specialClass == habitClass
    }

    // MARK: - Quests

    public func questDefinition(key: String) -> OfflineQuestDefinition? {
        guard let realm = getRealm() else {
            return nil
        }
        realm.refresh()
        guard let quest = realm.object(ofType: RealmQuest.self, forPrimaryKey: key) else {
            return nil
        }

        var bossHealth: Float = 0
        var bossStrength: Float = 0
        var bossDefense: Float = 0
        var rageValue: Float = 0
        if let boss = quest.realmBoss {
            bossHealth = Float(boss.health)
            bossStrength = boss.strength
            bossDefense = boss.defense
            rageValue = Float(boss.realmRage?.value ?? 0)
        }

        var collectTargets = [String: Int]()
        for item in quest.realmCollect {
            if let itemKey = item.key, itemKey.isEmpty == false {
                collectTargets[itemKey] = item.count
            }
        }

        var dropGold = 0
        var dropExperience = 0
        var dropItems = [OfflineQuestRewardItem]()
        if let drop = quest.realmDrop {
            dropGold = drop.gold
            dropExperience = drop.experience
            for item in drop.realmItems {
                dropItems.append(OfflineQuestRewardItem(type: item.type ?? ItemType.eggs.rawValue,
                                                       key: item.key ?? "",
                                                       text: item.text ?? item.key ?? "",
                                                       count: item.count))
            }
        }

        return OfflineQuestDefinition(key: key,
                                       bossHealth: bossHealth,
                                       bossStrength: bossStrength,
                                       bossDefense: bossDefense,
                                       rageValue: rageValue,
                                       collectTargets: collectTargets,
                                       dropGold: dropGold,
                                       dropExperience: dropExperience,
                                       dropItems: dropItems)
    }

    // MARK: - Drops

    public func dropTables() -> OfflineDropTables {
        guard let realm = getRealm() else {
            return .empty
        }
        realm.refresh()

        let food = realm.objects(RealmFood.self)
            .filter("canDrop == true")
            .compactMap { definition(key: $0.key, text: $0.text) }
        let eggs = realm.objects(RealmEgg.self)
            .filter { Self.droppableEggKeys.contains($0.key ?? "") }
            .compactMap { definition(key: $0.key, text: $0.text) }
        let potions = realm.objects(RealmHatchingPotion.self)
            .filter { Self.droppablePotionKeys.contains($0.key ?? "") }
            .compactMap { definition(key: $0.key, text: $0.text) }

        return OfflineDropTables(food: food, eggs: eggs, potions: potions)
    }

    private func definition(key: String?, text: String?) -> OfflineDropItemDefinition? {
        guard let key = key, key.isEmpty == false else {
            return nil
        }
        return OfflineDropItemDefinition(key: key, text: text ?? key)
    }

    // MARK: - Inventory

    public func inventorySnapshot(userID: String) -> OfflineInventorySnapshot {
        guard let realm = getRealm() else {
            return .empty
        }
        realm.refresh()
        guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
              let items = user.realmItems else {
            return .empty
        }

        let eggs = items.realmOwnedEggs.contains { $0.numberOwned > 0 }
        let potions = items.realmOwnedHatchingPotions.contains { $0.numberOwned > 0 }
        let food = items.realmOwnedFood.contains { $0.numberOwned > 0 }

        return OfflineInventorySnapshot(hasEggsOrPotions: eggs || potions, hasFood: food)
    }
    // MARK: - Shop catalogue

    /// Every released equipment piece, as a value type the app target can read.
    public func gearCatalog() -> [OfflineGearDefinition] {
        guard let realm = getRealm() else {
            return []
        }
        realm.refresh()
        return realm.objects(RealmGear.self)
            .filter("released == true")
            .compactMap { gear -> OfflineGearDefinition? in
                guard let key = gear.key, key.isEmpty == false else {
                    return nil
                }
                return OfflineGearDefinition(key: key,
                                            text: gear.text ?? key,
                                            value: gear.value,
                                            type: gear.type ?? "",
                                            habitClass: gear.habitClass,
                                            specialClass: gear.specialClass,
                                            twoHanded: gear.twoHanded,
                                            strength: gear.strength,
                                            intelligence: gear.intelligence,
                                            constitution: gear.constitution,
                                            perception: gear.perception)
            }
    }

    public func gear(key: String) -> OfflineGearDefinition? {
        guard let realm = getRealm() else {
            return nil
        }
        realm.refresh()
        guard let gear = realm.object(ofType: RealmGear.self, forPrimaryKey: key) else {
            return nil
        }
        return OfflineGearDefinition(key: gear.key ?? key,
                                    text: gear.text ?? key,
                                    value: gear.value,
                                    type: gear.type ?? "",
                                    habitClass: gear.habitClass,
                                    specialClass: gear.specialClass,
                                    twoHanded: gear.twoHanded,
                                    strength: gear.strength,
                                    intelligence: gear.intelligence,
                                    constitution: gear.constitution,
                                    perception: gear.perception)
    }

    /// The consumables of a given `ItemType.rawValue` that the market sells.
    public func itemCatalog(_ itemType: String) -> [OfflineItemDefinition] {
        guard let realm = getRealm() else {
            return []
        }
        realm.refresh()
        let results: [Object]
        switch ItemType(rawValue: itemType) {
        case .eggs:
            results = Array(realm.objects(RealmEgg.self))
        case .hatchingPotions:
            results = Array(realm.objects(RealmHatchingPotion.self))
        case .food:
            results = Array(realm.objects(RealmFood.self))
        case .quests:
            results = Array(realm.objects(RealmQuest.self))
        case .special:
            results = Array(realm.objects(RealmSpecialItem.self))
        default:
            return []
        }
        return results.compactMap { item -> OfflineItemDefinition? in
            guard let keyed = item as? ItemKeyable,
                  let key = keyed.itemKey, key.isEmpty == false else {
                return nil
            }
            return OfflineItemDefinition(key: key, text: keyed.itemText ?? key, value: keyed.itemValue)
        }
    }
}

private protocol ItemKeyable {
    var itemKey: String? { get }
    var itemText: String? { get }
    var itemValue: Float { get }
}

extension RealmEgg: ItemKeyable {
    var itemKey: String? { key }
    var itemText: String? { text }
    var itemValue: Float { value }
}

extension RealmHatchingPotion: ItemKeyable {
    var itemKey: String? { key }
    var itemText: String? { text }
    var itemValue: Float { value }
}

extension RealmFood: ItemKeyable {
    var itemKey: String? { key }
    var itemText: String? { text }
    var itemValue: Float { value }
}

extension RealmQuest: ItemKeyable {
    var itemKey: String? { key }
    var itemText: String? { text }
    var itemValue: Float { value }
}

extension RealmSpecialItem: ItemKeyable {
    var itemKey: String? { key }
    var itemText: String? { text }
    var itemValue: Float { value }
}
