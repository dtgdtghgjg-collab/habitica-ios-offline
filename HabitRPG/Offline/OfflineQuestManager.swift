//
//  OfflineQuestManager.swift
//  Habitica
//
//  Resolves quests entirely on-device: killing the boss or collecting every
//  item grants the quest's drop (items, experience, gold) straight into Realm.
//

import Foundation
import Habitica_Database

final class OfflineQuestManager {

    static let shared = OfflineQuestManager()

    private let mutationRepository = OfflineMutationRepository()

    private init() {}

    /// Grants the reward when the quest is finished and returns `true` when it
    /// was completed by this call. Realm is the source of truth: no server
    /// round-trip is needed.
    @discardableResult
    func completeIfNeeded(userID: String,
                          definition: OfflineQuestDefinition,
                          state: LocalQuestProgressState) -> Bool {
        guard isComplete(definition: definition, state: state) else {
            return false
        }
        mutationRepository.completeQuest(userID: userID,
                                         key: definition.key,
                                         rewardGold: definition.dropGold,
                                         rewardExperience: definition.dropExperience,
                                         rewardItems: definition.dropItems)
        return true
    }

    private func isComplete(definition: OfflineQuestDefinition,
                            state: LocalQuestProgressState) -> Bool {
        if definition.isBossQuest {
            return state.health <= 0
        }
        guard definition.isCollectionQuest else {
            return false
        }
        for (key, target) in definition.collectTargets where (state.collected[key] ?? 0) < target {
            return false
        }
        return true
    }
}