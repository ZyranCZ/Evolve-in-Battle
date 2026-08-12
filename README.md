# Evolve in Battle — v2.0.2

A Gen1Recomp gameplay mod that allows Pokémon to evolve **during an active battle** for a more anime-like experience.

Version **2.0.2** is the current stable release with dedicated **Pokémon Gold / Generation 2** support while retaining the existing Red / Blue / Yellow backend.

## Supported games

- Pokémon Red
- Pokémon Blue
- Pokémon Yellow
- Pokémon Gold

The manifest explicitly declares `games: ["gen1", "gold"]`, keeps `experimental: false`, and deliberately contains **no `game_version` pin**. The mod therefore does not refuse to run solely because the Gen1Recomp engine version changes.

## Level-up evolution during battle

Eligible Pokémon can evolve immediately after gaining a level in battle instead of waiting until the battle ends. This includes active Pokémon and eligible benched recipients.

On Gold the intended order is:

**EXP → level-up → normal level-up moves → evolution check → evolution → evolved-species exact-level moves → battle continues**

Several eligible Pokémon from the same EXP distribution are processed in party order. Normal level, happiness and stat evolutions remain cancelable with **B**.

## Native Gold evolution rules

The Gold backend delegates eligibility and record rebuilding to Gold's own Gen 2 systems. This preserves native behavior for:

- level evolutions,
- happiness/time evolutions,
- Tyrogue-style Attack/Defense evolutions,
- Everstone,
- native evolution data and hooks,
- Pokédex updates and Gen 2 party-record rebuilding.

Trade evolutions remain trade evolutions. King's Rock, Metal Coat, Dragon Scale and Up-Grade are not converted into battle-use evolution items.

## Evolved-species move learning

Gold species can learn a move at the exact level at which they evolve. Evolve in Battle preserves that ordering.

If the evolved Pokémon already knows four moves, the mod hands the pending move to Gold's native `Game2:learnMoveOn()` flow. The normal Forget Move selection, HM refusal, **Stop learning** branch and asynchronous UI therefore remain owned by Gold rather than being reimplemented by the mod. Multiple pending moves are processed one at a time before battle continuation.

## Evolution Stones in battle

### Red / Blue / Yellow

Supported battle-use Stones:

- Fire Stone
- Water Stone
- Thunder Stone
- Leaf Stone
- Moon Stone

### Gold

The Gold backend discovers native `EVOLVE_ITEM` rows and supports:

- Fire Stone
- Water Stone
- Thunderstone
- Leaf Stone
- Moon Stone
- Sun Stone

A valid use consumes exactly one item and one player action. Invalid targets and Eggs consume neither.

On Gold v0.1.78 these items are normally stopped one screen earlier by BattlePack because their item attributes are `ITEMMENU_NOUSE`. v2.0.2 retains the narrow PACK hand-off for **Rare Candy and native `EVOLVE_ITEM` items only**; unrelated field-only items keep Gold's normal “This isn't the time to use that!” refusal.

**Everstone follows native Generation II semantics:** it blocks level, happiness/stat, trade **and Evolution Stone** evolutions. An otherwise valid Rare Candy or Stone use therefore cannot evolve a holder. For a Stone refusal, neither the Stone nor the battle turn is consumed.

## Evolution Stones outside battle — Gold

Gold v0.1.78 contains an incomplete field-item port: `Game2:useFieldItem()` routes evolution Stones toward the party-item dispatcher, but `ItemEffects.partyAction()` has no Stone action, so selecting **USE** returns without opening the party list.

v2.0.2 fills only this missing Gold path. Using a native `EVOLVE_ITEM` Stone outside battle now opens Gold's own party menu, validates the selected Pokémon with native evolution data, runs `Gen2EvolutionAnim`, and consumes the Stone only after the evolution commits.

- invalid targets do not consume the Stone,
- Eggs are refused,
- Everstone blocks the Stone and the Stone is not consumed,
- all six Gold Stone families use the same data-driven path,
- normal **GIVE / TOSS / other field-item behavior** remains owned by Gold.

## Rare Candy in battle

Rare Candy can be used during battle on active or benched party members. Gold reuses its native Rare Candy arithmetic and follow-up move/evolution flow. Level-100 Pokémon and Eggs are refused without consuming the item or the turn.

## EXP Share support

On Red / Blue / Yellow, the existing optional **EXP Share Modes** integration remains available for compatible bench EXP behavior.

On Gold, native held **EXP.SHARE** remains the authority. Evolve in Battle observes the resulting level gains rather than replacing Gen 2 EXP calculations.

## Active battler synchronization

When the active Pokémon evolves, the existing battle is kept alive and Gold's battle/HUD references are synchronized to the evolved party record. The mod does not create a replacement battle, so battle-owned stages and other battle state remain intact. Benched evolution leaves the active battler untouched.

## Seamless battle music

The mod includes **EVOLUTION MUSIC**:

- **OFF (default):** the current battle/victory track continues without being replaced or restarted.
- **ON:** the evolution cue plays simultaneously on a separate source while the underlying battle/victory track continues.

On Gold the separate evolution cue follows the current music volume/filter options and ends before any evolved-species Forget Move flow. Normal evolutions outside the mod's in-battle path remain vanilla.

## Compatibility

```text
Mod API:           2
Version:           2.0.2
Games:             gen1, gold
Experimental:      false
Engine-version pin absent
Permission:        engine_internals
Link fingerprint:  affected
```

`engine_internals` is currently required because the public Mod API does not expose every precise battle-queue, PACK, active-reference and evolution-audio seam needed by the mod.

## Installation

Import `evolve_in_battle-v2.0.2.zip` through Gen1Recomp's Mod Manager and enable it normally for the game being launched.
