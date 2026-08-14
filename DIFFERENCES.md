# Differences from vanilla Gen1Recomp

Evolve in Battle intentionally changes **when and where** evolution can occur. It does not replace the game's species evolution data or invent a second Gold evolution engine.

## Gen 1 — Red / Blue / Yellow

### Level-up evolution

Vanilla Gen1Recomp defers level-based evolution until after battle. The existing Gen 1 backend moves the check into the battle EXP sequence after the level/stat/move UI. It applies to every party member whose level increased in the relevant distribution, including compatible bench EXP supplied by EXP Share Modes.

### Evolution Stones / Rare Candy

The existing Gen 1 battle paths remain unchanged from v1.0.3: five Gen 1 Stones and battle Rare Candy reuse the established vanilla-compatible logic.

### Battle music

For this mod's in-battle evolutions, EVOLUTION MUSIC OFF preserves the current battle/victory source; ON mixes the evolution cue beside it.

## Gold

### Evolution timing, not eligibility

Gold's native `Evolution.checkMon` remains the authority for level, happiness/time, stat and item evolution conditions. The mod moves that decision into the battle sequence after the relevant level-up move handling and before normal battle continuation.

### Native EXP and held EXP.SHARE

Gold's own `Battle:awardExperience` remains the EXP authority. The mod observes which party slots actually crossed levels. It does not port the Gen 1 EXP Share Modes arithmetic into Gold.

### Party record / battle state

Native `Evolution.apply` creates the evolved Gen 2 party record. The mod then synchronizes the existing active battle/HUD references if that slot is active; it never starts a replacement battle. Benched evolution does not touch the active battler.

### Evolved-species exact-level moves

Gold's evolution code can grant moves the **new species** learns exactly at the evolution level. A free slot stays entirely vanilla. On Gen1Recomp v0.1.86, `Gen2EvolutionAnim` already hands a full-four-move case into native `Game2:learnMoveOn()`; v2.0.3 detects this and installs no replacement. The former bridge remains capability-gated for older engines that only report the pending move.

Consequently the Forget Move selection, HM refusal, “Stop learning” branch and asynchronous UI remain Gold-native. Multiple exact-level moves are processed one at a time before battle continuation.

### Evolution items

The Gold backend discovers native `EVOLVE_ITEM` rows instead of inheriting the Gen 1 five-Stone list. Fire, Water, Thunder, Leaf, Moon and Sun Stone use the same data-driven path. Trade-held items remain `EVOLVE_TRADE` triggers and are never treated as battle Stones.

Gold v0.1.86 still rejects these field-only items in `Gen2PackMenu` before `BattleState:useItem` can see them. v2.0.3 retains that **one** BattlePack gate bypass only for Rare Candy and native `EVOLVE_ITEM` rows. All unrelated `ITEMMENU_NOUSE` items keep vanilla behavior.

Everstone behavior follows the original Gold item flow. `EvoStoneEffect` checks the target’s held item **before** it sets forced evolution, so an Everstone holder refuses an Evolution Stone even though the later `EvolvePokemon` item branch itself does not repeat that check. The mod reproduces this outer gate in battle: no evolution, no consumed Stone and no spent turn.

### Evolution Stones outside battle

Gen1Recomp v0.1.86 implements this path natively through the merged `item_effects` registry. v2.0.3 detects action `stone` and does not override `Game2:useFieldItem()` on the target engine. For older compatible engines such as v0.1.78, the previous narrow fallback remains available only when that native action is absent.

The resulting path opens `Gen2PartyMenu`, applies Gold's Everstone/valid-target rules, runs the native forced `Gen2EvolutionAnim`, and consumes the Stone only after a successful commit. Other field-item families and held-item GIVE behavior are unchanged.

### Rare Candy

Gold already implements Rare Candy arithmetic and `Game2:afterRareCandy`; vanilla battle PACK context simply does not normally allow the item. The mod bypasses that context prohibition, then delegates the effect, level moves and subsequent evolution back to Gold.

### Duplicate post-battle evolution

A level-derived in-battle prompt that was actually handled clears that slot's post-battle evolvable flag on success or B-cancel. If the mod cannot open the in-battle evolution screen, the flag is restored so vanilla Gold remains the fallback.

### Battle music

Only while an evolution initiated by this mod is active, a narrow Gold audio guard prevents `Gen2EvolutionAnim` from replacing the underlying battle/victory source. EVOLUTION MUSIC ON renders a separate evolution source with the current Gold music volume/filter settings. That overlay is explicitly stopped at Gold's post-animation music boundary before any full-moveset Forget Move UI begins.

Normal Gold evolutions outside the mod's in-battle context remain vanilla.

## Engine-internal scope

The public Mod API still does not expose every seam required for precise Gold battle queue insertion, PACK timing, active-reference synchronization and evolution-movie audio isolation. The package therefore retains `engine_internals` while keeping generation-specific code isolated.

There is deliberately no `game_version` gate.
