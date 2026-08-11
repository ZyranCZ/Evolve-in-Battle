# Evolve in Battle — v1.0.3

A Gen1Recomp gameplay mod that allows Pokémon to evolve **during an active battle** for a more anime-like experience.

It supports:

- level-up evolution from normal battle EXP,
- level-up evolution for benched Pokémon,
- EXP Share Modes bench EXP, including never-sent-out party members,
- Evolution Stones from the battle BAG,
- Rare Candy from the battle BAG,
- active and benched targets.

## Level-up evolution from EXP

The intended sequence is:

**EXP → level-up → stat box → normal level-up moves → evolution check → evolution → evolved-species exact-level moves → battle continues**

The eligibility check runs for every party Pokémon that actually gained one or more levels from that EXP distribution, not only the active battler.

This includes:

- the currently active Pokémon,
- a Pokémon that participated earlier and was switched out,
- EXP.ALL recipients,
- never-sent-out bench Pokémon receiving EXP through compatible EXP-sharing mods.

If several party Pokémon become evolution-eligible from the same KO, their checks are queued in party order.

Level-based evolutions remain cancelable with **B**. Once an in-battle evolution prompt has been handled, the same level-up is not offered again after the battle.

## EXP Share Modes compatibility

`exp_share_modes` is an optional dependency.

When EXP Share Modes exposes its `_enemyMonFainted` integration handler, Evolve in Battle wraps that complete EXP-distribution boundary instead of relying only on vanilla `battle.exp_award`.

This is necessary for **Modern Progressive**, where living nonparticipants can receive bench EXP outside vanilla `battle.exp_award`.

The complete order remains:

**participant EXP → custom bench EXP → bench level/stat/move UI → evolution checks → battle continuation**

If EXP Share Modes is not installed, Evolve in Battle uses the vanilla `battle.exp_award` timing seam.

## Evolution Stones in battle

The following Stones can be used from the battle BAG:

- FIRE STONE
- WATER STONE
- THUNDER STONE
- LEAF STONE
- MOON STONE

A valid Stone:

1. uses the normal vanilla Stone compatibility rules,
2. consumes one Stone,
3. runs the standard non-cancelable Stone evolution,
4. learns any evolved-species move belonging exactly to the current level,
5. returns to the same battle,
6. consumes the player's turn.

Invalid Stones do not consume the item or the turn. Yellow's starter Pikachu keeps its normal Thunder Stone refusal.

Stones can target either the active Pokémon or a benched party member.

## Rare Candy in battle

Rare Candy can be used from the battle BAG on any party Pokémon, including a benched Pokémon.

A successful Rare Candy follows:

**+1 level → stat/HP update → level-up message → stat box → level-up moves → evolution eligibility check → optional evolution → battle continues**

If the Pokémon is eligible for a level evolution, the normal evolution sequence starts immediately in battle. The evolution can still be canceled with **B**.

A successful Rare Candy consumes one item and one player turn even if the evolution is canceled. A level-100 target keeps the Candy and does not spend the turn.

## Active battler synchronization

When the active Pokémon evolves, the mod refreshes only the species-dependent cached battle view instead of rebuilding the complete battler.

This preserves battle-only state such as stat stages and other volatile effects while updating the evolved species, canonical stats, typing, moves and sprite where appropriate.

A benched Pokémon evolving never replaces or refreshes the active battler.


### Seamless battle music

During an in-battle evolution, the current battle or victory theme keeps playing continuously from the same position and is never restarted.

The mod option **EVOLUTION MUSIC** controls the evolution theme:

- **OFF (default):** no evolution music plays; battle/victory music continues alone at normal volume.
- **ON:** evolution music plays simultaneously with the battle/victory music. Neither track is ducked or otherwise volume-adjusted by the mod.

## Compatibility

- **Gen1Recomp:** no engine-version pin; the mod always attempts to load on newer releases
- **Mod API:** `2`
- **EXP Share Modes:** optional; tested with `1.0.0`
- **Link fingerprint:** affected
- **Permission:** `engine_internals`

Stone/Rare Candy support still uses narrow wrappers around engine-internal modules that are not part of the stable public mod API. Because engine-version pins cause harmless game updates to disable the mod pre-emptively, this release deliberately does not declare `game_version`. Compatibility is best-effort: update the mod only if an actual engine change breaks it.

## Installation

Import `evolve_in_battle-v1.0.3.zip` through Gen1Recomp's mod manager, enable **Evolve in Battle**, and restart the game when changing the installed mod set.

## Verified release scenarios

The included smoke tests cover:

- active EXP level evolution,
- benched EXP level evolution,
- multiple party evolutions from one EXP distribution,
- Evolution Stone on active and benched Pokémon,
- invalid Stone target,
- Yellow starter Pikachu Stone refusal,
- Rare Candy on active and benched Pokémon,
- Rare Candy without an eligible evolution,
- Rare Candy at level 100,
- EXP Share Modes Modern Progressive evolution of a never-sent-out bench Pokémon.
