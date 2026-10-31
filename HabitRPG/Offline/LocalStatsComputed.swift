//
//  LocalStatsComputed.swift
//  Habitica
//
//  The offline equivalent of `statsComputed` on the server.
//
//  Habitica adds four things to a base stat before it is used in a formula:
//  the bonus from equipped gear, the class bonus (class gear counts twice),
//  active buffs, and `floor(capByLevel(level) / 2)`.
//

import Foundation
import Habitica_Database

/// The extra sources of stats that are not stored on `RealmStats` itself.
struct LocalComputedStats {

    /// Sum of every equipped item, already including the class bonus.
    var gear: OfflineStatBonuses
    /// Temporary buffs (`stats.buffs`), for example from a party skill.
    var buffs: OfflineStatBonuses
    /// `warrior`, `rogue`, `wizard` or `healer`.
    var habitClass: String?

    static let none = LocalComputedStats(gear: .zero, buffs: .zero, habitClass: nil)

    init(gear: OfflineStatBonuses, buffs: OfflineStatBonuses, habitClass: String?) {
        self.gear = gear
        self.buffs = buffs
        self.habitClass = habitClass
    }
}

enum LocalStatKind: String {
    case strength
    case intelligence
    case constitution
    case perception
}

enum LocalHabitClass: String {
    case warrior
    case rogue
    case wizard
    case healer

    /// The stats the class' own gear boosts. This is what makes the class
    /// bonus visible in play: a warrior's class gear raises STR (and therefore
    /// boss damage), a mage's raises INT (and therefore experience), a rogue's
    /// raises PER (gold and drops) and a healer's raises CON (damage taken).
    var signatureStats: [LocalStatKind] {
        switch self {
        case .warrior:
            return [.strength, .constitution]
        case .rogue:
            return [.perception, .strength]
        case .wizard:
            return [.intelligence, .perception]
        case .healer:
            return [.intelligence, .constitution]
        }
    }
}

/// Class-aware view of the computed stats.
///
/// Habitica does not have a flat "warrior deals 10% more damage" multiplier;
/// class identity comes from the stats the class gear boosts plus the shared
/// formulas. This type keeps those formulas in one place so the scoring code
/// reads like the server and a new class passive can be added in one spot.
struct LocalClassBonus {

    let habitClass: LocalHabitClass?
    let strength: Float
    let intelligence: Float
    let constitution: Float
    let perception: Float

    init(habitClass: String?, strength: Float, intelligence: Float, constitution: Float, perception: Float) {
        self.habitClass = habitClass.flatMap { LocalHabitClass(rawValue: $0) }
        self.strength = strength
        self.intelligence = intelligence
        self.constitution = constitution
        self.perception = perception
    }

    /// Damage a task deals to a quest boss: `1 + STR / 200` for todos and
    /// dailies, `0.5 + STR / 400` for habits.
    var bossDamageMultiplier: Float {
        return 1 + strength / 200
    }

    var habitBossDamageMultiplier: Float {
        return 0.5 + strength / 400
    }

    /// Experience from a task: `1 + INT * 0.025`.
    var experienceMultiplier: Float {
        return 1 + intelligence * 0.025
    }

    /// Gold from a task: `1 + PER * 0.02`.
    var goldMultiplier: Float {
        return 1 + perception * 0.02
    }

    /// Health lost from a bad task: `max(0.1, 1 - CON / 250)`.
    var damageTakenMultiplier: Float {
        return max(0.1, 1 - constitution / 250)
    }

    var maxMana: Float {
        return intelligence * 2 + 30
    }

    /// Class gear contributes its stats once as gear and once as a class
    /// bonus, so matching gear is worth twice as much.
    var matchingGearMultiplier: Float {
        return habitClass == nil ? 1 : 2
    }
}
