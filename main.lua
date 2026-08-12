-- Evolve in Battle v2.0.2
-- Target: Gen1Recomp Mod API 2 (no engine-version pin)
--
-- Stable release. Supports in-battle evolution from ordinary EXP, EXP Share Modes bench EXP,
-- Evolution Stones, and Rare Candy:
--   * Evolution Stones still bypass only vanilla's mid-battle Stone gate.
--   * BagMenu.new is wrapped directly ONLY to intercept RARE_CANDY while a
--     battle is active; all other rows call the original BagMenu callback.
--   * Rare Candy uses vanilla's own level/stat calculation with battle=nil,
--     then runs level text -> stat box -> level moves -> level-evolution check.
--   * Whether or not an evolution is available/cancelled, the Candy consumes
--     exactly one item and one player turn after the full flow finishes.
--   * Active-battler cached stats/species are synchronized without rebuilding
--     volatile battle state.
--
-- Gold additionally wraps Gen2PackMenu's BattlePack hand-off so field-only
-- Rare Candy / EVOLVE_ITEM rows can reach the battle handler instead of being
-- rejected early as ITEMMENU_NOUSE. It also fills Gold v0.1.78's missing
-- overworld EVOLVE_ITEM party-action path, so Stones work both inside and
-- outside battle. Unrelated field-only items stay vanilla.
--
-- The ItemEffects/Evolution/BagMenu function wrappers are engine-internal overrides and are why the
-- manifest declares engine_internals; engine version is intentionally not pinned.

local function defineSharedOptions(mod)
  -- Shared contract across Red / Blue / Yellow / Gold. OFF is deliberately
  -- the default and means the currently playing battle/victory track is never
  -- stopped, restarted, seeked or ducked by an in-battle evolution.
  mod.options:define({
    { key = "evolution_music", label = "EVOLUTION MUSIC", type = "toggle", default = false },
  })
end

local function installGen1(mod)
  -- Generation-isolated loader: current gen2check is intentionally static and
  -- cannot prove that installGen1() is unreachable on Gold. Build the src.*
  -- name only inside this Gen 1 backend so the audit reports one explicit
  -- unresolved generation-gated require site instead of misclassifying every
  -- preserved Gen 1 internal as a Gold dependency.
  local function requireGen1(suffix)
    return require("src." .. suffix)
  end

  local Evolution = requireGen1("pokemon.Evolution")
  local BattleState = requireGen1("battle.BattleState")
  local ItemEffects = requireGen1("inventory.ItemEffects")
  local Music = requireGen1("core.Music")
  local EvolutionState = requireGen1("ui.EvolutionState")
  local VanillaBagMenu = requireGen1("ui.BagMenu")
  local Screens = requireGen1("ui.Screens")
  local Bag = requireGen1("inventory.Bag")
  local TextBox = requireGen1("render.TextBox")
  local Strings = requireGen1("core.Strings")

  local unpack_ = table.unpack or unpack
  local function pack(...)
    return { n = select("#", ...), ... }
  end

  local STONES = {
    FIRE_STONE = true,
    WATER_STONE = true,
    THUNDER_STONE = true,
    LEAF_STONE = true,
    MOON_STONE = true,
  }

  -- mon -> { battle, snapshot, expectedSpecies }
  -- Set by the ItemEffects.use override after vanilla Stone validation succeeds.
  -- Consumed synchronously when BagMenu calls Evolution.evolve(..., "ITEM").
  local pendingStone = setmetatable({}, { __mode = "k" })

  -- mon -> { battle, snapshot, synced }
  -- Lives only for the duration of an in-battle evolution movie.
  local pendingSync = setmetatable({}, { __mode = "k" })

  ---------------------------------------------------------------------------
  -- Helpers
  ---------------------------------------------------------------------------

  -- Snapshot whether the active battler is still using the canonical species
  -- views BEFORE evolution changes the party-mon tables. This lets us preserve
  -- Transform/Conversion-like battle-only overrides instead of rebuilding the
  -- whole battler and erasing volatile state.
  local function captureBattleView(battle, mon)
    local battler = battle and battle.player
    if not battler or battler.mon ~= mon then return nil end

    return {
      battler = battler,
      statsCanonical = (battler.curStats == mon.stats),
      typesCanonical = (battler.def ~= nil and battler.curTypes == battler.def.types),
      movesCanonical = (battler.curMoves == mon.moves),
    }
  end

  local function syncActiveBattler(battle, mon, snapshot)
    if not battle or not snapshot then return end
    local battler = snapshot.battler
    if not battler or battle.player ~= battler or battler.mon ~= mon then return end

    -- Build only a canonical reference view for the evolved species. Do NOT
    -- replace the live battler: stages, Substitute, confusion, trapping,
    -- recharge, Leech Seed, X-item flags, etc. must survive the evolution.
    local fresh = BattleState.makeBattler(battle.data, mon, true, battle.game.save)

    battler.def = fresh.def
    battler.name = fresh.name
    battler.shownHP = mon.hp

    if snapshot.statsCanonical then
      battler.curStats = fresh.curStats
      -- A transformed/custom stats view is also our conservative signal to
      -- keep its copied battle sprite instead of suddenly drawing the new form.
      battler.sprite = fresh.sprite
    end
    if snapshot.typesCanonical then
      battler.curTypes = fresh.curTypes
    end
    if snapshot.movesCanonical then
      battler.curMoves = fresh.curMoves
    end
  end

  ---------------------------------------------------------------------------
  -- In-battle evolution audio: keep the battle/victory track alive
  ---------------------------------------------------------------------------

  -- Vanilla EvolutionState calls Music.play(evolution), which replaces and
  -- STOPS the currently playing battle source. It later calls restoreMap(),
  -- and v1.0.1 then had to call playBattle()/playVictory() again, restarting
  -- the track from the beginning.  During evolutions started by this mod we
  -- instead leave the main Music source untouched and synthesize the evolution
  -- cue on a separate LOVE Source. The battle/victory music therefore keeps
  -- advancing underneath it and resumes at the exact same position naturally.
  local vanillaMusicPlay = Music.play
  local vanillaMusicRestoreMap = Music.restoreMap
  local vanillaEvolutionUpdate = EvolutionState.update

  local function evolutionMusicEnabled()
    return mod.options:get("evolution_music") == true
  end

  -- data -> { count, battle, overlay }
  -- Weak keys keep datasets collectible on a game/version reload.
  local battleEvolutionAudio = setmetatable({}, { __mode = "k" })

  local OVERLAY_BUFFER_COUNT = 8
  local OVERLAY_INITIAL_FILL = 4
  local OVERLAY_FILL_PER_UPDATE = 3

  local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
  end

  local function musicOptions(entry)
    local opts = entry and entry.battle and entry.battle.game
      and entry.battle.game.save and entry.battle.game.save.options or nil
    local level = clamp(opts and opts.musicVol or 7, 0, 7)
    local filter = clamp(opts and opts.musicFilter or 0, 0, 3)
    return level, filter
  end

  local function applyOverlayMix(src, entry)
    if not src then return end
    local level, filter = musicOptions(entry)
    -- Match Music.lua's base volume and user's music volume. The battle track
    -- remains at exactly the same volume while the evolution cue plays.
    pcall(src.setVolume, src, 0.7 * (level / 7))
    if filter > 0 then
      pcall(src.setFilter, src, {
        type = "lowpass", volume = 1, highgain = 0.4 ^ filter,
      })
    else
      pcall(src.setFilter, src)
    end
  end

  local function stopEvolutionOverlay(data)
    local entry = data and battleEvolutionAudio[data] or nil
    if not entry or not entry.overlay then return end
    local overlay = entry.overlay
    entry.overlay = nil
    if overlay.source then pcall(overlay.source.stop, overlay.source) end
  end

  local function fillChipOverlay(overlay, limit)
    if not overlay or overlay.kind ~= "chip" then return end
    local source, engine = overlay.source, overlay.engine
    if not source or not engine then return end
    local ChipSynth = requireGen1("core.ChipSynth")
    local free = source:getFreeBufferCount()
    while free > 0 and limit > 0 do
      local ok, data = pcall(
        ChipSynth.soundData, engine, ChipSynth.MUSIC_BUFFER_SAMPLES, 2
      )
      if not ok or not data then
        overlay.failed = true
        return
      end
      source:queue(data)
      free = free - 1
      limit = limit - 1
    end
  end

  local function startEvolutionOverlay(data)
    local entry = data and battleEvolutionAudio[data] or nil
    if not entry or not love or not love.audio then return false end

    stopEvolutionOverlay(data)

    local song = Music.special(data, "evolution")
    local def = data and data.audio and data.audio.songs and data.audio.songs[song]
    if not song or not def then return false end

    local overlay
    if def.file then
      local ok, source = pcall(love.audio.newSource, def.file, "stream")
      if not ok or not source then return false end
      pcall(source.setLooping, source, true)
      overlay = { kind = "file", source = source }
    else
      local ChipSynth = requireGen1("core.ChipSynth")
      if not (love.audio.newQueueableSource and ChipSynth.newEngine) then return false end
      local okEngine, engine = pcall(ChipSynth.newEngine, data, def, { allowLoops = true })
      if not okEngine or not engine then return false end
      local okSource, source = pcall(
        love.audio.newQueueableSource,
        ChipSynth.SAMPLE_RATE, 16, 2, OVERLAY_BUFFER_COUNT
      )
      if not okSource or not source then return false end
      overlay = { kind = "chip", source = source, engine = engine }
    end

    entry.overlay = overlay
    applyOverlayMix(overlay.source, entry)

    -- Keep the original battle/victory source completely untouched: no pause,
    -- restart, seek, or volume change. Both tracks play at the user's normal
    -- music-volume setting.

    if overlay.kind == "chip" then
      fillChipOverlay(overlay, OVERLAY_INITIAL_FILL)
      if overlay.failed then
        stopEvolutionOverlay(data)
        return false
      end
    end

    local okPlay = pcall(overlay.source.play, overlay.source)
    if not okPlay then
      stopEvolutionOverlay(data)
      return false
    end
    return true
  end

  local function armBattleEvolutionAudio(battle)
    local data = battle and battle.data
    if not data then return end
    local entry = battleEvolutionAudio[data]
    if not entry then
      entry = { count = 0, battle = battle, overlay = nil }
      battleEvolutionAudio[data] = entry
    end
    entry.count = entry.count + 1
    entry.battle = battle
  end

  local function disarmBattleEvolutionAudio(battle)
    local data = battle and battle.data
    local entry = data and battleEvolutionAudio[data] or nil
    if not entry then return end
    entry.count = math.max(0, (entry.count or 1) - 1)
    if entry.count == 0 then
      stopEvolutionOverlay(data)
      battleEvolutionAudio[data] = nil
    end
  end

  local wrappedMusicPlay
  wrappedMusicPlay = function(data, song, loop, ctx)
    local entry = data and battleEvolutionAudio[data] or nil
    if entry and entry.count > 0 and song == Music.special(data, "evolution") then
      -- Default OFF: swallow the evolution cue completely. The battle/victory
      -- theme continues at full volume on its existing source and position.
      if not evolutionMusicEnabled() then return end

      -- Optional ON mode: add the evolution cue in parallel while leaving the
      -- still-running battle/victory source untouched at its normal volume.
      if not startEvolutionOverlay(data) and mod.log and mod.log.warn then
        mod.log:warn("Could not start parallel evolution music; battle music left uninterrupted")
      end
      return
    end
    return vanillaMusicPlay(data, song, loop, ctx)
  end

  local wrappedMusicRestoreMap
  wrappedMusicRestoreMap = function(data)
    local entry = data and battleEvolutionAudio[data] or nil
    if entry and entry.count > 0 then
      -- EvolutionState's restoreMap belongs to field evolutions. During a live
      -- battle it would replace the still-playing battle/victory source.
      return
    end
    return vanillaMusicRestoreMap(data)
  end

  local wrappedEvolutionUpdate
  wrappedEvolutionUpdate = function(self, dt)
    local data = self and self.game and self.game.data or nil
    local entry = data and battleEvolutionAudio[data] or nil
    if entry and entry.overlay and entry.overlay.kind == "chip" then
      fillChipOverlay(entry.overlay, OVERLAY_FILL_PER_UPDATE)
      if entry.overlay.failed then stopEvolutionOverlay(data) end
    end

    local results = pack(vanillaEvolutionUpdate(self, dt))

    -- The visual evolution movie is over once EvolutionState sets done. Stop
    -- only the parallel cue here; keep suppressing restoreMap until vanilla's
    -- completion callback (including evolved-species move learning) returns.
    if entry and self and self.done then stopEvolutionOverlay(data) end
    return unpack_(results, 1, results.n)
  end

  local function showMessages(game, messages, onDone)
    if not messages or #messages == 0 then
      if onDone then onDone() end
      return
    end
    game.stack:push(TextBox.new(game, table.concat(messages, "\f"), onDone))
  end

  ---------------------------------------------------------------------------
  -- Engine-internal evolution wrapper
  ---------------------------------------------------------------------------

  -- Keep the original implementation.  All in-battle evolutions started by
  -- this mod go through this helper so the original function is called exactly
  -- once and the battle is resumed only after evolved-species move learning.
  local vanillaEvolve = Evolution.evolve

  local function beginBattleEvolution(battle, mon, newSpecies, via, snapshot, onDone)
    if not battle or not mon or not newSpecies then
      if onDone then onDone(false) end
      return
    end

    pendingSync[mon] = {
      battle = battle,
      snapshot = snapshot,
      synced = false,
    }
    armBattleEvolutionAudio(battle)

    local finished = false
    vanillaEvolve(battle.game, mon, newSpecies, function()
      if finished then return end
      finished = true

      local entry = pendingSync[mon]
      local evolved = entry and entry.synced or false
      pendingSync[mon] = nil

      -- Battle/victory music never stopped during the evolution. Release the
      -- restoreMap guard; there is deliberately no Music.playBattle restart.
      disarmBattleEvolutionAudio(battle)

      if onDone then onDone(evolved) end
    end, via)
  end

  ---------------------------------------------------------------------------
  -- Level-up evolution (vanilla EXP + EXP Share Modes integration)
  ---------------------------------------------------------------------------

  local function evolveAfterLevelUp(battle, mon, snapshot)
    if not battle then return end

    local newSpecies, evo = Evolution.pendingFor(battle.game, mon, { kind = "levelup" })
    if not newSpecies then return end

    -- Vanilla would otherwise offer the same evolution again in afterBattle().
    -- Clear only once we actually found an eligible evolution.
    if battle.leveledUp then battle.leveledUp[mon] = nil end

    beginBattleEvolution(
      battle, mon, newSpecies, evo and evo.method or "LEVEL", snapshot, nil
    )
  end

  local function capturePartyLevels(battle)
    if not battle or not battle.game or not battle.game.save then return nil end
    local party = {}
    local before = setmetatable({}, { __mode = "k" })
    for _, mon in ipairs(battle.game.save.party or {}) do
      party[#party + 1] = mon
      before[mon] = tonumber(mon.level) or 0
    end
    local activeMon = battle.player and battle.player.mon or nil
    local activeSnapshot = activeMon and captureBattleView(battle, activeMon) or nil
    return {
      party = party,
      before = before,
      activeMon = activeMon,
      activeSnapshot = activeSnapshot,
    }
  end

  local function queueLevelEvolutions(battle, snap, source)
    if not battle or not snap then return end
    for _, mon in ipairs(snap.party) do
      local before = snap.before[mon]
      local after = tonumber(mon.level) or before or 0
      if before ~= nil and after > before then
        local targetMon = mon
        local targetSnapshot = (mon == snap.activeMon) and snap.activeSnapshot or nil
        if mod.log and mod.log.info then
          mod.log:info("EXP level-up detected via %s: %s %d->%d%s",
            tostring(source or "battle.exp_award"), tostring(mon.species), before, after,
            mon == snap.activeMon and " (active)" or " (bench)")
        end
        -- At both integration points nextInsert is positioned immediately
        -- after all EXP / grew-level / stat-box / learn-move rows and before
        -- enemyMonFainted's continuation. actNext therefore gives the anime
        -- evolution the exact desired place in the queue.
        battle:actNext(function()
          evolveAfterLevelUp(battle, targetMon, targetSnapshot)
        end)
      end
    end
  end

  local function trackLevelChanges(battle, source, fn)
    local snap = capturePartyLevels(battle)
    if not snap then return fn() end
    local results = pack(fn())
    queueLevelEvolutions(battle, snap, source)
    return unpack_(results, 1, results.n)
  end

  -- EXP Share Modes 1.0.0 deliberately awards MODERN PROGRESSIVE bench EXP
  -- OUTSIDE BattleState:awardExp(): its awardModernBench() calls
  -- Experience.apply() directly after vanilla enemyMonFainted() has returned.
  -- Consequently battle.exp_award cannot observe a never-sent-out bench mon.
  --
  -- The mod intentionally publishes _enemyMonFainted as its inter-mod
  -- dispatcher handler. Our optional dependency makes exp_share_modes load
  -- first when present, so wrap that export and observe the COMPLETE EXP flow
  -- (vanilla participants + its extra bench pool) as one transaction. Its
  -- handler restores nextInsert to the end of its injected bench UI before it
  -- returns, so queueLevelEvolutions lands after those rows but before the
  -- trainer/wild continuation.
  local expShareHandle = mod.find and mod.find("exp_share_modes") or nil
  local expShareExports = expShareHandle and expShareHandle.exports or nil
  local vanillaExpShareHandler = expShareExports and expShareExports._enemyMonFainted or nil
  local wrappedExpShareHandler = nil

  if type(vanillaExpShareHandler) == "function" then
    wrappedExpShareHandler = function(originalEnemyMonFainted, battle)
      return trackLevelChanges(battle, "exp_share_modes", function()
        return vanillaExpShareHandler(originalEnemyMonFainted, battle)
      end)
    end
  else
    -- No compatible EXP Share Modes export is active: vanilla and ordinary
    -- hook-based EXP distributors are fully contained by battle.exp_award.
    mod.hooks:wrap("battle.exp_award", function(next, ctx)
      local battle = ctx and ctx.battle or nil
      if not battle then return next(ctx) end
      return trackLevelChanges(battle, "battle.exp_award", function()
        return next(ctx)
      end)
    end)
  end

  ---------------------------------------------------------------------------
  -- Rare Candy in the battle BAG
  ---------------------------------------------------------------------------

  -- Vanilla intentionally refuses RARE_CANDY whenever battle ~= nil.
  -- Its successful field-use path already performs the canonical level/EXP/
  -- stat/HP/happiness mutation and returns extra.leveledTo, so reuse exactly
  -- that calculation with battle=nil and own only the battle-specific UI tail.
  local vanillaItemUse = ItemEffects.use

  local function useRareCandyInBattle(battle, bagList)
    local game = battle and battle.game
    if not game or not bagList then return end

    Screens.push(game, "Party" .. "Menu", {
      pickOnly = true,
      onSwitch = function(mon)
        local beforeLevel = captureBattleView(battle, mon)
        local result, messages, extra = vanillaItemUse(
          game.data, game.save, "RARE_CANDY", mon, nil, nil, game.overworld
        )

        -- Level 100 / otherwise ineffective: preserve vanilla failure, leave
        -- the BAG open and do not spend an item or battle turn.
        if result ~= "consumed" or not extra or not extra.leveledTo then
          showMessages(game, messages)
          return
        end

        Bag.remove(game.save, "RARE_CANDY", 1)
        bagList:close()

        -- ItemEffects replaced mon.stats with a new table. Refresh the active
        -- battler's canonical view immediately, while preserving Transform-like
        -- custom battle views and every volatile battle flag/stage.
        syncActiveBattler(battle, mon, beforeLevel)

        local turnSpent = false
        local function finishCandyTurn()
          if turnSpent then return end
          turnSpent = true
          if not battle.result then battle:itemUsed({}) end
        end

        -- Mirror BagMenu.lua's vanilla Rare Candy sequence exactly, except the
        -- BAG is closed underneath it and the tail resumes battle afterwards.
        showMessages(game, messages, function()
          local StatBox = BattleState.StatBox
          game.stack:push(StatBox.new(game, mon, function()
            local Experience = requireGen1("battle.Experience")
            local def = game.data.pokemon[mon.species]
            local moves = Experience.movesLearnedAt(def, extra.leveledTo)
            local i = 0

            local function nextStep()
              i = i + 1
              local moveId = moves[i]
              if not moveId then
                -- This is the requested eligibility check. The same evolution
                -- registry + evolution.check hook used everywhere else decides.
                local evoTo, evo = Evolution.pendingFor(
                  game, mon, { kind = "levelup" }
                )

                if not evoTo then
                  finishCandyTurn()
                  return
                end

                local evolutionSnapshot = captureBattleView(battle, mon)
                beginBattleEvolution(
                  battle,
                  mon,
                  evoTo,
                  evo and evo.method or "LEVEL",
                  evolutionSnapshot,
                  function()
                    -- Level evolutions remain cancelable with B. Cancelling
                    -- does not refund the Rare Candy or the battle action.
                    finishCandyTurn()
                  end
                )
                return
              end

              for _, mv in ipairs(mon.moves) do
                if mv.id == moveId then return nextStep() end
              end

              local mdef = game.data.moves[moveId]
              if not mdef then return nextStep() end

              if #mon.moves < 4 then
                table.insert(mon.moves, { id = moveId, pp = mdef.pp })
                local name = mon.nickname or def.name
                showMessages(game, { Strings("%s learned\n%s!", name, mdef.name) }, nextStep)
              else
                Screens.push(game, "MoveLearn" .. "Menu", mon, moveId, nextStep)
              end
            end

            nextStep()
          end))
        end)
      end,
    })
  end

  -- Directly wrap the builtin BagMenu factory. Screens.lua caches the factory
  -- TABLE returned by require(), so mutating this table's .new remains effective
  -- even if the builtin factory was resolved before this mod finishes loading.
  -- Field BagMenu and every non-Candy battle row remain on the original path.
  local vanillaBagMenuNew = VanillaBagMenu.new
  local wrappedBagMenuNew
  wrappedBagMenuNew = function(game, opts)
    local state = vanillaBagMenuNew(game, opts)
    local battle = opts and opts.battle or nil
    if not battle or not state or type(state.onChoose) ~= "function" then
      return state
    end

    local originalOnChoose = state.onChoose
    state.onChoose = function(item, list)
      list = list or state
      if not item or list.swapIndex or item.value ~= "RARE_CANDY" then
        return originalOnChoose(item, list)
      end
      return useRareCandyInBattle(battle, list)
    end
    return state
  end

  ---------------------------------------------------------------------------
  -- Direct Stone override: bypass ONLY vanilla's mid-battle Stone gate
  ---------------------------------------------------------------------------

  -- BagMenu.lua holds a reference to the ItemEffects TABLE, not a copy of the
  -- use function, so replacing ItemEffects.use here changes the exact call at
  -- BagMenu.lua:46 while leaving every other method/field untouched.
  --
  -- Vanilla ItemEffects.use blocks STONES whenever battle ~= nil at lines
  -- 138-142.  For those five items only, call the original with battle=nil.
  -- The remainder of the original Stone implementation still validates:
  --   * target exists
  --   * Yellow starter Pikachu refuses Thunder Stone
  --   * species actually has an ITEM evolution matching this Stone
  -- and returns the same { evolveTo = ... } result as field use.
  local wrappedItemUse
  wrappedItemUse = function(data, save, itemId, target, battle, moveIndex, ow)
    if battle and STONES[itemId] then
      local results = pack(vanillaItemUse(data, save, itemId, target, nil, moveIndex, ow))
      local result, extra = results[1], results[3]

      if result == "consumed" and target and extra and extra.evolveTo then
        pendingStone[target] = {
          battle = battle,
          snapshot = captureBattleView(battle, target),
          expectedSpecies = extra.evolveTo,
        }
      elseif target then
        pendingStone[target] = nil
      end

      return unpack_(results, 1, results.n)
    end

    return vanillaItemUse(data, save, itemId, target, battle, moveIndex, ow)
  end

  ---------------------------------------------------------------------------
  -- Catch vanilla BagMenu's Stone-triggered Evolution.evolve call
  ---------------------------------------------------------------------------

  local wrappedEvolve
  wrappedEvolve = function(game, mon, newSpecies, onDone, via)
    local stone = mon and pendingStone[mon] or nil

    if via == "ITEM" and stone and stone.battle and stone.expectedSpecies == newSpecies then
      pendingStone[mon] = nil
      local battle = stone.battle

      beginBattleEvolution(
        battle,
        mon,
        newSpecies,
        via,
        stone.snapshot,
        function(evolved)
          -- Vanilla BagMenu already consumed the Stone before calling evolve.
          -- Our only missing battle-specific tail is spending the player's turn.
          -- Wait until the evolution AND evolved-species move learning finish.
          if evolved and not battle.result then
            battle:itemUsed({})
          end
          if onDone then onDone() end
        end
      )
      return
    end

    return vanillaEvolve(game, mon, newSpecies, onDone, via)
  end

  ---------------------------------------------------------------------------
  -- Battler sync event
  ---------------------------------------------------------------------------

  mod.events:on("pokemon.evolved", function(ev)
    if not ev or not ev.mon then return end
    local entry = pendingSync[ev.mon]
    if not entry then return end

    syncActiveBattler(entry.battle, ev.mon, entry.snapshot)
    entry.synced = true
  end)

  -- IMPORTANT: arbitrary engine-internal mutation is not part of the loader's
  -- rollback journal. Install these overrides LAST, after all registry/hook/
  -- event setup above has succeeded, so an earlier entry-chunk failure cannot
  -- leave a half-installed patch behind.
  if wrappedExpShareHandler and expShareExports then
    expShareExports._enemyMonFainted = wrappedExpShareHandler
  end
  ItemEffects.use = wrappedItemUse
  Evolution.evolve = wrappedEvolve
  VanillaBagMenu.new = wrappedBagMenuNew
  Music.play = wrappedMusicPlay
  Music.restoreMap = wrappedMusicRestoreMap
  EvolutionState.update = wrappedEvolutionUpdate

  if wrappedExpShareHandler then
    mod.log:info("Evolve in Battle v2.0.2 loaded (EXP Share Modes integration active, battle music continuity, evolution music default OFF)")
  else
    mod.log:info("Evolve in Battle v2.0.2 loaded (vanilla battle.exp_award tracking, battle music continuity, evolution music default OFF)")
  end
end


-----------------------------------------------------------------------------
-- Pokémon Gold / Gen 2 backend
-----------------------------------------------------------------------------

local function installGen2(mod, liveGame)
  -- Gold owns a different battle, party-record, item and evolution stack.  Keep
  -- the Gen 1 implementation above completely untouched and adapt only the
  -- timing/context seams that Gold itself does not expose yet.
  local Battle = require("src.battle.gen2.Battle")
  local BattleState = require("src.ui.gen2.BattleState")
  local PackMenu = require("src.ui.gen2.PackMenu")
  local Evolution = require("src.core.gen2.Evolution")
  local EvolutionAnim = require("src.ui.gen2.EvolutionAnim")
  local ItemEffects = require("src.core.gen2.ItemEffects")
  local Palettes = require("src.world.gen2.Palettes")
  local Screens = require("src.ui.Screens")
  local Music = require("src.core.Music")

  local unpack_ = table.unpack or unpack
  local function pack(...)
    return { n = select("#", ...), ... }
  end

  local LEVEL_MARKER = "__evolve_in_battle_gen2_level"
  local CANDY_MARKER = "__evolve_in_battle_gen2_candy"
  local LEARN_TAIL = "__evolve_in_battle_gen2_learn_tail"

  ---------------------------------------------------------------------------
  -- Shared/native helpers
  ---------------------------------------------------------------------------

  local function timeOfDay()
    return Palettes.clockDaytime()
  end

  local function partyOf(state)
    return (state and state.save and state.save.party)
      or (state and state.battle and state.battle.party)
      or {}
  end

  local function partyIndex(party, mon)
    for i, member in ipairs(party or {}) do
      if member == mon then return i end
    end
    return nil
  end

  -- The authoritative question is Gold's own evolution table + method
  -- registry.  With force=true, Evolution.checkMon permits EVOLVE_ITEM and
  -- blocks the level/happiness/stat paths; EVOLVE_TRADE still requires link.
  local function evolutionItemExists(data, itemId)
    if not (data and data.pokemon and itemId) then return false end
    for _, def in pairs(data.pokemon) do
      for _, row in ipairs((type(def) == "table" and def.evolutions) or {}) do
        if row.method == Evolution.ITEM and row.item == itemId then return true end
      end
    end
    return false
  end

  local function holdsEverstone(mon)
    if not mon then return false end
    if type(Evolution.holdsEverstone) == "function" then
      return Evolution.holdsEverstone(mon) and true or false
    end
    return mon.item == (Evolution.EVERSTONE or "EVERSTONE")
  end

  local function activeIndex(battle)
    if not battle then return nil end
    if battle.playerIndex then return battle.playerIndex end
    for i, mon in ipairs(battle.party or {}) do
      if mon == battle.player then return i end
    end
    return nil
  end

  -- Evolution.apply creates a NEW Gold party record.  For an active mon the
  -- battle engine still holds the old table in battle.player, so update only
  -- those identity/canonical caches.  All stages and side state remain on the
  -- Battle object, while Evolution.apply already carries unknown record fields
  -- (including volatile state) forward.
  local function syncGoldActive(state, index, oldMon, evolved)
    local battle = state and state.battle
    if not (battle and evolved and index) then return end
    if activeIndex(battle) ~= index and battle.player ~= oldMon then return end

    battle.player = evolved
    battle.playerIndex = index
    if type(battle.syncSides) == "function" then battle:syncSides() end

    if state.shownMon and state.shownMon.player == oldMon then
      state.shownMon.player = evolved
    end
    if state.shownHp then state.shownHp.player = evolved.hp end
    if state.shownLevel ~= nil then state.shownLevel = evolved.level end
    if state.shownExp ~= nil and type(state.expPixels) == "function" then
      local ok, pixels = pcall(state.expPixels, state,
        evolved, evolved.level, evolved.experience)
      if ok then state.shownExp = pixels end
    end
  end

  local function syncGoldLevelOnly(state, index, mon)
    local battle = state and state.battle
    if not (battle and mon and index) then return end
    if activeIndex(battle) ~= index and battle.player ~= mon then return end
    if state.shownHp then state.shownHp.player = mon.hp end
    if state.shownLevel ~= nil then state.shownLevel = mon.level end
    if state.shownExp ~= nil and type(state.expPixels) == "function" then
      local ok, pixels = pcall(state.expPixels, state,
        mon, mon.level, mon.experience)
      if ok then state.shownExp = pixels end
    end
  end

  local function resumeBattleQueue(state)
    if not state then return end
    state.phase = "resolving"
    if type(state.advanceQueue) == "function" then state:advanceQueue() end
  end

  local function spendItemTurn(state, itemId)
    if not (state and state.battle) then return end
    state.queue = state.queue or {}
    if type(state.pushAll) == "function" and type(state.battle.takeTurn) == "function" then
      state:pushAll(state.battle:takeTurn({ kind = "item", item = itemId }) or {})
    end
    resumeBattleQueue(state)
  end

  ---------------------------------------------------------------------------
  -- Gold in-battle evolution audio guard
  ---------------------------------------------------------------------------

  -- Gen2EvolutionAnim's native movie calls Music.stop(), starts
  -- Music_Evolution, then stops music again for the caught-mon SFX.  That is
  -- correct outside battle.  For this mod's in-battle movies only, leave the
  -- battle/victory Music source untouched.  With EVOLUTION MUSIC ON, synthesize
  -- the evolution song on a second LOVE Source, exactly as the Gen 1 backend
  -- does, so neither source has to seek/restart the other.
  local vanillaMusicPlay = Music.play
  local vanillaMusicStop = Music.stop
  local vanillaDuckForFanfare = Music.duckForFanfare
  local vanillaEvolutionAnimNew = EvolutionAnim.new
  local vanillaEvolutionAnimUpdate = EvolutionAnim.update
  local vanillaEvolutionAnimNextLearn = EvolutionAnim.nextLearn

  local audioByAnim = setmetatable({}, { __mode = "k" })
  local candyAudioPending = setmetatable({}, { __mode = "k" })
  local activeAudioCount = 0
  local currentAudio

  local OVERLAY_BUFFER_COUNT = 8
  local OVERLAY_INITIAL_FILL = 4
  local OVERLAY_FILL_PER_UPDATE = 3

  local function evolutionMusicEnabled()
    return mod.options:get("evolution_music") == true
  end

  local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
  end

  local function audioOptions(entry)
    local game = entry and entry.game
    local opts = game and (game.options or (game.save and game.save.options)) or nil
    return clamp(opts and opts.musicVol or 7, 0, 7),
      clamp(opts and opts.musicFilter or 0, 0, 3)
  end

  local function applyOverlayMix(src, entry)
    if not src then return end
    local level, filter = audioOptions(entry)
    pcall(src.setVolume, src, 0.7 * (level / 7))
    if filter > 0 then
      pcall(src.setFilter, src, {
        type = "lowpass", volume = 1, highgain = 0.4 ^ filter,
      })
    else
      pcall(src.setFilter, src)
    end
  end

  local function stopGoldOverlay(entry)
    if not (entry and entry.overlay) then return end
    local overlay = entry.overlay
    entry.overlay = nil
    if overlay.source then pcall(overlay.source.stop, overlay.source) end
  end

  local function fillGoldOverlay(overlay, limit)
    if not overlay or overlay.kind ~= "chip" then return end
    local source, engine = overlay.source, overlay.engine
    if not source or not engine then return end
    local ChipSynth = require("src.core.ChipSynth")
    local free = source:getFreeBufferCount()
    while free > 0 and limit > 0 do
      local ok, data = pcall(
        ChipSynth.soundData, engine, ChipSynth.MUSIC_BUFFER_SAMPLES, 2
      )
      if not ok or not data then
        overlay.failed = true
        return
      end
      source:queue(data)
      free = free - 1
      limit = limit - 1
    end
  end

  local function startGoldOverlay(entry, song)
    if not (entry and entry.game and love and love.audio) then return false end
    stopGoldOverlay(entry)

    local data = entry.game.data
    local def = data and data.audio and data.audio.songs and data.audio.songs[song]
    if not def then return false end

    local overlay
    if def.file then
      local ok, source = pcall(love.audio.newSource, def.file, "stream")
      if not ok or not source then return false end
      pcall(source.setLooping, source, true)
      overlay = { kind = "file", source = source }
    else
      local ChipSynth = require("src.core.ChipSynth")
      if not (love.audio.newQueueableSource and ChipSynth.newEngine) then return false end
      local okEngine, engine = pcall(ChipSynth.newEngine, data, def, { allowLoops = true })
      if not okEngine or not engine then return false end
      local okSource, source = pcall(
        love.audio.newQueueableSource,
        ChipSynth.SAMPLE_RATE, 16, 2, OVERLAY_BUFFER_COUNT
      )
      if not okSource or not source then return false end
      overlay = { kind = "chip", source = source, engine = engine }
      fillGoldOverlay(overlay, OVERLAY_INITIAL_FILL)
      if overlay.failed then
        pcall(source.stop, source)
        return false
      end
    end

    applyOverlayMix(overlay.source, entry)
    local ok = pcall(overlay.source.play, overlay.source)
    if not ok then
      pcall(overlay.source.stop, overlay.source)
      return false
    end
    entry.overlay = overlay
    return true
  end

  local function armGoldAudio(anim, game)
    if not anim or audioByAnim[anim] then return end
    local entry = {
      game = game,
      anim = anim,
      overlay = nil,
      pendingFullMove = nil,
      learningFullMove = false,
    }
    audioByAnim[anim] = entry
    activeAudioCount = activeAudioCount + 1
    currentAudio = entry
  end

  local function disarmGoldAudio(anim)
    local entry = anim and audioByAnim[anim] or nil
    if not entry then return end
    stopGoldOverlay(entry)
    audioByAnim[anim] = nil
    activeAudioCount = math.max(0, activeAudioCount - 1)
    if currentAudio == entry then currentAudio = nil end
  end

  local wrappedEvolutionAnimNew
  wrappedEvolutionAnimNew = function(game, opts)
    opts = opts or {}
    local inBattle = opts.__evolve_in_battle == true
      or (opts.mon and candyAudioPending[opts.mon] ~= nil)
    if not inBattle then return vanillaEvolutionAnimNew(game, opts) end

    local originalDone = opts.onDone
    local holder = {}
    opts.onDone = function(result)
      disarmGoldAudio(holder.anim)
      if originalDone then return originalDone(result) end
    end
    local anim = vanillaEvolutionAnimNew(game, opts)
    holder.anim = anim
    armGoldAudio(anim, game)
    return anim
  end

  -- Current upstream Gold reports an exact-level evolved-species move in
  -- EvolutionAnim.full when all four slots are occupied, but that screen does
  -- not itself open ForgetMove.  Gold already has the complete native
  -- Game2:learnMoveOn flow, so for this mod's in-battle animations only bridge
  -- that one missing presentation seam instead of inventing a move learner.
  -- The wrapper waits until EvolutionAnim advances past its own "wants to
  -- learn" page; then the native forget/decline/HM flow runs, and only after it
  -- completes do we ask EvolutionAnim for the next exact-level move.
  local wrappedEvolutionAnimNextLearn
  wrappedEvolutionAnimNextLearn = function(self, ...)
    local audio = self and audioByAnim[self] or nil
    if audio and audio.pendingFullMove and not audio.learningFullMove then
      local moveId = audio.pendingFullMove
      audio.pendingFullMove = nil
      local game = audio.game
      local mon = self.evolved
      if game and type(game.learnMoveOn) == "function" and mon then
        audio.learningFullMove = true
        game:learnMoveOn(mon, moveId, function()
          audio.learningFullMove = false
          return wrappedEvolutionAnimNextLearn(self)
        end)
        return
      end
      -- A future engine without learnMoveOn keeps upstream's existing
      -- degradation rather than hanging the evolution screen.
    end

    local beforeFull = #(self and self.full or {})
    local results = pack(vanillaEvolutionAnimNextLearn(self, ...))
    local afterFull = #(self and self.full or {})
    if audio and afterFull > beforeFull then
      audio.pendingFullMove = self.full[beforeFull + 1]
    end
    return unpack_(results, 1, results.n)
  end

  local wrappedEvolutionAnimUpdate
  wrappedEvolutionAnimUpdate = function(self, dt)
    local entry = self and audioByAnim[self] or nil
    if entry and entry.overlay and entry.overlay.kind == "chip" then
      fillGoldOverlay(entry.overlay, OVERLAY_FILL_PER_UPDATE)
      if entry.overlay.failed then stopGoldOverlay(entry) end
    end
    return vanillaEvolutionAnimUpdate(self, dt)
  end

  local wrappedMusicStop
  wrappedMusicStop = function(...)
    if activeAudioCount > 0 then
      -- Gen2EvolutionAnim calls Music.stop twice: once before starting the
      -- evolution cue and once after the congratulations page before the
      -- caught-mon SFX / move-learning tail.  The first must NOT touch the
      -- battle/victory BGM.  At the second, stop only our parallel overlay so
      -- evolution music cannot leak into post-evolution move prompts.
      if currentAudio and currentAudio.anim
          and currentAudio.anim.phase == "evolved" then
        stopGoldOverlay(currentAudio)
      end
      return
    end
    return vanillaMusicStop(...)
  end

  local wrappedMusicPlay
  wrappedMusicPlay = function(data, song, loop, ctx)
    if activeAudioCount > 0
        and (song == "Music_Evolution" or (ctx and ctx.reason == "evolution")) then
      if evolutionMusicEnabled() and currentAudio and not currentAudio.overlay then
        startGoldOverlay(currentAudio, song or "Music_Evolution")
      end
      return
    end
    return vanillaMusicPlay(data, song, loop, ctx)
  end

  local wrappedDuckForFanfare
  wrappedDuckForFanfare = function(...)
    -- Gen2EvolutionAnim plays Sfx_CaughtMon at the end. In battle that cue may
    -- coexist with the battle/victory track; do not let fanfare bookkeeping
    -- pause/duck the underlying song while our guarded movie is active.
    if activeAudioCount > 0 then return end
    return vanillaDuckForFanfare(...)
  end

  ---------------------------------------------------------------------------
  -- EXP level-up boundary -> Gold-native in-battle evolution queue
  ---------------------------------------------------------------------------

  local vanillaAwardExperience = Battle.awardExperience
  local wrappedAwardExperience
  wrappedAwardExperience = function(self, ...)
    local before = {}
    for i, mon in ipairs(self.party or {}) do before[i] = tonumber(mon.level) or 0 end

    local results = pack(vanillaAwardExperience(self, ...))

    local slots = {}
    for i, mon in ipairs(self.party or {}) do
      local old = before[i]
      local now = tonumber(mon.level) or old or 0
      if old ~= nil and now > old then slots[#slots + 1] = i end
    end
    if #slots > 0 and type(self.emit) == "function" then
      -- awardExperience runs inside faint resolution.  Emitting after the
      -- native EXP/level/move events puts this marker before replacement/send
      -- and battle-end events, while BattleState drains everything before it.
      self:emit({ kind = LEVEL_MARKER, slots = slots })
    end
    return unpack_(results, 1, results.n)
  end

  -- A full moveset pauses on choose-forget.  Its resolution messages are
  -- generated later and would otherwise be appended behind the already queued
  -- marker/replacement. Tag only those late messages and let the UI insert them
  -- immediately before the pending marker so move learning truly finishes
  -- before evolution.
  local vanillaResolveForget = Battle.resolveForget
  local vanillaDeclineForget = Battle.declineForget

  local function tagNewBattleEvents(battle, beforeCount)
    for i = beforeCount + 1, #(battle.events or {}) do
      local event = battle.events[i]
      if type(event) == "table" then event[LEARN_TAIL] = true end
    end
  end

  local wrappedResolveForget
  wrappedResolveForget = function(self, ...)
    local beforeCount = #(self.events or {})
    local results = pack(vanillaResolveForget(self, ...))
    tagNewBattleEvents(self, beforeCount)
    return unpack_(results, 1, results.n)
  end

  local wrappedDeclineForget
  wrappedDeclineForget = function(self, ...)
    local beforeCount = #(self.events or {})
    local results = pack(vanillaDeclineForget(self, ...))
    tagNewBattleEvents(self, beforeCount)
    return unpack_(results, 1, results.n)
  end

  local vanillaPushAll = BattleState.pushAll
  local wrappedPushAll
  wrappedPushAll = function(self, events)
    local queue = self.queue or {}
    local hasMarker = false
    for _, event in ipairs(queue) do
      if event and event.kind == LEVEL_MARKER then hasMarker = true break end
    end
    if not hasMarker then return vanillaPushAll(self, events) end

    local late, normal = {}, {}
    for _, event in ipairs(events or {}) do
      if type(event) == "table" and event[LEARN_TAIL] then
        event[LEARN_TAIL] = nil
        late[#late + 1] = event
      else
        normal[#normal + 1] = event
      end
    end
    if #late == 0 then return vanillaPushAll(self, events) end

    -- These events came from the forget decision that just completed. Put them
    -- at the front, ahead of any later choose-forget and the evolution marker.
    for i = #late, 1, -1 do table.insert(queue, 1, late[i]) end
    if #normal > 0 then vanillaPushAll(self, normal) end
  end

  local function beginGoldEvolution(state, index, entry, force, onDone)
    local party = partyOf(state)
    local mon = party[index]
    local game = state and state.game
    if not (mon and game and game.stack) then
      if onDone then onDone({ canceled = false, evolved = nil }) end
      return false
    end

    local oldMon = mon
    state.phase = "eib_evolving"
    Screens.push(game, "Gen2EvolutionAnim", {
      mon = mon,
      entry = entry,
      index = index,
      party = party,
      save = state.save,
      force = force == true,
      __evolve_in_battle = true,
      onDone = function(result)
        -- Gen2EvolutionAnim follows the normal screen contract: its owner pops
        -- it after completion. Do that before advancing the underlying battle.
        game.stack:pop()
        local evolved = result and result.evolved or party[index]
        if result and result.evolved then
          syncGoldActive(state, index, oldMon, result.evolved)
        end
        if onDone then onDone(result or { evolved = evolved }) end
      end,
    })
    return true
  end

  local function runLevelEvolutionBatch(state, marker)
    local slots = marker and marker.slots or {}
    local cursor = 0

    local function nextOne()
      cursor = cursor + 1
      local index = slots[cursor]
      if not index then return resumeBattleQueue(state) end

      local party = partyOf(state)
      local mon = party[index]
      if not mon or mon.isEgg then return nextOne() end

      local entry = Evolution.checkMon(state.game.data, mon, {
        timeOfDay = timeOfDay(),
      })
      if not entry then return nextOne() end

      -- The prompt is now being handled in battle. Clear Gold's normal
      -- post-battle flag BEFORE the screen starts, so success and B-cancel both
      -- suppress the duplicate offer for this same level-up.
      state.evolvable = state.evolvable or {}
      state.evolvable[index] = nil

      if not beginGoldEvolution(state, index, entry, false, function()
        nextOne()
      end) then
        -- If a screen could not start, restore vanilla's post-battle safety net
        -- instead of silently losing the evolution opportunity.
        state.evolvable[index] = true
        return nextOne()
      end
    end

    nextOne()
  end

  ---------------------------------------------------------------------------
  -- Gold Rare Candy in the battle PACK
  ---------------------------------------------------------------------------

  local function showNoTurnMessage(state, text)
    state.message = text or ItemEffects.TEXT_NO_EFFECT
    state.messageTimer = 0
    state.phase = "resolving"
  end

  local function openPartyTarget(state, onChoose)
    local game = state.game
    Screens.push(game, "Gen2PartyMenu", {
      prompt = "useItem",
      onCancel = function()
        game.stack:pop()
        if type(state.openPack) == "function" then state:openPack() end
      end,
      onChoose = function(index, mon)
        game.stack:pop()
        onChoose(index, mon)
      end,
    })
  end

  local function finishCandyAfterNativeFlow(state, itemId, index, oldMon)
    local party = partyOf(state)
    local evolved = party[index]
    candyAudioPending[oldMon] = nil
    if evolved and evolved ~= oldMon then
      syncGoldActive(state, index, oldMon, evolved)
    else
      syncGoldLevelOnly(state, index, evolved or oldMon)
    end
    spendItemTurn(state, itemId)
  end

  local function runCandyTail(state, payload)
    local party = partyOf(state)
    local mon = party[payload.index]
    if not mon then return resumeBattleQueue(state) end

    candyAudioPending[mon] = { state = state, index = payload.index }
    state.phase = "eib_evolving"
    state.game:afterRareCandy(mon, payload.result, function()
      finishCandyAfterNativeFlow(state, payload.itemId, payload.index, mon)
    end)
  end

  local function useGoldRareCandy(state, itemId)
    openPartyTarget(state, function(index, mon)
      local result = ItemEffects.useOnMon(itemId, mon, state.game.data)
      if not (result and result.used) then
        return showNoTurnMessage(state, result and result.text)
      end

      state:consumeItem(itemId)
      syncGoldLevelOnly(state, index, mon)

      state.queue = state.queue or {}
      state.queue[#state.queue + 1] = { kind = "message", text = result.text }
      state.queue[#state.queue + 1] = {
        kind = CANDY_MARKER,
        itemId = itemId,
        index = index,
        result = result,
      }
      resumeBattleQueue(state)
    end)
  end

  ---------------------------------------------------------------------------
  -- Gold native EVOLVE_ITEM path in the battle PACK (Sun Stone included)
  ---------------------------------------------------------------------------

  local function useGoldEvolutionItem(state, itemId)
    openPartyTarget(state, function(index, mon)
      if not mon or mon.isEgg then
        return showNoTurnMessage(state, mon and ItemEffects.TEXT_CANT_USE_ON_EGG)
      end

      -- Pokémon Gold checks EVERSTONE in EvoStoneEffect before it sets
      -- wForceEvolution and enters EvolvePokemon. Evolution.checkMon(force)
      -- models only the later EvolvePokemon walk, so reproduce that outer
      -- item-effect gate here or an in-battle Stone would incorrectly bypass
      -- Everstone. A refusal consumes neither the Stone nor the battle turn.
      if holdsEverstone(mon) then
        return showNoTurnMessage(state, ItemEffects.TEXT_NO_EFFECT)
      end

      local entry = Evolution.checkMon(state.game.data, mon, {
        force = true,
        item = itemId,
        timeOfDay = timeOfDay(),
      })
      if not entry or entry.method ~= Evolution.ITEM then
        return showNoTurnMessage(state, ItemEffects.TEXT_NO_EFFECT)
      end

      state:consumeItem(itemId)
      local started = beginGoldEvolution(state, index, entry, true, function(result)
        if result and result.evolved then
          spendItemTurn(state, itemId)
        else
          -- Forced item evolution is not B-cancelable. If upstream ever
          -- refuses to apply after successful eligibility, avoid charging a
          -- second turn; the consumed-item state is left visible for diagnosis.
          resumeBattleQueue(state)
        end
      end)
      if not started then
        -- No screen means no completed use. Refund the copy we removed if the
        -- save inventory is available; this is a defensive runtime failure path,
        -- not normal eligibility behavior.
        local inventory = state.save and state.save.inventory
        if inventory then inventory[itemId] = (inventory[itemId] or 0) + 1 end
        showNoTurnMessage(state, ItemEffects.TEXT_NO_EFFECT)
      end
    end)
  end

  ---------------------------------------------------------------------------
  -- Gold native EVOLVE_ITEM path from the overworld PACK
  ---------------------------------------------------------------------------

  -- Gold v0.1.78 routes non-TM field items through Game2:usePartyItem(), but
  -- ItemEffects.partyAction() intentionally has no evolution-Stone action yet.
  -- The call therefore returns before Gen2PartyMenu is opened. Fill only that
  -- missing EVOLVE_ITEM family here; every other field item still delegates to
  -- Game2's original dispatcher.
  local function fieldMessage(game, text)
    if game and type(game.say) == "function" then
      return game:say(text or ItemEffects.TEXT_NO_EFFECT)
    end
  end

  local function consumeFieldItem(game, itemId)
    if game and type(game.consumeItem) == "function" then
      return game:consumeItem(itemId)
    end
    local inventory = game and game.save and game.save.inventory
    if not inventory then return end
    local left = (inventory[itemId] or 1) - 1
    inventory[itemId] = left > 0 and left or nil
  end

  local function useGoldFieldEvolutionItem(game, itemId)
    local party = (game and game.save and game.save.party) or {}
    if #party == 0 then
      return fieldMessage(game, "You don't have a\n#MON!")
    end

    Screens.push(game, "Gen2PartyMenu", {
      prompt = "useItem",
      onCancel = function()
        if game.stack then game.stack:pop() end
      end,
      onChoose = function(index, mon)
        if game.stack then game.stack:pop() end

        if not mon or mon.isEgg then
          return fieldMessage(game, mon and ItemEffects.TEXT_CANT_USE_ON_EGG
            or ItemEffects.TEXT_NO_EFFECT)
        end

        -- The original Gold EvoStoneEffect performs this gate BEFORE
        -- wForceEvolution is set. Keep the same semantics outside battle:
        -- Everstone means no evolution and no Stone consumption.
        if holdsEverstone(mon) then
          return fieldMessage(game, ItemEffects.TEXT_NO_EFFECT)
        end

        local entry = Evolution.checkMon(game.data, mon, {
          force = true,
          item = itemId,
          timeOfDay = timeOfDay(),
        })
        if not entry or entry.method ~= Evolution.ITEM then
          return fieldMessage(game, ItemEffects.TEXT_NO_EFFECT)
        end

        local activeParty = (game.save and game.save.party) or party
        local oldMon = activeParty[index]
        if oldMon ~= mon then
          -- Party identity changing underneath the target picker is not a
          -- normal Gold path. Refuse rather than applying a Stone to a stale
          -- record or charging the item.
          return fieldMessage(game, ItemEffects.TEXT_NO_EFFECT)
        end

        Screens.push(game, "Gen2EvolutionAnim", {
          mon = mon,
          entry = entry,
          index = index,
          party = activeParty,
          save = game.save,
          force = true,
          onDone = function(result)
            if game.stack then game.stack:pop() end
            -- Forced Stone evolution cannot be B-cancelled. Charge the Stone
            -- only once the native animation actually committed the new party
            -- record, matching UseDisposableItem's success-only placement.
            if result and result.evolved then
              consumeFieldItem(game, itemId)
            end
          end,
        })
      end,
    })
  end

  local vanillaFieldUseItem = liveGame and liveGame.useFieldItem
  local wrappedFieldUseItem
  if liveGame and type(vanillaFieldUseItem) == "function" then
    wrappedFieldUseItem = function(self, itemId, ...)
      if evolutionItemExists(self and self.data, itemId) then
        return useGoldFieldEvolutionItem(self, itemId)
      end
      return vanillaFieldUseItem(self, itemId, ...)
    end
  end

  ---------------------------------------------------------------------------
  -- BattleState queue/item integration
  ---------------------------------------------------------------------------

  local vanillaAdvanceQueue = BattleState.advanceQueue
  local wrappedAdvanceQueue
  wrappedAdvanceQueue = function(self, ...)
    local event = self.queue and self.queue[1] or nil
    if event and event.kind == LEVEL_MARKER then
      table.remove(self.queue, 1)
      return runLevelEvolutionBatch(self, event)
    end
    if event and event.kind == CANDY_MARKER then
      table.remove(self.queue, 1)
      return runCandyTail(self, event)
    end
    return vanillaAdvanceQueue(self, ...)
  end

  local vanillaUseItem = BattleState.useItem
  local wrappedUseItem
  wrappedUseItem = function(self, itemId, ...)
    if itemId == "RARE_CANDY" then
      return useGoldRareCandy(self, itemId)
    end
    local data = self.game and self.game.data or nil
    if evolutionItemExists(data, itemId) then
      return useGoldEvolutionItem(self, itemId)
    end
    return vanillaUseItem(self, itemId, ...)
  end

  -- Gold v0.1.78's BattlePack rejects ITEMMENU_NOUSE inside PackMenu BEFORE
  -- BattleState:useItem is called. Rare Candy and evolution Stones are field-
  -- only in vanilla Gold, so our BattleState override never saw them. Bypass
  -- only that one Pack gate for the two feature classes this mod explicitly
  -- adds; every unrelated NOUSE item remains on PackMenu's vanilla path.
  local vanillaPackUseSelected = PackMenu.useSelected
  local wrappedPackUseSelected
  wrappedPackUseSelected = function(self, ...)
    local inBattle = self and type(self.inBattle) == "function" and self:inBattle()
    local row = inBattle and self.rows and self.rows[self.index] or nil
    local itemId = row and row.id or nil
    local game = self and self.game or nil
    local data = game and game.data or nil
    local allowed = itemId == "RARE_CANDY" or evolutionItemExists(data, itemId)

    if inBattle and row and allowed then
      -- Match PackMenu:useSelected's normal hand-off path exactly, except for
      -- skipping its ITEMMENU_NOUSE refusal. The BattleState that opened this
      -- PACK still owns target selection, validation, item consumption and the
      -- battle turn.
      if type(self.storeCursor) == "function" then self:storeCursor() end
      if self.give then
        if self.onChoose then self.onChoose(row.id, row.count) end
        return
      end
      if self.onChoose then
        self.staleRows = true
        return self.onChoose(row.id, row.count)
      end
      return
    end

    return vanillaPackUseSelected(self, ...)
  end

  ---------------------------------------------------------------------------
  -- Install last: no half-installed internal overrides after setup failure
  ---------------------------------------------------------------------------

  Battle.awardExperience = wrappedAwardExperience
  Battle.resolveForget = wrappedResolveForget
  Battle.declineForget = wrappedDeclineForget
  BattleState.pushAll = wrappedPushAll
  BattleState.advanceQueue = wrappedAdvanceQueue
  BattleState.useItem = wrappedUseItem
  PackMenu.useSelected = wrappedPackUseSelected
  if wrappedFieldUseItem then liveGame.useFieldItem = wrappedFieldUseItem end
  EvolutionAnim.new = wrappedEvolutionAnimNew
  EvolutionAnim.update = wrappedEvolutionAnimUpdate
  EvolutionAnim.nextLearn = wrappedEvolutionAnimNextLearn
  Music.play = wrappedMusicPlay
  Music.stop = wrappedMusicStop
  Music.duckForFanfare = wrappedDuckForFanfare

  if mod.log and mod.log.info then
    mod.log:info("Evolve in Battle Gold backend loaded (native Gen 2 evolution/item systems; EVOLUTION MUSIC default OFF)")
  end
end

-- Generation router. The real loader exposes the live service owner through
-- mod.game. Gold's data carries gen2Constants; Red/Blue/Yellow do not. The SDK
-- generation=2 loader intentionally has no Game2 instance, so it stops after
-- safe entry loading and dedicated Gold fixtures exercise the backend itself.
return function(mod)
  defineSharedOptions(mod)

  local installed = false
  local function activate(game)
    if installed or not game then return end
    local data = game.data
    if data and data.gen2Constants ~= nil then
      installed = true
      return installGen2(mod, game)
    end
    installed = true
    return installGen1(mod)
  end

  local game = mod.game
  if game then return activate(game) end

  -- The v1.0.3 standalone smoke harness predates mod.game/mod.manifest. Keep it
  -- as a Gen 1 contract fixture rather than weakening production detection.
  if mod.manifest == nil then
    installed = true
    return installGen1(mod)
  end

  -- Headless SDK generation=2 loads have no Game2 object by design. A real
  -- boot emits game.ready if the service owner was not available at entry time.
  if mod.events and mod.events.on then
    mod.events:on("game.ready", function(payload)
      local readyGame = payload and (payload.game or payload) or mod.game
      activate(readyGame)
    end)
  end
end
