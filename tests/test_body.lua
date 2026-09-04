-- Offline test of the player-body layer: BNS_Visual (server broadcast)
-- and BNS_Body (client IsoPlayer proxies).
--
-- Rendering itself cannot be tested here; what is tested is everything
-- around it, above all the fallback contract: if player bodies cannot
-- work on a build, the layer must switch off and leave the shells
-- visible - never draw a player body on top of a visible zombie.
math.randomseed(67)

local ROOT = arg[1]
local loaded = {}
function require(name)
    if loaded[name] then return end
    loaded[name] = true
    for _, dir in ipairs({ "/shared/", "/server/", "/client/" }) do
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
function getGameTime() return { getWorldAgeHours = function() return 5 end } end
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })
IsoDirections = { S = "S", N = "N" }

-- World -------------------------------------------------------------------
local shells = {}
local function makeShell(id, x, y, oid, opts)
    opts = opts or {}
    local z = { __iso = "IsoZombie", x = x, y = y, oid = oid, hidden = false,
        modData = { BNS = { id = id, animMode = "walk", health = 1.0,
                            weapon = { item = "Base.Axe" }, look = { female = false, skin = 1, outfit = "Farmer" } } } }
    function z:getX() return self.x end
    function z:getY() return self.y end
    function z:getZ() return 0 end
    function z:getDir() return "S" end
    function z:getOnlineID() return self.oid end
    function z:getModData() return self.modData end
    function z:isDead() return false end
    if not opts.unhidable then
        function z:setAlphaAndTarget(a) self.hidden = (a == 0) and not opts.stubbornAlpha end
    end
    if not opts.noGetter then
        function z:getAlpha() return self.hidden and 0 or 1 end
    end
    table.insert(shells, z)
    return z
end
function getCell()
    return {
        getZombieList = function()
            return { size = function() return #shells end, get = function(_, i) return shells[i + 1] end }
        end,
        getGridSquare = function() return nil end,
    }
end

local players = {}
local function makePlayer(name, x, y)
    local p = { name = name, x = x, y = y }
    function p:getUsername() return self.name end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:isDead() return false end
    return p
end
function getNumActivePlayers() return #players end
function getSpecificPlayer(i) return players[i + 1] end

-- IsoPlayer proxy stub -------------------------------------------------------
local proxyFailMode = false
local createdProxies, removedProxies = {}, {}
SurvivorFactory = { CreateSurvivor = function()
    local d = { female = nil }
    function d:setFemale(v) self.female = v end
    function d:getHumanVisual() return { setSkinTextureIndex = function() end,
        setHairModel = function() end, setBeardModel = function() end } end
    return d
end }
IsoPlayer = { new = function(cell, desc, x, y, z)
    if proxyFailMode then error("IsoPlayer unsupported on this build") end
    local p = { x = x, y = y, z = z, vars = {}, prim = nil, desc = desc, removed = false }
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:setX(v) self.x = v end
    function p:setY(v) self.y = v end
    function p:setZ(v) self.z = v end
    function p:setLastX() end
    function p:setLastY() end
    function p:setDir(d) self.dir = d end
    function p:setVariable(k, v) self.vars[k] = v end
    function p:setPrimaryHandItem(i) self.prim = i end
    function p:setSecondaryHandItem(i) self.sec = i end
    function p:setGodMod() end
    function p:setInvincible() end
    function p:setGhostMode() end
    function p:setNoClip() end
    function p:setSceneCulled() end
    function p:setInvisible() end
    function p:dressInNamedOutfit(o) self.outfit = o end
    function p:resetModelNextFrame() end
    function p:removeFromWorld() self.removed = true; table.insert(removedProxies, self) end
    function p:removeFromSquare() end
    function p:playAnimation(a) self.lastAnim = a end
    function p:DoAttack() self.didAttack = true end
    table.insert(createdProxies, p)
    return p
end }
function instanceItem(ft) return { ft = ft, isTwoHandWeapon = function() return false end } end

require("BNS/BNS_Core")
require("BNS/BNS_Persistence")
require("BNS/BNS_Visual")
require("BNS/BNS_Body")

local sent = {}
BNS.Client = { onServerCommand = function(_, command, args)
    table.insert(sent, { command = command, args = args })
end }

local function lastOf(cmd)
    for i = #sent, 1, -1 do if sent[i].command == cmd then return sent[i].args end end
    return nil
end

-- 1. Snapshot culls by distance ------------------------------------------------
local near = makeShell("n1", 100, 100, 11)
local far = makeShell("n2", 400, 400, 12)
local viewer = makePlayer("Alice", 100, 100)
players = { viewer }

sent = {}
BNS.Visual.sendTo(viewer, { { zombie = near, brain = near.modData.BNS },
                            { zombie = far, brain = far.modData.BNS } })
local vis = lastOf("npcVisual")
assert(vis and #vis.rows == 1, "only the near NPC is sent, got " .. #(vis and vis.rows or {}))
assert(vis.rows[1].id == "n1", "the right one")
assert(vis.rows[1].look and vis.rows[1].oid == 11, "first row carries appearance and the puppet id")
print("snapshot distance culling OK")

-- 2. Delta encoding: unchanged NPCs cost nothing --------------------------------
sent = {}
BNS.Visual.sendTo(viewer, { { zombie = near, brain = near.modData.BNS } })
assert(#sent == 0, "an unchanged NPC sends nothing at all")

near.x = 105
sent = {}
BNS.Visual.sendTo(viewer, { { zombie = near, brain = near.modData.BNS } })
vis = lastOf("npcVisual")
assert(vis and #vis.rows == 1 and vis.rows[1].x == 105, "movement is sent")
assert(vis.rows[1].look == nil, "appearance is not re-sent")
assert(vis.rows[1].weapon == nil, "unchanged weapon is not re-sent")
print("delta encoding OK")

-- 3. Leaving range produces a gone entry -----------------------------------------
sent = {}
BNS.Visual.sendTo(viewer, {})
vis = lastOf("npcVisual")
assert(vis and #vis.gone == 1 and vis.gone[1] == "n1", "departed NPC reported gone")
print("gone list OK")

-- 4. Action pulses go out immediately ---------------------------------------------
sent = {}
BNS.Visual.pulse(near.modData.BNS, "swing")
local anim = lastOf("npcAnim")
assert(anim and anim.id == "n1" and anim.action == "swing", "pulse broadcasts the action")
print("action pulse OK")

-- 5. Proxy lifecycle -----------------------------------------------------------------
BNS.Body.supported = nil
BNS.Body.hideFn = nil
BNS.Body.clearAll()
createdProxies, removedProxies = {}, {}

BNS.Body.onVisual({ rows = { { id = "n1", oid = 11, x = 100, y = 100, z = 0,
    anim = "walk", weapon = "Base.Axe", look = { female = true, skin = 2, outfit = "Farmer" } } } })
assert(#createdProxies == 1, "a proxy is created for the NPC")
assert(near.hidden, "its puppet is hidden")
local entry = BNS.Body.proxies["n1"]
assert(entry and entry.proxy.prim and entry.proxy.prim.ft == "Base.Axe",
    "the real weapon is put in its hands (this is what makes swings weapon-correct)")
assert(entry.proxy.desc.female == true, "appearance seed applied")
assert(entry.proxy.outfit == "Farmer", "outfit applied")
assert(entry.proxy.vars.bMoving == true and entry.proxy.vars.bRunning == false, "gait variables set")

-- a second update reuses the proxy and does not re-equip
local before = #createdProxies
entry.proxy.prim = nil
BNS.Body.onVisual({ rows = { { id = "n1", x = 101, y = 100, anim = "run" } } })
assert(#createdProxies == before, "no duplicate proxy")
assert(entry.proxy.prim == nil, "weapon not re-equipped when unchanged")
assert(entry.proxy.vars.bRunning == true, "running state applied")

BNS.Body.onVisual({ rows = {}, gone = { "n1" } })
assert(BNS.Body.proxies["n1"] == nil and #removedProxies == 1, "gone removes the proxy")
print("proxy lifecycle OK")

-- 6. Fallback contract: cannot hide the puppet -> no proxies at all ---------------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
createdProxies = {}
shells = {}
local stubborn = makeShell("n3", 100, 100, 33, { unhidable = true })
BNS.Body.onVisual({ rows = { { id = "n3", oid = 33, x = 100, y = 100, z = 0, anim = "walk" } } })
assert(BNS.Body.supported == false, "layer disables itself")
assert(#createdProxies == 0, "no player body is drawn over a visible zombie")
assert(not stubborn.hidden, "the shell stays visible and keeps rendering itself")
-- and it stays off
BNS.Body.onVisual({ rows = { { id = "n3", oid = 33, x = 101, y = 100 } } })
assert(#createdProxies == 0, "the layer stays off once disabled")
print("fallback (unhidable puppet) OK")

-- 7. Fallback contract: IsoPlayer construction fails --------------------------------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
createdProxies = {}
shells = {}
makeShell("n4", 100, 100, 44)
proxyFailMode = true
BNS.Body.onVisual({ rows = { { id = "n4", oid = 44, x = 100, y = 100, z = 0, anim = "idle" } } })
assert(BNS.Body.supported == false, "construction failure disables the layer")
assert(BNS.Body.proxies["n4"] == nil, "no half-built proxy left behind")
proxyFailMode = false
print("fallback (no IsoPlayer) OK")

-- 8. Actions and the animation lab ---------------------------------------------------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
shells = {}
makeShell("n5", 100, 100, 55)
BNS.Body.onVisual({ rows = { { id = "n5", oid = 55, x = 100, y = 100, z = 0, anim = "idle" } } })
local e5 = BNS.Body.proxies["n5"]
assert(e5, "proxy exists")

BNS.Body.chosen.swing = 1
BNS.Body.onAnim({ id = "n5", action = "swing" })
assert(e5.proxy.vars.StartedAttack == "true", "first swing candidate applied")

local name = BNS.Body.labCycle("swing")
assert(BNS.Body.chosen.swing == 2 and name, "lab cycles to the next candidate: " .. tostring(name))
BNS.Body.onAnim({ id = "n5", action = "swing" })
assert(e5.proxy.vars.bAttacking == "true", "second candidate applied after cycling")
-- cycling wraps
for _ = 1, #BNS.Body.ActionCandidates.swing do BNS.Body.labCycle("swing") end
assert(BNS.Body.chosen.swing == 2, "cycle wraps around")

local ok, msg = BNS.Body.labTest("shoot")
assert(ok and msg:find("proxy"), "lab test reports what it did: " .. tostring(msg))
BNS.Body.clearAll()
local ok2, msg2 = BNS.Body.labTest("swing")
assert(not ok2 and msg2:find("no proxy"), "lab test is honest when there is nothing to test")
assert(#BNS.Body.labStatus() >= 3, "lab status reports state")
print("actions + animation lab OK")

-- 9. Interpolation moves toward the puppet without overshooting ------------------------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
shells = {}
makeShell("n6", 100, 100, 66)
BNS.Body.onVisual({ rows = { { id = "n6", oid = 66, x = 100, y = 100, z = 0, anim = "walk" } } })
local e6 = BNS.Body.proxies["n6"]
BNS.Body.onVisual({ rows = { { id = "n6", x = 110, y = 100 } } })
local prev = e6.proxy:getX()
for _ = 1, 30 do
    BNS.Body.tick()
    local now = e6.proxy:getX()
    assert(now >= prev - 0.001 and now <= 110.001, "moves toward the target, never past it")
    prev = now
end
assert(math.abs(e6.proxy:getX() - 110) < 0.5, "converges on the puppet, got " .. e6.proxy:getX())
print("interpolation OK")

-- 10. No puppet found -> no proxy (never draw a body over a live zombie) ---------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
shells = {}
createdProxies = {}
BNS.Body.onVisual({ rows = { { id = "ghost", oid = 999, x = 500, y = 500, z = 0, anim = "walk" } } })
assert(#createdProxies == 0, "no puppet means no proxy")
assert(BNS.Body.supported ~= false, "a missing puppet is transient, not a reason to disable")
assert(BNS.Body.hidePuppet(nil) == false, "hidePuppet(nil) must refuse")
print("missing puppet handled OK")

-- 11. Puppet matching falls back mod data -> online id -> position -----------------
shells = {}
local byData = makeShell("m1", 10, 10, -1)
local found, how = BNS.Body.findPuppet(-1, "m1", 10, 10)
assert(found == byData and how == "modData", "mod data match wins (this is the SP case)")

shells = {}
local byOid = makeShell("other", 20, 20, 77)
found, how = BNS.Body.findPuppet(77, "not-here", 999, 999)
assert(found == byOid and how == "onlineId", "falls back to online id")

shells = {}
local byPos = makeShell("other2", 30, 30, -1)
byPos.modData.BNS = nil
found, how = BNS.Body.findPuppet(-1, "unknown", 30.5, 30.2)
assert(found == byPos and how == "position", "falls back to position")

found, how = BNS.Body.findPuppet(-1, "unknown", 900, 900)
assert(found == nil, "nothing within range matches nothing")
print("puppet matching fallbacks OK")

-- 12. A hide call that "works" but leaves the zombie visible is rejected ------------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
shells = {}
createdProxies = {}
local liar = makeShell("liar", 40, 40, 88, { stubbornAlpha = true })
BNS.Body.onVisual({ rows = { { id = "liar", oid = 88, x = 40, y = 40, z = 0, anim = "walk" } } })
assert(BNS.Body.supported == false, "unverified-visible puppet disables the layer")
assert(#createdProxies == 0, "and no body is drawn over it")
print("false-positive hiding rejected OK")

-- 13. Unverifiable hiding is accepted (but flagged) ---------------------------------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.hideVerified = nil
BNS.Body.clearAll(); shells = {}; createdProxies = {}
makeShell("nogetter", 50, 50, 99, { noGetter = true })
BNS.Body.onVisual({ rows = { { id = "nogetter", oid = 99, x = 50, y = 50, z = 0, anim = "walk" } } })
assert(#createdProxies == 1, "builds a proxy when hiding cannot be checked")
assert(BNS.Body.hideVerified == nil, "and records that it is unverified")
print("unverifiable hiding accepted + flagged OK")

-- 14. Descriptor vs constructor failures are told apart -------------------------------
local realFactory = SurvivorFactory
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
shells = {}; makeShell("d1", 60, 60, 101)
SurvivorFactory = nil
BNS.Body.onVisual({ rows = { { id = "d1", oid = 101, x = 60, y = 60, z = 0, anim = "idle" } } })
assert(BNS.Body.supported == false, "missing factory disables")
assert(tostring(BNS.Body.lastError):find("SurvivorFactory"),
    "and names SurvivorFactory, not IsoPlayer: " .. tostring(BNS.Body.lastError))
SurvivorFactory = realFactory

BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
shells = {}; makeShell("d2", 70, 70, 102)
proxyFailMode = true
BNS.Body.onVisual({ rows = { { id = "d2", oid = 102, x = 70, y = 70, z = 0, anim = "idle" } } })
assert(tostring(BNS.Body.lastError):find("IsoPlayer"),
    "constructor failure names IsoPlayer: " .. tostring(BNS.Body.lastError))
proxyFailMode = false
print("failure attribution OK")

-- 15. The probe reports a line per pipeline step ---------------------------------------
BNS.Body.supported = nil; BNS.Body.hideFn = nil; BNS.Body.clearAll()
shells = {}; makeShell("p1", 80, 80, 111)
BNS.Body.stats.snapshots = 3
local report = BNS.Body.probe()
local blob = table.concat(report, "\n")
assert(blob:find("snapshots received"), "reports whether the server is talking to us")
assert(blob:find("SurvivorFactory"), "reports character construction")
assert(blob:find("IsoPlayer.new exists"), "reports the constructor")
assert(blob:find("puppet"), "reports puppet lookup")
assert(blob:find("state:"), "reports the resulting state")
print("probe OK (" .. #report .. " lines)")

-- 16. Living-look pass applies what the build supports, skips the rest ------------------
local looked = { skin = false, blood = false, model = false }
local shell = {
    getHumanVisual = function() return {
        setSkinTextureIndex = function() looked.skin = true end,
        clearBlood = function() looked.blood = true end,
        -- no clearDirt / hair / beard on this fake build
    } end,
    resetModelNextFrame = function() looked.model = true end,
    getItemVisuals = function() return nil end,
}
require("BNS/BNS_Look")
local applied = BNS.Look.apply(shell, { look = { skin = 2, hair = "Bob", beard = "Full" } })
assert(looked.skin and looked.blood and looked.model, "supported operations ran")
assert(applied >= 3, "counted what landed, got " .. tostring(applied))
assert(BNS.Look.support["living skin"] == true, "records what works")
assert(BNS.Look.support["clear dirt"] == false, "records what does not")
assert(#BNS.Look.report() >= 6, "reports a line per operation")
print("living-look pass OK (" .. applied .. " ops applied)")

-- 17. Item visuals whose setters are per-body-part ------------------------------------
-- The engine's ItemVisual wants setBlood(BloodBodyPartType, value); the
-- first in-game run threw "expected 2 arguments, got 1" on every call.
BloodBodyPartType = {
    MAX = { index = function() return 3 end },
    FromIndex = function(i) return { part = i } end,
}
local cleaned = {}
local strictVisual = {
    setBlood = function(self, part, value)
        if value == nil then error("expected 2 arguments, got 1") end
        table.insert(cleaned, { part = part.part, value = value })
    end,
}
local shell2 = {
    getHumanVisual = function() return {} end,
    getItemVisuals = function() return {
        size = function() return 1 end,
        get = function() return strictVisual end,
    } end,
}
BNS.Look.support = {}
BNS.Look.broken = {}
BNS.Look.apply(shell2, { look = {} })
assert(#cleaned == 3, "cleaned every blood body part, got " .. #cleaned)
assert(BNS.Look.support["clean clothing"] == true, "the two-argument form is accepted")
assert(BNS.Look.broken["clean clothing"] == nil, "a working op is not marked broken")
print("per-body-part item visuals OK (" .. #cleaned .. " parts cleared)")

-- 18. Builds whose setters take a single value still work --------------------------------
-- Same op, a method that rejects the per-part form: it must fall back
-- rather than be written off as unsupported.
local single = 0
local looseVisual = { setDirt = function(self, a, b)
    if b ~= nil then error("expected 1 argument, got 2") end
    if a == nil then error("no value") end
    single = single + 1
end }
local shell3 = {
    getHumanVisual = function() return {} end,
    getItemVisuals = function() return {
        size = function() return 1 end,
        get = function() return looseVisual end,
    } end,
}
BNS.Look.support = {}
BNS.Look.broken = {}
BNS.Look.apply(shell3, { look = {} })
assert(single == 1, "fell back to the single-argument form, got " .. single)
assert(BNS.Look.support["clean clothing"] == true, "the op still counts as working")
BNS.Look.apply(shell3, { look = {} })
assert(single == 2, "and the working form is remembered, got " .. single)
print("single-argument item visuals OK")

-- 19. An op that throws is disabled, not retried forever --------------------------------
-- 1263 identical stack traces in one session came from re-calling, on every
-- re-assertion, an op the build cannot support.
local calls = 0
local shell4 = {
    getHumanVisual = function() return {} end,
    getItemVisuals = function()
        calls = calls + 1
        return { size = function() error("no such method") end }
    end,
}
BNS.Look.support = {}
BNS.Look.broken = {}
for _ = 1, 20 do BNS.Look.apply(shell4, { look = {} }) end
assert(calls == 1, "a throwing op is called once, not every tick (got " .. calls .. ")")
assert(BNS.Look.broken["clean clothing"], "the failure is recorded")
assert(BNS.Look.support["clean clothing"] == false, "and reported as unsupported")
local blob2 = table.concat(BNS.Look.report(), "\n")
assert(blob2:find("%[err%]"), "the probe reports it as an error, not a silent no")
print("broken-op lockout OK (" .. calls .. " calls across 20 passes)")

-- 20. Item ids are resolved against the running build -----------------------------------
require("BNS/BNS_Loadouts")
local present = { ["Base.Machete"] = true, ["Base.WaterBottle"] = true }
ScriptManager = { instance = { getItem = function(_, id) return present[id] end } }
assert(BNS.Loadouts.item("Base.Machete") == "Base.Machete", "a real id passes through")
assert(BNS.Loadouts.item("Base.WaterBottleFull") == "Base.WaterBottle",
    "a renamed id resolves to its alternate")
assert(BNS.Loadouts.item("Base.NotAThing") == nil, "an unknown id with no alternate is dropped")
local filtered = BNS.Loadouts.filter({
    { item = "Base.Machete", value = 1 },
    { item = "Base.NotAThing", value = 2 },
    { item = "Base.WaterBottleFull", value = 3 },
})
assert(#filtered == 2, "unresolvable lines are dropped, got " .. #filtered)
assert(filtered[2].item == "Base.WaterBottle", "the surviving line carries the resolved id")
assert(filtered[2].value == 3, "and keeps its other fields")
print("item id resolution OK")

print("ALL TESTS PASSED")
