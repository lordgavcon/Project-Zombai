--***********************************************************************
-- Bandits & Survivors — director (server)
--
-- Population control and the live/virtual boundary:
--   * spawns fresh bandits/survivors as records out in the unloaded world
--   * gives a body to any record standing on ground that is streamed in
--   * takes it back when that ground goes, or they are left far behind
--   * steps virtual NPCs across the world so they keep travelling
--   * samples player positions and schedules base raids
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Persistence"
require "BNS/BNS_Spawner"
require "BNS/BNS_Squads"
require "BNS/BNS_Brain"
require "BNS/BNS_Bases"
require "BNS/BNS_Raids"
require "BNS/BNS_Commands"

BNS.Main = {}

-- The live/virtual boundary is the *loaded world*, not a radius.
--
-- A record gets a body exactly when the square it is standing on is
-- streamed in, and gives it back when that stops being true. Using a
-- radius instead was the bug: the streamed area is neither round nor a
-- fixed size, so records could sit inside the wake radius while the
-- square under them stayed unloaded -- and the old code only stepped
-- records *outside* that radius, so those were embodied never and moved
-- never. Once an NPC drifted into that band it stayed there for the rest
-- of the save.
local VIRTUAL_RADIUS = 200 -- shells this far from every player despawn as well
local WAKE_FAILS = 3       -- failed embodiments before a record moves on

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

    local total, live = BNS.Persistence.count()
    if live >= opts.maxLive then return end
    if total >= BNS.recordCeiling() then return end

    for _, p in ipairs(players) do
        if opts.banditRate > 0 and ZombRand(100) < opts.banditRate * 4 then
            BNS.Spawner.spawnBanditNear(p)
        end
        if opts.survivorRate > 0 and ZombRand(100) < opts.survivorRate * 4 then
            BNS.Spawner.spawnSurvivorNear(p)
        end
        total, live = BNS.Persistence.count()
        if live >= opts.maxLive then break end
        if total >= BNS.recordCeiling() then break end
    end
end

-- Live/virtual boundary ---------------------------------------------------

function BNS.Main.boundaryTick()
    local state = BNS.Persistence.getState()

    -- Re-centre every squad on its members and walk the ones with nobody
    -- in the loaded world onward, before any record is stepped: the
    -- anchor is what virtual members are then placed around.
    BNS.Squads.tick(state)

    -- Hand back the body of any shell whose ground has gone -- either it
    -- has been left far behind, or the chunk under it unloaded. Doing the
    -- second explicitly matters: a shell whose chunk goes without us is
    -- taken by the engine, and the record then keeps whatever position it
    -- last synced rather than where the NPC actually was.
    for _, zombie in ipairs(liveShells()) do
        local _, d = BNS.nearestPlayer(zombie:getX(), zombie:getY())
        local stranded = not BNS.squareLoaded(zombie:getX(), zombie:getY(), zombie:getZ())
        if stranded or (d and d > VIRTUAL_RADIUS) then
            BNS.Spawner.dematerialise(zombie)
        else
            BNS.Persistence.syncFromShell(zombie)
        end
    end

    -- Give a body to every virtual record standing on loaded ground, and
    -- keep the rest walking the world off-screen.
    local opts = BNS.Options()
    local _, live = BNS.Persistence.count()
    for _, rec in pairs(state.npcs) do
        if not rec.live then
            if not BNS.squareLoaded(rec.x, rec.y, rec.z) then
                BNS.Persistence.virtualStep(rec)
            elseif live >= opts.maxLive then
                -- Only the population cap is holding them back, and they
                -- are stood on ground the player can walk to. Leave them
                -- exactly where they are rather than teleporting them.
                rec.capped = true
            else
                rec.capped = nil
                if BNS.Spawner.materialise(rec) then
                    live = live + 1
                    rec.wakeFails = nil
                else
                    -- Loaded ground that will not take a body (no free
                    -- square, a failed spawn). Try again next pass, but
                    -- never forever: a record that cannot be embodied here
                    -- moves on rather than sitting in limbo, which is the
                    -- failure this whole rewrite is about.
                    rec.wakeFails = (rec.wakeFails or 0) + 1
                    if rec.wakeFails >= WAKE_FAILS then
                        rec.wakeFails = nil
                        BNS.Persistence.virtualStep(rec)
                    end
                end
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
    BNS.Main.populationTick()
end

function BNS.Main.everyHours()
    BNS.Raids.samplePlayerPositions()
    BNS.Raids.tryLaunchRaid()
    -- Re-check POI claims in case sandbox raised the cap mid-game.
    BNS.Bases.claimPOIs()
end

Events.OnInitGlobalModData.Add(BNS.Main.onInitGlobalModData)
-- The boundary runs on its own, faster clock. Waking is meant to feel
-- like the NPC was always there when you arrive, and ten in-game minutes
-- is long enough to walk through a whole street first.
Events.EveryOneMinute.Add(BNS.Main.boundaryTick)
Events.EveryTenMinutes.Add(BNS.Main.everyTenMinutes)
Events.EveryHours.Add(BNS.Main.everyHours)
