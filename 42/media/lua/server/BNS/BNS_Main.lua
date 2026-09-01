--***********************************************************************
-- Bandits & Survivors — director (server)
--
-- Population control and the live/virtual boundary:
--   * spawns fresh bandits/survivors near players by sandbox rates
--   * dematerialises shells that drift far from every player
--   * materialises virtual records whose position comes into range
--   * steps virtual NPCs across the world so they keep travelling
--   * samples player positions and schedules base raids
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Persistence"
require "BNS/BNS_Spawner"
require "BNS/BNS_Brain"
require "BNS/BNS_Bases"
require "BNS/BNS_Raids"
require "BNS/BNS_Commands"

BNS.Main = {}

local LIVE_RADIUS    = 120 -- records inside this of a player get shells
local VIRTUAL_RADIUS = 200 -- shells beyond this of every player despawn

local function liveShells()
    local out = {}
    local zombies = getCell() and getCell():getZombieList() or nil
    if not zombies then return out end
    for i = 0, zombies:size() - 1 do
        local z = zombies:get(i)
        if BNS.isNPC(z) then table.insert(out, z) end
    end
    return out
end

-- Spawning ---------------------------------------------------------------

function BNS.Main.populationTick()
    local opts = BNS.Options()
    local players = BNS.getPlayers()
    if #players == 0 then return end

    local _, live = BNS.Persistence.count()
    if live >= opts.maxLive then return end

    for _, p in ipairs(players) do
        if opts.banditRate > 0 and ZombRand(100) < opts.banditRate * 4 then
            BNS.Spawner.spawnBanditNear(p)
        end
        if opts.survivorRate > 0 and ZombRand(100) < opts.survivorRate * 4 then
            BNS.Spawner.spawnSurvivorNear(p)
        end
        _, live = BNS.Persistence.count()
        if live >= opts.maxLive then break end
    end
end

-- Live/virtual boundary ---------------------------------------------------

function BNS.Main.boundaryTick()
    local state = BNS.Persistence.getState()

    -- Despawn shells too far from every player.
    for _, zombie in ipairs(liveShells()) do
        local _, d = BNS.nearestPlayer(zombie:getX(), zombie:getY())
        if d and d > VIRTUAL_RADIUS then
            BNS.Spawner.dematerialise(zombie)
        else
            BNS.Persistence.syncFromShell(zombie)
        end
    end

    -- Wake virtual records near players; step the rest.
    local opts = BNS.Options()
    local _, live = BNS.Persistence.count()
    for _, rec in pairs(state.npcs) do
        if not rec.live then
            local _, d = BNS.nearestPlayer(rec.x, rec.y)
            if d and d < LIVE_RADIUS and live < opts.maxLive then
                if BNS.Spawner.materialise(rec) then live = live + 1 end
            else
                BNS.Persistence.virtualStep(rec)
            end
        end
    end
end

-- Repair records whose shell vanished without a death event (e.g. the
-- chunk unloaded underneath them or the server restarted mid-flight).
function BNS.Main.reconcile()
    local state = BNS.Persistence.getState()
    local seen = {}
    for _, zombie in ipairs(liveShells()) do
        local brain = BNS.brain(zombie)
        if brain then seen[brain.id] = true end
    end
    for id, rec in pairs(state.npcs) do
        if rec.live and not seen[id] then rec.live = false end
    end
end

-- Wiring -------------------------------------------------------------------

function BNS.Main.onInitGlobalModData()
    local state = BNS.Persistence.getState()
    -- Nothing survives a load as a live shell; records respawn on demand.
    for _, rec in pairs(state.npcs) do rec.live = false end
    BNS.Bases.claimPOIs()
    BNS.log("initialised: " .. tostring(BNS.Persistence.count()) .. " persistent NPCs, version " .. BNS.Version)
end

function BNS.Main.everyTenMinutes()
    BNS.Main.reconcile()
    BNS.Main.boundaryTick()
    BNS.Main.populationTick()
end

function BNS.Main.everyHours()
    BNS.Raids.samplePlayerPositions()
    BNS.Raids.tryLaunchRaid()
    -- Re-check POI claims in case sandbox raised the cap mid-game.
    BNS.Bases.claimPOIs()
end

Events.OnInitGlobalModData.Add(BNS.Main.onInitGlobalModData)
Events.EveryTenMinutes.Add(BNS.Main.everyTenMinutes)
Events.EveryHours.Add(BNS.Main.everyHours)
