--***********************************************************************
-- Project Zombai — what an NPC knows about where you are (server)
--
-- Pursuit used to read the player's live coordinates every tick, which is
-- perfect knowledge: break line of sight, cross a building, and they
-- still walked exactly to you. Nothing a player did could shake one off.
--
-- So an NPC now *remembers* rather than tracks. While they can see you
-- the memory is refreshed to where you actually are; the moment they
-- cannot, the memory is all they have, and it does not move. They walk to
-- the last place they saw you, look around, and give up.
--
-- Sight is deliberately conservative about *losing* you and generous
-- about keeping you: a bandit who forgets the instant you step behind a
-- lamppost is as unconvincing as one who never forgets at all.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Combat"

BNS.Senses = {}

BNS.Senses.SIGHT = 30       -- tiles: past this nobody is spotted at all
BNS.Senses.CLOSE = 8        -- tiles: too close to sneak past
BNS.Senses.SNEAK_SPOT = 10  -- % chance per look of spotting a sneaker
BNS.Senses.GRACE = 30       -- engine ticks of lost sight before it counts
BNS.Senses.MEMORY = 1800    -- engine ticks a last-known spot is worth walking to

-- Can this NPC see the player right now?
--
-- Walls first, because that is the part the player controls: BNS.Combat
-- .canSee wraps the engine's own line-of-sight check and returns true on
-- builds that do not expose one, so a build without it behaves exactly
-- as before rather than blinding every NPC.
function BNS.Senses.canSee(zombie, brain, player, dist)
    if not player then return false end
    if dist > BNS.Senses.SIGHT then return false end
    if not BNS.Combat.canSee(zombie, player) then return false end
    if dist < BNS.Senses.CLOSE then return true end
    if player.isSneaking and player:isSneaking() then
        return ZombRand(100) < BNS.Senses.SNEAK_SPOT
    end
    return true
end

-- Run once per brain tick, before any program looks at the player.
--
-- Fills in what the *NPC* knows, which is what programs must steer by:
--   ctx.visible  -- can they see them this instant
--   ctx.goX/goY  -- where to head: the player if seen, the memory if not
--   ctx.lost     -- sight has been gone long enough to act on
--   ctx.stale    -- the memory has run out; there is nowhere left to go
--   ctx.knownDist-- how far the *NPC* thinks it is: to the player when
--                   seen, to the remembered spot when not. Give-up tests
--                   must use this, never ctx.dist -- deciding you are too
--                   far away to chase, from a position they cannot see,
--                   is perfect knowledge wearing a different hat.
function BNS.Senses.observe(zombie, brain, ctx)
    local seen = BNS.Senses.canSee(zombie, brain, ctx.player, ctx.dist)
    ctx.visible = seen

    if seen then
        brain.seenX, brain.seenY = ctx.player:getX(), ctx.player:getY()
        brain.seenZ = ctx.player:getZ()
        brain.lostFor = 0
        brain.heard = nil  -- eyes beat ears; this is a sighting now
        ctx.goX, ctx.goY, ctx.goZ = brain.seenX, brain.seenY, brain.seenZ
        ctx.lost, ctx.stale = false, false
        ctx.knownDist = ctx.dist
        return
    end

    brain.lostFor = (brain.lostFor or 0) + BNS.Senses.TICK
    ctx.goX, ctx.goY, ctx.goZ = brain.seenX, brain.seenY, brain.seenZ
    -- A moment out of sight is a lamppost, not an escape.
    ctx.lost = (brain.lostFor or 0) > BNS.Senses.GRACE
    ctx.stale = brain.seenX == nil or (brain.lostFor or 0) > BNS.Senses.MEMORY
    if ctx.goX then
        ctx.knownDist = BNS.dist(zombie:getX(), zombie:getY(), ctx.goX, ctx.goY)
    else
        ctx.knownDist = ctx.dist
    end
end

-- observe() runs on full brain ticks, so "ticks" here are those, scaled
-- to engine ticks so every timer in the mod means the same thing.
BNS.Senses.TICK = 10

-- Hearing ---------------------------------------------------------------
--
-- A noise is a *place*, which is exactly what the sight memory already
-- holds, so hearing a gunshot and losing sight of someone land in the
-- same slot and are answered by the same SEARCH: go there, look around,
-- give up. Nothing new has to be built for "react to a noise" except the
-- ear.
--
-- Not everyone within earshot comes. The odds fall off towards the edge
-- of the noise, so a shot brings the street rather than the district, and
-- two bandits at the same distance do not move like one animal.

-- Programs already busy with something louder than a bang somewhere.
local DEAF = {
    [BNS.Program.ATTACK] = true, [BNS.Program.ROB] = true,
    [BNS.Program.FIGHTZ] = true, [BNS.Program.FLEE] = true,
    [BNS.Program.RAID] = true,
}

function BNS.Senses.hears(dist, radius)
    if dist > radius then return false end
    local near = 1 - (dist / math.max(radius, 0.1))
    local odds = BNS.Behaviour.hearingFall
        + (1 - BNS.Behaviour.hearingFall) * near
    return ZombRand(100) < odds * 100
end

-- One NPC's reaction. Split out so the suite can drive a single shell.
function BNS.Senses.hear(zombie, brain, x, y, z, radius)
    if not brain or DEAF[brain.program] then return false end
    if BNS.Combat.isDown(brain) then return false end
    -- Already looking at something with their own eyes: better information.
    if (brain.lostFor or 0) == 0 and brain.seenX then return false end

    local d = BNS.dist(zombie:getX(), zombie:getY(), x, y)
    if not BNS.Senses.hears(d, radius) then return false end

    -- Neutrals do not investigate gunfire, they leave: a trader walking
    -- towards a firefight is not a person, it is a target.
    if not BNS.isHostile(brain) then
        brain.fleeFrom = { x = x, y = y }
        -- Referenced rather than required: BNS_Programs requires this
        -- module, so requiring it back would be a cycle.
        brain.fleeUntil = (BNS.Programs and BNS.Programs.FLEE_TICKS) or 30
        brain.program = BNS.Program.FLEE
        return true
    end

    -- Go and look. The point goes in the same slot a lost sighting uses,
    -- aged past the grace window so it reads as "somewhere to check"
    -- rather than "someone I can see".
    brain.seenX, brain.seenY, brain.seenZ = x, y, z or 0
    brain.lostFor = BNS.Senses.GRACE + BNS.Senses.TICK
    brain.searchLook = nil
    brain.restUntil = nil
    brain.heard = true  -- so the debug panel can tell an ear from an eye
    brain.program = BNS.Program.SEARCH
    BNS.Say(zombie, brain, getText("UI_BNS_HeardThat"))
    return true
end

-- Something loud happened here. Called by whatever made the noise.
function BNS.Senses.noise(x, y, z, radius)
    local heard = 0
    for _, zombie in ipairs(BNS.liveShells()) do
        local brain = BNS.brain(zombie)
        if brain and BNS.Senses.hear(zombie, brain, x, y, z, radius) then
            heard = heard + 1
        end
    end
    return heard
end

function BNS.Senses.forget(brain)
    brain.seenX, brain.seenY, brain.seenZ = nil, nil, nil
    brain.lostFor = nil
    brain.searchLook = nil
    brain.heard = nil
end

-- Standing at the last place they saw you, having a look round.
--
-- setHeadLookAround is the engine's own "scan about" and costs nothing
-- where it exists; where it does not, the pause alone still reads as
-- someone who has lost you, so it is not worth a candidate list.
function BNS.Senses.lookAround(zombie, on)
    if not zombie.setHeadLookAround then return false end
    return pcall(function() zombie:setHeadLookAround(on and true or false) end)
end
