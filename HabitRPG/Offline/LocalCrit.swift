//
//  LocalCrit.swift
//  Habitica
//
//  Critical hits, ported from `website/common/script/fns/crit.js`.
//

import Foundation

enum LocalCritStat {
    case strength
    case perception
}

enum LocalCrit {

    /// Habitica's server crits on Strength. Switch this to `.perception` to
    /// make crits Perception-based instead; everything else stays the same.
    /// Perception already drives gold and drop chance, exactly as on the
    /// server.
    static let critStat: LocalCritStat = .strength

    static let baseChance: Float = 0.03

    static func chance(for statValue: Float) -> Float {
        return baseChance * (1 + statValue / 100)
    }

    static func multiplier(for statValue: Float) -> Float {
        return 1.5 + (4 * statValue) / (statValue + 200)
    }

    /// Returns `1` when there is no crit, otherwise the damage/points
    /// multiplier. The server compares with `<=`, so we do too.
    static func roll(classBonus: LocalClassBonus, randomizer: LocalRandomizing) -> Float {
        let statValue: Float
        switch critStat {
        case .strength:
            statValue = classBonus.strength
        case .perception:
            statValue = classBonus.perception
        }
        if randomizer.roll() <= chance(for: statValue) {
            return multiplier(for: statValue)
        }
        return 1
    }
}
