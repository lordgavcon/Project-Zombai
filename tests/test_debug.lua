-- Offline test of BNS_Debug with stubbed PZ APIs.
-- The security case (an unprivileged client forging debug commands)
-- is the most important assertion in this file.
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
local worldHours = 10
function getGameTime() return { getWorldAgeHours = function() return worldHours end } end
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
IsoDirections = { S = "S" }

-- BNS_Debug pulls in modules that register event handlers at load.
Events = setmetatable({}, { __index = function(t, k)
    local handler = { Add = function() end, Remove = function() end }
    rawset(t, k, handler)
    return handler
end })

-- Debug-mode switch the gate reads.
local debugMode = false
function getDebug() return debugMode end

-- World stubs -------------------------------------------------------------
local grid, spawnedZombies = {}, {}
local function square(x, y, z)
    local k = x .. "," .. y .. "," .. z
    if not grid[k] then
        local sq = { x = x, y = y, z = z, objects = {}, floor = {}, modData = {} }
        function sq:getX() return self.x end
        function sq:getY() return self.y end
        function sq:getZ() return self.z end
        function sq:getModData() return self.modData end
        function sq:isFree() return true end
        function sq:getObjects()
            return { size = function() return #sq.objects end, get = function(_, i) return sq.objects[i + 1] end }
        end
        function sq:AddWorldInventoryItem(ft) table.insert(sq.floor, ft) end
        grid[k] = sq
    end
    return grid[k]
end

local shells = {}
local function makeShell(x, y, brain)
    local z = { __iso = "IsoZombie", x = x, y = y, modData = { BNS = brain }, dead = false }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:setX(v) self.x = v end
    function z:setY(v) self.y = v end
    function z:setZ() end
    function z:setLastX() end
    function z:setLastY() end
    function z:getModData() return self.modData end
    function z:isDead() return self.dead end
    function z:setHealth(h) if h <= 0 then self.dead = true end end
    function z:Kill() self.dead = true end
    function z:getOnlineID() return 1 end
    function z:playSound() end
    function z:setVariable() end
    function z:removeFromWorld() self.gone = true end
    function z:removeFromSquare() end
    function z:getCurrentSquare() return square(math.floor(self.x), math.floor(self.y), 0) end
    function z:setUseless() end
    function z:makeInactive() end
    function z:setTarget() end
    function z:setAttackedBy() end
    function z:setPrimaryHandItem() end
    function z:setSecondaryHandItem() end
    function z:setRunning() end
    table.insert(shells, z)
    return z
end

function getCell()
    return {
        getGridSquare = function(_, x, y, z) return square(x, y, z) end,
        getZombieList = function()
            return { size = function() return #shells end, get = function(_, i) return shells[i + 1] end }
        end,
        getVehicles = function() return { size = function() return 0 end, get = function() end } end,
    }
end

-- addZombiesInOutfit backs both NPC shells and the debug horde spawner.
function addZombiesInOutfit(x, y, z, n, outfit, ...)
    local made = {}
    for _ = 1, n do
        local zed
        if outfit == nil then
            -- plain zombie (debug horde): not a BNS shell
            zed = { __iso = "IsoZombie", x = x, y = y, modData = {}, dead = false }
            function zed:getX() return self.x end
            function zed:getY() return self.y end
            function zed:getZ() return 0 end
            function zed:getModData() return self.modData end
            function zed:isDead() return false end
            table.insert(spawnedZombies, zed)
            table.insert(shells, zed)
        else
            zed = makeShell(x, y, nil)
        end
        table.insert(made, zed)
    end
    return { size = function() return #made end, get = function(_, i) return made[i + 1] end }
end

function instanceItem() return nil end

local function makePlayer(name, access)
    local p = { name = name, access = access or "None", x = 100, y = 100, items = {} }
    function p:getUsername() return self.name end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return 0 end
    function p:setX(v) self.x = v end
    function p:setY(v) self.y = v end
    function p:setZ() end
    function p:setLastX() end
    function p:setLastY() end
    function p:getAccessLevel() return self.access end
    function p:getCurrentSquare() return square(math.floor(self.x), math.floor(self.y), 0) end
    function p:getInventory()
        return { AddItem = function(_, ft) table.insert(p.items, ft) end }
    end
    function p:setHaloNote() end
    function p:isDead() return false end
    return p
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
require("BNS/BNS_Spawner")
require("BNS/BNS_Vehicles")
require("BNS/BNS_Debug")

-- Capture replies to the client.
local replies = {}
BNS.Client = { onServerCommand = function(_, command, args)
    table.insert(replies, { command = command, args = args })
end }

local function lastSnapshot()
    for i = #replies, 1, -1 do
        if replies[i].command == "debugSnapshot" then return replies[i].args end
    end
    return nil
end

local function npcCount()
    local n = 0
    for _ in pairs(BNS.Persistence.getState().npcs) do n = n + 1 end
    return n
end

-- 1. SECURITY: an unprivileged player must change nothing -----------------
debugMode = false
local intruder = makePlayer("Eve", "None")
assert(not BNS.Debug.isAllowed(intruder), "plain player is not allowed")
local before = npcCount()
assert(BNS.Debug.handle("debugSpawn", intruder, { archetype = "exmilitary", count = 5 }),
    "command is recognised (and swallowed)")
assert(npcCount() == before, "unprivileged spawn must not create NPCs")
BNS.Debug.handle("debugClear", intruder, {})
BNS.Debug.handle("debugRaid", intruder, {})
BNS.Debug.handle("debugOption", intruder, { name = "ScavengingEnabled", value = false })
assert(npcCount() == before, "no debug command mutates state for an unprivileged player")
assert(SandboxVars.BNS.ScavengingEnabled == nil, "sandbox untouched by unprivileged caller")
assert(#replies == 0, "no data leaked back to an unprivileged caller")
print("security gate OK (unprivileged commands refused)")

-- 2. Admin is allowed; debug mode is allowed --------------------------------
local admin = makePlayer("Alice", "Admin")
assert(BNS.Debug.isAllowed(admin), "admin allowed in MP")
debugMode = true
assert(BNS.Debug.isAllowed(intruder), "debug mode allows the local tester")
debugMode = false
print("access rules OK")

-- 3. spawnNPC honours the requested archetype/tier ---------------------------
BNS.Debug.handle("debugSpawn", admin, { archetype = "police", count = 3 })
local police, squads = 0, {}
for _, rec in pairs(BNS.Persistence.getState().npcs) do
    if rec.archetype == "police" then
        police = police + 1
        assert(rec.tier == BNS.Tier.THUG, "police archetype maps to thug tier")
        squads[rec.squad or "none"] = true
    end
end
assert(police == 3, "spawned exactly 3, got " .. police)
local squadCount = 0
for _ in pairs(squads) do squadCount = squadCount + 1 end
assert(squadCount == 1, "multi-spawn shares one squad id")
print("spawn archetype/tier/squad OK")

-- 4. Snapshot shape matches state --------------------------------------------
replies = {}
BNS.Debug.handle("debugSnapshot", admin, {})
local snap = lastSnapshot()
assert(snap, "snapshot returned")
assert(#snap.npcs == npcCount(), "snapshot lists every NPC")
assert(snap.counts.live + snap.counts.virtual == npcCount(), "counts add up")
assert(snap.options.scavenging ~= nil, "options included")
assert(snap.npcs[1].dist ~= nil and snap.npcs[1].program, "rows carry program + distance")
for i = 2, #snap.npcs do
    assert(snap.npcs[i].dist >= snap.npcs[i - 1].dist, "rows sorted nearest first")
end
print("snapshot OK (" .. #snap.npcs .. " rows)")

-- 5. forceProgram lands and clears stale transition state ---------------------
local targetId, targetShell
for _, shell in ipairs(shells) do
    local b = shell.modData and shell.modData.BNS
    if b then targetId, targetShell = b.id, shell break end
end
assert(targetId, "found a live shell")
targetShell.modData.BNS.warned = true
targetShell.modData.BNS.intent = "attack"
BNS.Debug.handle("debugProgram", admin, { id = targetId, program = BNS.Program.FLEE })
assert(targetShell.modData.BNS.program == BNS.Program.FLEE, "program forced")
assert(targetShell.modData.BNS.warned == nil and targetShell.modData.BNS.intent == nil,
    "stale transition state cleared")
assert(targetShell.modData.BNS.fleeUntil, "flee timer primed")
print("forceProgram OK")

-- 6. killNPC removes exactly one ------------------------------------------------
local beforeKill = npcCount()
BNS.Debug.handle("debugKill", admin, { id = targetId })
assert(npcCount() == beforeKill - 1, "one record removed")
assert(targetShell.dead, "shell killed")
print("killNPC OK")

-- 7. setOption changes what Options() returns -----------------------------------
assert(BNS.Options().scavenging == true, "default on")
BNS.Debug.handle("debugOption", admin, { name = "ScavengingEnabled", value = false })
assert(BNS.Options().scavenging == false, "live override applied")
BNS.Debug.handle("debugOption", admin, { name = "ScavengingEnabled", value = true })
print("setOption OK")

-- 8. clearNPCs wipes everything ---------------------------------------------------
BNS.Debug.handle("debugSpawn", admin, { archetype = "farmer", count = 2 })
assert(npcCount() > 0, "have NPCs before clearing")
BNS.Debug.handle("debugClear", admin, {})
assert(npcCount() == 0, "all records cleared")
print("clearNPCs OK")

-- 9. spawnNPC returns the ids it created ---------------------------------------------
-- (regression: scenarios used to pick "the newest" NPC by iterating
-- pairs(), whose order is arbitrary, and acted on the wrong NPC)
BNS.Debug.handle("debugClear", admin, {})
local ids = BNS.Debug.spawnNPC(admin, { archetype = "farmer", count = 3 })
assert(#ids == 3, "returns one id per spawn")
local seen = {}
for _, id in ipairs(ids) do
    assert(BNS.Persistence.getState().npcs[id], "returned id exists: " .. tostring(id))
    assert(not seen[id], "ids are distinct")
    seen[id] = true
end
BNS.Debug.handle("debugClear", admin, {})
print("spawn returns ids OK")

-- 10. Scenarios are all runnable, and act on their own spawns -------------------------
for name, sc in pairs(BNS.Debug.Scenarios) do
    assert(sc.label and sc.watch and type(sc.run) == "function", name .. " is well formed")
    replies = {}
    BNS.Debug.handle("debugScenario", admin, { name = name })
    local told, misfired = false, false
    for _, r in ipairs(replies) do
        if r.command == "debugResult" then
            if r.args.text:find(sc.watch, 1, true) then told = true end
            if r.args.text:find("NPC not loaded", 1, true) then misfired = true end
        end
    end
    assert(told, name .. " reports what to watch for")
    assert(not misfired, name .. " must target the NPC it just spawned")
    BNS.Debug.handle("debugClear", admin, {})
end
print("scenarios OK (" .. (function() local n = 0 for _ in pairs(BNS.Debug.Scenarios) do n = n + 1 end return n end)() .. ")")

-- 11. Log ring buffer caps and keeps the newest --------------------------------------
local realPrint = print
print = function() end -- BNS.log prints; keep the suite output readable
for i = 1, BNS.LOG_BUFFER_MAX + 25 do BNS.log("entry " .. i) end
print = realPrint
assert(#BNS.logBuffer == BNS.LOG_BUFFER_MAX, "buffer capped at " .. BNS.LOG_BUFFER_MAX)
assert(BNS.logBuffer[#BNS.logBuffer].text == "entry " .. (BNS.LOG_BUFFER_MAX + 25), "newest kept")
assert(BNS.logBuffer[1].text ~= "entry 1", "oldest dropped")
assert(BNS.logBuffer[1].h == worldHours, "entries timestamped with world hours")
replies = {}
BNS.Debug.handle("debugSnapshot", admin, {})
local snap2 = lastSnapshot()
assert(#snap2.log > 0 and #snap2.log <= 41, "snapshot carries a bounded log tail")
assert(snap2.log[1].text:find("entry"), "log tail is newest first")
print("log buffer OK")

-- 12. Unknown commands are not claimed by the debug handler ---------------------------
assert(BNS.Debug.handle("requestTrade", admin, {}) == false,
    "non-debug commands fall through to the normal dispatcher")
print("dispatch passthrough OK")

print("ALL TESTS PASSED")
