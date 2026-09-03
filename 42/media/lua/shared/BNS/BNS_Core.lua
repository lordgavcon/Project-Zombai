--***********************************************************************
-- Bandits & Survivors — shared core
--
-- Namespace, sandbox option access and helpers used on both sides.
-- NPCs are implemented as server-controlled "zombie shell" characters:
-- an IsoZombie carries a BNS brain record in its mod data and is driven
-- every tick by the server (also in single player, where server lua runs
-- locally). This gives us engine pathfinding and MP position sync.
--***********************************************************************

BNS = BNS or {}
BNS.Version = "0.1.0"
BNS.CommandModule = "BNS"

-- Roles ----------------------------------------------------------------
BNS.Role = {
    BANDIT   = "bandit",
    SURVIVOR = "survivor",
    TRADER   = "trader",
}

-- Bandit tiers, lowest to highest --------------------------------------
BNS.Tier = {
    CIVILIAN = 1, -- desperate civilian, makeshift melee, prefers robbery
    THUG     = 2, -- organised thug, real melee / rare pistol, robs or attacks
    MILITIA  = 3, -- rogue militia, firearms, squads, raids and holds POIs
}

-- Brain programs -------------------------------------------------------
BNS.Program = {
    WANDER   = "wander",
    APPROACH = "approach",
    ROB      = "rob",
    ATTACK   = "attack",
    FLEE     = "flee",
    RAID     = "raid",
    DEFEND   = "defend",
    TRADE    = "trade",
    FIGHTZ   = "fightz",   -- fighting off real zombies
    SCAVENGE = "scavenge", -- looting a building for supplies
    HAUL     = "haul",     -- carrying loot to a claimed vehicle
}

-- Sandbox --------------------------------------------------------------
function BNS.SV(name, default)
    local sv = SandboxVars and SandboxVars.BNS
    if sv and sv[name] ~= nil then return sv[name] end
    return default
end

function BNS.Options()
    return {
        banditRate       = BNS.SV("BanditSpawnRate", 3),
        survivorRate     = BNS.SV("SurvivorSpawnRate", 2),
        maxLive          = BNS.SV("MaxLiveNPCs", 20),
        militia          = BNS.SV("MilitiaEnabled", true),
        militiaGunChance = BNS.SV("MilitiaGunChance", 60),
        raids            = BNS.SV("BaseRaidsEnabled", true),
        raidCooldown     = BNS.SV("RaidCooldownHours", 24),
        pois             = BNS.SV("FortifiedPOIsEnabled", true),
        maxPois          = BNS.SV("MaxFortifiedPOIs", 4),
        traders          = BNS.SV("TradersEnabled", true),
        robbery          = BNS.SV("RobberyEnabled", true),
        damageMult       = BNS.SV("NPCDamageMultiplier", 1.0),
        doorDelay        = BNS.SV("DoorOpenDelay", 3),
        scavenging       = BNS.SV("ScavengingEnabled", true),
        vehicles         = BNS.SV("NPCVehiclesEnabled", true),
        poiSigns         = BNS.SV("POISignsEnabled", true),
        playerBodies     = BNS.SV("PlayerBodiesEnabled", true),
    }
end

-- Helpers --------------------------------------------------------------

function BNS.dist(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- Is this IsoZombie one of our NPC shells?
function BNS.isNPC(zombie)
    if not zombie or not instanceof(zombie, "IsoZombie") then return false end
    local md = zombie:getModData()
    return md and md.BNS ~= nil
end

function BNS.brain(zombie)
    local md = zombie:getModData()
    return md and md.BNS or nil
end

function BNS.isBandit(zombie)
    local b = BNS.brain(zombie)
    return b ~= nil and b.role == BNS.Role.BANDIT
end

function BNS.isTrader(zombie)
    local b = BNS.brain(zombie)
    return b ~= nil and b.role == BNS.Role.TRADER
end

-- All connected players (works in SP, MP client and MP server).
function BNS.getPlayers()
    local out = {}
    if isServer() then
        local list = getOnlinePlayers()
        if list then
            for i = 0, list:size() - 1 do table.insert(out, list:get(i)) end
        end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(i)
            if p and not p:isDead() then table.insert(out, p) end
        end
    end
    return out
end

function BNS.nearestPlayer(x, y)
    local best, bestD = nil, 999999
    for _, p in ipairs(BNS.getPlayers()) do
        local d = BNS.dist(x, y, p:getX(), p:getY())
        if d < bestD then best, bestD = p, d end
    end
    return best, bestD
end

-- Simple in-game hours timestamp for cooldowns.
function BNS.worldHours()
    local gt = getGameTime()
    return gt:getWorldAgeHours()
end

-- Recent log lines, newest last. The debug UI reads this so testers
-- don't have to tail console.txt; every existing BNS.log call feeds it.
BNS.logBuffer = BNS.logBuffer or {}
BNS.LOG_BUFFER_MAX = 120

function BNS.log(msg)
    local text = tostring(msg)
    print("[BNS] " .. text)
    local stamp = 0
    if getGameTime then
        local ok, hours = pcall(function() return getGameTime():getWorldAgeHours() end)
        if ok and hours then stamp = hours end
    end
    table.insert(BNS.logBuffer, { h = stamp, text = text })
    while #BNS.logBuffer > BNS.LOG_BUFFER_MAX do
        table.remove(BNS.logBuffer, 1)
    end
end

-- Deterministic-ish unique id generator (persisted counter is kept in
-- global mod data by the server; this fallback covers first use).
function BNS.newId(state)
    state.nextId = (state.nextId or 1) + 1
    return "bns_" .. tostring(state.nextId)
end
