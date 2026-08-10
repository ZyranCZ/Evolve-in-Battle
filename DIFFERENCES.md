# Differences from vanilla Gen1Recomp 0.1.75

Evolve in Battle intentionally changes when and where evolution can occur while retaining vanilla evolution eligibility and species data.

## Level-up evolution

Vanilla Gen1Recomp defers level-based evolution until after battle. This mod moves the evolution check into the battle EXP sequence after the level-up/stat/move UI has completed.

The check applies to every party member whose level increased during the relevant EXP distribution, including benched Pokémon.

## EXP Share Modes integration

EXP Share Modes Modern Progressive can award additional EXP to never-sent-out bench Pokémon outside vanilla `battle.exp_award`. When its exported `_enemyMonFainted` handler is available, this mod uses that full distribution boundary so those level gains receive the same in-battle evolution check.

## Evolution Stones

Vanilla Gen1Recomp rejects Evolution Stones while a battle is active. This mod bypasses only that timing prohibition for FIRE, WATER, THUNDER, LEAF and MOON STONE, then delegates compatibility/evolution rules back to vanilla logic.

A successful Stone use spends the player's battle action after the evolution flow finishes.

## Rare Candy

Vanilla Gen1Recomp also rejects Rare Candy during battle. This mod enables a battle-specific Rare Candy flow that reuses vanilla level/stat mutation, then performs the normal level-up UI, move learning and level-evolution eligibility check before spending the player's battle action.

## Engine-internal scope

The public Mod API does not currently expose every seam required for these behaviors. The release therefore declares `engine_internals` and is pinned to Gen1Recomp 0.1.75.

## Battle music continuity

- In-battle evolution no longer replaces the current battle/victory music source.
- Evolution music is synthesized/played on a separate source and mixed over the still-running battle track.
- Field evolutions retain vanilla music switching behavior.
