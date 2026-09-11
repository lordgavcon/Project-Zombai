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

require("BNS/BNS_Core")
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

-- 5. Shell suppression: the unverified parking calls are off by default -------------------
-- setUseless/makeInactive were added on a guess about what they do, and a
-- parked shell cannot walk. They stay switchable from the debug panel so
-- the question is settled in game, but nothing calls them unasked.
assert(BNS.Suppress.clearTarget == true, "clearing the zombie's target is what stops aggression")
assert(BNS.Suppress.useless == false, "setUseless is not asserted by default")
assert(BNS.Suppress.inactive == false, "makeInactive is not asserted by default")
print("shell suppression defaults OK")

print("ALL TESTS PASSED")
