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

local REASSERT_TICKS = 300 -- full brain ticks between re-applications

local function visualOf(zombie)
    if not zombie.getHumanVisual then return nil end
    local ok, visual = pcall(function() return zombie:getHumanVisual() end)
    if ok then return visual end
    return nil
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
                    if iv.setBlood then iv:setBlood(0.0) done = true end
                    if iv.clearBlood then iv:clearBlood() done = true end
                    if iv.setDirt then iv:setDirt(0.0) done = true end
                    if iv.setHoleLevel then iv:setHoleLevel(0) done = true end
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
        local ok, did = pcall(function() return op.apply(zombie, look) end)
        local worked = (ok and did) and true or false
        -- Once an op is known to work, keep that verdict.
        if worked or BNS.Look.support[op.name] == nil then
            BNS.Look.support[op.name] = worked
        end
        if worked then applied = applied + 1 end
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
        table.insert(lines, string.format("  %s %s",
            state == true and "[ok]" or (state == false and "[no]" or "[ ? ]"), op.name))
    end
    return lines
end
