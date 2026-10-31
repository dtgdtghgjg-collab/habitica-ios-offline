# Offline mode

This document describes the offline support added to the app: what works without
a network connection, how writes are queued and replayed, how scoring and the
daily rollover are computed locally, and what is deliberately left to the
server.

## Goals

1. Every screen keeps working from the Realm cache with no connection.
2. Every write the player makes is persisted immediately and replayed later,
   in the order it was made.
3. The local game state (task values, stats, streaks, dailies) stays plausible
   while offline, and is replaced by the authoritative server state as soon as
   the queue is drained.

## What works offline

| Action | Offline behaviour |
| --- | --- |
| Browse habits, dailies, todos, rewards | Works (already read from Realm) |
| Create / edit / delete a task | Saved to Realm, queued |
| Create / edit / delete a tag | Saved to Realm, queued |
| Reorder a task | Applied to the local order, queued |
| Score a habit / daily / todo / reward | Computed locally, queued |
| Critical hits | Rolled locally from the computed crit stat |
| Gear, class and buff bonuses | Read from Realm, applied to the local stats |
| Loot drops | Generated locally with Habitica's chance and daily cap |
| Quest progress | Boss damage / collection applied locally, marker queued |
| Achievements | First task, first created task and 21-day streaks unlocked locally |
| Daily rollover (cron) | Applied locally once per Habitica day, `runCron` queued |
| Buying a reward | Scored locally (gold is deducted), queued as a score |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ UI                                                           │
│  OfflineStatusBanner        (pill above the tab bar)         │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ HabitRPG (app target)                                        │
│  NetworkMonitor     NWPathMonitor + NSError.isConnectionError│
│  OfflineState       shared observable state (online, pending)│
│  OfflineScoreEngine optimistic score + enqueue               │
│  OfflineCronEngine  local day rollover                       │
│  OfflineSyncEngine  queue replay, backoff, silent errors     │
│  LocalScoreCalculator  Swift port of the server's math       │
│  LocalStatsComputed    gear / class / buff stat bonuses      │
│  LocalCrit             critical hit chance and multiplier    │
│  LocalDropGenerator    drop chance, daily cap, item choice   │
│  LocalQuestProgress    boss damage and collection items      │
│  LocalRandomizer       system / seeded random source         │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ Habitica Database (framework)                                │
│  RealmPendingOperation      persisted queue row              │
│  PendingOperationSnapshot   value copy used by the engine    │
│  PendingOperationRepository enqueue / coalesce / backoff     │
│  OfflineMutationRepository  apply score, drops, quest, stats │
│  OfflineGameContentRepository  gear, quest and drop tables   │
│  OfflineGameModels          public value types for the above │
└──────────────────────────────────────────────────────────────┘
```

Wiring points:

* `HabiticaAppDelegate.setupOfflineSupport()` starts both engines after
  `setupDatabase()`.
* `TaskRepositoryImpl` branches on `OfflineState.shared.isOffline` for
  `score`, `createTask`, `updateTask`, `deleteTask`, `createTag`, `updateTag`,
  `deleteTag` and `moveTask`, and falls back to the same path when a request
  fails with a connection error.
* `UserRepository.runCron` enqueues `runCron` instead of calling the API.
* `HabiticaNetworkErrorHandler.handle` reports connection failures to
  `NetworkMonitor`, so the UI flips to offline before NWPathMonitor notices.

## The queue

`RealmPendingOperation` is a plain Realm row:

| Field | Meaning |
| --- | --- |
| `id` | primary key (UUID) |
| `userID` | owner, so accounts never mix queues |
| `type` | `createTask`, `updateTask`, `deleteTask`, `scoreTask`, `scoreChecklist`, `questProgress`, `moveTask`, `createTag`, `updateTag`, `deleteTag`, `runCron` |
| `entityID` | task or tag id; `"quest"` for `questProgress`; `nil` for `runCron` |
| `payload` | small JSON dictionary (e.g. `{"direction":"up"}`) |
| `sequence` | monotonic counter, the replay order |
| `attempts`, `nextAttemptAt`, `lastError` | backoff bookkeeping |

**The payload never contains a full task.** When an operation is replayed the
current local state is read from Realm. A coalesced queue therefore always sends
the newest version of an object, and the queue stays small.

### Coalescing rules

| New operation | Existing operation for the same entity | Result |
| --- | --- | --- |
| `updateTask` | `createTask` | Dropped, the create already carries the latest state |
| `updateTask` | `updateTask` | Payload replaced in place |
| `createTask` | `createTask` | Payload replaced in place |
| `deleteTask` | `createTask` | Both removed: the server never learned about the task |
| `deleteTask` | anything else | All operations for that entity removed, then one `deleteTask` added |
| `updateTag` | `updateTag` | Payload replaced in place |
| `deleteTag` | anything for that tag | All removed, then one `deleteTag` added |
| `questProgress` | `questProgress` | Replaced in place: one marker is enough |
| `scoreTask`, `moveTask`, `runCron` | – | Never coalesced, order matters |

### Replay

`OfflineSyncEngine` flushes when connectivity returns, on
`didBecomeActive`, whenever the queue changes, and on a timer (15 s after
launch, 60 s after a successful drain, 20 s after a failure).

Operations are replayed strictly in `sequence` order, one at a time. The first
operation that cannot be completed stops the flush, so ordering is preserved.

Each request's outcome is classified:

| Outcome | Action |
| --- | --- |
| Success | Row deleted, next operation |
| Connection error | Retry in 5 s, offline state reported |
| HTTP 429 or 5xx | Retry in 30 s |
| Other HTTP 4xx | Dropped (the server rejected it permanently) |
| No response | Retry in 15 s |

Error alerts are suppressed during replay by temporarily swapping
`AuthenticatedCall.errorHandler` for a silent handler; the real handler is
restored as soon as each request finishes.

When the queue is drained the engine calls `retrieveUser(withTasks: true)`, so
task values, stats, streaks and the `lastCron` date are replaced by the
server's.

A task created offline carries a client UUID. When the `createTask` replay
succeeds the server answers with its own id, so the engine deletes the local
row and rewrites the `entityID` of everything still queued for that task
(`PendingOperationRepository.remapEntity`). Without that, a score queued after
the create would be replayed against an id the server has never seen. The same
remap is done for tags.

## Local scoring

`LocalScoreCalculator` is a Swift port of the server's `scoreTask.js`,
`statsComputed.js`, `updateStats.js`, `crit.js`, `randomDrop.js` and
`statHelpers.js`.

Exact:

* task value delta `0.9747^value`, clamped to `[-47.27, 21.27]`;
* reverse delta when unchecking a task (iterative solve);
* experience, gold and health formulas, including priority, streak bonus and
  diminishing returns for health;
* mana gain and cap;
* level-up loop, `toNextLevel`, health refill on level-up, stat points;
* checklist multipliers;
* cron damage for unchecked dailies;
* critical hit chance and multiplier (`LocalCrit`);
* gear, class and buff bonuses in the computed stats (`LocalStatsComputed`);
* drop chance, daily cap, first drops and rarity buckets (`LocalDropGenerator`);
* boss damage, rage and collection distribution (`LocalQuestProgress`);
* the first-task, first-created-task and 21-day streak achievements.

The local stats are written straight into Realm, so the header, the level-up
sheet and the faint dialog all react as usual.

### Computed stats

Habitica never uses the raw `stats` values in a formula. It adds:

1. the bonus of every equipped item (`user.items.gear.equipped`);
2. the same bonus again when the item's `klass` or `specialClass` matches the
   player's class;
3. active buffs (`stats.buffs`);
4. `floor(capByLevel(level) / 2)`.

`OfflineGameContentRepository.statBonuses(userID:)` reads the equipped keys from
Realm, looks the items up in the cached `RealmGear` content and returns a
public `OfflineStatBonuses` value. `LocalScoreCalculator.computedStats` adds it,
the buffs and the level bonus to the base stats. `OfflineCronEngine` passes the
same value into cron scoring, so gear reduces cron damage through CON.

### Critical hits

`LocalCrit` ports `crit.js`:

```
chance     = 0.03 * (1 + stat / 100)
multiplier = 1.5 + 4 * stat / (stat + 200)
```

The server crits on **Strength** (`critStat = .strength`). Changing the single
`LocalCrit.critStat` constant to `.perception` makes crits Perception-based
without touching the formulas. Perception already drives gold and drop chance
in both the server and this port, exactly as Habitica does.

The crit multiplier is applied to experience, gold, mana and quest progress,
and it raises the drop chance, matching `_tmp.crit`.

### Gear and class bonuses

Habitica has no flat "warrior deals 10% more damage" multiplier. Class identity
comes from the stats each class' gear boosts and from the shared formulas:

| Class | Signature stats | Effect |
| --- | --- | --- |
| Warrior | STR, CON | more boss damage, less damage taken |
| Rogue | PER, STR | more gold and a higher drop chance |
| Mage (`wizard`) | INT, PER | more experience and mana |
| Healer | INT, CON | more mana, less damage taken |

`LocalClassBonus` keeps those formulas in one place: `1 + STR / 200` for boss
damage, `1 + INT * 0.025` for experience, `1 + PER * 0.02` for gold,
`max(0.1, 1 - CON / 250)` for damage taken and `INT * 2 + 30` for max mana.
Matching class gear contributes its stats twice, which is what makes a class
feel different without inventing new rules.

### Loot drops

`LocalDropGenerator` is a pure function (it never touches Realm) ported from
`randomDrop.js`:

* the chance is `min(|value - 21.27|, 37.5) / 150 + 0.02`, multiplied by task
  priority, the new-player bonus, streak, Perception, contributor level,
  rebirths, streak achievements, the crit multiplier and completed checklist
  items, then passed through `diminishingReturns(..., 0.75)`;
* the first roll decides whether the score also counts as a quest collection
  item (before the cap check, as on the server);
* the cap is `(subscriber ? 2 : 1) * (5 + floor(PER / 25) + contributorLevel)`
  per Habitica day; a new day resets the counter;
* a player with no food always gets food; a player with no eggs or potions gets
  Habitica's "first drops" (one egg and one potion);
* the rarity roll picks food (`> 0.6`), an egg (`> 0.3`) or a potion from the
  Golden / rare / uncommon / common bucket.

The daily counter is stored in `UserDefaults` under
`offlineLastDropDate_<userID>` and `offlineLastDropCount_<userID>`.
`OfflineMutationRepository.applyDrops` adds the item to the matching
`RealmOwnedItem` list and the score response carries a temporary
`_tmp.drop`, so the usual toast appears.

### Quests

When the player has an active party quest, `LocalQuestProgress` applies the
server's rules:

* todos and dailies deal `ceil(delta * crit * (1 + STR / 200))` to the boss,
  habits `ceil(delta * crit * (0.5 + STR / 400))`;
* boss health is reduced by that amount (never below zero);
* rage grows from the damage the party takes; the iOS quest model stores only
  the value, so healing and mana-drain effects are left to the server;
* collection quests distribute the found items over the remaining targets
  (`shuffle(remaining).prefix(found)`), exactly like `_processCollectionQuest`.

The local score writes the new progress into `RealmQuestProgress` and returns a
temporary `_tmp.quest`. A single `questProgress` marker is queued for the UI;
its replay is a no-op because the server recalculates quest progress from the
replayed scores.

### Achievements

`OfflineMutationRepository.applyAchievements` unlocks `completedTask` on the
first upward score, `createdTask` on the first task created offline and
increments/decrements `streak` at the 21-day milestones. The server confirms
these on replay.

### Why the replayed score does not touch the task

The optimistic score already moved the task value and the streak. The server
response only carries the *delta* plus absolute stats, so
`TaskLocalRepository.update` would add the delta on top of the value we already
applied. Replayed scores therefore use
`OfflineMutationRepository.applyServerScoreStats`, which overwrites the
**absolute** stat values and leaves the task alone. The task list is refreshed
from the server when the queue is drained.

## Local cron

`OfflineCronEngine` runs only while offline. It:

1. reads the Habitica day start (`preferences.dayStart`) and the reference date
   from `UserDefaults` (`offlineLastCron_<userID>`), falling back to
   `user.lastCron`;
2. counts how many Habitica days have passed, capped at 7;
3. applies cron damage to every unchecked, non-group daily for each missed day;
4. unchecks all dailies and recomputes `isDue` from `nextDue`;
5. enqueues a `runCron` operation so the server reconciles;
6. stores the new reference date.

On the very first offline launch there is no reference date, so the engine
adopts "now" and waits for the next rollover instead of inventing damage.

The server remains the source of truth: when `runCron` is replayed the server
runs its own cron from its own `lastCron`, and the subsequent
`retrieveUser(withTasks:)` replaces the local values.

## Conflicts

There is no merge: the last writer wins, and the server is the authority.

* A write made offline is replayed against the newest server state, so a task
  edited on two devices ends up with the offline version if it is replayed
  last.
* A score is a delta operation, so scores from two devices compose instead of
  overwriting each other.
* When the queue is drained, the full server snapshot overwrites local values,
  which resolves any divergence in stats, streaks or due dates.

## Known limitations

* **User profile and settings writes are not queued.** Changing the avatar,
  buying gear, allocating stat points, party/guild actions, chat and challenges
  still require a connection and fail with the usual offline error.
* **Checklist item scoring is folded into `updateTask`.** Ticking a checklist
  item offline updates the item and the task locally and queues an
  `updateTask`; the checklist XP bonus is applied by the server on replay.
* **Offline randomness is not reproducible after a reinstall.** Crits, drops and
  collection items use `SystemRandomNumberGenerator` in production; the server
  rolls again on replay, so the authoritative result can differ. Tests inject
  `LocalSeededRandomizer` to get a fixed sequence.
* **Drop state lives in `UserDefaults`.** Deleting the app clears the daily drop
  counter, so a fresh install can receive more than the daily cap until the
  server snapshot arrives.
* **No conflict UI.** Divergence is resolved silently by the server snapshot.
* **`isSynced` is not used for scores.** The banner is the only indication that
  scores are pending; a task's "not synced" indicator still means "this task's
  definition has not reached the server".
* **Group tasks** that need approval are not modelled: an offline score of a
  group task may apply damage locally that the server later rejects.
* **Boss rewards are granted by the server.** Killing a boss offline updates the
  local HP bar, but the quest-completion rewards and chat arrive on sync.
* **Notifications and party chat** are unaffected and simply unavailable.

## Testing

Simulator:

1. Log in with a network connection so the Realm cache is populated.
2. Turn the Mac's Wi-Fi off (or use Network Link Conditioner → 100% loss).
3. The pill above the tab bar should read *Offline — changes are saved on this
   device*.
4. Create a habit, edit a daily, delete a todo, tick a checklist item, score a
   habit up and down, reorder tasks.
5. Force-quit and relaunch. The queue survives; the pill shows the pending
   count.
6. Re-enable the network. The pill turns blue (*Syncing N changes*), then green
   (*All changes synced*) and disappears.
7. Compare with the web client: task values, streaks, XP, gold and HP should
   match.

Day rollover:

1. Set the device date forward by one day while offline, keeping the app
   backgrounded, then foreground it.
2. Unchecked dailies lose HP, their streaks reset and they become unchecked.
3. Go online: the server cron runs and the authoritative values are pulled.

Game mechanics:

1. Score tasks up until a crit appears; the toast, gold, XP and quest damage
   should all include the crit multiplier.
2. Equip class gear and compare the gold/XP/damage with the web client; class
   gear should be worth twice its listed stats.
3. Score tasks repeatedly and confirm drops stop at the daily cap, then set the
   device date forward one day and confirm the cap resets.
4. Start a boss quest, score a task and check that the boss HP falls by
   `ceil(delta * crit * (1 + STR / 200))`; do the same for a collection quest
   and check that the found items match the remaining needs.
5. Check that the first task ever scored does not drop anything, and that the
   first task created offline sets `achievements.createdTask`.

Edge cases worth checking:

* create a task offline and delete it before going online — nothing is sent;
* create a task offline, edit it twice, then go online — one `POST`;
* kill the app mid-flush — `resetInFlightState` clears the stale `isSyncing`
  flags on the next launch;
* log out while offline — the queue is keyed by user id and stays with that
  account.

## Build notes

* `Habitica Database` gained:
  * `Models/Sync/RealmPendingOperation.swift`
  * `Models/Offline/OfflineGameModels.swift`
  * `Repositories/PendingOperationRepository.swift`
  * `Repositories/OfflineMutationRepository.swift`
  * `Repositories/OfflineGameContentRepository.swift`
* The app target gained:
  * `HabitRPG/Offline/NetworkMonitor.swift`, `OfflineState.swift`,
    `OfflineScoreEngine.swift`, `OfflineCronEngine.swift`,
    `OfflineSyncEngine.swift`
  * `HabitRPG/Offline/LocalScoreCalculator.swift`, `LocalStatsComputed.swift`,
    `LocalCrit.swift`, `LocalDropGenerator.swift`, `LocalQuestProgress.swift`,
    `LocalRandomizer.swift`
  * `HabitRPG/UI/General/OfflineStatusBanner.swift`
* `RealmUserAchievements.streak`, `.createdTask`, `.completedTask`,
  `.hatchedPet`, `.fedPet`, `.purchasedEquipment`, `.rebirths`,
  `.rebirthLevel`, `RealmQuestProgressCollect.key`, `.count`,
  `RealmQuestBossRage.value` and the `RealmQuestParticipant` fields are now
  `@objc dynamic` so the offline engine can persist them. These are additive
  properties with defaults, and `AppDelegate` sets
  `deleteRealmIfMigrationNeeded = true`, so no migration block is needed.
* `UserDefaults` keys owned by offline mode:
  * `offlineLastCron_<userID>` — reference date for the local cron
  * `offlineLastDropDate_<userID>` — last Habitica day a drop was generated
  * `offlineLastDropCount_<userID>` — drops generated that day
* The banner and drop dialog strings are English literals on purpose; move them
  to `Strings/Localizable.strings` (and `L10n`) before shipping translations.
