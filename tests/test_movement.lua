-- Offline test of how NPC shells are ordered to move.
--
-- The bug this covers: the repath budget in BNS.Programs.walkTo exists so
-- a shell that is already walking somewhere is not re-ordered mid-step
-- (which is what made NPCs skate). But it assumed the order it issued was
-- still being walked. When the engine drops the path -- the shell's own
-- AI changing state, a blocked square, a failed path -- the budget turned
-- into a gag: the NPC stood still and the brain politely declined to
-- re-order it. That is "bandits don't walk around" from the outside.
math.randomseed(11)

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
function getGameTime() return { getWorldAgeHours = function() return 0 end } end
function getCell() return { getZombieList = function()
    return { size = function() return 0 end, get = function() return nil end }
end } end
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })

function instanceItem(id) return { id = id } end
ScriptManager = { instance = { getItem = function() return true end } }

require("BNS/BNS_Core")
require("BNS/BNS_Persistence")
require("BNS/BNS_Programs")

-- A shell that records path orders and reports whether it still holds one.
local function makeShell(brain, opts)
    opts = opts or {}
    local z = {
        __iso = "IsoZombie", x = 0, y = 0, orders = 0, path = false,
        modData = { BNS = brain }, vars = {},
    }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:getModData() return self.modData end
    function z:setVariable(k, v) self.vars[k] = v end
    function z:setRunning() end
    function z:pathToLocationF(px, py)
        self.orders = self.orders + 1
        self.path = true
    end
    if opts.hasPath ~= false then
        function z:hasPath() return self.path end
    end
    if opts.throwOnHasPath then
        function z:hasPath() error("wrong signature") end
    end
    return z
end

-- 1. A shell still walking its order is left alone ---------------------------------------
BNS.Programs.pathProbe = nil
local brain = { id = "a" }
local z = makeShell(brain)
BNS.Programs.walkTo(z, 10, 10, 0, false)
assert(z.orders == 1, "the first order is issued, got " .. z.orders)
for _ = 1, 10 do BNS.Programs.walkTo(z, 10, 10, 0, false) end
assert(z.orders <= 4, "a walking shell is not re-ordered every tick, got " .. z.orders)
assert((brain.pathLost or 0) == 0, "and nothing was recorded as a lost path")
print("repath budget still holds for a moving shell OK")

-- 2. A dropped path is re-issued at once, not waited out ---------------------------------
BNS.Programs.pathProbe = nil
brain = { id = "b" }
z = makeShell(brain)
BNS.Programs.walkTo(z, 10, 10, 0, false)
assert(z.orders == 1)
z.path = false -- the engine dropped it
BNS.Programs.walkTo(z, 10, 10, 0, false)
assert(z.orders == 2, "the dropped order is re-issued immediately, got " .. z.orders)
assert(brain.pathLost == 1, "and counted, got " .. tostring(brain.pathLost))
-- Repeatedly losing it keeps the NPC moving rather than parked forever.
for _ = 1, 5 do z.path = false; BNS.Programs.walkTo(z, 10, 10, 0, false) end
assert(z.orders == 7, "every lost path gets a fresh order, got " .. z.orders)
print("lost path is re-ordered OK")

-- 3. A build without the query behaves exactly as before ---------------------------------
BNS.Programs.pathProbe = nil
brain = { id = "c" }
z = makeShell(brain, { hasPath = false })
for _ = 1, 10 do BNS.Programs.walkTo(z, 10, 10, 0, false) end
assert(z.orders <= 4, "no query means assume it is walking, got " .. z.orders)
assert(BNS.Programs.pathProbe == false, "and the probe settles instead of retrying")
print("unknown build falls back to the old budget OK")

-- 4. A query that throws is written off, not retried on every tick ------------------------
-- pcall stops the error propagating but Kahlua still dumps a stack trace
-- each time, so a bad signature must be called once, not sixty times a
-- second (CLAUDE.md: never retry an op that threw).
BNS.Programs.pathProbe = nil
brain = { id = "d" }
z = makeShell(brain, { throwOnHasPath = true })
local calls = 0
local realThrow = z.hasPath
function z:hasPath() calls = calls + 1; return realThrow(self) end
for _ = 1, 20 do BNS.Programs.walkTo(z, 10, 10, 0, false) end
assert(calls == 1, "a throwing query is called once, got " .. calls)
assert(BNS.Programs.pathProbe == false, "and locked out for the session")
print("throwing path query is locked out OK (" .. calls .. " calls across 20 ticks)")

-- 4b. A wandering bandit actually wanders --------------------------------------------------
-- "Set them to wander and they just stand still" was not a pathing bug:
-- destinations were being picked out of a box around a point with no
-- regard for where the NPC already was, so the destination was routinely
-- the tile underfoot. They "arrived" at once, rolled a rest, and stood
-- there -- worst for a bandit in a squad, whose bubble is ten tiles wide
-- and whose anchor follows its own members. What is asserted here is the
-- behaviour, not the numbers: they cover ground.
local function wanderShell(brain, x, y)
    local z = makeShell(brain)
    z.x, z.y = x, y
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:pathToLocationF(px, py)
        self.orders = self.orders + 1
        self.path = true
        self.goal = { px, py }
    end
    function z:clearPath() self.goal = nil; self.path = false end
    function z:setMoving() end
    function z:StopAllActionQueue() end
    function z:CanSee() return false end
    function z:setSpeedMod() end
    function z:playSound() end
    function z:setHeadLookAround(v) self.looking = v end
    function z:getOnlineID() return 1 end
    return z
end

-- Walk the shell towards its last order, roughly a person's pace, and
-- report how much of the time it was actually going somewhere.
local WALK = 0.45 -- tiles per full brain tick
local function wanderFor(brain, npc, ticks)
    local away = { getX = function() return 9000 end, getY = function() return 9000 end,
                   getZ = function() return 0 end, isDead = function() return false end,
                   isSneaking = function() return false end,
                   isAiming = function() return false end,
                   isRunning = function() return false end }
    local moving, travelled = 0, 0
    for _ = 1, ticks do
        local ctx = { player = away, dist = 9000 }
        BNS.Senses.observe(npc, brain, ctx)
        BNS.Programs[brain.program](npc, brain, ctx)
        local px, py = npc.x, npc.y
        if npc.goal and BNS.dist(npc.x, npc.y, npc.goal[1], npc.goal[2]) > 0.3 then
            local dx, dy = npc.goal[1] - npc.x, npc.goal[2] - npc.y
            local d = math.max(BNS.dist(0, 0, dx, dy), 0.001)
            npc.x, npc.y = npc.x + dx / d * WALK, npc.y + dy / d * WALK
        end
        local step = BNS.dist(px, py, npc.x, npc.y)
        if step > 0.01 then moving = moving + 1 end
        travelled = travelled + step
    end
    return moving / ticks, travelled
end

local TICKS = 1800 -- about five minutes of full brain ticks
BNS.Programs.pathProbe = nil
local lone = { id = "w1", role = BNS.Role.BANDIT, tier = BNS.Tier.THUG,
               health = 1.0, animMode = "idle", stamina = 1.0,
               program = BNS.Program.WANDER }
local loneShell = wanderShell(lone, 0, 0)
local loneMoving, loneDist = wanderFor(lone, loneShell, TICKS)
assert(loneMoving > 0.4, "a lone bandit spends most of its time walking, got "
    .. math.floor(loneMoving * 100) .. "%")

-- The squad case is the one that was broken: the group's bubble is small
-- and its anchor sits on top of its own members.
BNS.Squads.create(BNS.Persistence.getState(), "wsq", 0, 0)
local grouped = { id = "w2", role = BNS.Role.BANDIT, tier = BNS.Tier.THUG,
                  health = 1.0, animMode = "idle", stamina = 1.0,
                  program = BNS.Program.WANDER, squad = "wsq" }
local groupShell = wanderShell(grouped, 0, 0)
local sqMoving, sqDist = wanderFor(grouped, groupShell, TICKS)
assert(sqMoving > 0.15, "a bandit in a squad mills about rather than standing still, got "
    .. math.floor(sqMoving * 100) .. "%")
assert(sqDist > 100, "and covers real ground, got " .. math.floor(sqDist) .. " tiles")
-- ...without leaving the group, which is the constraint that makes the
-- destination small in the first place.
assert(BNS.dist(groupShell.x, groupShell.y, 0, 0) < BNS.Squads.COHESION * 2,
    "and stays with its squad")

-- The pause is a look round, not a nap: that is the "looking for the
-- player" half of wandering, and it is what SEARCH does on arrival too.
grouped.restUntil = 30
groupShell.looking = nil
BNS.Programs[BNS.Program.WANDER](groupShell, grouped,
    { player = nil, dist = 9000, visible = false })
assert(groupShell.looking == true, "a resting bandit looks around")
grouped.restUntil = 1
BNS.Programs[BNS.Program.WANDER](groupShell, grouped,
    { player = nil, dist = 9000, visible = false })
assert(groupShell.looking == false, "and stops when they move off again")
print(string.format("wandering bandits wander OK (alone %d%%/%d tiles, in a squad %d%%/%d tiles)",
    math.floor(loneMoving * 100), math.floor(loneDist),
    math.floor(sqMoving * 100), math.floor(sqDist)))

-- 5. Shell suppression: the unverified parking calls are off by default -------------------
-- setUseless/makeInactive were added on a guess about what they do, and a
-- parked shell cannot walk. They stay switchable from the debug panel so
-- the question is settled in game, but nothing calls them unasked.
assert(BNS.Suppress.clearTarget == true, "clearing the zombie's target is what stops aggression")
assert(BNS.Suppress.useless == false, "setUseless is not asserted by default")
assert(BNS.Suppress.inactive == false, "makeInactive is not asserted by default")
print("shell suppression defaults OK")

print("ALL TESTS PASSED")
