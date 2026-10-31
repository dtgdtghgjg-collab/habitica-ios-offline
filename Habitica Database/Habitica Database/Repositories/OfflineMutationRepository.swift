//
//  OfflineMutationRepository.swift
//  Habitica Database
//
//  Writes the result of a locally computed score into Realm.
//

import Foundation
import Habitica_Models
import RealmSwift

public enum OfflineHistoryAction {
    case none
    case append
    case removeLast
}

public struct OfflineTaskScoreUpdate {
    public var taskID: String
    public var value: Float
    public var completed: Bool
    public var streak: Int
    public var counterUp: Int
    public var counterDown: Int
    public var historyAction: OfflineHistoryAction
    public var historyValue: Float
    public var historyDate: Date
    public var isDue: Bool

    public init(taskID: String,
                value: Float,
                completed: Bool,
                streak: Int,
                counterUp: Int,
                counterDown: Int,
                historyAction: OfflineHistoryAction,
                historyValue: Float,
                historyDate: Date,
                isDue: Bool) {
        self.taskID = taskID
        self.value = value
        self.completed = completed
        self.streak = streak
        self.counterUp = counterUp
        self.counterDown = counterDown
        self.historyAction = historyAction
        self.historyValue = historyValue
        self.historyDate = historyDate
        self.isDue = isDue
    }
}

public struct OfflineUserStatsUpdate {
    public var health: Float
    public var mana: Float
    public var experience: Float
    public var gold: Float
    public var level: Int
    public var points: Int
    public var toNextLevel: Float
    public var strength: Int
    public var intelligence: Int
    public var constitution: Int
    public var perception: Int

    public init(health: Float,
                mana: Float,
                experience: Float,
                gold: Float,
                level: Int,
                points: Int,
                toNextLevel: Float,
                strength: Int,
                intelligence: Int,
                constitution: Int,
                perception: Int) {
        self.health = health
        self.mana = mana
        self.experience = experience
        self.gold = gold
        self.level = level
        self.points = points
        self.toNextLevel = toNextLevel
        self.strength = strength
        self.intelligence = intelligence
        self.constitution = constitution
        self.perception = perception
    }
}

/// One item that a local drop put into the inventory.
public struct OfflineDroppedItem {
    /// `ItemType.rawValue`: "food", "eggs" or "hatchingPotions".
    public var itemType: String
    public var key: String
    public var text: String
    /// The toast text the server would have sent in `_tmp.drop.dialog`.
    public var dialog: String

    public init(itemType: String, key: String, text: String, dialog: String) {
        self.itemType = itemType
        self.key = key
        self.text = text
        self.dialog = dialog
    }

    /// The `type` string the API puts in `_tmp.drop.type`.
    public var responseType: String {
        switch itemType {
        case ItemType.food.rawValue:
            return "Food"
        case ItemType.eggs.rawValue:
            return "Egg"
        case ItemType.hatchingPotions.rawValue:
            return "HatchingPotion"
        default:
            return itemType
        }
    }
}

/// Progress of the party quest after one local score.
public struct OfflineQuestProgressUpdate {
    public var health: Float
    public var rage: Float
    public var progressUp: Float
    public var collectedItems: Int
    /// Item key -> new absolute count for that item.
    public var collected: [String: Int]

    public init(health: Float,
                rage: Float,
                progressUp: Float,
                collectedItems: Int,
                collected: [String: Int]) {
        self.health = health
        self.rage = rage
        self.progressUp = progressUp
        self.collectedItems = collectedItems
        self.collected = collected
    }
}

public class OfflineMutationRepository: BaseLocalRepository {

    /// Applies an optimistic score. The server response, once the operation is
    /// replayed, overwrites these values with the authoritative ones.
    public func applyScore(userID: String, taskUpdate: OfflineTaskScoreUpdate?, statsUpdate: OfflineUserStatsUpdate?) {
        updateCall { realm in
            if let update = taskUpdate,
               let task = realm.object(ofType: RealmTask.self, forPrimaryKey: update.taskID) {
                task.value = update.value
                task.complete(forUser: userID, completed: update.completed)
                task.streak = update.streak
                task.counterUp = update.counterUp
                task.counterDown = update.counterDown

                switch update.historyAction {
                case .append:
                    let entry = RealmTaskHistory()
                    entry.taskID = task.id
                    entry.combinedID = (task.id ?? "") + String(update.historyDate.timeIntervalSince1970)
                    entry.timestamp = update.historyDate
                    entry.value = update.historyValue
                    entry.isDue = update.isDue
                    entry.completed = true
                    task.realmHistory.append(entry)
                case .removeLast:
                    if task.realmHistory.isEmpty == false {
                        task.realmHistory.removeLast()
                    }
                case .none:
                    break
                }
            }

            if let update = statsUpdate,
               let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
               let stats = user.realmStats {
                stats.health = update.health
                stats.mana = update.mana
                stats.experience = update.experience
                stats.gold = update.gold
                stats.level = update.level
                stats.points = update.points
                stats.toNextLevel = update.toNextLevel
                stats.strength = update.strength
                stats.intelligence = update.intelligence
                stats.constitution = update.constitution
                stats.perception = update.perception
            }
        }
    }

    /// Applies the authoritative stat values that came back with a replayed
    /// score.
    ///
    /// The task itself is deliberately left alone: it already holds the
    /// optimistic value we computed locally, and `TaskLocalRepository.update`
    /// would add the server delta on top of it. The task list is refreshed from
    /// the server once the queue is drained.
    public func applyServerScoreStats(userID: String, response: TaskResponseProtocol) {
        guard let level = response.level, level > 0 else {
            // Group tasks that need approval do not change the player's stats.
            return
        }
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let stats = user.realmStats else {
                return
            }
            stats.health = response.health ?? stats.health
            stats.mana = response.magic ?? stats.mana
            stats.experience = response.experience ?? stats.experience
            stats.gold = response.gold ?? stats.gold
            stats.level = level
        }
    }

    // MARK: - Drops

    /// Puts the items a local drop produced into the inventory.
    ///
    /// `OfflineDroppedItem.itemType` is the raw value of `ItemType`, so the
    /// item lands in the same bucket the server would use. The server response
    /// overwrites these counts once the score is replayed.
    public func applyDrops(userID: String, items: [OfflineDroppedItem]) {
        guard items.isEmpty == false else {
            return
        }
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let userItems = user.realmItems else {
                return
            }
            for dropped in items {
                guard let itemType = ItemType(rawValue: dropped.itemType) else {
                    continue
                }
                let ownedItems: List<RealmOwnedItem>
                switch itemType {
                case .food:
                    ownedItems = userItems.realmOwnedFood
                case .eggs:
                    ownedItems = userItems.realmOwnedEggs
                case .hatchingPotions:
                    ownedItems = userItems.realmOwnedHatchingPotions
                case .quests, .special:
                    continue
                }

                if let existing = ownedItems.first(where: { $0.key == dropped.key }) {
                    existing.numberOwned += 1
                } else {
                    let owned = RealmOwnedItem()
                    owned.userID = userID
                    owned.key = dropped.key
                    owned.itemType = dropped.itemType
                    owned.numberOwned = 1
                    owned.combinedKey = userID + dropped.key + dropped.itemType
                    realm.add(owned, update: .modified)
                    ownedItems.append(owned)
                }
            }
        }
    }

    // MARK: - Quests

    /// Writes the party quest progress computed by a local score.
    ///
    /// Only the active party quest is touched. The score operations themselves
    /// are replayed later, and the server recalculates the authoritative
    /// progress from them.
    public func applyQuestProgress(userID: String, update: OfflineQuestProgressUpdate) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let progress = user.realmParty?.realmQuest?.realmProgress else {
                return
            }
            progress.health = update.health
            progress.rage = update.rage
            progress.up = update.progressUp
            progress.collectedItems = update.collectedItems

            let groupID = progress.id ?? userID
            for (key, count) in update.collected {
                if let existing = progress.realmCollect.first(where: { $0.key == key }) {
                    existing.count = count
                } else {
                    let collected = RealmQuestProgressCollect()
                    collected.groupID = groupID
                    collected.key = key
                    collected.count = count
                    collected.combinedKey = groupID + key
                    realm.add(collected, update: .modified)
                    progress.realmCollect.append(collected)
                }
            }
        }
    }

    // MARK: - Achievements

    /// Unlocks the achievements that a local score can grant.
    public func applyAchievements(userID: String,
                                  completedTask: Bool = false,
                                  createdTask: Bool = false,
                                  streakDelta: Int = 0,
                                  hatchedPet: Bool = false,
                                  fedPet: Bool = false,
                                  purchasedEquipment: Bool = false,
                                  streak: Int? = nil) {
        guard completedTask || createdTask || streakDelta != 0
            || hatchedPet || fedPet || purchasedEquipment || streak != nil else {
            return
        }
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID) else {
                return
            }
            let achievements: RealmUserAchievements
            if let existing = user.realmAchievements {
                achievements = existing
            } else {
                let created = RealmUserAchievements()
                created.userID = userID
                realm.add(created, update: .modified)
                user.realmAchievements = created
                achievements = created
            }
            if completedTask {
                achievements.completedTask = true
            }
            if createdTask {
                achievements.createdTask = true
            }
            if streakDelta != 0 {
                achievements.streak = max(0, achievements.streak + streakDelta)
            }
            if let streak = streak {
                achievements.streak = max(achievements.streak, streak)
            }
            if hatchedPet {
                achievements.hatchedPet = true
            }
            if fedPet {
                achievements.fedPet = true
            }
            if purchasedEquipment {
                achievements.purchasedEquipment = true
            }
        }
    }

    public func setTaskSynced(taskID: String, synced: Bool) {
        updateCall { realm in
            realm.object(ofType: RealmTask.self, forPrimaryKey: taskID)?.isSynced = synced
        }
    }

    public func setTaskSyncing(taskID: String, syncing: Bool) {
        updateCall { realm in
            realm.object(ofType: RealmTask.self, forPrimaryKey: taskID)?.isSyncing = syncing
        }
    }

    /// Clears the "currently uploading" flag left behind by a crash or kill.
    public func resetInFlightState(userID: String) {
        updateCall { realm in
            let tasks = realm.objects(RealmTask.self).filter("ownerID == %@ AND isSyncing == true", userID)
            for task in tasks {
                task.isSyncing = false
            }
        }
    }

    /// Applies the local part of a day rollover: dailies become unchecked again
    /// and their "due" flag is recomputed from the schedule the server sent us.
    public func resetDailiesForNewDay(userID: String) {
        let today = Date()
        updateCall { realm in
            let tasks = realm.objects(RealmTask.self).filter("ownerID == %@ AND type == 'daily'", userID)
            for task in tasks {
                task.completed = false
                if task.realmNextDue.isEmpty == false {
                    task.isDue = task.dueOn(date: today)
                }
            }
        }
    }
    // MARK: - Standalone economy

    /// Sets the player's gold. Realm is the source of truth, so this is the
    /// value every later score starts from.
    public func applyGold(userID: String, gold: Float) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let stats = user.realmStats else {
                return
            }
            stats.gold = gold
        }
    }

    /// Gems are stored in `RealmUser.balance`, where 1 gem is worth 0.25.
    public func spendGems(userID: String, gems: Int) {
        guard gems > 0 else {
            return
        }
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID) else {
                return
            }
            user.balance -= Float(gems) / 4.0
        }
    }

    public func addGems(userID: String, gems: Int) {
        guard gems > 0 else {
            return
        }
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID) else {
                return
            }
            user.balance += Float(gems) / 4.0
        }
    }

    /// Marks a piece of gear as owned. Already-owned keys are a no-op.
    public func addOwnedGear(userID: String, key: String) {
        guard key.isEmpty == false else {
            return
        }
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let gear = user.realmItems?.realmGear else {
                return
            }
            if let existing = gear.realmOwned.first(where: { $0.key == key }) {
                existing.isOwned = true
                return
            }
            let owned = RealmOwnedGear()
            owned.userID = userID
            owned.key = key
            owned.isOwned = true
            owned.combinedKey = userID + key
            realm.add(owned, update: .modified)
            gear.realmOwned.append(owned)
        }
    }

    /// Adds consumables or quest scrolls to the right inventory bucket.
    public func addOwnedItem(userID: String, itemType: String, key: String, quantity: Int = 1) {
        guard key.isEmpty == false, quantity > 0 else {
            return
        }
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let items = user.realmItems else {
                return
            }
            let list: List<RealmOwnedItem>?
            switch ItemType(rawValue: itemType) {
            case .food:
                list = items.realmOwnedFood
            case .eggs:
                list = items.realmOwnedEggs
            case .hatchingPotions:
                list = items.realmOwnedHatchingPotions
            case .quests:
                list = items.realmOwnedQuests
            case .special:
                list = items.realmOwnedSpecialItems
            default:
                list = nil
            }
            guard let ownedList = list else {
                return
            }
            if let existing = ownedList.first(where: { $0.key == key }) {
                existing.numberOwned += quantity
            } else {
                let owned = RealmOwnedItem()
                owned.userID = userID
                owned.key = key
                owned.itemType = itemType
                owned.numberOwned = quantity
                owned.combinedKey = userID + key + itemType
                realm.add(owned, update: .modified)
                ownedList.append(owned)
            }
        }
    }

    /// Removes one unit of a consumable from the inventory (selling, feeding).
    public func removeOwnedItem(userID: String, itemType: String, key: String) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let items = user.realmItems else {
                return
            }
            let list: List<RealmOwnedItem>?
            switch ItemType(rawValue: itemType) {
            case .food:
                list = items.realmOwnedFood
            case .eggs:
                list = items.realmOwnedEggs
            case .hatchingPotions:
                list = items.realmOwnedHatchingPotions
            case .quests:
                list = items.realmOwnedQuests
            case .special:
                list = items.realmOwnedSpecialItems
            default:
                list = nil
            }
            guard let ownedList = list else {
                return
            }
            guard let index = ownedList.firstIndex(where: { $0.key == key }) else {
                return
            }
            let existing = ownedList[index]
            existing.numberOwned -= 1
            if existing.numberOwned <= 0 {
                ownedList.remove(at: index)
                realm.delete(existing)
            }
        }
    }

    /// Equips gear, a pet or a mount straight into Realm.
    public func equip(userID: String, type: String, key: String) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID) else {
                return
            }
            if type == "pet" {
                user.realmItems?.currentPet = key
                return
            }
            if type == "mount" {
                user.realmItems?.currentMount = key
                return
            }
            guard let outfit = user.realmItems?.realmGear?.realmEquipped else {
                return
            }
            switch type {
            case "weapon":
                outfit.weapon = key
            case "armor":
                outfit.armor = key
            case "head":
                outfit.head = key
            case "shield":
                outfit.shield = key
            case "back":
                outfit.back = key
            case "body":
                outfit.body = key
            case "eyewear":
                outfit.eyewear = key
            case "headAccessory":
                outfit.headAccessory = key
            case "hair":
                user.realmPreferences?.hair?.color = key
            case "shirt":
                user.realmPreferences?.shirt = key
            case "skin":
                user.realmPreferences?.skin = key
            case "background":
                user.realmPreferences?.background = key
            case "chair":
                user.realmPreferences?.chair = key
            default:
                break
            }
        }
    }

    /// Distributes stat points gained on level-up. Callers must already have
    /// validated that the player has enough unspent points.
    public func applyStatAllocation(userID: String,
                                    strength: Int,
                                    intelligence: Int,
                                    constitution: Int,
                                    perception: Int,
                                    points: Int) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let stats = user.realmStats else {
                return
            }
            stats.strength = strength
            stats.intelligence = intelligence
            stats.constitution = constitution
            stats.perception = perception
            stats.points = points
        }
    }

    /// Applies avatar changes. `nil` leaves a field untouched.
    public func updatePreferences(userID: String,
                                  skin: String? = nil,
                                  shirt: String? = nil,
                                  size: String? = nil,
                                  background: String? = nil,
                                  chair: String? = nil,
                                  hairColor: String? = nil,
                                  hairBase: Int? = nil,
                                  hairBangs: Int? = nil,
                                  hairBeard: Int? = nil,
                                  hairMustache: Int? = nil,
                                  hairFlower: Int? = nil) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID),
                  let prefs = user.realmPreferences else {
                return
            }
            if let skin = skin {
                prefs.skin = skin
            }
            if let shirt = shirt {
                prefs.shirt = shirt
            }
            if let size = size {
                prefs.size = size
            }
            if let background = background {
                prefs.background = background
            }
            if let chair = chair {
                prefs.chair = chair
            }
            guard hairColor != nil || hairBase != nil || hairBangs != nil
                || hairBeard != nil || hairMustache != nil || hairFlower != nil else {
                return
            }
            let hair: RealmHair
            if let existing = prefs.realmHair {
                hair = existing
            } else {
                let created = RealmHair()
                created.id = userID
                realm.add(created, update: .modified)
                prefs.realmHair = created
                hair = created
            }
            if let color = hairColor {
                hair.color = color
            }
            if let base = hairBase {
                hair.base = base
            }
            if let bangs = hairBangs {
                hair.bangs = bangs
            }
            if let beard = hairBeard {
                hair.beard = beard
            }
            if let mustache = hairMustache {
                hair.mustache = mustache
            }
            if let flower = hairFlower {
                hair.flower = flower
            }
        }
    }

    /// Updates the display name / description and marks the avatar as set up.
    public func updateProfile(userID: String, name: String?, blurb: String?) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID) else {
                return
            }
            if let profile = user.realmProfile {
                if let name = name {
                    profile.name = name
                }
                if let blurb = blurb {
                    profile.blurb = blurb
                }
                return
            }
            let created = RealmProfile()
            created.id = userID
            created.name = name
            created.blurb = blurb
            realm.add(created, update: .modified)
            user.realmProfile = created
        }
    }

    // MARK: - Quest completion

    /// Grants the quest reward and marks the party quest as completed.
    /// Realm is the source of truth: no server round-trip happens.
    public func completeQuest(userID: String,
                              key: String,
                              rewardGold: Int,
                              rewardExperience: Int,
                              rewardItems: [OfflineQuestRewardItem]) {
        updateCall { realm in
            guard let user = realm.object(ofType: RealmUser.self, forPrimaryKey: userID) else {
                return
            }
            if let quest = user.realmParty?.realmQuest {
                quest.completed = key
            }
            if let stats = user.realmStats {
                stats.gold += Float(rewardGold)
                stats.experience += Float(rewardExperience)
                Self.levelUp(stats: stats)
            }
            for item in rewardItems {
                if let itemType = ItemType(rawValue: item.type) {
                    switch itemType {
                    case .eggs, .hatchingPotions, .food, .quests, .special:
                        guard let items = user.realmItems else {
                            continue
                        }
                        let list: List<RealmOwnedItem>
                        switch itemType {
                        case .food:
                            list = items.realmOwnedFood
                        case .eggs:
                            list = items.realmOwnedEggs
                        case .hatchingPotions:
                            list = items.realmOwnedHatchingPotions
                        case .quests:
                            list = items.realmOwnedQuests
                        case .special:
                            list = items.realmOwnedSpecialItems
                        }
                        if let existing = list.first(where: { $0.key == item.key }) {
                            existing.numberOwned += item.count
                        } else {
                            let owned = RealmOwnedItem()
                            owned.userID = userID
                            owned.key = item.key
                            owned.itemType = item.type
                            owned.numberOwned = item.count
                            owned.combinedKey = userID + item.key + item.type
                            realm.add(owned, update: .modified)
                            list.append(owned)
                        }
                    default:
                        // Known limitation (documented, not fixed): this branch
                        // is unreachable. The surrounding `if let itemType =
                        // ItemType(rawValue:)` matches every case that itemType
                        // can hold, so a quest reward whose `type` is not an
                        // `ItemType` raw value (e.g. "gear") is skipped at that
                        // guard and never reaches the wardrobe. Offline quest
                        // completion therefore does not grant gear rewards.
                        guard let gear = user.realmItems?.realmGear else {
                            continue
                        }
                        if let existing = gear.realmOwned.first(where: { $0.key == item.key }) {
                            existing.isOwned = true
                        } else {
                            let owned = RealmOwnedGear()
                            owned.userID = userID
                            owned.key = item.key
                            owned.isOwned = true
                            owned.combinedKey = userID + item.key
                            realm.add(owned, update: .modified)
                            gear.realmOwned.append(owned)
                        }
                    }
                }
            }
        }
    }

    /// Level-up loop shared by quest rewards and any other offline experience
    /// grant, mirroring `LocalScoreCalculator.toNextLevel`.
    private static func levelUp(stats: RealmStats) {
        while stats.experience >= toNextLevel(stats.level) && stats.level < 100 {
            stats.experience -= toNextLevel(stats.level)
            stats.level += 1
            stats.health = 50
        }
    }

    private static func toNextLevel(_ level: Int) -> Float {
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
