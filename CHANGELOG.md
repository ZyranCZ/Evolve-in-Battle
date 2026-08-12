# Evolve in Battle — Changelog

## 2.0.0 — Stable Generation 2 release

- Promoted the consolidated Gold backend from `1.0.5-goldtest3` to the first stable Generation 2 release.
- Supports Red / Blue / Yellow and Pokémon Gold from one package via `games: ["gen1", "gold"]`.
- Gold level, happiness/time and stat evolutions can occur during battle while retaining native Gold eligibility, Everstone behavior and party-record rebuilding.
- Gold native held EXP.SHARE recipients, active/bench Rare Candy, all six Gen 2 evolution Stones, multi-evolution queues and B cancellation are supported.
- Evolved-species exact-level move learning uses Gold's native `Game2:learnMoveOn()` flow, including full four-move sets, HM refusal and Stop Learning.
- Preserves the seamless battle/victory music behavior and optional simultaneous evolution cue.
- Keeps the engine-version pin removed: compatibility is best-effort and should only require an update when the engine actually breaks the mod.
- No gameplay logic was changed between the verified `1.0.5-goldtest3` candidate and this `2.0.0` release; the release delta is versioning/documentation/packaging only.

## 1.0.5-goldtest3 — Consolidated pre-live Gold build

- Added native Gold full-four-move handling for **moves learned by the evolved species at the exact evolution level**. The mod now hands the pending move to Gold's own `Game2:learnMoveOn()` instead of creating a second Forget Move implementation.
- The native Forget Move UI now blocks battle continuation correctly; multiple exact-level evolved-species moves are serialized and the decline branch resumes cleanly.
- EVOLUTION MUSIC ON now stops the separate evolution overlay at Gold's native post-animation music boundary, before an evolved-species Forget Move flow can begin, while the underlying battle/victory source remains untouched.
- Added automated verification that the separate evolution source follows Gold's persisted music volume and low-pass filter settings.
- Expanded Gold stress/negative coverage: all six Gen 2 Stones; Egg/invalid target; all four trade-held evolution items; active/bench Rare Candy; level 100/Egg Candy refusal; forced-Stone B immunity; mixed cancel/success batches; Everstone skip + later eligible slot; `1 → 3 → 5` party ordering; multi-level threshold crossing; screen-start failure fallback; and preservation of Gold record metadata.
- Expanded active-state assertions for battle/HUD/side references without battle reconstruction.
- Added a current-upstream seam inventory to the Loader test so a future API rename fails with an exact module/member.
- Re-audited the narrow Gold integration seams against a newer `dev` source snapshot after a large upstream drift window; retained the no-`game_version` policy and explicit `games: ["gen1", "gold"]` targeting.

## 1.0.4-goldtest2 — Gold targeting fix

- Declared `games: ["gen1", "gold"]` so Gen1Recomp loads the Gold backend normally on Pokémon Gold.
- Kept `experimental: false`.
- Kept `game_version` absent; no engine-version gate was reintroduced.
- No gameplay/evolution logic changed from Gold Test Build 1.
- Updated the Loader harness to validate the shipped Gold target claim directly instead of injecting it in the test process.

## 1.0.3-goldtest1 — First Gold backend test build

- Added a generation router that preserves the complete v1.0.3 Gen 1 backend and activates a separate Gold backend only on a live Gen 2 game.
- Gold level-up evolution runs inside the battle flow using native `Evolution.checkMon`, `Gen2EvolutionAnim` and `Evolution.apply`.
- Added Gold `EVOLVE_LEVEL`, `EVOLVE_HAPPINESS` and `EVOLVE_STAT` support including time, happiness, current stats and Everstone.
- Native Gold held EXP.SHARE recipients can evolve in battle without depending on external Gen 1 EXP Share Modes.
- Multiple Gold evolutions from one EXP distribution are queued in party order.
- Successful or B-canceled in-battle prompts suppress an immediate duplicate post-battle prompt for the same level gain.
- Gold evolution items are discovered from native `EVOLVE_ITEM` data, including Sun Stone, while trade-held items remain trade-only.
- Enabled Gold Rare Candy from battle by reusing native `ItemEffects` and `Game2:afterRareCandy`.
- Added active Gold party-reference/HUD synchronization without rebuilding the battle.
- Added a Gold-specific in-battle audio guard for EVOLUTION MUSIC OFF/ON while leaving normal Gold evolution audio vanilla.
- Added Gold backend, native-system and real Loader smoke harnesses.
- This first test build intentionally did not yet claim Gold in the manifest; Gold targeting was corrected in the next test build so live testing could proceed normally.

## 1.0.3

- Removed the `game_version` engine pin from the manifest.
- Future Gen1Recomp releases no longer disable the mod solely because the engine version changed.
- Compatibility is best-effort: update only when an actual incompatibility appears.
- `experimental` remains `false`; gameplay behavior is unchanged from 1.0.2.

## 1.0.2

- Battle/victory music continues through in-battle evolutions without restarting.
- Added **EVOLUTION MUSIC**.
- **OFF (default):** suppresses evolution music and leaves battle/victory music unchanged.
- **ON:** plays evolution music simultaneously with battle/victory music at the configured music volume; no intentional ducking.
- Vanilla field-evolution music remains unchanged.

## 1.0.0

First stable release.

- In-battle level evolution for active and benched eligible Pokémon.
- Party-order multi-evolution queue and B cancellation.
- EXP Share Modes integration for Modern Progressive bench EXP.
- FIRE/WATER/THUNDER/LEAF/MOON Stone battle use with vanilla compatibility.
- Rare Candy in battle for active/bench targets.
- Active battler cache synchronization without resetting volatile battle state.
