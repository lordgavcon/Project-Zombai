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

-- Shell suppression -----------------------------------------------------
--
-- A shell has to stop behaving like a zombie without being frozen. Only
-- the target clearing is understood: it is what stops a shell lunging at
-- players, and it is cheap. `setUseless` and `makeInactive` were added on
-- a guess ("calm the engine's instincts") and never verified against a
-- running build -- and a shell that will not walk while its brain issues
-- path orders is exactly what those two would look like if either parks
-- the character. They are off by default and can be switched back on from
-- the debug panel, so the question can be answered in game rather than
-- argued about here.
BNS.Suppress = {
    clearTarget = true,  -- setTarget(nil)/setAttackedBy(nil): stops zombie aggression
    lockState   = true,  -- setStateMachineLocked while standing in melee range
    useless     = false, -- setUseless(true)
    inactive    = false, -- makeInactive(true)
}

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
        attackSpeed      = BNS.SV("NPCAttackSpeed", 0.5),
        doorDelay        = BNS.SV("DoorOpenDelay", 3),
        scavenging       = BNS.SV("ScavengingEnabled", true),
        vehicles         = BNS.SV("NPCVehiclesEnabled", true),
        poiSigns         = BNS.SV("POISignsEnabled", true),
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

-- Is this NPC hostile to players *right now*? Role is the whole answer:
-- survivors and traders never fight people, and a neutral turned on you
-- has already had its role flipped to BANDIT (BNS_Brain's hit handler).
-- Combat is gated on this rather than on which program happens to be
-- running, so a friendly NPC standing next to you cannot throw a punch
-- however it got there.
function BNS.isHostile(brain)
    return brain ~= nil and brain.role == BNS.Role.BANDIT
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

-- Shared bandit behaviour ------------------------------------------------
--
-- Every bandit behaves the same way, whatever their tier. The tiers used
-- to fork the *rules*: only civilians ran when hurt, only civilians and
-- thugs would rob you, militia stood their ground three times as often,
-- and each hit doors for a different number. That made a bandit's tier
-- something you had to learn separately rather than the same person with
-- better kit, and it made every one of those behaviours a separate code
-- path to get wrong.
--
-- So the rules live here, once, and every tier reads them. What a tier
-- still decides is *gear* -- which weapons and outfits they roll, and how
-- likely a firearm is -- plus one stat, toughness, because that is what a
-- tier is for. Nothing else should branch on `brain.tier`.
BNS.Behaviour = {
    robChance   = 40,   -- % chance an engagement opens as a robbery
    fleeHealth  = 0.35, -- below this, a hurt bandit breaks off
    standChance = 10,   -- % who stand their ground against a zombie mob
    grabHold    = 120,  -- engine ticks held by a zombie's grab
    bashDamage  = 35,   -- damage per bash against a door's durability
    spareMags   = 2,    -- spare magazines carried
    squadMin    = 2,    -- how many arrive together
    squadMax    = 4,
}

-- The one thing a tier still changes about a bandit in a fight.
BNS.Toughness = {
    [BNS.Tier.CIVILIAN] = 1.0,
    [BNS.Tier.THUG]     = 1.15,
    [BNS.Tier.MILITIA]  = 1.3,
}

-- How many NPC records may exist at once.
--
-- New NPCs are created *virtual*, out in the unloaded world, so the live
-- cap no longer throttles how many exist -- it only throttles how many
-- have bodies. Without its own ceiling the pool would grow by one every
-- ten minutes for the life of the save, none of them counted against
-- anything. Several times the live cap leaves room for the walking-around
-- population that makes meeting the same scavenger two towns over
-- possible.
BNS.VirtualPool = 3 -- total records allowed, as a multiple of maxLive

function BNS.recordCeiling()
    return (BNS.Options().maxLive or 20) * BNS.VirtualPool
end

-- Is the world actually streamed in at this point?
--
-- This is the only honest answer to "can an NPC exist here", and it is
-- what the live/virtual boundary is built on. A radius around the player
-- is *not* the same thing: the streamed area is neither round nor a fixed
-- size, so a record could sit inside a generous radius while the square
-- under it stayed unloaded -- close enough that BNS thought it should be
-- awake, too far for the engine to give it a body. Records in that band
-- were embodied never and stepped never: frozen for the rest of the save.
function BNS.squareLoaded(x, y, z)
    local cell = getCell()
    if not cell then return false end
    local ok, sq = pcall(function()
        return cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
    end)
    return ok and sq ~= nil
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
