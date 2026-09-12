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
-- A STRING condition is <m_Type>STRING</m_Type> paired with
-- <m_StringValue>. That is the form the game's own AnimSets use, and the
-- form every published animation-framework template uses. <m_Value>
-- parses into nothing: the node loads, never matches, and the shell keeps
-- playing the vanilla zombie clip -- which is exactly what "bandits use
-- the zombie idle animation" was.
--
-- The tree is generated (tools/gen_animsets.lua), so the suite also
-- checks the checked-in files still match what the generator emits.
local ROOT_DIR = ROOT:gsub("/42/media/lua$", "")
local gen = dofile(ROOT_DIR .. "/tools/gen_animsets.lua")

local animRoot = ROOT:gsub("/lua$", "") .. "/AnimSets/zombie"
local function listXml(dir)
    local out = {}
    local p = io.popen('find "' .. dir .. '" -name "*.xml" 2>/dev/null')
    if not p then return out end
    for line in p:lines() do table.insert(out, line) end
    p:close()
    table.sort(out)
    return out
end
local files = listXml(animRoot)
assert(#files >= 10, "the overlay set exists, found " .. #files)

local sawSwing, sawAim = false, false
local perState = {}
for _, path in ipairs(files) do
    local f = assert(io.open(path, "r"))
    local xml = f:read("*a")
    f:close()
    local name = path:match("[^/]+$")
    local state = path:match("([^/]+)/[^/]+$")
    assert(not xml:find("<m_Value>"),
        name .. " uses <m_Value>; STRING conditions are read from <m_StringValue>")
    -- XML forbids "--" inside a comment, and the game's parser rejects
    -- the whole file over it: the generator's own header comment once
    -- carried one and every node in the mod silently failed to load
    -- ('The string "--" is not permitted within comments'), which read
    -- in game as NPCs still using the zombie clips.
    for body in xml:gmatch("<!%-%-(.-)%-%->") do
        assert(not body:find("%-%-"),
            name .. " has \"--\" inside an XML comment; the whole file will fail to parse")
    end
    assert(xml:find("<m_Name>BNSNPC</m_Name>"),
        name .. " must be gated on BNSNPC or it would apply to real zombies")
    assert(xml:find("<m_AnimName>Bob_"),
        name .. " should play a player clip, not a zombie one")
    local anim = xml:match("<m_Name>BNSAnim</m_Name>%s*<m_Type>STRING</m_Type>%s*<m_StringValue>([^<]+)</m_StringValue>")
    assert(anim, name .. " must select on a BNSAnim mode, in the STRING/m_StringValue form")
    assert(BNS.Anim.Modes[anim], name .. " selects on unknown mode '" .. anim .. "'")
    local weapon = xml:match("<m_Name>Weapon</m_Name>%s*<m_Type>STRING</m_Type>%s*<m_StringValue>([^<]+)</m_StringValue>")
    if weapon then
        assert(BNS.Anim.WeaponClasses[weapon],
            name .. " selects on weapon class '" .. weapon .. "', which vanilla does not use")
    end
    perState[state] = perState[state] or {}
    perState[state][anim] = true
    if anim == "swing" then sawSwing = true end
    if anim == "aim" then sawAim = true end
end
assert(sawSwing and sawAim, "swings and aiming are both covered")

-- An AnimNode only competes inside the AnimState directory it lives in,
-- and the shell's engine state has nothing to do with the mode we ask
-- for: BNS suppresses the shell's target, so it never enters its own
-- attack state, and a swing pulse lands while it is standing or walking.
-- Every mode therefore has to exist in every state directory shipped, or
-- that mode silently does nothing for a shell in that state.
-- The states the engine can throw a shell into on its own -- a lunge
-- above all -- are the ones where an uncovered state means vanilla
-- *zombie* clips play. BNS suppresses the target that causes a lunge,
-- but the node has to be there for the frames before that lands.
for _, engineState in ipairs({ "lunge", "staggerback", "thump" }) do
    assert(perState[engineState],
        "no overlay for '" .. engineState .. "' -- a shell thrown into it "
            .. "would play the zombie clip")
end
for _, state in ipairs(gen.STATES) do
    assert(perState[state], "no overlay nodes shipped for AnimState '" .. state .. "'")
    for mode in pairs(BNS.Anim.Modes) do
        assert(perState[state][mode],
            "state '" .. state .. "' has no node for mode '" .. mode .. "'")
    end
end

-- ...and the checked-in tree is exactly what the generator produces, so
-- a node edited by hand in one directory cannot drift from its copies.
local expected = gen.files()
local expectedCount = 0
for path, body in pairs(expected) do
    expectedCount = expectedCount + 1
    local f = io.open(ROOT_DIR .. "/42/" .. path, "r")
    assert(f, "missing generated overlay " .. path .. " -- run tools/gen_animsets.lua")
    local got = f:read("*a")
    f:close()
    assert(got == body, path .. " differs from tools/gen_animsets.lua -- regenerate it")
end
assert(#files == expectedCount,
    "the overlay tree has " .. #files .. " files but the generator emits "
        .. expectedCount .. " -- regenerate it")
print("AnimSet overlays OK (" .. #files .. " nodes across " .. #gen.STATES
    .. " states, every mode covered in each)")

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

-- 5b. Zombie rot, human skin, and the moan -----------------------------------------------
-- Restyling the skin *index* never stopped shells reading as corpses:
-- HumanVisual carries a zombieRotStage the texture creator composites
-- over the body, and IsoZombie rolls one at spawn.
BNS.Look.support = {}
BNS.Look.broken = {}
BNS.Look.clearSkinCache()

local rotVisual = { zombieRotStage = 3, skinIndex = nil, skinName = nil }
function rotVisual:setSkinTextureIndex(i) self.skinIndex = i end
function rotVisual:setSkinTextureName(n) self.skinName = n end
function rotVisual:getSkinTexture() return self.skinName or "M_Bod_Test" end
function rotVisual:isZombie() return true end

-- A living character this build definitely has, so the texture name is
-- read rather than guessed.
function getSpecificPlayer(i)
    if i ~= 0 then return nil end
    return { getHumanVisual = function() return {
        getSkinTexture = function() return "M_Bod_Living" end } end }
end

local rebuilt = false
local rotShell = {
    getHumanVisual = function() return rotVisual end,
    getItemVisuals = function() return nil end,
    checkUpdateModelTextures = function() rebuilt = true end,
}
BNS.Look.apply(rotShell, { look = { skin = 1 } })
assert(rotVisual.zombieRotStage == 0, "the rot stage is zeroed, got "
    .. tostring(rotVisual.zombieRotStage))
assert(BNS.Look.support["no zombie rot"] == true, "and reported as working")
assert(rotVisual.skinName == "M_Bod_Living",
    "a living character's own skin texture is copied on, got "
        .. tostring(rotVisual.skinName))
assert(rebuilt, "the composited body texture is rebuilt afterwards")

-- A build that will not let the field be written must report [no], not a
-- silent success: "the call did not error" is not proof anything changed.
BNS.Look.support = {}
BNS.Look.broken = {}
local stubborn = setmetatable({}, { __newindex = function() end, __index = function(t, k)
    if k == "zombieRotStage" then return 4 end
    return nil
end })
BNS.Look.apply({ getHumanVisual = function() return stubborn end,
                 getItemVisuals = function() return nil end }, { look = {} })
assert(BNS.Look.support["no zombie rot"] == false,
    "a rot stage that would not move is reported as not working")
print("zombie rot and skin texture OK")

-- The moan is an ordinary emitter sound with a name the shell will give
-- us, so it is stopped by name -- and only that name, because stopAll()
-- would take the footsteps and BNS's own gunshots with it.
BNS.Look.support = {}
BNS.Look.broken = {}
BNS.Look.hushProbe = nil
local playing = { ["ZombieIdle"] = true, ["ZombieBite"] = true, ["ShotgunShot"] = true }
local stopped = {}
local voiceShell = {
    getVoiceSoundName = function() return "ZombieIdle" end,
    getBiteSoundName = function() return "ZombieBite" end,
    getEmitter = function() return {
        isPlaying = function(_, name) return playing[name] == true end,
        stopSoundByName = function(_, name)
            playing[name] = nil
            table.insert(stopped, name)
        end,
    } end,
}
local vBrain = {}
for _ = 1, 40 do BNS.Look.hush(voiceShell, vBrain) end
assert(#stopped >= 2, "the moan and the bite are both cut, got " .. #stopped)
assert(playing["ShotgunShot"], "and nothing else is touched")
assert(BNS.Look.support["no zombie moan"] == true, "reported as working")

-- Cutting a moan is throttled: it cannot be an engine call per tick.
local checks = 0
local countingShell = {
    getVoiceSoundName = function() return "ZombieIdle" end,
    getEmitter = function()
        checks = checks + 1
        return { isPlaying = function() return false end,
                 stopSoundByName = function() end }
    end,
}
local cBrain = {}
for _ = 1, 240 do BNS.Look.hush(countingShell, cBrain) end
assert(checks > 0, "it does check")
assert(checks <= 240 / BNS.Look.HUSH_EVERY + 1,
    "and not on every tick: " .. checks .. " emitter reads in 240")

-- An emitter that throws is written off once, not several times a second
-- for the rest of the session.
BNS.Look.hushProbe = nil
BNS.Look.support = {}
BNS.Look.broken = {}
local hushCalls = 0
local angryShell = {
    getVoiceSoundName = function() return "ZombieIdle" end,
    getEmitter = function()
        hushCalls = hushCalls + 1
        error("no emitter on this build")
    end,
}
local aBrain = {}
for _ = 1, 200 do BNS.Look.hush(angryShell, aBrain) end
assert(hushCalls == 1, "a throwing emitter is asked once, got " .. hushCalls)
assert(BNS.Look.broken["no zombie moan"], "and the failure is reported")
BNS.Look.hushProbe = nil
BNS.Look.support = {}
BNS.Look.broken = {}
getSpecificPlayer = nil
BNS.Look.clearSkinCache()
print("zombie moan silencing OK (" .. #stopped .. " sounds cut)")

-- 5c. Nobody turns up naked --------------------------------------------------------------
-- addZombiesInOutfit takes an outfit *name*, and a name this build does
-- not have leaves the shell with nothing on rather than erroring -- so
-- the outfit list is a set of unverifiable strings with a very visible
-- failure mode. The fix is to ask the shell what it is wearing rather
-- than to trust the name.
BNS.Look.support = {}
BNS.Look.broken = {}
local dressed = { count = 0, calls = 0 }
local nakedShell = {
    getHumanVisual = function() return nil end,
    getItemVisuals = function() return nil end,
    getWornItems = function()
        return { size = function() return dressed.count end }
    end,
    dressInRandomNonSillyOutfit = function()
        dressed.calls = dressed.calls + 1
        dressed.count = 4
    end,
}
BNS.Look.apply(nakedShell, { look = { outfit = "NoSuchOutfit" } })
assert(dressed.count > 0, "a shell that spawned naked is dressed in something")
assert(BNS.Look.support["clothed"] == true, "and reported as clothed")

-- One that is already dressed is left alone: re-rolling their clothes on
-- every re-assert would change what a bandit looks like as you watch.
local before = dressed.calls
for _ = 1, 10 do BNS.Look.apply(nakedShell, { look = {} }) end
assert(dressed.calls == before, "an already-dressed shell is not re-dressed")

-- A build that will not dress them says so rather than reporting success.
BNS.Look.support = {}
BNS.Look.broken = {}
local stubbornlyNaked = {
    getHumanVisual = function() return nil end,
    getItemVisuals = function() return nil end,
    getWornItems = function() return { size = function() return 0 end } end,
    dressInRandomNonSillyOutfit = function() end,
}
BNS.Look.apply(stubbornlyNaked, { look = {} })
assert(BNS.Look.support["clothed"] == false,
    "a shell that could not be dressed is reported, not quietly passed")
BNS.Look.support = {}
BNS.Look.broken = {}

-- ...and it stops asking. Dressing is the one op here that must not
-- re-assert: a build whose worn-item count reads zero for a shell that
-- is visibly dressed would otherwise hand every bandit a fresh random
-- outfit every REASSERT_TICKS, which in game is bandits changing clothes
-- for the rest of their lives.
local liar = { calls = 0 }
local lyingShell = {
    getHumanVisual = function() return nil end,
    getItemVisuals = function() return nil end,
    getWornItems = function() return { size = function() return 0 end } end,
    dressInRandomNonSillyOutfit = function() liar.calls = liar.calls + 1 end,
}
local liarBrain = { look = {} } -- one brain, as a single body has
for _ = 1, 40 do BNS.Look.apply(lyingShell, liarBrain) end
assert(liar.calls <= BNS.Look.DRESS_TRIES,
    "a shell is dressed at most DRESS_TRIES times per body, not once per "
        .. "re-assert (got " .. liar.calls .. ")")
assert(liarBrain.dressed, "and the question is settled for that body")

-- A new body asks again, because materialise builds the brain afresh
-- from the record: the latch must not be something a record carries.
liar.calls = 0
BNS.Look.apply(lyingShell, { look = {} })
assert(liar.calls > 0, "a newly materialised shell is looked at again")

-- The outfit an archetype rolled is kept when it lands. The random
-- fallback used to run unconditionally straight after it, so the
-- intended outfit was overwritten every single time.
local worn = 0
local ownOutfit = { persistent = nil, random = 0 }
local outfitShell = {
    getHumanVisual = function() return nil end,
    getItemVisuals = function() return nil end,
    getWornItems = function() return { size = function() return worn end } end,
    dressInPersistentOutfit = function(_, name)
        ownOutfit.persistent = name
        worn = 5
    end,
    dressInRandomNonSillyOutfit = function() ownOutfit.random = ownOutfit.random + 1 end,
}
BNS.Look.apply(outfitShell, { look = { outfit = "Bandit" } })
assert(ownOutfit.persistent == "Bandit", "their own outfit is tried first")
assert(ownOutfit.random == 0, "and is not immediately overwritten by a random one")

BNS.Look.support = {}
BNS.Look.broken = {}
print("always clothed OK")
print("dressing does not repeat OK")

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
