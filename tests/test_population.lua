-- Offline test of the live/virtual boundary.
--
-- The bug this covers: a record was woken on a *radius* around the
-- player, but embodying it needs the square under it to be streamed in.
-- Those two are not the same shape, so a record could sit inside the wake
-- radius on unloaded ground -- and the old code only stepped records
-- *outside* that radius, so it was embodied never and moved never. Once
-- an NPC drifted into that band it stayed there for the rest of the save.
math.randomseed(31)

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

-- PZ stubs -------------------------------------------------------------
function ZombRand(a, b) if b then return math.random(a, b - 1) end return math.random(0, a - 1) end
function ZombRandFloat(a, b) return a + math.random() * (b - a) end
function instanceof(obj, cls) return type(obj) == "table" and obj.__iso == cls end
function isServer() return false end
function isClient() return false end
function getText(k) return k end
function addSound() end
function getNumActivePlayers() return #(_G.PLAYERS or {}) end
function getSpecificPlayer(i) return (_G.PLAYERS or {})[i + 1] end
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
function getWorld() return { getMetaGrid = function()
    return { getZoneAt = function() return nil end } end } end
function instanceItem(id) return { id = id, getFullType = function() return id end } end
ScriptManager = { instance = { getItem = function() return true end } }
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })

-- The world: only the squares in LOADED exist. Everything else is
-- unstreamed, exactly as it is off-screen in game.
local LOADED = {}
local SHELLS = {}
local spawnFails = {}

local function key(x, y) return math.floor(x) .. "," .. math.floor(y) end
local function load(x, y) LOADED[key(x, y)] = true end
local function unloadAll() LOADED = {} end

function getCell()
    return {
        getGridSquare = function(_, x, y)
            if not LOADED[key(x, y)] then return nil end
            return { getX = function() return x end, getY = function() return y end,
                     getZ = function() return 0 end,
                     isFree = function() return true end,
                     isSolidTrans = function() return false end }
        end,
        getZombieList = function()
            return { size = function() return #SHELLS end,
                     get = function(_, i) return SHELLS[i + 1] end }
        end,
    }
end

-- addZombiesInOutfit is what actually gives a record a body.
function addZombiesInOutfit(x, y, z, n, outfit)
    if spawnFails[key(x, y)] then return { size = function() return 0 end } end
    local z0 = {
        __iso = "IsoZombie", x = x, y = y, modData = {}, vars = {},
    }
    function z0:getX() return self.x end
    function z0:getY() return self.y end
    function z0:getZ() return 0 end
    function z0:getModData() return self.modData end
    function z0:setVariable(k, v) self.vars[k] = v end
    function z0:setHealth() end
    function z0:isDead() return false end
    function z0:getOnlineID() return 1 end
    function z0:setPrimaryHandItem() end
    function z0:setSecondaryHandItem() end
    function z0:getHumanVisual() return nil end
    function z0:getItemVisuals() return nil end
    function z0:resetModelNextFrame() end
    function z0:removeFromWorld()
        for i, other in ipairs(SHELLS) do
            if other == self then table.remove(SHELLS, i) break end
        end
    end
    function z0:removeFromSquare() end
    table.insert(SHELLS, z0)
    return { size = function() return 1 end, get = function() return z0 end }
end

require("BNS/BNS_Core")
require("BNS/BNS_Main")

local function makePlayer(x, y)
    return { getX = function() return x end, getY = function() return y end,
             getZ = function() return 0 end, isDead = function() return false end }
end

local state = BNS.Persistence.getState()
local function reset()
    state.npcs = {}
    SHELLS = {}
    spawnFails = {}
    unloadAll()
end

-- 1. The limbo band: unloaded ground always keeps moving ---------------------------------
-- 100 tiles out was inside the old 120-tile wake radius and outside the
-- streamed world, so the record was frozen: no body, no step, for ever.
reset()
_G.PLAYERS = { makePlayer(0, 0) }
local stuck = BNS.Persistence.newRecord(BNS.Role.BANDIT, BNS.Tier.THUG, 100, 0, 0)
local startX, startY = stuck.x, stuck.y
for _ = 1, 5 do BNS.Main.boundaryTick() end
assert(not stuck.live, "unloaded ground gives no body")
assert(BNS.dist(stuck.x, stuck.y, startX, startY) > 0,
    "and a record on it keeps walking the world instead of freezing")
print("no limbo band OK (moved " ..
    math.floor(BNS.dist(stuck.x, stuck.y, startX, startY)) .. " tiles)")

-- 2. The square loading is what wakes them ----------------------------------------------
reset()
local waiting = BNS.Persistence.newRecord(BNS.Role.BANDIT, BNS.Tier.THUG, 500, 500, 0)
waiting.home = { x = 500, y = 500 } -- pinned, so the step cannot move it
BNS.Main.boundaryTick()
assert(not waiting.live, "still virtual while its ground is unstreamed")
assert(#SHELLS == 0, "and nothing was put in the world")

load(500, 500)
BNS.Main.boundaryTick()
assert(waiting.live, "the square loading is what gives them a body")
assert(#SHELLS == 1, "exactly one, in the world")
assert(SHELLS[1]:getX() == 500 and SHELLS[1]:getY() == 500,
    "standing where the record said they were")
print("wakes when its square loads OK")

-- 3. ...and hands it back when that ground goes -----------------------------------------
-- A shell whose chunk unloads is taken by the engine, and the record then
-- keeps whatever it last synced rather than where the NPC really was.
local shell = SHELLS[1]
shell.x, shell.y = 503, 504 -- they walked a little before the chunk went
unloadAll()
BNS.Main.boundaryTick()
assert(not waiting.live, "the body is handed back when the ground unloads")
assert(math.floor(waiting.x) == 503 and math.floor(waiting.y) == 504,
    "with the position they had walked to, got " .. waiting.x .. "," .. waiting.y)
print("dematerialises with its ground OK")

-- 4. Loaded ground that will not take a body does not trap them --------------------------
reset()
local blocked = BNS.Persistence.newRecord(BNS.Role.SURVIVOR, BNS.Tier.CIVILIAN, 20, 20, 0)
blocked.home = { x = 20, y = 20 }
load(20, 20)
spawnFails[key(20, 20)] = true
for _ = 1, 2 do BNS.Main.boundaryTick() end
assert(not blocked.live and blocked.wakeFails == 2, "failures are counted, not ignored")
BNS.Main.boundaryTick()
assert(blocked.wakeFails == nil, "and after a few tries they stop retrying that spot")
print("failed embodiment moves on OK")

-- 5. The live cap holds bodies back, it does not teleport people -------------------------
-- A record standing on loaded ground that is only waiting for a slot must
-- stay exactly where it is: stepping it would slide an NPC across the
-- street the player is standing in.
reset()
SandboxVars.BNS.MaxLiveNPCs = 0
local capped = BNS.Persistence.newRecord(BNS.Role.BANDIT, BNS.Tier.THUG, 30, 30, 0)
load(30, 30)
for _ = 1, 5 do BNS.Main.boundaryTick() end
assert(not capped.live, "the cap keeps them virtual")
assert(capped.x == 30 and capped.y == 30, "but they are left where they stand")
assert(capped.capped, "and it is recorded as the cap, not a failure")
SandboxVars.BNS.MaxLiveNPCs = nil
print("population cap does not teleport OK")

-- 6. New NPCs are created outside the loaded world ---------------------------------------
-- An NPC that pops into existence inside the streamed area can appear in
-- front of you; at forty tiles in an open field that is on screen.
reset()
for x = -80, 80 do
    for y = -80, 80, 4 do load(x, y) end
end
local player = makePlayer(0, 0)
_G.PLAYERS = { player }
for _ = 1, 25 do BNS.Spawner.spawnBanditNear(player) end
local made = 0
for _, rec in pairs(state.npcs) do
    made = made + 1
    assert(not rec.live, "a fresh NPC has no body yet")
    assert(not BNS.squareLoaded(rec.x, rec.y, 0),
        "and is created out in the unloaded world, not at "
            .. math.floor(rec.x) .. "," .. math.floor(rec.y))
end
assert(made > 0, "some were created, got " .. made)
print("spawns outside the loaded world OK (" .. made .. " records)")

-- 7. The record population is bounded -----------------------------------------------------
-- The live cap used to throttle creation because spawning made a body on
-- the spot. It cannot any more, so the pool needs its own ceiling.
reset()
_G.PLAYERS = { makePlayer(0, 0) }
SandboxVars.BNS.MaxLiveNPCs = 4
SandboxVars.BNS.BanditSpawnRate = 25
SandboxVars.BNS.SurvivorSpawnRate = 25
for _ = 1, 400 do BNS.Main.populationTick() end
local total = BNS.Persistence.count()
assert(total > 0, "it does spawn")
assert(total <= BNS.recordCeiling(),
    "records stop accumulating at the pool ceiling ("
        .. BNS.recordCeiling() .. "), got " .. total)
SandboxVars.BNS.MaxLiveNPCs = nil
SandboxVars.BNS.BanditSpawnRate = nil
SandboxVars.BNS.SurvivorSpawnRate = nil
print("record pool is bounded OK (" .. total .. " records)")

print("ALL TESTS PASSED")
