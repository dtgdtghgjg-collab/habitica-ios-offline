//
//  LocalRandomizer.swift
//  Habitica
//
//  The random source used by the offline game mechanics.
//
//  Habitica rolls critical hits, drops and quest item distribution with
//  `Math.random()`. The protocol below keeps that decision out of the scoring
//  code so tests can inject a seeded generator and get the same result twice.
//

import Foundation

protocol LocalRandomizing: AnyObject {
    /// A value in `0..<1`, matching `Math.random()`.
    func roll() -> Float
}

extension LocalRandomizing {

    /// Fisher-Yates shuffle driven by `roll()`, so a seeded randomizer produces
    /// the same quest item distribution every time.
    func shuffle<T>(_ values: [T]) -> [T] {
        guard values.count > 1 else {
            return values
        }
        var result = values
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let target = min(Int(roll() * Float(index + 1)), index)
            result.swapAt(index, target)
        }
        return result
    }

    func pick<T>(_ values: [T]) -> T? {
        guard values.isEmpty == false else {
            return nil
        }
        let index = min(Int(roll() * Float(values.count)), values.count - 1)
        return values[index]
    }
}

/// The generator used in production.
final class LocalSystemRandomizer: LocalRandomizing {

    func roll() -> Float {
        return Float.random(in: 0..<1)
    }
}

/// The generator used for standalone scoring.
///
/// The sequence is derived only from the user id and a per-user counter stored
/// in `UserDefaults`. No server seed is ever involved, and the same score
/// replay produces the same sequence, which keeps crits and rare drops
/// deterministic on the device while remaining independent of the server's
/// PRNG.
final class LocalDeviceRandomizer: LocalRandomizing {

    private let inner: LocalSeededRandomizer

    init(userID: String) {
        let defaults = UserDefaults.standard
        let key = "offlineRandomNonce_\(userID)"
        var nonce = defaults.integer(forKey: key) + 1
        if nonce > 1_000_000 {
            nonce = 1
        }
        defaults.set(nonce, forKey: key)

        var seed: UInt64 = 1469598103934665603 // FNV-1a offset basis
        for byte in userID.utf8 {
            seed ^= UInt64(byte)
            seed = seed &* 1099511628211
        }
        inner = LocalSeededRandomizer(seed: seed &+ UInt64(nonce))
    }

    func roll() -> Float {
        return inner.roll()
    }
}

/// A small xorshift generator for deterministic tests and replays.
final class LocalSeededRandomizer: LocalRandomizing {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    func roll() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state % 10_000) / 10_000
    }
}
