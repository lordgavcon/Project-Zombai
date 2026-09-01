--***********************************************************************
-- Bandits & Survivors — persistence (server)
--
-- All NPCs live in global mod data as plain-table records. A record is
-- either "live" (bound to a spawned IsoZombie shell by id) or "virtual"
-- (no shell; position advanced abstractly so NPCs keep travelling the
-- world while unloaded). State survives save/load and server restarts.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"

BNS.Persistence = {}

local STATE_KEY = "BNS_State"

function BNS.Persistence.getState()
    local state = ModData.getOrCreate(STATE_KEY)
    state.npcs      = state.npcs or {}       -- id -> npc record
    state.bases     = state.bases or {}      -- poi name -> base record
    state.playerBases = state.playerBases or {} -- key -> {x,y,lastRaid}
    state.nextId    = state.nextId or 1
    return state
end

-- npc record layout:
-- {
--   id, role, tier, name, x, y, z,
--   program, targetX, targetY,          -- current goal
--   health,                             -- 0..1
--   weapon = {item,dmg,range,gun,sound,hit},
--   stock = { {item,value,count}, ... } -- traders only
--   squad,                              -- shared squad id for groups
--   home = {x,y},                       -- POI defenders anchor here
--   live = true/false                   -- has a spawned shell right now
-- }

function BNS.Persistence.newRecord(role, tier, x, y, z)
    local state = BNS.Persistence.getState()
    local rec = {
        id = BNS.newId(state),
        role = role,
        tier = tier or BNS.Tier.CIVILIAN,
        name = BNS.Loadouts.randomName(),
        x = x, y = y, z = z or 0,
        program = BNS.Program.WANDER,
        health = 1.0,
        live = false,
    }
    state.npcs[rec.id] = rec
    return rec
end

function BNS.Persistence.remove(id)
    local state = BNS.Persistence.getState()
    state.npcs[id] = nil
end

function BNS.Persistence.count(filter)
    local state = BNS.Persistence.getState()
    local total, live = 0, 0
    for _, rec in pairs(state.npcs) do
        if not filter or filter(rec) then
            total = total + 1
            if rec.live then live = live + 1 end
        end
    end
    return total, live
end

-- Sync a live shell's actual position back into its record so a crash
-- or despawn never loses more than one tick of movement.
function BNS.Persistence.syncFromShell(zombie)
    local brain = BNS.brain(zombie)
    if not brain then return end
    local state = BNS.Persistence.getState()
    local rec = state.npcs[brain.id]
    if not rec then return end
    rec.x, rec.y, rec.z = zombie:getX(), zombie:getY(), zombie:getZ()
    rec.program = brain.program
    rec.targetX, rec.targetY = brain.targetX, brain.targetY
    rec.health = brain.health
    rec.loot = brain.loot
    rec.stock = brain.stock
end

-- Advance a virtual (unloaded) NPC towards its wander target. Called
-- every ten in-game minutes; speed is a rough walking pace.
function BNS.Persistence.virtualStep(rec)
    if rec.live then return end
    if rec.home then return end -- POI defenders stay put
    if not rec.targetX then
        rec.targetX = rec.x + ZombRand(-400, 400)
        rec.targetY = rec.y + ZombRand(-400, 400)
    end
    local d = BNS.dist(rec.x, rec.y, rec.targetX, rec.targetY)
    local step = 60 -- tiles per virtual tick
    if d <= step then
        rec.x, rec.y = rec.targetX, rec.targetY
        rec.targetX, rec.targetY = nil, nil
    else
        rec.x = rec.x + (rec.targetX - rec.x) / d * step
        rec.y = rec.y + (rec.targetY - rec.y) / d * step
    end
end
