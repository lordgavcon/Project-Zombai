--***********************************************************************
-- Project Zombai — signs of a bandit-held POI (server)
--
-- Claimed strongholds used to be invisible until you walked into the
-- guns: no map marker, no warning, nothing. This module makes them
-- legible from the world itself — no UI, no map pins, just things you
-- can see and hear on the approach:
--
--   * defenders challenge you from 15-30 tiles before anyone shoots
--   * camp noise (gunfire, hammering) carries from a held POI
--   * an outer ring of spent casings, bloodied rags and broken junk
--     builds up as you get closer, with camp clutter at the core
--
-- Item ids are the recurring hazard in this mod, so every decoration
-- pool lists several candidates and is filtered once against what this
-- build actually ships. An empty pool just means that cue is skipped.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Persistence"

BNS.Signs = {}

BNS.Signs.APPROACH_MULT   = 2.5 -- outer ring = radius * this
local CORE_DENSITY        = 12  -- % of core squares that get clutter
local APPROACH_DENSITY    = 8   -- % of approach squares that get evidence
local MAX_DECORATIONS     = 60  -- per base, so a POI never becomes a landfill
local BLOOD_CHANCE        = 25  -- % of decorated approach squares
local AMBIENCE_RANGE      = 70  -- tiles: camp noise reaches this far
local AMBIENCE_COOLDOWN_H = 1   -- in-game hours between cues per POI
local AMBIENCE_CHANCE     = 60  -- % roll once a POI is eligible
local CHALLENGE_COOLDOWN  = 90  -- brain ticks (~15s) between challenges

-- Decoration pools ---------------------------------------------------------

local POOLS = {
    casings = { "Base.BulletShell", "Base.9mmShellCasing", "Base.ShellCasing",
                "Base.ShotgunShell", "Base.Bullets9mm" },
    rags    = { "Base.RippedSheetsDirty", "Base.RippedSheets", "Base.DirtyRag",
                "Base.Bandage" },
    refuse  = { "Base.EmptyTinCan", "Base.TinCanEmpty", "Base.BrokenGlass",
                "Base.GarbageBag", "Base.Cigarettes" },
    camp    = { "Base.Charcoal", "Base.CharcoalStick", "Base.Ash", "Base.Logs",
                "Base.WoodenStick", "Base.Twigs" },
    broken  = { "Base.BrokenGlass", "Base.WoodenStick", "Base.Plank" },
}

local CORE_POOLS     = { "camp", "refuse", "casings" }
local APPROACH_POOLS = { "casings", "rags", "broken", "refuse" }

local resolved = {}

-- Filter a pool down to the ids this build actually knows, once.
function BNS.Signs.resolvePool(name)
    if resolved[name] then return resolved[name] end
    local out = {}
    for _, fullType in ipairs(POOLS[name] or {}) do
        local ok, item = pcall(function()
            return ScriptManager.instance:getItem(fullType)
        end)
        if ok and item then table.insert(out, fullType) end
    end
    if #out == 0 then
        BNS.log("no usable items for decoration pool '" .. name .. "'")
    end
    resolved[name] = out
    return out
end

function BNS.Signs.clearPoolCache()
    resolved = {}
end

-- Ground evidence ------------------------------------------------------------

-- Called once per square as claimed-POI terrain streams in (from
-- BNS_Bases.onLoadGridsquare). zone is "core" or "approach".
function BNS.Signs.decorateSquare(square, base, zone)
    if not BNS.Options().poiSigns then return false end
    if not square or not base then return false end
    base.decorations = base.decorations or 0
    if base.decorations >= MAX_DECORATIONS then return false end

    local density = (zone == "core") and CORE_DENSITY or APPROACH_DENSITY
    if ZombRand(100) >= density then return false end

    local pools = (zone == "core") and CORE_POOLS or APPROACH_POOLS
    local items = BNS.Signs.resolvePool(pools[ZombRand(#pools) + 1])
    if #items == 0 then return false end

    square:AddWorldInventoryItem(items[ZombRand(#items) + 1],
        ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
    base.decorations = base.decorations + 1

    -- Blood on the approach if this build exposes it; purely a bonus.
    if zone == "approach" and ZombRand(100) < BLOOD_CHANCE and square.addBlood then
        pcall(function() square:addBlood(nil, false, true, false) end)
    end
    return true
end

-- Camp noise -------------------------------------------------------------------

local KINDS = { "gunshot", "shotgun", "hammering" }

function BNS.Signs.broadcast(base, kind)
    local args = { x = base.x, y = base.y, kind = kind }
    if isServer() then
        sendServerCommand(BNS.CommandModule, "poiAmbience", args)
    elseif BNS.Client and BNS.Client.onServerCommand then
        BNS.Client.onServerCommand(BNS.CommandModule, "poiAmbience", args)
    end
    -- Real noise in the world model too, so the dead drift toward camps.
    pcall(function()
        addSound(nil, base.x, base.y, 0, 60, 40)
    end)
end

function BNS.Signs.ambientTick()
    if not BNS.Options().poiSigns then return end
    local state = BNS.Persistence.getState()
    local now = BNS.worldHours()
    for _, base in pairs(state.bases) do
        if now - (base.lastAmbience or -999) >= AMBIENCE_COOLDOWN_H then
            local _, d = BNS.nearestPlayer(base.x, base.y)
            if d and d < AMBIENCE_RANGE and ZombRand(100) < AMBIENCE_CHANCE then
                base.lastAmbience = now
                BNS.Signs.broadcast(base, KINDS[ZombRand(#KINDS) + 1])
            end
        end
    end
end

-- Challenges --------------------------------------------------------------------

local CHALLENGE_LINES = {
    "UI_BNS_Challenge1", "UI_BNS_Challenge2",
    "UI_BNS_Challenge3", "UI_BNS_Challenge4",
}

-- Shouted by a garrison defender at a player in the outer band, before
-- the DEFEND program escalates to ATTACK. Returns true if it spoke.
function BNS.Signs.challenge(zombie, brain)
    if not BNS.Options().poiSigns then return false end
    brain.challengeCooldown = (brain.challengeCooldown or 0) - 1
    if brain.challengeCooldown > 0 then return false end
    brain.challengeCooldown = CHALLENGE_COOLDOWN
    if not BNS.Say then return false end
    brain.speechCooldown = 0
    BNS.Say(zombie, brain, getText(CHALLENGE_LINES[ZombRand(#CHALLENGE_LINES) + 1]))
    return true
end

-- Harness-friendly: only hook the game loop when Events exists.
if Events and Events.EveryTenMinutes then
    Events.EveryTenMinutes.Add(BNS.Signs.ambientTick)
end
