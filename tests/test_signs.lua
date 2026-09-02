-- Offline test of BNS_Signs (in-world cues for bandit-held POIs).
math.randomseed(53)

local ROOT = arg[1]
local loaded = {}
function require(name)
    if loaded[name] then return end
    loaded[name] = true
    for _, dir in ipairs({ "/shared/", "/server/" }) do
        local p = ROOT .. dir .. name .. ".lua"
        local f = io.open(p, "r")
        if f then f:close(); dofile(p); return end
    end
    error("require not found: " .. name)
end

function ZombRand(a, b) if b then return math.random(a, b - 1) end return math.random(0, a - 1) end
function ZombRandFloat(a, b) return a + math.random() * (b - a) end
function instanceof(obj, cls) return type(obj) == "table" and obj.__iso == cls end
function isServer() return false end
function isClient() return false end
function getText(k) return k end
function getWorld() return { getMetaGrid = function() return { getZoneAt = function() return nil end } end } end
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
local worldHours = 100
function getGameTime() return { getWorldAgeHours = function() return worldHours end } end
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })

local worldSounds = {}
function addSound(_, x, y, z, radius, vol)
    table.insert(worldSounds, { x = x, y = y, radius = radius })
end

-- Only these item ids "exist" in this fake build; everything the mod
-- lists as a candidate but that is missing here must never be placed.
local KNOWN_ITEMS = {
    ["Base.Bullets9mm"] = true,
    ["Base.RippedSheets"] = true,
    ["Base.Bandage"] = true,
    ["Base.Cigarettes"] = true,
    ["Base.Plank"] = true,
    ["Base.WoodenStick"] = true,
}
ScriptManager = { instance = { getItem = function(_, fullType)
    if KNOWN_ITEMS[fullType] then return { type = fullType } end
    return nil
end } }

-- Player positions drive both nearestPlayer and ambience range.
local players = {}
local function makePlayer(x, y)
    local p = { x = x, y = y }
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return 0 end
    function p:isDead() return false end
    return p
end
function getNumActivePlayers() return #players end
function getSpecificPlayer(i) return players[i + 1] end

local function makeSquare(x, y)
    local sq = { x = x, y = y, floor = {}, modData = {}, blood = 0, objects = {} }
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return 0 end
    function sq:getModData() return self.modData end
    function sq:AddWorldInventoryItem(ft) table.insert(self.floor, ft) end
    function sq:addBlood() self.blood = self.blood + 1 end
    function sq:getObjects()
        return { size = function() return #sq.objects end, get = function(_, i) return sq.objects[i + 1] end }
    end
    return sq
end

function getCell()
    return {
        getGridSquare = function(_, x, y, z) return makeSquare(x, y) end,
        getZombieList = function() return { size = function() return 0 end, get = function() end } end,
    }
end

require("BNS/BNS_Core")
require("BNS/BNS_Persistence")
require("BNS/BNS_Signs")

local function newBase(x, y, radius)
    return { name = "Test POI", x = x, y = y, z = 0, radius = radius or 10,
             stockedSquares = {} }
end

-- 1. Item pool safety: unknown ids are never placed ------------------------
BNS.Signs.clearPoolCache()
local base = newBase(0, 0, 10)
local placed = {}
for i = 1, 4000 do
    local sq = makeSquare(i, 0)
    BNS.Signs.decorateSquare(sq, base, i % 2 == 0 and "core" or "approach")
    for _, ft in ipairs(sq.floor) do placed[ft] = (placed[ft] or 0) + 1 end
end
assert(next(placed), "something was placed")
for ft, _ in pairs(placed) do
    assert(KNOWN_ITEMS[ft], "placed an item this build does not have: " .. ft)
end
print("item pool filtering OK (" .. (function()
    local n = 0 for _ in pairs(placed) do n = n + 1 end return n end)() .. " distinct ids, all known)")

-- 2. Per-base decoration cap ------------------------------------------------
assert(base.decorations <= 60, "decoration cap held, got " .. base.decorations)
assert(base.decorations == 60, "cap actually reached in this many squares")
local sqAfter = makeSquare(9999, 0)
BNS.Signs.decorateSquare(sqAfter, base, "approach")
assert(#sqAfter.floor == 0, "no decoration once the cap is hit")
print("decoration cap OK (" .. base.decorations .. ")")

-- 3. Density: sparse, and the core is denser than the approach --------------
-- Sample in batches small enough that the per-base cap never binds.
local function densityOf(zone, batches, perBatch)
    local hits, total = 0, 0
    for b = 1, batches do
        local base_ = newBase(0, 0, 10)
        for i = 1, perBatch do
            local sq = makeSquare(i, 7)
            if BNS.Signs.decorateSquare(sq, base_, zone) then hits = hits + 1 end
            total = total + 1
        end
        assert(base_.decorations < 60, "batch must not hit the cap")
    end
    return hits / total * 100
end
local coreD = densityOf("core", 20, 200)
local approachD = densityOf("approach", 20, 200)
assert(coreD > 8 and coreD < 16, "core density ~12%, got " .. coreD)
assert(approachD > 5 and approachD < 11, "approach density ~8%, got " .. approachD)
assert(coreD > approachD, "core is more cluttered than the approach")
print(string.format("density OK (core %.1f%%, approach %.1f%%)", coreD, approachD))

-- 4. Blood only on the approach -----------------------------------------------
local coreBlood, approachBlood = 0, 0
for b = 1, 20 do
    local b4 = newBase(0, 0, 10)
    for i = 1, 200 do
        local sq = makeSquare(i, 11)
        BNS.Signs.decorateSquare(sq, b4, "core")
        coreBlood = coreBlood + sq.blood
    end
    local b5 = newBase(0, 0, 10)
    for i = 1, 200 do
        local sq = makeSquare(i, 12)
        BNS.Signs.decorateSquare(sq, b5, "approach")
        approachBlood = approachBlood + sq.blood
    end
end
assert(coreBlood == 0, "no blood inside the camp")
assert(approachBlood > 0, "blood appears on the approach")
print("blood placement OK (approach only, " .. approachBlood .. " squares)")

-- 5. Sandbox toggle disables every layer ---------------------------------------
SandboxVars.BNS.POISignsEnabled = false
local b6 = newBase(0, 0, 10)
local any = false
for i = 1, 500 do
    local sq = makeSquare(i, 13)
    if BNS.Signs.decorateSquare(sq, b6, "approach") then any = true end
end
assert(not any, "toggle off means no decoration")
local brainOff = { id = "x" }
assert(BNS.Signs.challenge({}, brainOff) == false, "toggle off means no challenge")
worldSounds = {}
local state = BNS.Persistence.getState()
state.bases["Test POI"] = newBase(50, 50, 10)
players = { makePlayer(55, 50) }
BNS.Signs.ambientTick()
assert(#worldSounds == 0, "toggle off means no camp noise")
SandboxVars.BNS.POISignsEnabled = true
print("sandbox toggle OK")

-- 6. Ambience: needs a player in range, respects its cooldown ----------------
local replies = {}
BNS.Client = { onServerCommand = function(_, command, args)
    table.insert(replies, { command = command, args = args })
end }
local poi = newBase(500, 500, 10)
state.bases = { ["Test POI"] = poi }

players = { makePlayer(5000, 5000) } -- far away
BNS.Signs.ambientTick()
assert(#replies == 0, "no noise with nobody near")

players = { makePlayer(520, 500) } -- ~20 tiles: in range
local fired = 0
for _ = 1, 40 do
    poi.lastAmbience = nil -- eligible each attempt
    replies = {}
    BNS.Signs.ambientTick()
    if #replies > 0 then fired = fired + 1 end
end
assert(fired > 15 and fired < 40, "ambience rolls a chance, fired " .. fired .. "/40")

replies = {}
poi.lastAmbience = nil
while #replies == 0 do BNS.Signs.ambientTick() end -- force one through
local msg = replies[1]
assert(msg.command == "poiAmbience", "broadcasts poiAmbience")
assert(msg.args.x == 500 and msg.args.y == 500, "positioned at the POI")
assert(msg.args.kind, "carries a sound kind")
assert(#worldSounds > 0, "camp noise also exists in the world model for zombies")
-- immediately after, the cooldown blocks it
replies = {}
for _ = 1, 20 do BNS.Signs.ambientTick() end
assert(#replies == 0, "cooldown holds within the same hour")
worldHours = worldHours + 2
replies = {}
for _ = 1, 40 do
    if #replies > 0 then break end
    BNS.Signs.ambientTick()
end
assert(#replies > 0, "eligible again after the cooldown")
print("camp ambience OK")

-- 7. Challenge shouts ------------------------------------------------------------
local said = {}
BNS.Say = function(zombie, brain, text) table.insert(said, text) end
local guard = { id = "g1", name = "Guard" }
assert(BNS.Signs.challenge({}, guard) == true, "first challenge speaks")
assert(#said == 1 and said[1]:find("UI_BNS_Challenge"), "uses a challenge line")
assert(BNS.Signs.challenge({}, guard) == false, "cooldown silences the next call")
for _ = 1, 89 do BNS.Signs.challenge({}, guard) end
assert(#said == 2, "speaks again once the cooldown runs out, said " .. #said)
print("challenge shouts OK")

-- 8. The approach ring is decorated but NEVER fortified or stocked ------------
-- (the regression to guard: widening the per-square hook must not make
-- the mod barricade and loot-stock a 2.5x wider area)
local barricades = 0
IsoBarricade = { AddBarricadeToObject = function()
    barricades = barricades + 1
    return { addPlank = function() end }
end }

require("BNS/BNS_Loadouts")
require("BNS/BNS_POIs")
require("BNS/BNS_Archetypes")
require("BNS/BNS_Anim")
require("BNS/BNS_Spawner")
require("BNS/BNS_Bases")

local function furnishedSquare(x, y)
    local sq = makeSquare(x, y)
    local items = {}
    local container = {
        getItems = function()
            return { size = function() return #items end,
                     get = function(_, i) return items[i + 1] end }
        end,
        AddItem = function(_, ft) table.insert(items, ft) end,
    }
    sq.contents = items
    table.insert(sq.objects, { getContainer = function() return container end })
    table.insert(sq.objects, { __iso = "IsoWindow" })
    return sq
end

local hq = newBase(0, 0, 10)          -- core <= 10, approach <= 25
state.bases = { ["Test POI"] = hq }

local coreSq = furnishedSquare(3, 0)
BNS.Bases.onLoadGridsquare(coreSq)
assert(#coreSq.contents > 0, "core containers are stocked")
assert(barricades > 0, "core windows are barricaded")

barricades = 0
local approachSq = furnishedSquare(20, 0)
BNS.Bases.onLoadGridsquare(approachSq)
assert(#approachSq.contents == 0, "approach containers must NOT be stocked")
assert(barricades == 0, "approach windows must NOT be barricaded")

local outsideSq = furnishedSquare(300, 0)
BNS.Bases.onLoadGridsquare(outsideSq)
assert(#outsideSq.contents == 0 and #outsideSq.floor == 0, "squares outside both rings are untouched")

-- once per square, however often it streams in
local repeatSq = furnishedSquare(3, 0)
BNS.Bases.onLoadGridsquare(repeatSq)
assert(#repeatSq.contents == 0, "an already-processed square is skipped")
print("core/approach zoning OK (fortify core only, decorate both)")

print("ALL TESTS PASSED")
