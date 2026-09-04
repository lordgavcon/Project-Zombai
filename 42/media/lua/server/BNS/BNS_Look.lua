--***********************************************************************
-- Project Zombai — making a shell look alive (server)
--
-- The client-side player-body proxies (BNS_Body.lua) are the ideal, but
-- they depend on engine calls that may not exist on a given build. The
-- *appearance* half of "stop looking like zombies" does not: a shell is
-- an IsoZombie, but its model is the same human model a player uses, so
-- restyling its HumanVisual — living skin instead of grey, no blood, no
-- wounds, real hair — makes it read as a living person even when no
-- proxy is ever created.
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
}

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
    brain.lookTimer = (brain.lookTimer or ZombRand(REASSERT_TICKS)) + 1
    if brain.lookTimer < REASSERT_TICKS then return end
    brain.lookTimer = 0
    BNS.Look.apply(zombie, brain)
end

-- For the debug probe: which restyling operations this build supports.
function BNS.Look.report()
    local lines = {}
    for _, op in ipairs(OPS) do
        local state = BNS.Look.support[op.name]
        local err = BNS.Look.broken[op.name]
        table.insert(lines, string.format("  %s %s%s",
            err and "[err]" or (state == true and "[ok]" or (state == false and "[no]" or "[ ? ]")),
            op.name, err and (" - " .. err) or ""))
    end
    return lines
end
