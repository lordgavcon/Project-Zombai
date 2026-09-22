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
require "BNS/BNS_Loadouts"

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

-- One-shot modes: swing / shoot / hit. Holds the variable for one clip
-- length, then falls back to the sustained base mode.
--
-- The hold is a caller's decision, not a constant, because it has to sit
-- inside the beat that produced it. Too short and the clip is visibly cut
-- off part way through the swing; too long and BNSAnim never leaves
-- "swing" between swings, the condition never changes, and the node has
-- no edge to re-trigger on -- so the *next* swing plays nothing at all.
-- BNS.Combat.clipHold works both ends out from the combat cycle.
BNS.Anim.PULSE_TICKS = 45 -- ~0.75s at 60 ticks/s, when the caller has no better idea

function BNS.Anim.pulse(zombie, brain, mode, ticks)
    if not BNS.Anim.Modes[mode] then return end
    brain.animBase = brain.animBase or "idle"
    brain.animPulse = math.max(math.floor(ticks or BNS.Anim.PULSE_TICKS), 1)
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

-- Which classes need both hands. Which hands a weapon occupies and which
-- clips it plays are the same question, so they are answered from the
-- same classification -- a bat carried one-handed and swung with a
-- two-handed animation looks wrong from either end.
BNS.Anim.TwoHanded = {
    ["2handed"] = true, heavy = true, spear = true,
    firearm = true, chainsaw = true,
}

-- Ask the item first, because the script is the authority on what it is,
-- and fall back to the class when the build does not expose the method.
-- Probed once and remembered: a signature that throws must not be
-- retried (CLAUDE.md).
BNS.Anim.twoHandProbe = nil -- nil = untried, true = usable, false = written off

function BNS.Anim.isTwoHanded(item, class)
    if item and BNS.Anim.twoHandProbe ~= false and item.isTwoHandWeapon then
        local ok, two = pcall(function() return item:isTwoHandWeapon() end)
        if ok and type(two) == "boolean" then
            BNS.Anim.twoHandProbe = true
            return two
        end
        BNS.Anim.twoHandProbe = false
    end
    return BNS.Anim.TwoHanded[class] == true
end

-- Vanilla handlers that assume a player ---------------------------------
--
-- `setPrimaryHandItem` fires `OnEquipPrimary`, and every Lua handler
-- registered on that event then runs against *our shell*. B42's fishing
-- handler calls a method only IsoPlayer has, so arming an NPC threw
-- "Object tried to call nil in handleFishing" and dumped a full Kahlua
-- stack trace -- two dozen of them in one session, every one of them
-- from BNS_Anim.equip. A pcall around the setter does not help: the
-- trace is printed where the error surfaces, inside the event, long
-- before anything of ours could catch it.
--
-- So the handler is *wrapped* rather than the setter guarded: it is
-- removed and re-added behind a filter that lets a player through
-- untouched and drops a shell. The handler has to be reachable by name
-- to do that, which is not something that can be checked offline, so it
-- is a candidate list (CLAUDE.md) and each entry is reported. A build
-- where none of them resolve behaves exactly as before -- noisily, but
-- correctly -- rather than having vanilla fishing quietly rewired.
--
-- Only ever wrap; never just remove. Dropping a vanilla handler takes
-- the feature with it.
BNS.Anim.PlayerOnlyHandlers = {
    -- event name, then where the handler might be reachable from.
    { event = "OnEquipPrimary", path = "FishingHandler.onEquipPrimary" },
    { event = "OnEquipPrimary", path = "FishingHandler.OnEquipPrimary" },
    { event = "OnEquipPrimary", path = "onEquipPrimary" },
}

-- op path -> "wrapped" / "not found" / an error, for the debug probe.
BNS.Anim.shielded = {}
-- ...and the handler functions already dealt with, because two candidate
-- paths can point at the same function. Wrapping one twice would run
-- vanilla's handler twice for every player equipping anything.
BNS.Anim.shieldedFns = {}

local function resolve(path)
    local node = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
        if node == nil then return nil end
    end
    return type(node) == "function" and node or nil
end

function BNS.Anim.shieldEquipEvents()
    for _, entry in ipairs(BNS.Anim.PlayerOnlyHandlers) do
        -- "not found" is not settled: nothing was called to find out, so
        -- looking again costs a couple of table reads and a handler that
        -- is registered later still gets shielded. Only a wrap or a real
        -- failure latches.
        if BNS.Anim.shielded[entry.path] == nil
                or BNS.Anim.shielded[entry.path] == "not found" then
            local handler = resolve(entry.path)
            local event = Events and Events[entry.event]
            if not handler or not event or not event.Remove or not event.Add then
                BNS.Anim.shielded[entry.path] = "not found"
            elseif BNS.Anim.shieldedFns[handler] then
                BNS.Anim.shielded[entry.path] = "wrapped"
            else
                local ok, err = pcall(function()
                    event.Remove(handler)
                    event.Add(function(character, item)
                        -- A shell is not a player and never fishes.
                        if character and BNS.isNPC(character) then return end
                        return handler(character, item)
                    end)
                end)
                BNS.Anim.shielded[entry.path] = ok and "wrapped" or tostring(err)
                if ok then BNS.Anim.shieldedFns[handler] = true end
                if ok then
                    BNS.log("shielded vanilla '" .. entry.path
                        .. "' from NPC shells (" .. entry.event .. ")")
                else
                    BNS.log("could not shield '" .. entry.path .. "': " .. tostring(err))
                end
            end
        end
    end
end

-- For the debug probe: what the shielding pass managed.
function BNS.Anim.shieldReport()
    local lines = {}
    for _, entry in ipairs(BNS.Anim.PlayerOnlyHandlers) do
        local state = BNS.Anim.shielded[entry.path]
        table.insert(lines, string.format("  %s %s (%s)",
            state == "wrapped" and "[ok]" or "[no]", entry.path, entry.event))
    end
    return lines
end

-- Put a weapon in the shell's hands -- in as many hands as it takes --
-- and point the animation at the matching clip set. Every weapon a shell
-- ever holds goes through here, so a swap mid-fight is dressed the same
-- way the initial spawn is.
function BNS.Anim.equip(zombie, brain, weapon)
    -- Done here rather than at load: vanilla's own files may not have
    -- run yet when this module is required, and the first equip is the
    -- first time it matters. The pass is a no-op once each candidate has
    -- been settled one way or the other.
    BNS.Anim.shieldEquipEvents()
    if weapon then brain.weapon = weapon end
    local class = BNS.Anim.weaponClass(brain.weapon)
    local item = nil
    local id = brain.weapon and brain.weapon.item
        and BNS.Loadouts.item(brain.weapon.item)
    if id then item = instanceItem(id) end
    if item and zombie.setPrimaryHandItem then
        pcall(function() zombie:setPrimaryHandItem(item) end)
    end
    -- Always write the off hand, including clearing it: dropping a rifle
    -- for a knife has to let go with the hand that was holding the rifle.
    if zombie.setSecondaryHandItem then
        local off = (item and BNS.Anim.isTwoHanded(item, class)) and item or nil
        pcall(function() zombie:setSecondaryHandItem(off) end)
    end
    BNS.Anim.setWeapon(zombie, brain)
    return item
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
