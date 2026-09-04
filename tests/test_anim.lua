-- Offline test of how NPC shells are made to look and animate like people:
-- BNS_Anim (the animation variables the AnimSet overlays branch on),
-- BNS_Look (restyling the shell into a living human) and the overlay XML
-- files themselves.
--
-- The rendering cannot be tested here. What can be, and is, is everything
-- that decides *which* clip the engine is asked for -- which is where the
-- real bugs have been: a clip name that does not exist, or a condition
-- written in a form the game does not parse.
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
SandboxVars = { BNS = {} }
BodyPartType = setmetatable({}, { __index = function(t, k) return k end })
function getGameTime() return { getWorldAgeHours = function() return 5 end } end
local modDataStore = {}
ModData = { getOrCreate = function(k) modDataStore[k] = modDataStore[k] or {}; return modDataStore[k] end }
Events = setmetatable({}, { __index = function(t, k)
    local h = { Add = function() end, Remove = function() end }
    rawset(t, k, h); return h
end })

require("BNS/BNS_Core")
require("BNS/BNS_Anim")

-- A shell records the animation variables set on it, which is the entire
-- contract between the brain and the AnimSet.
local function makeShell()
    local z = { vars = {}, modData = { BNS = {} } }
    function z:setVariable(k, v) self.vars[k] = v end
    function z:getModData() return self.modData end
    return z
end

-- 1. Sustained modes set BNSAnim, and only when the mode changes ------------------------
local z, brain = makeShell(), { weapon = { item = "Base.Axe" } }
BNS.Anim.init(z, brain)
assert(z.vars.BNSNPC == "true", "the shell is flagged as an NPC for the overlays")
assert(z.vars.BNSAnim == "idle", "and starts idle")

local writes = 0
local realSet = z.setVariable
function z:setVariable(k, v) if k == "BNSAnim" then writes = writes + 1 end realSet(self, k, v) end
for _ = 1, 10 do BNS.Anim.set(z, brain, "walk") end
assert(z.vars.BNSAnim == "walk", "walking sets the walk node's condition")
assert(writes == 1, "an unchanged mode is not rewritten every tick, got " .. writes)
print("sustained modes OK")

-- 2. A pulse plays once and falls back to the sustained mode ----------------------------
BNS.Anim.set(z, brain, "walk")
BNS.Anim.pulse(z, brain, "swing")
assert(z.vars.BNSAnim == "swing", "the swing node is selected")
BNS.Anim.set(z, brain, "run")
assert(z.vars.BNSAnim == "swing", "a sustained change does not cut the swing short")
for _ = 1, 60 do BNS.Anim.tick(z, brain) end
assert(z.vars.BNSAnim == "run", "and it falls back to the mode underneath it, not to idle")
print("pulse over sustained mode OK")

-- 3. Weapon class drives the weapon-specific clips --------------------------------------
-- Vanilla conditions every weapon-specific idle/walk/aim/attack node on
-- `Weapon`, so this mapping is what makes a swing match what is held.
local cases = {
    { "Base.Axe", "heavy" }, { "Base.Sledgehammer", "heavy" },
    { "Base.BaseballBat", "2handed" }, { "Base.Plank", "2handed" },
    { "Base.KitchenKnife", "knife" }, { "Base.Machete", "knife" },
    { "Base.GardenFork", "spear" },
    { "Base.RollingPin", "1handed" },
}
for _, c in ipairs(cases) do
    local got = BNS.Anim.weaponClass({ item = c[1] })
    assert(got == c[2], c[1] .. " -> " .. got .. ", expected " .. c[2])
end
assert(BNS.Anim.weaponClass({ item = "Base.Pistol", gun = true }) == "handgun", "pistols aim one-handed")
assert(BNS.Anim.weaponClass({ item = "Base.Shotgun", gun = true }) == "firearm", "long guns aim two-handed")
assert(BNS.Anim.weaponClass(nil) == "1handed", "unarmed falls back to one-handed")
for _, c in ipairs(cases) do
    assert(BNS.Anim.WeaponClasses[c[2]], c[2] .. " is a class vanilla actually branches on")
end

local z2 = makeShell()
local b2 = { weapon = { item = "Base.Pistol", gun = true } }
BNS.Anim.init(z2, b2)
assert(z2.vars.Weapon == "handgun", "the class is set on the shell")
local wWrites = 0
local realSet2 = z2.setVariable
function z2:setVariable(k, v) if k == "Weapon" then wWrites = wWrites + 1 end realSet2(self, k, v) end
for _ = 1, 5 do BNS.Anim.setWeapon(z2, b2) end
assert(wWrites == 0, "and is not rewritten while the weapon is unchanged")
b2.weapon = { item = "Base.Axe" }
BNS.Anim.setWeapon(z2, b2)
assert(z2.vars.Weapon == "heavy", "swapping weapons re-selects the clip set")
print("weapon class mapping OK")

-- 4. The overlay XML files are in the form the game parses ------------------------------
-- The overlays previously paired <m_Type>STRING</m_Type> with
-- <m_StringValue>, a combination that appears nowhere in the game's own
-- AnimSets -- so the conditions never matched and no node was ever used.
local animRoot = ROOT:gsub("/lua$", "") .. "/AnimSets/zombie"
local function listXml(dir)
    local out = {}
    local p = io.popen('find "' .. dir .. '" -name "*.xml" 2>/dev/null')
    if not p then return out end
    for line in p:lines() do table.insert(out, line) end
    p:close()
    return out
end
local files = listXml(animRoot)
assert(#files >= 10, "the overlay set exists, found " .. #files)
local sawSwing, sawAim = false, false
for _, path in ipairs(files) do
    local f = assert(io.open(path, "r"))
    local xml = f:read("*a")
    f:close()
    local name = path:match("[^/]+$")
    assert(not xml:find("m_StringValue"),
        name .. " uses <m_StringValue>; the game's own files use <m_Value> for STRING conditions")
    assert(xml:find("<m_Name>BNSNPC</m_Name>"),
        name .. " must be gated on BNSNPC or it would apply to real zombies")
    assert(xml:find("<m_AnimName>Bob_"),
        name .. " should play a player clip, not a zombie one")
    local anim = xml:match("<m_Name>BNSAnim</m_Name>%s*<m_Type>STRING</m_Type>%s*<m_Value>([^<]+)</m_Value>")
    assert(anim, name .. " must select on a BNSAnim mode")
    assert(BNS.Anim.Modes[anim], name .. " selects on unknown mode '" .. anim .. "'")
    local weapon = xml:match("<m_Name>Weapon</m_Name>%s*<m_Type>STRING</m_Type>%s*<m_Value>([^<]+)</m_Value>")
    if weapon then
        assert(BNS.Anim.WeaponClasses[weapon],
            name .. " selects on weapon class '" .. weapon .. "', which vanilla does not use")
    end
    if anim == "swing" then sawSwing = true end
    if anim == "aim" then sawAim = true end
end
assert(sawSwing and sawAim, "swings and aiming are both covered")

-- Every mode the brain can set must have at least one node, or that mode
-- silently does nothing in game.
local covered = {}
for _, path in ipairs(files) do
    local f = assert(io.open(path, "r")); local xml = f:read("*a"); f:close()
    local anim = xml:match("<m_Name>BNSAnim</m_Name>%s*<m_Type>STRING</m_Type>%s*<m_Value>([^<]+)</m_Value>")
    if anim then covered[anim] = true end
end
for mode in pairs(BNS.Anim.Modes) do
    assert(covered[mode], "no AnimSet node plays mode '" .. mode .. "'")
end
print("AnimSet overlays OK (" .. #files .. " nodes, every mode covered)")

-- 5. Living-look pass applies what the build supports, skips the rest ------------------
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

-- 6. Item visuals whose setters are per-body-part ------------------------------------
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

-- 7. Builds whose setters take a single value still work --------------------------------
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

-- 8. An op that throws is disabled, not retried forever --------------------------------
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

-- 9. Item ids are resolved against the running build -----------------------------------
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
