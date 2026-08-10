-- Headless smoke test for Evolve in Battle v1.0.1.
-- Run from the mod folder with: texlua tests/smoke.lua

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local ROOT = scriptPath:match("^(.*)/tests/") or "."

local listeners = {}
local hooks = {}
local screenPickTarget = nil
local music = { battle = 0, victory = 0 }
local originalItemCalls = {}
local originalEvolutionCalls = 0
local yellowMode = false

local function emit(name, payload)
  for _, fn in ipairs(listeners[name] or {}) do fn(payload) end
end

local pokemonDefs = {
  CHARMANDER = { name = "CHARMANDER", types = { "FIRE" }, learnAt = { [16] = { "TEST_MOVE" } } },
  CHARMELEON = { name = "CHARMELEON", types = { "FIRE" } },
  CLEFAIRY = {
    name = "CLEFAIRY", types = { "NORMAL" },
    evolutions = { { method = "ITEM", item = "MOON_STONE", species = "CLEFABLE" } },
  },
  CLEFABLE = { name = "CLEFABLE", types = { "NORMAL" }, evolutions = {} },
  PIKACHU = {
    name = "PIKACHU", types = { "ELECTRIC" },
    evolutions = { { method = "ITEM", item = "THUNDER_STONE", species = "RAICHU" } },
  },
  RAICHU = { name = "RAICHU", types = { "ELECTRIC" }, evolutions = {} },
  BULBASAUR = { name = "BULBASAUR", types = { "GRASS", "POISON" }, evolutions = {} },
}

package.preload["src.pokemon.Evolution"] = function()
  local E = {}
  function E.pendingFor(game, mon, trigger)
    if trigger.kind == "levelup" and mon.species == "CHARMANDER" and mon.level >= 16 then
      return "CHARMELEON", { method = "LEVEL" }
    end
    return nil
  end
  function E.evolve(game, mon, species, onDone, via)
    originalEvolutionCalls = originalEvolutionCalls + 1
    local old = mon.species
    mon.species = species
    mon.stats = {
      hp = species == "CLEFABLE" and 95 or species == "RAICHU" and 90 or 70,
      attack = 50, defense = 40, speed = 60, special = 50,
    }
    mon.hp = mon.stats.hp - 5
    emit("pokemon.evolved", { mon = mon, fromSpecies = old, toSpecies = species, via = via })
    -- In the real engine this callback occurs only after congratulations and
    -- Evolution.learnEvolutionMoves have finished.
    if onDone then onDone() end
  end
  return E
end

package.preload["src.battle.BattleState"] = function()
  local B = {}

  function B.makeBattler(data, mon)
    local def = data.pokemon[mon.species]
    return {
      mon = mon,
      def = def,
      name = mon.nickname or def.name,
      curStats = mon.stats,
      curTypes = def.types,
      curMoves = mon.moves,
      sprite = "sprite:" .. mon.species,
      shownHP = mon.hp,
    }
  end

  B.StatBox = {
    new = function(game, mon, onDone)
      return { __auto = onDone }
    end,
  }

  -- Realistic shape of BattleState:awardExp. The real engine wraps
  -- the participant/EXP.ALL distribution in Runtime.call("battle.exp_award",
  -- vanillaExpAward, ctx). Reproduce that contract here so the smoke test
  -- exercises the same hook chain as live gameplay.
  function B.awardExp(self)
    local function vanilla(ctx)
      for _, row in ipairs(self._awardPlan or {}) do
        local mon = row.mon
        local levels = row.levels or {}
        if #levels > 0 then
          mon.level = levels[#levels]
          mon.stats = { hp = (mon.stats.hp or 50) + 5, attack = 35, defense = 30, speed = 40, special = 35 }
          mon.hp = math.min(mon.stats.hp, (mon.hp or mon.stats.hp) + 5)
          self.leveledUp = self.leveledUp or {}
          self.leveledUp[mon] = true
        end

        self.nextInsert = (self.nextInsert or 0) + 1
        table.insert(self.queue, self.nextInsert, { text = "EXP" })
        for _ = 1, #levels do
          self.nextInsert = self.nextInsert + 1
          table.insert(self.queue, self.nextInsert, { text = "LEVEL/MOVE" })
        end
      end
    end

    local ctx = { battle = self, participants = 1, alive = {} }
    local wrapper = hooks["battle.exp_award"]
    if wrapper then
      return wrapper(function(nextCtx) return vanilla(nextCtx or ctx) end, ctx)
    end
    return vanilla(ctx)
  end

  return B
end

package.preload["src.inventory.ItemEffects"] = function()
  local I = {}
  function I.use(data, save, id, mon, battle)
    table.insert(originalItemCalls, { id = id, battle = battle, mon = mon })

    -- Reproduce the important vanilla 0.1.75 invariant: Stones fail solely
    -- because battle ~= nil before the actual Stone validation runs.
    local stone = id == "MOON_STONE" or id == "THUNDER_STONE"
    if battle and (stone or id == "RARE_CANDY") then
      return "failed", { "OAK: RED! This isn't the time to use that!" }
    end

    if id == "RARE_CANDY" then
      if not mon or mon.level >= 100 then
        return "failed", { "It won't have any effect." }
      end
      mon.level = mon.level + 1
      mon.exp = mon.level * 1000
      local oldHP = mon.stats.hp or 1
      mon.stats = { hp = oldHP + 5, attack = 40, defense = 35, speed = 45, special = 40 }
      mon.hp = math.min(mon.stats.hp, mon.hp + 5)
      return "consumed", { (mon.species .. " grew to level " .. mon.level .. "!") },
             { leveledTo = mon.level }
    end

    if id == "POTION" then
      return battle and "consumed" or "consumed", { "HP restored" }
    end

    if id == "MOON_STONE" then
      if mon and mon.species == "CLEFAIRY" then
        return "consumed", nil, { evolveTo = "CLEFABLE" }
      end
      return "failed", { "It won't have any effect." }
    end

    if id == "THUNDER_STONE" then
      if mon and mon.species == "PIKACHU" and yellowMode
         and mon.ot == save.player.name and mon.otId == save.player.id then
        return "failed", { "PIKACHU is refusing!" }
      end
      if mon and mon.species == "PIKACHU" then
        return "consumed", nil, { evolveTo = "RAICHU" }
      end
      return "failed", { "It won't have any effect." }
    end

    return "failed", { "no effect" }
  end
  return I
end

package.preload["src.ui.BagMenu"] = function()
  return {
    new = function(game, opts)
      local state = {
        game = game,
        items = { { value = "RARE_CANDY", right = "x2" } },
        index = 1,
        swapIndex = nil,
        closed = false,
        vanillaChooseCalls = 0,
      }
      function state:close() self.closed = true end
      state.onChoose = function(item) state.vanillaChooseCalls = state.vanillaChooseCalls + 1 end
      return state
    end,
  }
end

package.preload["src.ui.Screens"] = function()
  return {
    push = function(game, id, ...)
      local args = { ... }
      if id == "PartyMenu" then
        local opts = args[1]
        local target = screenPickTarget or game.save.party[1]
        opts.onSwitch(target)
        return {}
      end
      if id == "MoveLearnMenu" then
        local onDone = args[3]
        if onDone then onDone(false) end
        return {}
      end
      error("unexpected screen: " .. tostring(id))
    end,
  }
end

package.preload["src.inventory.Bag"] = function()
  return {
    remove = function(save, id, qty)
      local left = (save.inventory[id] or 0) - qty
      save.inventory[id] = left > 0 and left or nil
    end,
  }
end

package.preload["src.render.TextBox"] = function()
  return {
    new = function(game, text, onDone)
      return { __auto = onDone, text = text }
    end,
  }
end

package.preload["src.core.Strings"] = function()
  return function(fmt, ...) return string.format(fmt, ...) end
end

package.preload["src.battle.Experience"] = function()
  return {
    movesLearnedAt = function(def, level)
      return (def.learnAt and def.learnAt[level]) or {}
    end,
  }
end

package.preload["src.core.Music"] = function()
  return {
    playBattle = function() music.battle = music.battle + 1 end,
    playVictory = function() music.victory = music.victory + 1 end,
  }
end

local mod = {
  hooks = {
    wrap = function(self, name, fn) hooks[name] = fn end,
  },
  events = {
    on = function(self, name, fn)
      listeners[name] = listeners[name] or {}
      table.insert(listeners[name], fn)
      return function() end
    end,
  },
  log = { info = function() end },
}

local Evolution = require("src.pokemon.Evolution")
local BattleState = require("src.battle.BattleState")
local ItemEffects = require("src.inventory.ItemEffects")
local BagMenu = require("src.ui.BagMenu")
local originalUse = ItemEffects.use
local originalEvolve = Evolution.evolve
local originalBagNew = BagMenu.new
local originalAwardExp = BattleState.awardExp

local entry = assert(loadfile(ROOT .. "/main.lua"))()
entry(mod)

assert(ItemEffects.use ~= originalUse, "ItemEffects.use was not directly overridden")
assert(Evolution.evolve ~= originalEvolve, "Evolution.evolve was not wrapped")
assert(BagMenu.new ~= originalBagNew, "BagMenu.new was not directly wrapped")
assert(BattleState.awardExp == originalAwardExp, "v1.0.1 should not monkey-patch BattleState.awardExp")
assert(hooks["battle.exp_award"], "battle.exp_award hook was not registered")
assert(not listeners["battle.exp_gained"], "v1.0.0 fallback should not depend on battle.exp_gained")

local function newGame(party)
  return {
    data = {
      pokemon = pokemonDefs,
      items = {
        MOON_STONE = { name = "MOON STONE" },
        THUNDER_STONE = { name = "THUNDER STONE" },
        POTION = { name = "POTION" },
        RARE_CANDY = { name = "RARE CANDY" },
      },
      moves = { TEST_MOVE = { name = "TEST MOVE", pp = 20 } },
    },
    save = {
      party = party,
      player = { name = "RED", id = 1234 },
      inventory = { MOON_STONE = 2, THUNDER_STONE = 2, POTION = 2, RARE_CANDY = 2 },
    },
  }
end

local function newBattle(game, mon)
  local b = {
    game = game,
    data = game.data,
    kind = "trainer",
    musicKind = "trainer",
    trainer = { id = "TEST", name = "TEST" },
    leveledUp = {},
    queue = {},
    nextInsert = 0,
    result = nil,
    itemUsedCalls = 0,
  }
  b.player = {
    mon = mon,
    def = game.data.pokemon[mon.species],
    name = mon.species,
    curStats = mon.stats,
    curTypes = game.data.pokemon[mon.species].types,
    curMoves = mon.moves,
    sprite = "sprite:" .. mon.species,
    shownHP = mon.hp,
    stages = { attack = 2 },
    substituteHP = 11,
  }
  b.awardExp = BattleState.awardExp
  function b:actNext(fn)
    self.nextInsert = self.nextInsert + 1
    table.insert(self.queue, self.nextInsert, { fn = fn })
  end
  function b:itemUsed(messages)
    self.itemUsedCalls = self.itemUsedCalls + 1
  end
  game.stack = game.stack or {
    push = function(self, state)
      if state and state.__auto then state.__auto() end
      return state
    end,
  }
  return b
end

-- 1) Direct regression: vanilla Moon Stone + battle would fail. Patched call
-- must run the original function with battle=nil and return its valid Stone
-- evolution result instead.
do
  local mon = { species = "CLEFAIRY", level = 30, hp = 60, stats = { hp = 65 }, moves = {} }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)

  local result, msgs, extra = ItemEffects.use(game.data, game.save, "MOON_STONE", mon, battle)
  assert(result == "consumed", "Moon Stone still hit the vanilla battle block")
  assert(extra and extra.evolveTo == "CLEFABLE", "Moon Stone lost vanilla evolveTo result")
  local call = originalItemCalls[#originalItemCalls]
  assert(call.battle == nil, "direct override did not clear battle only for Stone validation")

  -- Simulate vanilla BagMenu: it consumes the Stone, closes the list, then
  -- invokes Evolution.evolve(target, evolveTo, nil, \"ITEM\").
  game.save.inventory.MOON_STONE = game.save.inventory.MOON_STONE - 1
  Evolution.evolve(game, mon, extra.evolveTo, nil, "ITEM")

  assert(mon.species == "CLEFABLE", "Moon Stone evolution did not apply")
  assert(game.save.inventory.MOON_STONE == 1, "Moon Stone was not consumed exactly once")
  assert(battle.itemUsedCalls == 1, "Stone evolution did not spend the player's turn")
  assert(battle.player.def == pokemonDefs.CLEFABLE, "active battler species cache was not refreshed")
  assert(battle.player.curStats == mon.stats, "active battler stats were not refreshed")
  assert(battle.player.sprite == "sprite:CLEFABLE", "active battler sprite was not refreshed")
  assert(battle.player.stages.attack == 2, "battle stat stages were lost")
  assert(battle.player.substituteHP == 11, "volatile battle state was lost")
  assert(music.battle >= 1, "battle music was not restored after Stone evolution")
end

-- 2) Invalid Stone target: bypass the battle gate but preserve vanilla
-- compatibility validation; no evolution and no battle turn.
do
  local mon = { species = "BULBASAUR", level = 30, hp = 60, stats = { hp = 65 }, moves = {} }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)
  local result, msgs, extra = ItemEffects.use(game.data, game.save, "MOON_STONE", mon, battle)
  assert(result == "failed", "invalid Moon Stone target unexpectedly succeeded")
  assert(not extra, "invalid Moon Stone target produced evolveTo")
  assert(battle.itemUsedCalls == 0, "failed Stone use spent a turn")
end

-- 3) Yellow starter Pikachu refusal remains inside vanilla Stone validation.
do
  yellowMode = true
  local mon = {
    species = "PIKACHU", level = 30, hp = 60, stats = { hp = 65 }, moves = {},
    ot = "RED", otId = 1234,
  }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)
  local result, msgs, extra = ItemEffects.use(game.data, game.save, "THUNDER_STONE", mon, battle)
  assert(result == "failed", "Yellow starter Pikachu should refuse Thunder Stone")
  assert(not extra, "refusing Pikachu should not produce evolveTo")
  assert(battle.itemUsedCalls == 0, "refused Thunder Stone spent a turn")
  yellowMode = false
end

-- 4) Non-Stone battle items must still receive the real battle object and use
-- their untouched vanilla path.
do
  local mon = { species = "CLEFAIRY", level = 30, hp = 40, stats = { hp = 65 }, moves = {} }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)
  local result = ItemEffects.use(game.data, game.save, "POTION", mon, battle)
  assert(result == "consumed", "non-Stone item behavior changed")
  local call = originalItemCalls[#originalItemCalls]
  assert(call.battle == battle, "non-Stone battle item lost its battle context")
end

-- 5) Bench Stone evolution also spends the turn but does not replace active
-- battler caches.
do
  local active = { species = "BULBASAUR", level = 30, hp = 60, stats = { hp = 65 }, moves = {} }
  local bench = { species = "CLEFAIRY", level = 30, hp = 60, stats = { hp = 65 }, moves = {} }
  local game = newGame({ active, bench })
  local battle = newBattle(game, active)
  local activeDef = battle.player.def
  local result, _, extra = ItemEffects.use(game.data, game.save, "MOON_STONE", bench, battle)
  assert(result == "consumed" and extra and extra.evolveTo == "CLEFABLE")
  Evolution.evolve(game, bench, extra.evolveTo, nil, "ITEM")
  assert(bench.species == "CLEFABLE", "bench Clefairy did not evolve")
  assert(battle.itemUsedCalls == 1, "bench Stone evolution did not spend the player's turn")
  assert(battle.player.def == activeDef, "bench evolution altered active battler")
end

-- 6) Real awardExp flow: active Pokémon level-up is discovered from the
-- before/after party-level delta, queued after vanilla EXP UI, and clears
-- the post-battle duplicate evolution flag.
do
  local mon = {
    species = "CHARMANDER", level = 15, hp = 45,
    stats = { hp = 50, attack = 30, defense = 25, speed = 35, special = 30 },
    moves = {},
  }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)
  battle._awardPlan = { { mon = mon, levels = { 16 } } }

  battle:awardExp()

  assert(#battle.queue == 3 and battle.queue[3].fn,
    "active level evolution was not queued after real awardExp UI")
  battle.queue[3].fn()
  assert(mon.species == "CHARMELEON", "active EXP level evolution did not apply")
  assert(battle.leveledUp[mon] == nil, "active EXP evolution would duplicate after battle")
  assert(battle.player.def == pokemonDefs.CHARMELEON,
    "active EXP evolution did not refresh active battler")
end

-- 7) Rare Candy in battle: the screen override must bypass the vanilla battle
-- refusal, consume exactly one Candy, update active cached stats, perform the
-- level evolution check, evolve at 16, and spend exactly one turn afterwards.
do
  local mon = {
    species = "CHARMANDER", level = 15, hp = 45,
    stats = { hp = 50, attack = 30, defense = 25, speed = 35, special = 30 },
    moves = {},
  }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)
  screenPickTarget = mon
  local bag = BagMenu.new(game, { battle = battle })
  bag.onChoose({ value = "RARE_CANDY" }, bag)
  screenPickTarget = nil

  assert(bag.vanillaChooseCalls == 0, "battle Rare Candy fell through to vanilla BagMenu")
  assert(bag.closed, "battle BAG was not closed after successful Rare Candy")
  assert(game.save.inventory.RARE_CANDY == 1, "Rare Candy was not consumed exactly once")
  assert(mon.level == 16, "Rare Candy did not increase level")
  assert(mon.moves[1] and mon.moves[1].id == "TEST_MOVE", "Rare Candy level-up move was not learned before evolution")
  assert(mon.species == "CHARMELEON", "Rare Candy did not trigger eligible level evolution")
  assert(battle.player.def == pokemonDefs.CHARMELEON, "Rare Candy evolution did not sync active species")
  assert(battle.player.curStats == mon.stats, "Rare Candy/evolution did not sync active stats")
  assert(battle.itemUsedCalls == 1, "Rare Candy did not spend exactly one battle turn")
end

-- 8) Rare Candy with no eligible evolution still spends the turn after the
-- level/stat/move flow and updates active stats.
do
  local mon = {
    species = "BULBASAUR", level = 10, hp = 35,
    stats = { hp = 40, attack = 25, defense = 25, speed = 20, special = 30 },
    moves = {},
  }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)
  local oldStats = mon.stats
  screenPickTarget = mon
  local bag = BagMenu.new(game, { battle = battle })
  bag.onChoose({ value = "RARE_CANDY" }, bag)
  screenPickTarget = nil

  assert(mon.level == 11, "non-evolving Rare Candy did not increase level")
  assert(mon.species == "BULBASAUR", "non-evolving Rare Candy changed species")
  assert(mon.stats ~= oldStats and battle.player.curStats == mon.stats, "Rare Candy stats cache was not refreshed")
  assert(game.save.inventory.RARE_CANDY == 1, "non-evolving Rare Candy was not consumed once")
  assert(battle.itemUsedCalls == 1, "non-evolving Rare Candy did not spend the turn")
end

-- 9) Level-100 target: Candy remains in the bag, BAG remains open, and no
-- battle action is spent.
do
  local mon = {
    species = "BULBASAUR", level = 100, hp = 100,
    stats = { hp = 100, attack = 80, defense = 80, speed = 80, special = 80 },
    moves = {},
  }
  local game = newGame({ mon })
  local battle = newBattle(game, mon)
  screenPickTarget = mon
  local bag = BagMenu.new(game, { battle = battle })
  bag.onChoose({ value = "RARE_CANDY" }, bag)
  screenPickTarget = nil

  assert(mon.level == 100, "level-100 Candy changed level")
  assert(game.save.inventory.RARE_CANDY == 2, "failed level-100 Candy was consumed")
  assert(not bag.closed, "failed level-100 Candy closed the BAG")
  assert(battle.itemUsedCalls == 0, "failed level-100 Candy spent a turn")
end


-- 10) BagMenu wrapper scope: field Rare Candy and unrelated battle items still
-- call the original vanilla BagMenu callback.
do
  local mon = { species = "BULBASAUR", level = 10, hp = 35, stats = { hp = 40 }, moves = {} }
  local game = newGame({ mon })
  local fieldBag = BagMenu.new(game, {})
  fieldBag.onChoose({ value = "RARE_CANDY" }, fieldBag)
  assert(fieldBag.vanillaChooseCalls == 1, "field Rare Candy was intercepted")

  local battle = newBattle(game, mon)
  local battleBag = BagMenu.new(game, { battle = battle })
  battleBag.onChoose({ value = "POTION" }, battleBag)
  assert(battleBag.vanillaChooseCalls == 1, "non-Candy battle item was intercepted")
end


-- 11) REAL EXP level-up while benched. Simulate the important live-game case:
-- Charmander participated earlier, is now switched out, and had already leveled
-- once earlier in the same battle (battle.leveledUp[bench] is already true).
-- A second KO takes it 15 -> 16. The before/after detector must still see
-- THIS award and evolve it; comparing leveledUp table keys would fail here.
do
  local active = {
    species = "BULBASAUR", level = 20, hp = 55,
    stats = { hp = 60, attack = 35, defense = 35, speed = 30, special = 40 },
    moves = {},
  }
  local bench = {
    species = "CHARMANDER", level = 15, hp = 45,
    stats = { hp = 50, attack = 30, defense = 25, speed = 35, special = 30 },
    moves = {},
  }
  local game = newGame({ active, bench })
  local battle = newBattle(game, active)
  local activeDef = battle.player.def
  local activeStats = battle.player.curStats
  local activeSprite = battle.player.sprite
  local activeStages = battle.player.stages

  -- Represents an earlier 14 -> 15 level in this same battle.
  battle.leveledUp[bench] = true
  battle._awardPlan = { { mon = bench, levels = { 16 } } }

  battle:awardExp()

  assert(#battle.queue == 3 and battle.queue[3].fn,
    "real benched participant evolution was not queued")
  battle.queue[3].fn()
  assert(bench.species == "CHARMELEON",
    "benched Charmander did not evolve after real KO-earned level-up")
  assert(battle.leveledUp[bench] == nil, "bench evolution would duplicate after battle")
  assert(battle.player.mon == active, "bench evolution replaced the active mon")
  assert(battle.player.def == activeDef, "bench evolution changed active species cache")
  assert(battle.player.curStats == activeStats, "bench evolution changed active stat cache")
  assert(battle.player.sprite == activeSprite, "bench evolution changed active sprite")
  assert(battle.player.stages == activeStages, "bench evolution disturbed volatile active state")
end

-- 12) Multiple party members can level from one REAL award pass. The level
-- delta detector must queue both checks after all vanilla UI and preserve party order.
do
  local first = {
    species = "CHARMANDER", level = 15, hp = 45,
    stats = { hp = 50, attack = 30, defense = 25, speed = 35, special = 30 }, moves = {},
  }
  local second = {
    species = "CHARMANDER", level = 15, hp = 44,
    stats = { hp = 50, attack = 30, defense = 25, speed = 35, special = 30 }, moves = {},
  }
  local game = newGame({ first, second })
  local battle = newBattle(game, first)
  battle._awardPlan = {
    { mon = first, levels = { 16 } },
    { mon = second, levels = { 16 } },
  }

  battle:awardExp()

  -- 2 vanilla rows per mon, then 2 evolution acts.
  assert(#battle.queue == 6 and battle.queue[5].fn and battle.queue[6].fn,
    "multiple real EXP evolutions were not queued after all vanilla UI")
  battle.queue[5].fn()
  assert(first.species == "CHARMELEON", "first party member did not evolve")
  assert(battle.player.def == pokemonDefs.CHARMELEON,
    "active evolution did not sync before bench check")
  local activeDefAfterFirst = battle.player.def
  battle.queue[6].fn()
  assert(second.species == "CHARMELEON", "second/benched party member did not evolve")
  assert(battle.player.mon == first and battle.player.def == activeDefAfterFirst,
    "second/bench evolution disturbed active evolved battler")
end

-- 13) Rare Candy targeted at a benched Pokémon: level + move + evolution all
-- happen for the bench target, while active battler caches remain untouched.
do
  local active = {
    species = "BULBASAUR", level = 20, hp = 55,
    stats = { hp = 60, attack = 35, defense = 35, speed = 30, special = 40 }, moves = {},
  }
  local bench = {
    species = "CHARMANDER", level = 15, hp = 45,
    stats = { hp = 50, attack = 30, defense = 25, speed = 35, special = 30 }, moves = {},
  }
  local game = newGame({ active, bench })
  local battle = newBattle(game, active)
  local activeDef = battle.player.def
  local activeStats = battle.player.curStats
  local activeSprite = battle.player.sprite

  screenPickTarget = bench
  local bag = BagMenu.new(game, { battle = battle })
  bag.onChoose({ value = "RARE_CANDY" }, bag)
  screenPickTarget = nil

  assert(bench.level == 16, "bench Rare Candy did not increase level")
  assert(bench.moves[1] and bench.moves[1].id == "TEST_MOVE", "bench Rare Candy did not learn level move")
  assert(bench.species == "CHARMELEON", "bench Rare Candy did not trigger level evolution")
  assert(game.save.inventory.RARE_CANDY == 1, "bench Rare Candy was not consumed exactly once")
  assert(battle.itemUsedCalls == 1, "bench Rare Candy did not spend exactly one turn")
  assert(battle.player.mon == active, "bench Rare Candy replaced active mon")
  assert(battle.player.def == activeDef, "bench Rare Candy changed active species cache")
  assert(battle.player.curStats == activeStats, "bench Rare Candy changed active stat cache")
  assert(battle.player.sprite == activeSprite, "bench Rare Candy changed active sprite")
end

print("PASS: evolve_in_battle v1.0.1 smoke tests")
