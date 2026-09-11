--***********************************************************************
-- Project Zombai — making a shell look alive (server)
--
-- Appearance half of "stop looking like zombies". A shell is an
-- IsoZombie, but its model is the same human model a player uses, so
-- restyling its HumanVisual — living skin instead of grey, no blood, no
-- wounds, real hair — makes it read as a living person. Animation is the
-- other half and is handled by BNS_Anim through the AnimSet overlays.
--
-- Every call is a named, guarded operation. Whatever this build
-- supports is applied; the rest is skipped and reported, so the debug
-- probe can say exactly which parts landed instead of leaving the
-- result a mystery.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"

BNS.Look = {}

-- op name -> true (worked at least once) / false (never worked)
BNS.Look.support = {}
-- op name -> the error text, for ops that threw and are now disabled
BNS.Look.broken = {}

local REASSERT_TICKS = 300 -- full brain ticks between re-applications

local function visualOf(zombie)
    if not zombie.getHumanVisual then return nil end
    local ok, visual = pcall(function() return zombie:getHumanVisual() end)
    if ok then return visual end
    return nil
end

-- ItemVisual's blood/dirt/hole setters are per-body-part on this engine:
-- setBlood(BloodBodyPartType, float), not setBlood(float). Guessing the
-- arity wrong throws "expected 2 arguments, got 1" on every call, which
-- is exactly what the first in-game run produced. Probe both forms once,
-- remember which one this build wants, and never call a form that has
-- already failed.
local bloodParts = nil

local function getBloodParts()
    if bloodParts then return bloodParts end
    bloodParts = {}
    if BloodBodyPartType and BloodBodyPartType.FromIndex then
        pcall(function()
            local count = 0
            if BloodBodyPartType.MAX and BloodBodyPartType.MAX.index then
                count = BloodBodyPartType.MAX:index()
            elseif BloodBodyPartType.MAX and BloodBodyPartType.MAX.ordinal then
                count = BloodBodyPartType.MAX:ordinal()
            end
            for i = 0, count - 1 do
                local part = BloodBodyPartType.FromIndex(i)
                if part then table.insert(bloodParts, part) end
            end
        end)
    end
    return bloodParts
end

-- method name -> 2 (per body part), 1 (single value), or false (broken)
local setterArity = {}

local function setOnVisual(iv, name, value)
    if not iv[name] then return false end
    local arity = setterArity[name]
    if arity == false then return false end
    if arity ~= 1 then
        local parts = getBloodParts()
        if #parts > 0 and pcall(function()
                for _, part in ipairs(parts) do iv[name](iv, part, value) end
            end) then
            setterArity[name] = 2
            return true
        end
        if arity == 2 then setterArity[name] = false return false end
    end
    if pcall(function() iv[name](iv, value) end) then
        setterArity[name] = 1
        return true
    end
    setterArity[name] = false
    return false
end

-- Each op returns true when it actually did something.
local OPS = {
    {
        name = "living skin",
        apply = function(zombie, look)
            local v = visualOf(zombie)
            if not v then return false end
            local skin = look and look.skin or 0
            if v.setSkinTextureIndex then
                v:setSkinTextureIndex(skin)
                return true
            end
            if v.setSkinTexture then
                v:setSkinTexture(skin)
                return true
            end
            return false
        end,
    },
    {
        -- The reason they still read as corpses after the skin index was
        -- set. HumanVisual carries a `zombieRotStage` -- the decay
        -- variant the texture creator composites over the body -- and
        -- IsoZombie rolls one at spawn (pickRandomZombieRotStage). The
        -- skin *index* being human does not undo it. Zero it, then check
        -- it actually took: a public field a build will not let Lua write
        -- would otherwise report as working while nothing changed.
        name = "no zombie rot",
        apply = function(zombie)
            local v = visualOf(zombie)
            if not v then return false end
            if v.setZombieRotStage then
                v:setZombieRotStage(0)
            elseif v.zombieRotStage ~= nil then
                v.zombieRotStage = 0
            else
                return false
            end
            local stage = v.getZombieRotStage and v:getZombieRotStage() or v.zombieRotStage
            return stage == 0 or stage == nil
        end,
    },
    {
        -- Belt and braces on the same problem: if the rot stage will not
        -- move, copying a *living* character's own skin texture name onto
        -- the shell puts a human body texture on it. The name is read off
        -- a real player rather than guessed, so it is valid on whatever
        -- build this is -- there is no list of texture names to get wrong.
        name = "human skin texture",
        apply = function(zombie)
            local v = visualOf(zombie)
            if not v or not v.setSkinTextureName then return false end
            local name = BNS.Look.playerSkinTexture()
            if not name then return false end
            v:setSkinTextureName(name)
            return true
        end,
    },
    {
        -- Bandits were turning up naked. `addZombiesInOutfit` takes an
        -- outfit *name*, and a name this build does not have leaves the
        -- shell with nothing on rather than erroring -- so the outfit
        -- list is a set of unverifiable strings with a very visible
        -- failure mode. Rather than guess at names, ask the shell what it
        -- is actually wearing and dress it if the answer is "nothing":
        -- dressInRandomNonSillyOutfit needs no name at all.
        name = "clothed",
        apply = function(zombie, look)
            if not zombie.getWornItems then return false end
            local ok, worn = pcall(function()
                local w = zombie:getWornItems()
                return w and w:size() or 0
            end)
            if not ok then return false end
            if worn > 0 then return true end

            -- Naked. Try the outfit they were meant to have, then
            -- anything at all: a clothed bandit in the wrong jacket beats
            -- a naked one in the right story.
            if look and look.outfit and zombie.dressInPersistentOutfit then
                pcall(function() zombie:dressInPersistentOutfit(look.outfit) end)
            end
            if zombie.dressInRandomNonSillyOutfit then
                pcall(function() zombie:dressInRandomNonSillyOutfit() end)
            end
            local okAfter, after = pcall(function()
                local w = zombie:getWornItems()
                return w and w:size() or 0
            end)
            if okAfter and after > 0 then
                BNS.log("re-dressed a shell that spawned with nothing on"
                    .. " (outfit '" .. tostring(look and look.outfit) .. "')")
                return true
            end
            return false
        end,
    },
    {
        name = "clear blood",
        apply = function(zombie)
            local v = visualOf(zombie)
            if v and v.clearBlood then v:clearBlood() return true end
            if zombie.clearBlood then zombie:clearBlood() return true end
            return false
        end,
    },
    {
        name = "clear dirt",
        apply = function(zombie)
            local v = visualOf(zombie)
            if v and v.clearDirt then v:clearDirt() return true end
            return false
        end,
    },
    {
        name = "clean clothing",
        apply = function(zombie)
            -- Zombie outfits spawn bloodied and torn; wipe the item
            -- visuals so the same clothes read as worn, not butchered.
            if not zombie.getItemVisuals then return false end
            local visuals = zombie:getItemVisuals()
            if not visuals then return false end
            local done = false
            for i = 0, visuals:size() - 1 do
                local iv = visuals:get(i)
                if iv then
                    if setOnVisual(iv, "setBlood", 0.0) then done = true end
                    if setOnVisual(iv, "setDirt", 0.0) then done = true end
                    if setOnVisual(iv, "setHoleLevel", 0) then done = true end
                end
            end
            return done
        end,
    },
    {
        name = "heal wounds",
        apply = function(zombie)
            if zombie.getBodyDamage then
                local ok, bd = pcall(function() return zombie:getBodyDamage() end)
                if ok and bd and bd.RestoreToFullHealth then
                    bd:RestoreToFullHealth()
                    return true
                end
            end
            return false
        end,
    },
    {
        name = "hair",
        apply = function(zombie, look)
            if not look or not look.hair then return false end
            local v = visualOf(zombie)
            if v and v.setHairModel then v:setHairModel(look.hair) return true end
            return false
        end,
    },
    {
        name = "beard",
        apply = function(zombie, look)
            if not look or not look.beard or look.female then return false end
            local v = visualOf(zombie)
            if v and v.setBeardModel then v:setBeardModel(look.beard) return true end
            return false
        end,
    },
    {
        name = "refresh model",
        apply = function(zombie)
            if zombie.resetModelNextFrame then zombie:resetModelNextFrame() return true end
            if zombie.resetModel then zombie:resetModel() return true end
            return false
        end,
    },
    {
        -- The body texture is composited, not just referenced, so a
        -- changed visual does not show until the engine rebuilds it.
        -- Must come after everything above.
        name = "rebuild textures",
        apply = function(zombie)
            if zombie.checkUpdateModelTextures then
                zombie:checkUpdateModelTextures()
                return true
            end
            return false
        end,
    },
}

-- A skin texture name that this build definitely has, taken off a living
-- character rather than guessed. Read once and remembered; nil until a
-- player exists (which is fine -- the op simply reports [no] and the next
-- re-assert picks it up).
local playerSkin = nil

function BNS.Look.playerSkinTexture()
    if playerSkin ~= nil then return playerSkin or nil end
    if type(getSpecificPlayer) ~= "function" then return nil end
    for i = 0, 3 do
        local ok, p = pcall(function() return getSpecificPlayer(i) end)
        if ok and p and p.getHumanVisual then
            local okV, name = pcall(function()
                local v = p:getHumanVisual()
                return v and v.getSkinTexture and v:getSkinTexture() or nil
            end)
            if okV and name and tostring(name) ~= "" then
                playerSkin = tostring(name)
                BNS.log("using living skin texture '" .. playerSkin .. "' for NPC shells")
                return playerSkin
            end
        end
    end
    return nil
end

function BNS.Look.clearSkinCache()
    playerSkin = nil
end

-- Voice ------------------------------------------------------------------
--
-- A shell is an IsoZombie, so the engine gives it a zombie's idle moan --
-- which no amount of restyling covers up. There is no "be quiet" flag on
-- the character, but the moan is an ordinary emitter sound with a name
-- the shell will tell us (getVoiceSoundName), so it can be stopped by
-- name the moment it starts.
--
-- Only that sound, and only when it is actually playing: stopAll() would
-- also kill the footsteps and the gunshots BNS itself plays through the
-- same emitter.
BNS.Look.HUSH_EVERY = 12 -- engine ticks between checks (~5/s)
BNS.Look.VoiceNames = { "getVoiceSoundName", "getBiteSoundName" }
BNS.Look.hushProbe = nil -- nil = untried, true = usable, false = written off

function BNS.Look.hush(zombie, brain)
    if BNS.Look.hushProbe == false then return end
    brain.hushTick = (brain.hushTick or ZombRand(BNS.Look.HUSH_EVERY)) - 1
    if brain.hushTick > 0 then return end
    brain.hushTick = BNS.Look.HUSH_EVERY

    if not zombie.getEmitter then
        BNS.Look.hushProbe = false
        BNS.Look.support["no zombie moan"] = false
        return
    end
    local ok, silenced = pcall(function()
        local emitter = zombie:getEmitter()
        if not emitter or not emitter.stopSoundByName or not emitter.isPlaying then
            return nil
        end
        local stopped = false
        for _, getter in ipairs(BNS.Look.VoiceNames) do
            if zombie[getter] then
                local name = zombie[getter](zombie)
                if name and tostring(name) ~= "" and emitter:isPlaying(name) then
                    emitter:stopSoundByName(name)
                    stopped = true
                end
            end
        end
        return stopped
    end)
    if not ok then
        -- Never retry an op that threw: it would be a stack trace several
        -- times a second, per NPC, for the whole session.
        BNS.Look.hushProbe = false
        BNS.Look.broken["no zombie moan"] = tostring(silenced)
        BNS.Look.support["no zombie moan"] = false
        BNS.log("cannot silence zombie vocals on this build: " .. tostring(silenced))
        return
    end
    if silenced == nil then
        BNS.Look.hushProbe = false
        BNS.Look.support["no zombie moan"] = false
        return
    end
    BNS.Look.hushProbe = true
    -- Only claim it works once a moan has actually been caught and cut.
    if silenced then BNS.Look.support["no zombie moan"] = true
    elseif BNS.Look.support["no zombie moan"] == nil then
        BNS.Look.support["no zombie moan"] = false
    end
end

-- Apply the living look. Called when a shell materialises and
-- re-asserted periodically, because the engine re-rolls zombie visuals.
function BNS.Look.apply(zombie, brain)
    if not zombie or not brain then return end
    local look = brain.look
    local applied = 0
    for _, op in ipairs(OPS) do
        if not BNS.Look.broken[op.name] then
            local ok, did = pcall(function() return op.apply(zombie, look) end)
            if not ok then
                -- An op that threw is asking the engine for something this
                -- build does not have. Retrying it every re-assert turns one
                -- wrong guess into thousands of stack traces in console.txt,
                -- so record it and never call it again this session.
                BNS.Look.broken[op.name] = tostring(did)
                BNS.Look.support[op.name] = false
                BNS.log("look op '" .. op.name .. "' unsupported on this build: " .. tostring(did))
            else
                local worked = did and true or false
                -- Once an op is known to work, keep that verdict.
                if worked or BNS.Look.support[op.name] == nil then
                    BNS.Look.support[op.name] = worked
                end
                if worked then applied = applied + 1 end
            end
        end
    end
    brain.lookApplied = applied
    return applied
end

-- Re-apply now and then so a shell doesn't drift back to looking dead.
function BNS.Look.tick(zombie, brain)
    -- Cutting a moan has to happen near enough as it starts, so it runs
    -- on its own short throttle rather than the slow restyling one.
    BNS.Look.hush(zombie, brain)
    brain.lookTimer = (brain.lookTimer or ZombRand(REASSERT_TICKS)) + 1
    if brain.lookTimer < REASSERT_TICKS then return end
    brain.lookTimer = 0
    BNS.Look.apply(zombie, brain)
end

-- For the debug probe: which restyling operations this build supports.
function BNS.Look.report()
    local lines = {}
    local function line(name)
        local state = BNS.Look.support[name]
        local err = BNS.Look.broken[name]
        table.insert(lines, string.format("  %s %s%s",
            err and "[err]" or (state == true and "[ok]" or (state == false and "[no]" or "[ ? ]")),
            name, err and (" - " .. err) or ""))
    end
    for _, op in ipairs(OPS) do line(op.name) end
    line("no zombie moan")
    return lines
end

-- What the shell's visual actually says about itself, for the debug
-- probe. "The op did not error" has never been proof that anything
-- changed on screen (CLAUDE.md), and these three fields are what a
-- person looking at a bandit is really asking about.
function BNS.Look.describe(zombie)
    local v = visualOf(zombie)
    if not v then return "no HumanVisual" end
    local function read(getter, field)
        if v[getter] then
            local ok, value = pcall(function() return v[getter](v) end)
            if ok then return tostring(value) end
            return "[err]"
        end
        if field and v[field] ~= nil then return tostring(v[field]) end
        return "-"
    end
    local worn = "-"
    if zombie.getWornItems then
        local okW, n = pcall(function()
            local w = zombie:getWornItems()
            return w and w:size() or 0
        end)
        worn = okW and tostring(n) or "[err]"
    end
    return string.format("worn=%s isZombie=%s rot=%s skin=%s/%s",
        worn,
        read("isZombie"),
        read("getZombieRotStage", "zombieRotStage"),
        read("getSkinTextureIndex"), read("getSkinTexture"))
end
