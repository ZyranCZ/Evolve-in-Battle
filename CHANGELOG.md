# Changelog

## 1.0.3

- Removed the `game_version` engine pin from the manifest.
- Future Gen1Recomp releases no longer disable the mod solely because the engine version changed.
- Compatibility is now best-effort: the mod attempts to load on newer engine releases and only needs an update when an actual incompatibility appears.
- `experimental` remains `false`; gameplay behavior is unchanged from 1.0.2.

## 1.0.2

- Battle/victory music now continues uninterrupted through in-battle evolutions without restarting.
- Added **EVOLUTION MUSIC** mod option.
- **OFF (default):** suppresses evolution music and leaves battle/victory music fully unchanged.
- **ON:** plays evolution music simultaneously with battle/victory music at the normal configured music volume; no ducking is applied.
- Vanilla field-evolution music behavior remains unchanged.

## 1.0.0

First stable release.

### In-battle level evolution
- Pokémon can evolve immediately after gaining an evolution-eligible level during battle.
- Works for the active battler and benched party Pokémon.
- Preserves normal level-up text, stat box and move-learning order before evolution.
- Level evolutions remain cancelable with B.
- Prevents a duplicate post-battle evolution prompt for an already handled level-up.
- Supports multiple eligible party evolutions from the same EXP distribution in party order.

### EXP Share Modes integration
- Adds `exp_share_modes@>=1.0.0` as an optional dependency for load ordering and inter-mod discovery.
- Integrates with the mod's exported `_enemyMonFainted` handler when available.
- Supports Modern Progressive EXP awarded directly to living, never-sent-out bench Pokémon outside vanilla `battle.exp_award`.
- Leaves the vanilla `battle.exp_award` fallback active when no compatible EXP Share Modes export is present.

### Evolution Stones
- FIRE, WATER, THUNDER, LEAF and MOON STONE can be used during battle.
- Reuses vanilla target compatibility and Stone evolution logic while bypassing only the vanilla mid-battle prohibition.
- Stone evolution is non-cancelable and consumes one player turn after the complete evolution flow.
- Supports active and benched targets.
- Preserves Yellow starter Pikachu's Thunder Stone refusal.

### Rare Candy
- Rare Candy can be used during battle on active or benched party Pokémon.
- Reuses vanilla level/EXP/stat/HP/happiness calculation.
- Performs level-up moves before the level-evolution eligibility check.
- Eligible Pokémon evolve immediately during battle; the evolution remains cancelable with B.
- Successful use consumes one Rare Candy and one player turn.
- Level-100 targets do not consume the item or the turn.

### Battle-state preservation
- Active evolution synchronizes species-dependent cached battler data without rebuilding volatile battle state.
- Benched evolution leaves the active battler untouched.
- Battle music is restored after returning from the standard evolution screen.

### Compatibility
- Pinned to Gen1Recomp 0.1.75 / Mod API 2.
- Declares `engine_internals` because Stone, Rare Candy and active-battler synchronization require private engine modules.
