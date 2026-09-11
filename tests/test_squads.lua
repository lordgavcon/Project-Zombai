-- Offline test of bandit squads.
--
-- Two properties, and the second is the one that used to fail silently:
-- bandits arrive as a group, and they are still a group later. Records
-- were stepped one at a time off-screen, so a squad came apart across the
-- map within a few in-game hours and the player met the survivors of it
-- one at a time -- which looks exactly like bandits spawning alone.
math.randomseed(41)

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
function getNumActivePlayers() return 0 end
function getSpecificPlayer() return nil end
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
function getWorld() return { getMetaGrid = function()
    return { getZoneAt = function() return nil end } end } end
function instanceItem(id) return { id = id } end
function getCell()
    return {
        getGridSquare = function() return nil end, -- nothing is streamed in
        getZombieList = function()
            return { size = function() return 0 end, get = function() return nil end }
        end,
    }
end
ScriptManager = { instance = { getItem = function() return true end } }
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })

require("BNS/BNS_Core")
require("BNS/BNS_Main")

local state = BNS.Persistence.getState()
local function reset()
    state.npcs = {}
    state.squads = {}
end

local function members(squadId)
    local out = {}
    for _, rec in pairs(state.npcs) do
        if rec.squad == squadId then table.insert(out, rec) end
    end
    return out
end

local function spread(recs)
    local worst = 0
    for _, a in ipairs(recs) do
        for _, b in ipairs(recs) do
            worst = math.max(worst, BNS.dist(a.x, a.y, b.x, b.y))
        end
    end
    return worst
end

-- 1. Bandits arrive as a group ------------------------------------------------------------
reset()
local player = { getX = function() return 0 end, getY = function() return 0 end,
                 getZ = function() return 0 end, isDead = function() return false end }
for _ = 1, 30 do BNS.Spawner.spawnBanditNear(player) end

local squadIds, solo = {}, 0
for _, rec in pairs(state.npcs) do
    if rec.squad then squadIds[rec.squad] = true else solo = solo + 1 end
end
assert(solo == 0, "no bandit arrives on their own, got " .. solo)
local groups = 0
for id in pairs(squadIds) do
    groups = groups + 1
    local m = members(id)
    assert(#m >= 2, "a group is at least a pair, got " .. #m)
    assert(spread(m) <= 12, "and they start together, spread " .. spread(m))
    assert(BNS.Squads.get(id), "with a squad the module actually manages")
end
assert(groups > 0, "groups were made")
print("bandits arrive in groups OK (" .. groups .. " groups)")

-- 2. ...and are still a group hours later ------------------------------------------------
-- This is the one that mattered: every record used to walk off on its own
-- random 400-tile errand while virtual.
reset()
BNS.Squads.create(state, "squad_t", 1000, 1000)
for i = 1, 4 do
    local rec = BNS.Persistence.newRecord(BNS.Role.BANDIT, BNS.Tier.THUG, 1000, 1000, 0)
    rec.squad = "squad_t"
end
for _ = 1, 200 do BNS.Main.boundaryTick() end
local m = members("squad_t")
assert(#m == 4, "nobody was lost")
assert(spread(m) <= BNS.Squads.COHESION,
    "the group is still a group after 200 boundary ticks, spread " .. spread(m))
local ax, ay = BNS.Squads.anchor("squad_t")
assert(BNS.dist(ax, ay, 1000, 1000) > 0, "and it travelled rather than standing still")
print("squads travel together OK (spread " .. math.floor(spread(m))
    .. ", moved " .. math.floor(BNS.dist(ax, ay, 1000, 1000)) .. " tiles)")

-- 3. Every member gets their own spot in it ----------------------------------------------
-- A squad standing on one tile reads as one person.
local seen = {}
for _, rec in ipairs(m) do
    local k = math.floor(rec.x) .. "," .. math.floor(rec.y)
    assert(not seen[k], "two of them are standing on the same square")
    seen[k] = true
end
-- ...and that spot is theirs, not re-rolled every tick: an offset that
-- moved each pass would have them shuffling around each other for ever.
local ox, oy = BNS.Squads.offset(m[1].id)
for _ = 1, 20 do
    local nx, ny = BNS.Squads.offset(m[1].id)
    assert(nx == ox and ny == oy, "their place in the group is stable")
end
BNS.Squads.placeVirtual(m[1])
local heldX, heldY = m[1].x, m[1].y
BNS.Squads.placeVirtual(m[1])
assert(m[1].x == heldX and m[1].y == heldY,
    "so placing them twice puts them in the same spot")
print("formation OK")

-- 4. A live group's anchor follows its members, not the reverse ---------------------------
reset()
BNS.Squads.create(state, "squad_l", 0, 0)
for i = 1, 3 do
    local rec = BNS.Persistence.newRecord(BNS.Role.BANDIT, BNS.Tier.THUG, 300 + i, 300, 0)
    rec.squad = "squad_l"
    rec.live = true -- they have bodies and walked here themselves
end
BNS.Squads.tick(state)
local lx, ly = BNS.Squads.anchor("squad_l")
assert(math.abs(lx - 302) < 2 and math.abs(ly - 300) < 2,
    "the anchor re-centres on where the members actually are, got " .. lx .. "," .. ly)
-- A squad with anyone live is not marched around by the anchor stepper.
for _ = 1, 20 do BNS.Squads.tick(state) end
local lx2, ly2 = BNS.Squads.anchor("squad_l")
assert(math.abs(lx2 - lx) < 2 and math.abs(ly2 - ly) < 2,
    "and a live group is left to walk itself")
print("live groups lead their anchor OK")

-- 5. An emptied squad is dropped ----------------------------------------------------------
-- Otherwise the anchor pass carries a group of nobody around the map for
-- the rest of the save.
reset()
BNS.Squads.create(state, "squad_dead", 50, 50)
local lone = BNS.Persistence.newRecord(BNS.Role.BANDIT, BNS.Tier.THUG, 50, 50, 0)
lone.squad = "squad_dead"
BNS.Squads.recompute(state)
assert(BNS.Squads.get("squad_dead"), "alive while it has members")
state.npcs[lone.id] = nil -- killed
BNS.Squads.recompute(state)
assert(not BNS.Squads.get("squad_dead"), "and dropped once it has none")
print("empty squads are dropped OK")

-- 6. Wander destinations come from the group's bubble --------------------------------------
-- Cohesion is meant to be where they choose to go, not a correction
-- dragged out of them after they have already wandered off.
reset()
BNS.Squads.create(state, "squad_w", 200, 200)
local brain = { id = "bns_9", squad = "squad_w" }
for _ = 1, 200 do
    local tx, ty, urgent = BNS.Squads.wanderTarget(brain, 200, 200)
    assert(tx, "a squad member is given somewhere to go")
    assert(not urgent, "milling about is not urgent")
    assert(BNS.dist(tx, ty, 200, 200) <= BNS.Squads.MILL * 1.5,
        "and it is inside the group's bubble, got " .. BNS.dist(tx, ty, 200, 200))
end

-- Wandered out: the next destination brings them properly back in, not
-- just to the edge where they would drift straight out again.
local sx, sy, urgent = BNS.Squads.wanderTarget(brain, 260, 200)
assert(urgent, "regrouping is urgent -- no stopping for a rest half way")
assert(BNS.dist(sx, sy, 200, 200) <= BNS.Squads.REGROUP + 1,
    "and it lands well inside, got " .. BNS.dist(sx, sy, 200, 200))
assert(BNS.Squads.strayed(brain, 260, 200), "being out there is recognised")
assert(not BNS.Squads.strayed(brain, 205, 200), "and being in is not")

-- On the march, everyone heads for the group's destination.
local squad = BNS.Squads.get("squad_w")
squad.targetX, squad.targetY = 900, 900
local mx, my, marching = BNS.Squads.wanderTarget(brain, 200, 200)
assert(marching, "a group on the move does not stop to rest")
assert(BNS.dist(mx, my, 900, 900) < 10, "and everyone heads for the same place")
BNS.Squads.arrived(brain, 900, 900)
assert(BNS.Squads.get("squad_w").targetX == nil, "arriving ends the march")
print("cohesion by destination OK")

print("ALL TESTS PASSED")
