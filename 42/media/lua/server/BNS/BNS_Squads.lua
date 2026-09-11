--***********************************************************************
-- Project Zombai — bandit squads (server)
--
-- Bandits travel in groups, and a group that scatters the moment it is
-- created is not a group. This module is the thing that keeps one
-- together, and it has to work on both sides of the live/virtual
-- boundary: members wander around a shared anchor while they have
-- bodies, and are carried by that anchor while they do not. Stepping
-- each record independently off-screen -- which is what used to happen --
-- pulls a squad apart across the map in a couple of in-game hours, and
-- the player then meets the survivors of it one at a time.
--
-- A squad is *managed* exactly when it has an entry in state.squads.
-- Wandering bandit groups get one at spawn; POI garrisons and raid
-- parties deliberately do not, because they already have somewhere to be
-- (a home, a target base) and a wander anchor would fight it.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Persistence"

BNS.Squads = {}

-- How far a member may drift from the group before heading back, and how
-- close it has to get before it counts as back. The gap between the two
-- is hysteresis: without it a bandit sitting exactly on the line spends
-- the whole day turning round.
BNS.Squads.COHESION = 20 -- tiles
BNS.Squads.REGROUP = 12  -- tiles: walk back to at least this close

-- Milling about: local destinations are picked inside this of the anchor,
-- so cohesion is mostly a property of where they choose to go rather than
-- something that has to drag them back.
BNS.Squads.MILL = 10

-- Chance per full brain tick that a member decides the group should move
-- on, and how far it takes them.
BNS.Squads.TREK_CHANCE = 600
BNS.Squads.TREK_REACH = 250

-- Off-screen travel, in tiles per boundary tick.
BNS.Squads.STEP = 60

local function squads(state)
    state.squads = state.squads or {}
    return state.squads
end

function BNS.Squads.create(state, id, x, y)
    squads(state)[id] = { x = x, y = y }
    return squads(state)[id]
end

function BNS.Squads.get(id)
    local state = BNS.Persistence.getState()
    return squads(state)[id]
end

-- A squad this module drives, as opposed to one that only shares an id.
function BNS.Squads.manages(rec)
    return rec ~= nil and rec.squad ~= nil and not rec.home
        and BNS.Squads.get(rec.squad) ~= nil
end

function BNS.Squads.anchor(id)
    local squad = BNS.Squads.get(id)
    if not squad then return nil end
    return squad.x, squad.y
end

-- Where in the group this particular NPC stands. Derived from the record
-- id so it is stable across saves and never puts two of them on the same
-- tile -- a squad standing in a single square reads as one person.
function BNS.Squads.offset(id)
    local hash = 0
    for i = 1, #id do hash = (hash * 31 + string.byte(id, i)) % 100000 end
    local angle = (hash % 360) * math.pi / 180
    local reach = 2 + (hash % 5)
    return math.cos(angle) * reach, math.sin(angle) * reach
end

-- Anchors follow their members, not the other way round: a live group
-- that walks somewhere takes its anchor with it. Squads that have lost
-- everyone are dropped.
function BNS.Squads.recompute(state)
    local sums = {}
    for _, rec in pairs(state.npcs) do
        if rec.squad and squads(state)[rec.squad] then
            local s = sums[rec.squad] or { x = 0, y = 0, n = 0 }
            s.x, s.y, s.n = s.x + rec.x, s.y + rec.y, s.n + 1
            sums[rec.squad] = s
        end
    end
    for id, squad in pairs(squads(state)) do
        local s = sums[id]
        if not s then
            squads(state)[id] = nil
        else
            squad.x, squad.y = s.x / s.n, s.y / s.n
            squad.size = s.n
        end
    end
end

-- Move a squad's anchor towards wherever the group is headed. Called
-- once per squad per boundary tick, never per member: stepping members
-- individually is what scattered them.
function BNS.Squads.stepAnchor(squad)
    if not squad.targetX then
        squad.targetX = squad.x + ZombRand(-400, 400)
        squad.targetY = squad.y + ZombRand(-400, 400)
    end
    local d = BNS.dist(squad.x, squad.y, squad.targetX, squad.targetY)
    if d <= BNS.Squads.STEP then
        squad.x, squad.y = squad.targetX, squad.targetY
        squad.targetX, squad.targetY = nil, nil
    else
        squad.x = squad.x + (squad.targetX - squad.x) / d * BNS.Squads.STEP
        squad.y = squad.y + (squad.targetY - squad.y) / d * BNS.Squads.STEP
    end
end

-- One pass over every managed squad: re-centre on the members, then walk
-- the ones with nobody in the loaded world onward. A squad with even one
-- live member stays put -- its anchor is being decided by real positions.
function BNS.Squads.tick(state)
    BNS.Squads.recompute(state)
    local anyLive = {}
    for _, rec in pairs(state.npcs) do
        if rec.live and rec.squad then anyLive[rec.squad] = true end
    end
    for id, squad in pairs(squads(state)) do
        if not anyLive[id] then BNS.Squads.stepAnchor(squad) end
    end
end

-- Carry a virtual member along with its squad instead of letting it walk
-- off on its own. Returns true when it handled the record.
function BNS.Squads.placeVirtual(rec)
    if not BNS.Squads.manages(rec) then return false end
    local squad = BNS.Squads.get(rec.squad)
    local dx, dy = BNS.Squads.offset(rec.id)
    rec.x, rec.y = squad.x + dx, squad.y + dy
    rec.targetX, rec.targetY = nil, nil
    if rec.vehicle and rec.aboard then
        rec.vehicle.x, rec.vehicle.y = math.floor(rec.x), math.floor(rec.y)
    end
    return true
end

-- Where a live squad member should be wandering to.
--
-- Returns a destination and whether it is a *regroup* -- one the NPC
-- should not stop and rest half way through. Milling destinations are
-- picked inside the group's bubble, so staying together is mostly a
-- consequence of where they choose to go rather than a correction
-- applied afterwards.
function BNS.Squads.wanderTarget(brain, x, y)
    if not brain.squad then return nil end
    local squad = BNS.Squads.get(brain.squad)
    if not squad then return nil end

    -- The group is on the move: everyone heads for it, in formation.
    if squad.targetX then
        local dx, dy = BNS.Squads.offset(brain.id)
        return squad.targetX + dx, squad.targetY + dy, true
    end

    -- Drifted out: come back inside, not merely to the edge.
    if BNS.dist(x, y, squad.x, squad.y) > BNS.Squads.COHESION then
        local dx, dy = BNS.Squads.offset(brain.id)
        local pull = BNS.Squads.REGROUP / math.max(BNS.dist(0, 0, dx, dy), 0.1)
        return squad.x + dx * pull, squad.y + dy * pull, true
    end

    -- Milling about near the others.
    local mill = BNS.Squads.MILL
    return squad.x + ZombRand(-mill, mill + 1),
           squad.y + ZombRand(-mill, mill + 1), false
end

-- Has this member been left behind by the group?
function BNS.Squads.strayed(brain, x, y)
    local squad = brain.squad and BNS.Squads.get(brain.squad) or nil
    if not squad then return false end
    local ax, ay = squad.targetX or squad.x, squad.targetY or squad.y
    return BNS.dist(x, y, ax, ay) > BNS.Squads.COHESION
end

-- Now and then someone decides the group should move on, and the whole
-- squad goes rather than one bandit wandering off alone.
function BNS.Squads.maybeTrek(brain)
    local squad = brain.squad and BNS.Squads.get(brain.squad) or nil
    if not squad or squad.targetX then return false end
    if ZombRand(BNS.Squads.TREK_CHANCE) ~= 0 then return false end
    local reach = BNS.Squads.TREK_REACH
    squad.targetX = squad.x + ZombRand(-reach, reach + 1)
    squad.targetY = squad.y + ZombRand(-reach, reach + 1)
    return true
end

-- The group has arrived; stop marching and mill about again.
function BNS.Squads.arrived(brain, x, y)
    local squad = brain.squad and BNS.Squads.get(brain.squad) or nil
    if not squad or not squad.targetX then return end
    if BNS.dist(x, y, squad.targetX, squad.targetY) <= BNS.Squads.MILL then
        squad.targetX, squad.targetY = nil, nil
    end
end
