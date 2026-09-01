-- Offline test of BNS_Scavenge with stubbed PZ APIs.
math.randomseed(23)

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
function getNumActivePlayers() return 0 end
function getText(k) return k end
function addSound() end
function getWorld() return { getMetaGrid = function() return { getZoneAt = function() return nil end } end } end
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
local worldHours = 0
function getGameTime() return { getWorldAgeHours = function() return worldHours end } end
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }

-- World stubs -----------------------------------------------------------
local grid = {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function square(x, y, z)
    local k = key(x, y, z)
    if not grid[k] then
        local sq = { x = x, y = y, z = z, objects = {}, floor = {}, modData = {} }
        function sq:getX() return self.x end
        function sq:getY() return self.y end
        function sq:getZ() return self.z end
        function sq:getModData() return self.modData end
        function sq:getObjects()
            return { size = function() return #sq.objects end, get = function(_, i) return sq.objects[i + 1] end }
        end
        function sq:AddWorldInventoryItem(fullType, fx, fy, fz)
            table.insert(sq.floor, fullType)
        end
        grid[k] = sq
    end
    return grid[k]
end
function getCell()
    return {
        getGridSquare = function(_, x, y, z) return square(x, y, z) end,
        getZombieList = function() return { size = function() return 0 end, get = function() end } end,
    }
end

local function makeItem(fullType, cat)
    local it = { fullType = fullType, cat = cat }
    function it:getFullType() return self.fullType end
    function it:getCategory() return self.cat end
    return it
end

local function makeContainer(items)
    local c = { items = items }
    function c:getItems()
        return { size = function() return #c.items end, get = function(_, i) return c.items[i + 1] end }
    end
    function c:Remove(item)
        for i, v in ipairs(c.items) do if v == item then table.remove(c.items, i) return end end
    end
    return c
end

local function placeContainer(x, y, items)
    local sq = square(x, y, 0)
    local c = makeContainer(items)
    table.insert(sq.objects, { getContainer = function() return c end })
    return sq, c
end

local function makeNPC(x, y, role, tier)
    local z = { __iso = "IsoZombie", x = x, y = y, sounds = {}, vars = {},
        modData = { BNS = { id = "s1", role = role or "bandit", tier = tier or 1, program = "wander" } } }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:getModData() return self.modData end
    function z:playSound(s) table.insert(self.sounds, s) end
    function z:setVariable(k, v) self.vars[k] = v end
    function z:isDead() return false end
    function z:getCurrentSquare() return square(self.x, self.y, 0) end
    function z:setRunning() end
    return z
end

require("BNS/BNS_Core")
require("BNS/BNS_Loadouts")
require("BNS/BNS_POIs")
require("BNS/BNS_Archetypes")
require("BNS/BNS_Persistence")
require("BNS/BNS_Anim")
require("BNS/BNS_Combat")
require("BNS/BNS_Programs")
require("BNS/BNS_Scavenge")

-- Deterministic randomness helper for probe-based searches.
local realZombRand = ZombRand
local function fixRand(v)
    ZombRand = function(a, b) if b then return a end return v or 0 end
end
local function restoreRand() ZombRand = realZombRand end

-- 1. lootSquare: valuables taken, junk left + scattered ------------------
local npc = makeNPC(10, 10, "bandit", BNS.Tier.THUG)
local brain = npc:getModData().BNS
local sq1, c1 = placeContainer(11, 10, {
    makeItem("Base.Antibiotics"),           -- barter 25: taken
    makeItem("Base.TinnedBeans"),           -- barter 5: taken
    makeItem("Base.HuntingKnife", "Weapon"),-- category weapon 8: taken
    makeItem("Base.Bullets9mm"),            -- barter 2 (<3): left
    makeItem("Base.CrumpledPaper"),         -- 0: left
    makeItem("Base.Spoon"),                 -- 0: left
})
fixRand(0) -- scatter roll -> exactly 1 scattered
BNS.Scavenge.lootSquare(npc, brain, sq1)
restoreRand()
assert(#brain.loot == 3, "3 valuables taken, got " .. #brain.loot)
assert(#sq1.floor == 1, "one junk item scattered on the floor, got " .. #sq1.floor)
assert(#c1.items == 2, "remaining junk stays in the container, got " .. #c1.items)
assert(sq1.modData.BNS_Looted == worldHours, "square marked looted")
for _, ft in ipairs(brain.loot) do
    assert(ft ~= "Base.CrumpledPaper" and ft ~= "Base.Spoon" and ft ~= "Base.Bullets9mm",
        "junk must not be in the pack")
end
print("lootSquare take/leave/scatter OK")

-- 2. Per-container take cap ----------------------------------------------
local npc2 = makeNPC(20, 20, "bandit", BNS.Tier.THUG)
local b2 = npc2:getModData().BNS
local many = {}
for i = 1, 8 do many[i] = makeItem("Base.Antibiotics") end
local sq2, c2 = placeContainer(21, 20, many)
fixRand(0)
BNS.Scavenge.lootSquare(npc2, b2, sq2)
restoreRand()
assert(#b2.loot == 4, "take cap of 4 per container, got " .. #b2.loot)
assert(#c2.items == 4, "cap leaves valuables behind too")
print("take cap OK")

-- 3. Pack cap --------------------------------------------------------------
local npc3 = makeNPC(30, 30, "bandit", BNS.Tier.THUG)
local b3 = npc3:getModData().BNS
b3.loot = {}
for i = 1, 9 do b3.loot[i] = "Base.TinnedBeans" end
local sq3 = placeContainer(31, 30, { makeItem("Base.Antibiotics"), makeItem("Base.Antibiotics") })
fixRand(0)
BNS.Scavenge.lootSquare(npc3, b3, sq3)
restoreRand()
assert(#b3.loot == 10, "pack cap of 10, got " .. #b3.loot)
print("pack cap OK")

-- 4. Looted cooldown --------------------------------------------------------
local npc4 = makeNPC(100, 100, "bandit", BNS.Tier.THUG)
placeContainer(85, 85, { makeItem("Base.Antibiotics") }) -- at cx-15, cy-15
fixRand(0) -- probes hit exactly (85,85)
assert(BNS.Scavenge.findContainerSquare(npc4), "container found before looting")
square(85, 85, 0).modData.BNS_Looted = worldHours
assert(not BNS.Scavenge.findContainerSquare(npc4), "freshly looted square skipped")
worldHours = worldHours + 100 -- past the 72h cooldown
assert(BNS.Scavenge.findContainerSquare(npc4), "square lootable again after cooldown")
restoreRand()
print("loot cooldown OK")

-- 5. Trader converts finds into stock ---------------------------------------
local trader = makeNPC(40, 40, BNS.Role.TRADER, BNS.Tier.CIVILIAN)
local tb = trader:getModData().BNS
local sq5 = placeContainer(41, 40, {
    makeItem("Base.Antibiotics"),            -- barter value: to stock
    makeItem("Base.Antibiotics"),            -- merged count
    makeItem("Base.HuntingKnife", "Weapon"), -- no barter value: to pack
})
fixRand(0)
BNS.Scavenge.lootSquare(trader, tb, sq5)
restoreRand()
assert(tb.stock and #tb.stock == 1 and tb.stock[1].item == "Base.Antibiotics"
    and tb.stock[1].count == 2 and tb.stock[1].value == 25, "trader stock merged")
assert(#tb.loot == 1 and tb.loot[1] == "Base.HuntingKnife", "non-barter find goes to pack")
print("trader restock OK")

-- 6. Player bases are off limits --------------------------------------------
local state = BNS.Persistence.getState()
state.playerBases["b"] = { x = 200, y = 200, hits = 999, lastRaid = 0 }
local npc6 = makeNPC(215, 215, "bandit", BNS.Tier.THUG)
placeContainer(200, 200, { makeItem("Base.Antibiotics") })
fixRand(0) -- probe hits exactly (200,200), inside the exclusion radius
assert(not BNS.Scavenge.findContainerSquare(npc6), "player-base squares never chosen")
restoreRand()
print("player-base exclusion OK")

-- 7. dropLoot drops the pack ------------------------------------------------
require("BNS/BNS_Spawner")
local victim = makeNPC(50, 50, "bandit", BNS.Tier.CIVILIAN)
local vb = victim:getModData().BNS
vb.loot = { "Base.Antibiotics", "Base.TinnedBeans" }
vb.weapon = { item = "Base.Plank" }
BNS.Spawner.dropLoot(victim, vb)
local floorItems = square(50, 50, 0).floor
local found = 0
for _, ft in ipairs(floorItems) do
    if ft == "Base.Antibiotics" or ft == "Base.TinnedBeans" then found = found + 1 end
end
assert(found == 2, "scavenged pack drops on death, got " .. found)
print("death drop OK")

-- 8. tryStart wires up the program ------------------------------------------
SandboxVars.BNS.ScavengingEnabled = true
local npc8 = makeNPC(300, 300, "bandit", BNS.Tier.THUG)
local b8 = npc8:getModData().BNS
placeContainer(285, 285, { makeItem("Base.Antibiotics") })
fixRand(0)
assert(BNS.Scavenge.tryStart(npc8, b8), "loot run starts")
restoreRand()
assert(b8.program == BNS.Program.SCAVENGE and b8.scav and b8.scav.x == 285, "program + target set")
SandboxVars.BNS.ScavengingEnabled = false
local b9 = makeNPC(300, 300, "bandit", BNS.Tier.THUG):getModData().BNS
fixRand(0)
assert(not BNS.Scavenge.tryStart(npc8, b9), "sandbox toggle disables scavenging")
restoreRand()
print("tryStart + sandbox toggle OK")

print("ALL TESTS PASSED")
