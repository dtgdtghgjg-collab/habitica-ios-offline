//
//  LocalQuestProgress.swift
//  Habitica
//
//  Quest progress for an offline score, ported from
//  `website/common/script/ops/scoreTask.js` and
//  `website/server/models/group.js`.
//

import Foundation
import Habitica_Database

struct LocalQuestProgressState {
    var health: Float
    var rage: Float
    var up: Float
    var collectedItems: Int
    /// Item key -> how many the party has collected so far.
    var collected: [String: Int]
}

struct LocalQuestContext {
    var isActive: Bool
    var isOnQuest: Bool
    var definition: OfflineQuestDefinition
    var state: LocalQuestProgressState
    /// Damage the party took from missed dailies. Boss rage grows from this.
    var progressDown: Float
}

struct LocalQuestOutcome {
    var state: LocalQuestProgressState
    /// `_tmp.quest.progressDelta`: damage dealt to the boss by this score.
    var progressDelta: Float
    /// `_tmp.quest.collection`: how many quest items this score produced.
    var collection: Int
}

enum LocalQuestProgress {

    static func apply(context: LocalQuestContext,
                      taskType: String,
                      delta: Float,
                      critMultiplier: Float,
                      strength: Float,
                      collectionItemsFound: Int,
                      randomizer: LocalRandomizing) -> LocalQuestOutcome {
        guard context.isActive, context.isOnQuest, delta > 0 else {
            return LocalQuestOutcome(state: context.state,
                                     progressDelta: 0,
                                     collection: 0)
        }

        var state = context.state
        var progressDelta: Float = 0

        switch taskType {
        case "todo", "daily":
            progressDelta = Float(ceil(Double(delta * critMultiplier * (1 + strength / 200))))
        case "habit":
            progressDelta = Float(ceil(Double(delta * critMultiplier * (0.5 + strength / 400))))
        default:
            break
        }

        if progressDelta > 0 {
            state.up += progressDelta
            if context.definition.isBossQuest {
                state.health = max(0, state.health - progressDelta)
            }
        }

        // Rage grows from the damage the party takes, not from the damage it
        // deals. It resets when the threshold is reached. The iOS quest model
        // only stores the value, so the effect itself is left to the server.
        if context.definition.rageValue > 0, context.progressDown > 0 {
            state.rage += abs(context.progressDown)
            if state.rage >= context.definition.rageValue {
                state.rage = 0
            }
        }

        var collection = 0
        if context.definition.isCollectionQuest, collectionItemsFound > 0 {
            let remaining = remainingItems(for: context.definition, collected: state.collected)
            let found = randomizer.shuffle(remaining).prefix(collectionItemsFound)
            for key in found {
                state.collected[key, default: 0] += 1
                collection += 1
            }
            // The server counts every successful roll, even when the party has
            // already collected everything.
            state.collectedItems += collectionItemsFound
        }

        return LocalQuestOutcome(state: state,
                                 progressDelta: progressDelta,
                                 collection: collection)
    }

    private static func remainingItems(for definition: OfflineQuestDefinition,
                                       collected: [String: Int]) -> [String] {
        var remaining = [String]()
        for (key, target) in definition.collectTargets {
            let missing = max(0, target - (collected[key] ?? 0))
            remaining.append(contentsOf: repeatElement(key, count: missing))
        }
        return remaining
    }
}
