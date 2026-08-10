-- Integration regression for Evolve in Battle v1.0.2 + EXP Share Modes 1.0.0.
-- Focus: Modern Progressive awards a never-sent-out bench mon outside battle.exp_award.

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local ROOT = scriptPath:match("^(.*)/tests/") or "."

local listeners, hooks = {}, {}
local function emit(name, payload)
  for _, fn in ipairs(listeners[name] or {}) do fn(payload) end
end

local pokemonDefs = {
  BULBASAUR = { name = "BULBASAUR", types = { "GRASS", "POISON" } },
  CHARMANDER = { name = "CHARMANDER", types = { "FIRE" } },
  CHARMELEON = { name = "CHARMELEON", types = { "FIRE" } },
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
    local old = mon.species
    mon.species = species
    mon.stats = { hp = 60, attack = 40, defense = 35, speed = 45, special = 40 }
    emit("pokemon.evolved", { mon = mon, fromSpecies = old, toSpecies = species, via = via })
    if onDone then onDone() end
  end
  return E
end

package.preload["src.battle.BattleState"] = function()
  local B = {}
  function B.makeBattler(data, mon)
    return {
      mon = mon,
      def = data.pokemon[mon.species],
      name = mon.nickname or data.pokemon[mon.species].name,
      curStats = mon.stats,
      curTypes = data.pokemon[mon.species].types,
      curMoves = mon.moves,
      sprite = "sprite:" .. mon.species,
      shownHP = mon.hp,
    }
  end
  B.StatBox = { new = function() return {} end }
  return B
end

package.preload["src.inventory.ItemEffects"] = function()
  return { use = function() return "failed", {} end }
end
package.preload["src.ui.EvolutionState"] = function()
  return { update = function() end }
end

package.preload["src.core.Music"] = function()
  return {
    play = function() end, restoreMap = function() end,
    special = function() return "EVOLUTION" end,
    setVolumeLevel = function() end,
    playBattle = function() end, playVictory = function() end,
  }
end
package.preload["src.ui.BagMenu"] = function()
  return { new = function() return { onChoose = function() end } end }
end
package.preload["src.ui.Screens"] = function()
  return { push = function() return {} end }
end
package.preload["src.inventory.Bag"] = function()
  return { remove = function() end }
end
package.preload["src.render.TextBox"] = function()
  return { new = function() return {} end }
end
package.preload["src.core.Strings"] = function()
  return function(fmt, ...) return string.format(fmt, ...) end
end

-- Faithful shape of EXP Share Modes' published dispatcher handler in Modern mode:
-- original enemyMonFainted runs first, then direct bench EXP is inserted at the
-- boundary immediately before the already-queued continuation.
local benchRef
local expShareExports = {}
expShareExports._enemyMonFainted = function(original, battle)
  local boundary
  local act = battle.act
  battle.act = function(self, ...)
    if boundary == nil then boundary = self.nextInsert or 0 end
    return act(self, ...)
  end

  original(battle)
  battle.act = act

  local finalNext = battle.nextInsert or 0
  boundary = boundary or finalNext
  battle.nextInsert = boundary

  local bench = assert(benchRef)
  bench.level = 16
  bench.stats = { hp = 55, attack = 35, defense = 30, speed = 40, special = 35 }
  battle.leveledUp[bench] = true
  battle:sayNext("BENCH EXP")
  battle:sayNext("BENCH LEVEL/MOVE")

  local inserted = (battle.nextInsert or boundary) - boundary
  battle.nextInsert = finalNext + inserted
end

local logs = {}
local mod = {
  options = {
    define = function(self, defs)
      self.values = self.values or {}
      for _, def in ipairs(defs or {}) do
        if self.values[def.key] == nil then self.values[def.key] = def.default end
      end
    end,
    get = function(self, key) return self.values and self.values[key] end,
  },
  hooks = { wrap = function(self, name, fn) hooks[name] = fn end },
  events = {
    on = function(self, name, fn)
      listeners[name] = listeners[name] or {}
      table.insert(listeners[name], fn)
      return function() end
    end,
  },
  find = function(id)
    if id == "exp_share_modes" then
      return { id = id, version = "1.0.0", exports = expShareExports }
    end
    return nil
  end,
  log = { info = function(self, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end },
}

local entry = assert(loadfile(ROOT .. "/main.lua"))()
entry(mod)

assert(type(expShareExports._enemyMonFainted) == "function", "EXP Share handler missing")
assert(hooks["battle.exp_award"] == nil,
  "EXP Share integration must replace fallback battle.exp_award tracking to avoid duplicates")

local active = {
  species = "BULBASAUR", level = 20, hp = 50,
  stats = { hp = 55, attack = 35, defense = 35, speed = 30, special = 40 }, moves = {},
}
local bench = {
  species = "CHARMANDER", level = 15, hp = 45,
  stats = { hp = 50, attack = 30, defense = 25, speed = 35, special = 30 }, moves = {},
}
benchRef = bench

local game = {
  data = { pokemon = pokemonDefs, items = {}, moves = {} },
  save = { party = { active, bench }, inventory = {}, player = { name = "RED", id = 1 } },
}
local battle = {
  game = game,
  data = game.data,
  kind = "trainer",
  musicKind = "trainer",
  trainer = { id = "TEST" },
  leveledUp = {},
  queue = {},
  nextInsert = 0,
  result = nil,
}
battle.player = {
  mon = active,
  def = pokemonDefs.BULBASAUR,
  name = "BULBASAUR",
  curStats = active.stats,
  curTypes = pokemonDefs.BULBASAUR.types,
  curMoves = active.moves,
  sprite = "sprite:BULBASAUR",
  shownHP = active.hp,
  stages = { attack = 1 },
}
function battle:sayNext(text)
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { text = text })
end
function battle:actNext(fn)
  self.nextInsert = (self.nextInsert or 0) + 1
  table.insert(self.queue, self.nextInsert, { fn = fn, tag = "EVOLUTION" })
end
function battle:act(fn)
  table.insert(self.queue, { fn = fn, tag = "CONTINUATION" })
end

local function vanillaEnemyMonFainted(b)
  b:sayNext("ACTIVE EXP")
  b:act(function() end)
end

expShareExports._enemyMonFainted(vanillaEnemyMonFainted, battle)

assert(bench.level == 16, "EXP Share simulation did not level bench mon")
assert(#battle.queue == 5, "unexpected queue size: " .. tostring(#battle.queue))
assert(battle.queue[1].text == "ACTIVE EXP", "participant EXP order changed")
assert(battle.queue[2].text == "BENCH EXP", "bench EXP row missing/late")
assert(battle.queue[3].text == "BENCH LEVEL/MOVE", "bench level/move row missing/late")
assert(battle.queue[4].tag == "EVOLUTION", "evolution was not inserted after EXP Share bench UI")
assert(battle.queue[5].tag == "CONTINUATION", "evolution did not stay before battle continuation")

battle.queue[4].fn()
assert(bench.species == "CHARMELEON", "never-sent-out bench mon did not evolve")
assert(battle.leveledUp[bench] == nil, "post-battle duplicate evolution flag was not cleared")
assert(battle.player.mon == active and battle.player.def == pokemonDefs.BULBASAUR,
  "bench evolution disturbed active battler")

print("PASS: EXP Share Modes Modern Progressive bench evolution integration")
