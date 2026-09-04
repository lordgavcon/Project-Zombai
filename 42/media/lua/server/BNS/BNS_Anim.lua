--***********************************************************************
-- Bandits & Survivors — animation driver (server)
--
-- NPC shells play player animation clips through the AnimSet overlays
-- in media/AnimSets/zombie/ (nodes conditioned on BNSNPC / BNSAnim /
-- Weapon). This module owns those variables: programs and combat report
-- what the NPC is doing; the variables only change when the mode changes
-- so non-looped clips aren't re-triggered every tick.
--
-- This is the whole visual approach now -- the same one the shipping B42
-- NPC mods use: an IsoZombie flagged with an animation variable and given
-- human clips. There is no second character to keep in sync.
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

-- Weapon categories the player AnimSet branches on. Verified against the
-- game's own media/AnimSets/player: every weapon-specific idle, walk, run,
-- aim and attack node is conditioned on `Weapon` having one of these
-- values, so setting it on a shell is what makes its animation match what
-- it is actually holding.
BNS.Anim.WeaponClasses = {
    ["1handed"] = true, ["2handed"] = true, heavy = true, knife = true,
    spear = true, handgun = true, firearm = true, chainsaw = true,
    throwing = true,
}

-- Map a loadout entry onto one of those categories.
function BNS.Anim.weaponClass(weapon)
    if not weapon or not weapon.item then return "1handed" end
    if weapon.gun then
        local item = weapon.item
        if item:find("Pistol") or item:find("Revolver") then return "handgun" end
        return "firearm"
    end
    local item = weapon.item
    if item:find("Knife") or item:find("Machete") then return "knife" end
    if item:find("Spear") or item:find("Fork") then return "spear" end
    if item:find("Axe") or item:find("Sledge") or item:find("Maul") then return "heavy" end
    if item:find("Bat") or item:find("Plank") or item:find("Crowbar") then return "2handed" end
    return "1handed"
end

function BNS.Anim.setWeapon(zombie, brain)
    local class = BNS.Anim.weaponClass(brain.weapon)
    if brain.animWeapon == class then return end
    brain.animWeapon = class
    zombie:setVariable("Weapon", class)
end

-- Initial variables when a shell materialises.
function BNS.Anim.init(zombie, brain)
    zombie:setVariable("BNSNPC", "true")
    brain.animMode = "idle"
    brain.animBase = "idle"
    brain.animWeapon = nil
    zombie:setVariable("BNSAnim", "idle")
    BNS.Anim.setWeapon(zombie, brain)
end
