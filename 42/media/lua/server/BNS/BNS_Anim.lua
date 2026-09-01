--***********************************************************************
-- Bandits & Survivors — animation driver (server)
--
-- NPC shells play player animation clips through the AnimSet overlays
-- in media/AnimSets/zombie/ (nodes conditioned on the BNSNPC/BNSAnim
-- variables). This module owns those variables: programs and combat
-- report what the NPC is doing; the variables only change when the
-- mode changes so non-looped clips aren't re-triggered every tick.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"

BNS.Anim = {}

BNS.Anim.Modes = {
    idle = true, walk = true, run = true,
    aim = true, swing = true, shoot = true,
    hit = true,     -- one-shot flinch when a zombie lands a hit
    grabbed = true, -- sustained struggle while held by a zombie
}

-- Sustained modes: idle / walk / run / aim / grabbed. The base mode is
-- tracked separately from pulses so a one-shot flinch can never eat a
-- sustained state (e.g. a hit landing while grabbed).
function BNS.Anim.set(zombie, brain, mode)
    if not BNS.Anim.Modes[mode] then mode = "idle" end
    brain.animBase = mode
    -- A pulse in flight keeps the variable until its timer restores base.
    if brain.animPulse and brain.animPulse > 0 then return end
    if brain.animMode == mode then return end
    brain.animMode = mode
    zombie:setVariable("BNSAnim", mode)
end

-- One-shot modes: swing / shoot / hit. Holds the variable for roughly
-- one clip length, then falls back to the sustained base mode.
function BNS.Anim.pulse(zombie, brain, mode)
    if not BNS.Anim.Modes[mode] then return end
    brain.animBase = brain.animBase or "idle"
    brain.animPulse = 45 -- ~0.75s at 60 ticks/s
    brain.animMode = mode
    zombie:setVariable("BNSAnim", mode)
end

-- Called every engine tick from BNS_Brain so pulses expire on time.
function BNS.Anim.tick(zombie, brain)
    if brain.animPulse and brain.animPulse > 0 then
        brain.animPulse = brain.animPulse - 1
        if brain.animPulse <= 0 then
            brain.animPulse = nil
            brain.animMode = brain.animBase or "idle"
            zombie:setVariable("BNSAnim", brain.animMode)
        end
    end
end

-- Initial variables when a shell materialises.
function BNS.Anim.init(zombie, brain)
    zombie:setVariable("BNSNPC", "true")
    brain.animMode = "idle"
    brain.animBase = "idle"
    zombie:setVariable("BNSAnim", "idle")
end
