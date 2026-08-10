-- Evolve in Battle v1.0.2
-- Target: Gen1Recomp 0.1.75 / Mod API 2
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
-- The ItemEffects/Evolution/BagMenu function wrappers are engine-internal overrides and are why the
-- manifest declares engine_internals and pins game_version to 0.1.75.

return function(mod)
  -- In-battle audio policy. OFF is deliberately the default: the battle or
  -- victory theme keeps playing at its normal volume and EvolutionState's
  -- evolution cue is suppressed. ON enables the optional parallel evolution
  -- overlay while leaving the underlying battle track at its normal volume.
  mod.options:define({
    { key = "evolution_music", label = "EVOLUTION MUSIC", type = "toggle", default = false },
  })

  local Evolution = require("src.pokemon.Evolution")
  local BattleState = require("src.battle.BattleState")
  local ItemEffects = require("src.inventory.ItemEffects")
  local Music = require("src.core.Music")
  local EvolutionState = require("src.ui.EvolutionState")
  local VanillaBagMenu = require("src.ui.BagMenu")
  local Screens = require("src.ui.Screens")
  local Bag = require("src.inventory.Bag")
  local TextBox = require("src.render.TextBox")
  local Strings = require("src.core.Strings")

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

  -- Vanilla 0.1.75 intentionally refuses RARE_CANDY whenever battle ~= nil.
  -- Its successful field-use path already performs the canonical level/EXP/
  -- stat/HP/happiness mutation and returns extra.leveledTo, so reuse exactly
  -- that calculation with battle=nil and own only the battle-specific UI tail.
  local vanillaItemUse = ItemEffects.use

  local function useRareCandyInBattle(battle, bagList)
    local game = battle and battle.game
    if not game or not bagList then return end

    Screens.push(game, "PartyMenu", {
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
            local Experience = require("src.battle.Experience")
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
                Screens.push(game, "MoveLearnMenu", mon, moveId, nextStep)
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
    mod.log:info("Evolve in Battle v1.0.2 loaded (EXP Share Modes integration active, battle music continuity, evolution music default OFF, Gen1Recomp 0.1.75)")
  else
    mod.log:info("Evolve in Battle v1.0.2 loaded (vanilla battle.exp_award tracking, battle music continuity, evolution music default OFF, Gen1Recomp 0.1.75)")
  end
end
