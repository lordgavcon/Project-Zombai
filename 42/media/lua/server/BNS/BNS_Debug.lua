--***********************************************************************
-- Project Zombai — debug commands (server)
--
-- Backs the in-game debug UI: spawn specific NPCs, force behaviours,
-- inspect world state and run scenario tests on demand, instead of
-- waiting for a 24h raid cooldown or a 5% last-stand roll to happen by
-- itself.
--
-- SECURITY: every command here is re-checked server-side. A multiplayer
-- client can send any sendClientCommand it likes, so the UI's own
-- "am I allowed" check is cosmetic — this gate is the real one. Only
-- debug-mode singleplayer or an actual admin gets through.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Loadouts"
require "BNS/BNS_Anim"
require "BNS/BNS_Archetypes"
require "BNS/BNS_POIs"
require "BNS/BNS_Persistence"
require "BNS/BNS_Spawner"
require "BNS/BNS_Squads"
require "BNS/BNS_Programs"
require "BNS/BNS_Combat"
require "BNS/BNS_Look"
require "BNS/BNS_Bases"
require "BNS/BNS_Raids"
require "BNS/BNS_Locks"
require "BNS/BNS_Vehicles"

BNS.Debug = {}

-- Access -----------------------------------------------------------------

function BNS.Debug.isAllowed(player)
    if not player then return false end
    if type(getDebug) == "function" and getDebug() then return true end
    if player.getAccessLevel then
        local ok, level = pcall(function() return player:getAccessLevel() end)
        if ok and level and level ~= "" and level ~= "None" then return true end
    end
    if player.isAccessLevel then
        local ok, admin = pcall(function() return player:isAccessLevel("admin") end)
        if ok and admin then return true end
    end
    return false
end

local function reply(player, command, args)
    if isServer() then
        sendServerCommand(player, BNS.CommandModule, command, args)
    elseif BNS.Client and BNS.Client.onServerCommand then
        BNS.Client.onServerCommand(BNS.CommandModule, command, args)
    end
end

local function note(player, text)
    BNS.log("debug: " .. text)
    reply(player, "debugResult", { text = text })
end

-- Helpers ----------------------------------------------------------------

local function liveShells()
    local out = {}
    local cell = getCell()
    local list = cell and cell:getZombieList() or nil
    if not list then return out end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if BNS.isNPC(z) then
            local brain = BNS.brain(z)
            if brain then out[brain.id] = z end
        end
    end
    return out
end

local function freeSquareNear(player, minD, maxD)
    for _ = 1, 20 do
        local angle = ZombRandFloat(0, 2 * math.pi)
        local d = ZombRand(minD or 4, (maxD or 10) + 1)
        local x = math.floor(player:getX() + math.cos(angle) * d)
        local y = math.floor(player:getY() + math.sin(angle) * d)
        local sq = getCell():getGridSquare(x, y, math.floor(player:getZ()))
        if sq and sq:isFree(false) then return sq, x, y end
    end
    local sq = player:getCurrentSquare()
    return sq, math.floor(player:getX()), math.floor(player:getY())
end

-- Snapshot ----------------------------------------------------------------

function BNS.Debug.snapshot(player)
    local state = BNS.Persistence.getState()
    local shells = liveShells()
    local px, py = player:getX(), player:getY()

    local npcs, counts = {}, { live = 0, virtual = 0, bandit = 0, survivor = 0, trader = 0 }
    for id, rec in pairs(state.npcs) do
        local shell = shells[id]
        local brain = shell and BNS.brain(shell) or nil
        local x = shell and shell:getX() or rec.x
        local y = shell and shell:getY() or rec.y
        if shell then counts.live = counts.live + 1 else counts.virtual = counts.virtual + 1 end
        counts[rec.role] = (counts[rec.role] or 0) + 1
        table.insert(npcs, {
            id = id,
            name = rec.name,
            role = rec.role,
            tier = rec.tier,
            archetype = rec.archetype,
            program = (brain and brain.program) or rec.program,
            health = (brain and brain.health) or rec.health or 1.0,
            x = math.floor(x), y = math.floor(y),
            dist = math.floor(BNS.dist(px, py, x, y)),
            live = shell ~= nil,
            -- Why a record has no body: standing on ground the game has
            -- not streamed, waiting for a slot, or failing to embody
            -- where it stands. A virtual NPC that is none of these and
            -- stays virtual is the bug this replaced.
            onLoaded = shell == nil and BNS.squareLoaded(x, y, rec.z) or false,
            capped = rec.capped or false,
            wakeFails = rec.wakeFails or 0,
            loot = (brain and brain.loot and #brain.loot) or (rec.loot and #rec.loot) or 0,
            stock = (brain and brain.stock and #brain.stock) or (rec.stock and #rec.stock) or 0,
            vehicle = (brain and brain.vehicle ~= nil) or (rec.vehicle ~= nil),
            squad = rec.squad,
            -- How far this one is from its group. A squad that is doing
            -- its job keeps every member inside BNS.Squads.COHESION.
            fromSquad = (function()
                if not rec.squad then return nil end
                local ax, ay = BNS.Squads.anchor(rec.squad)
                if not ax then return nil end
                return math.floor(BNS.dist(x, y, ax, ay))
            end)(),
            weapon = rec.weapon and rec.weapon.item or nil,
            gun = rec.weapon and rec.weapon.gun or false,
            warned = brain and brain.warned or false,
            ammo = brain and brain.ammo and brain.ammo.left or nil,
            mags = brain and brain.ammo and brain.ammo.spares or nil,
            reloading = brain and brain.reloadTimer ~= nil or false,
            stamina = brain and brain.stamina or nil,
            swing = brain and brain.swingPhase or nil,
            down = brain and BNS.Combat.isDown(brain) or false,
            staggered = brain and BNS.Combat.isStaggered(brain) or false,
            lunges = brain and brain.lunges or 0,
            jams = brain and brain.zJams or 0,
            held = brain and brain.stateLocked or false,
            grabbed = brain and brain.grabbedTimer ~= nil or false,
            door = brain and brain.door ~= nil or false,
            paths = brain and brain.pathCount or 0,
        })
    end
    table.sort(npcs, function(a, b) return a.dist < b.dist end)

    -- Every known POI, fortified or not: the debug UI teleports to any
    -- of them, so an unclaimed one can be visited and then fortified.
    local bases = {}
    for _, poi in ipairs(BNS.POIs) do
        local claimed = state.bases[poi.name] ~= nil
        local garrison = 0
        if claimed then
            for _, rec in pairs(state.npcs) do
                if rec.squad == ("garrison_" .. poi.name) then garrison = garrison + 1 end
            end
        end
        table.insert(bases, {
            name = poi.name, x = poi.x, y = poi.y, z = poi.z or 0,
            dist = math.floor(BNS.dist(px, py, poi.x, poi.y)),
            claimed = claimed, garrison = garrison,
        })
    end
    table.sort(bases, function(a, b) return a.dist < b.dist end)

    local opts = BNS.Options()
    local playerBases = {}
    local now = BNS.worldHours()
    for _, rec in pairs(state.playerBases) do
        if rec.hits >= 6 then
            table.insert(playerBases, {
                x = rec.x, y = rec.y, hits = rec.hits,
                dist = math.floor(BNS.dist(px, py, rec.x, rec.y)),
                raidIn = math.max(0, math.floor((rec.lastRaid or 0) + opts.raidCooldown - now)),
            })
        end
    end

    local log = {}
    local from = math.max(1, #BNS.logBuffer - 40)
    for i = #BNS.logBuffer, from, -1 do
        table.insert(log, BNS.logBuffer[i])
    end

    reply(player, "debugSnapshot", {
        npcs = npcs, counts = counts, bases = bases,
        playerBases = playerBases, options = opts, log = log,
        hours = math.floor(now),
    })
end

-- Actions ------------------------------------------------------------------

-- args = { role, tier, archetype, count }. Returns the ids created, so
-- scenarios can act on exactly what they just spawned (pairs() order
-- over the record table is arbitrary and must never be used for that).
function BNS.Debug.spawnNPC(player, args)
    local count = math.min(args.count or 1, 12)
    local archetype = args.archetype
    local def = BNS.Archetypes.get(archetype)
    local role = args.role or BNS.Role.BANDIT
    local tier = args.tier or (def and def.tier) or BNS.Tier.CIVILIAN
    local squad = count > 1 and ("debug_" .. tostring(ZombRand(100000))) or nil
    local ids = {}

    for _ = 1, count do
        local sq, x, y = freeSquareNear(player, 4, 9)
        local rec = BNS.Persistence.newRecord(role, tier, x, y, math.floor(player:getZ()))
        rec.archetype = archetype
        rec.squad = squad
        rec.weapon = BNS.Spawner.rollWeapon(tier, archetype)
        if role == BNS.Role.TRADER then
            rec.stock = {}
            for _, s in ipairs(BNS.Loadouts.TraderStock) do
                if ZombRand(100) < 60 then
                    table.insert(rec.stock, { item = s.item, value = s.value, count = ZombRand(s.max) + 1 })
                end
            end
        end
        BNS.Spawner.materialise(rec)
        table.insert(ids, rec.id)
    end
    note(player, "spawned " .. count .. " " .. (archetype or role))
    return ids
end

function BNS.Debug.findNPC(id)
    local shells = liveShells()
    return shells[id]
end

function BNS.Debug.forceProgram(player, args)
    local shell = BNS.Debug.findNPC(args.id)
    if not shell then note(player, "NPC not loaded: " .. tostring(args.id)) return end
    local brain = BNS.brain(shell)
    brain.program = args.program
    -- Clear the state a natural transition would have cleared, so the
    -- forced program starts clean.
    brain.warned, brain.warnTimer, brain.intent = nil, nil, nil
    brain.scav, brain.door, brain.raid = nil, nil, nil
    if args.program == BNS.Program.FLEE then brain.fleeUntil = BNS.Programs.FLEE_TICKS end
    if args.program == BNS.Program.SCAVENGE and BNS.Scavenge then
        BNS.Scavenge.tryStart(shell, brain)
    end
    note(player, brain.name .. " -> " .. tostring(args.program))
end

-- Force an animation mode so each AnimSet node can be checked against a
-- live shell. A mode that visibly does nothing means its node is not
-- matching -- wrong clip name, or a condition the shell does not satisfy.
function BNS.Debug.forceAnim(player, args)
    local shell = BNS.Debug.findNPC(args.id)
    if not shell then note(player, "NPC not loaded: " .. tostring(args.id)) return end
    local brain = BNS.brain(shell)
    local mode = args.mode
    if not BNS.Anim.Modes[mode] then note(player, "unknown anim mode: " .. tostring(mode)) return end
    if mode == "swing" or mode == "shoot" or mode == "hit" then
        BNS.Anim.pulse(shell, brain, mode)
    else
        BNS.Anim.set(shell, brain, mode)
    end
    note(player, string.format("%s -> BNSAnim=%s, Weapon=%s (%s)",
        brain.name, mode, tostring(brain.animWeapon),
        brain.weapon and tostring(brain.weapon.item) or "unarmed"))
end

-- Read the live shell rather than guessing at it.
--
-- Two things about the shell can only be learned from a running game,
-- and both have silently broken animation before:
--
--   * which AnimState the shell is actually in -- an AnimNode only
--     competes inside its own state directory, so a node filed under a
--     state the shell never enters can never play. The overlays are
--     generated into every plausible state (tools/gen_animsets.lua); this
--     prints the name the engine reports so the list can be trimmed to
--     the truth.
--   * whether the engine is holding the path we ordered. A shell that
--     will not walk reads identically to one that is never asked to.
--
-- Everything here is a read, and every method is checked for presence
-- before it is called (a pcall on a missing method still dumps a stack
-- trace, so probing is not free).
local function readShell(shell, name)
    if not shell[name] then return nil end
    local ok, value = pcall(function() return shell[name](shell) end)
    if not ok then return "[err]" end
    if value == nil then return "nil" end
    return tostring(value)
end

function BNS.Debug.animProbe(player, args)
    local shell = BNS.Debug.findNPC(args.id)
    if not shell then note(player, "NPC not loaded: " .. tostring(args.id)) return end
    local brain = BNS.brain(shell)

    note(player, string.format("%s: state=%s anim=%s action=%s",
        brain.name,
        readShell(shell, "getCurrentStateName") or "[no getCurrentStateName]",
        readShell(shell, "getAnimationStateName") or "[no getAnimationStateName]",
        readShell(shell, "getActionStateName") or "-"))
    local function handOf(getter)
        if not shell[getter] then return "-" end
        local ok, it = pcall(function() return shell[getter](shell) end)
        if not ok then return "[err]" end
        if not it then return "empty" end
        local okName, name = pcall(function() return it:getFullType() end)
        return okName and tostring(name) or "held"
    end
    -- What the visual says about itself, and what the restyling managed.
    -- "The op did not error" has never been proof anything changed on
    -- screen, and isZombie / rot stage / skin texture are the three the
    -- eye is actually reading.
    if BNS.Look and BNS.Look.describe then
        note(player, "  visual: " .. BNS.Look.describe(shell))
        for _, line in ipairs(BNS.Look.report()) do note(player, "  " .. line) end
    end
    note(player, string.format("  hands: main=%s off=%s",
        handOf("getPrimaryHandItem"), handOf("getSecondaryHandItem")))
    note(player, string.format("  vars: BNSNPC=%s BNSAnim=%s Weapon=%s (brain mode %s)",
        tostring(shell.getVariable and shell:getVariable("BNSNPC")),
        tostring(shell.getVariable and shell:getVariable("BNSAnim")),
        tostring(shell.getVariable and shell:getVariable("Weapon")),
        tostring(brain.animMode)))
    -- Times the shell was caught in a zombie action state (a lunge above
    -- all) with a player close. Should stay at zero: anything else means
    -- the target suppression is losing the race and the player is seeing
    -- zombie behaviour.
    note(player, string.format(
        "  zombie states entered: %d, jammed: %d, machine held: %s (state now: %s)",
        brain.lunges or 0, brain.zJams or 0, tostring(brain.stateLocked == true),
        BNS.Combat.stateName(shell) or "?"))
    note(player, string.format("  path: hasPath=%s moving=%s target=%s,%s orders=%d lost=%d",
        readShell(shell, "hasPath") or "-",
        readShell(shell, "isMoving") or "-",
        readShell(shell, "getPathTargetX") or "-",
        readShell(shell, "getPathTargetY") or "-",
        brain.pathCount or 0, brain.pathLost or 0))

    -- The clip the engine is actually playing. This is the observation
    -- that settles "are they using player animations?" without anyone
    -- having to squint at a bandit: a Bob_* name means a BNS node won,
    -- anything else means the overlays are not being selected. (All
    -- ninety of them once failed to load over an XML comment, and from
    -- the outside that was indistinguishable from them losing.)
    if shell.dbgGetAnimTrackName then
        local tracks = {}
        for i = 0, 3 do
            local ok, name = pcall(function() return shell:dbgGetAnimTrackName(i) end)
            if not ok then
                table.insert(tracks, "[err]")
                break
            end
            if name == nil or tostring(name) == "" then break end
            local weight = "?"
            if shell.dbgGetAnimTrackWeight then
                local okW, w = pcall(function() return shell:dbgGetAnimTrackWeight(i) end)
                if okW and w then weight = string.format("%.2f", w) end
            end
            table.insert(tracks, tostring(name) .. "@" .. weight)
        end
        note(player, "  playing: " .. (#tracks > 0 and table.concat(tracks, ", ")
            or "[no tracks reported]"))
    else
        note(player, "  playing: [no dbgGetAnimTrackName on this build]")
    end

    -- Displacement since the last probe: the only observation that
    -- actually proves the shell is walking.
    local x, y = shell:getX(), shell:getY()
    if brain.probeX then
        note(player, string.format("  moved %.2f tiles since the last probe",
            BNS.dist(x, y, brain.probeX, brain.probeY)))
    else
        note(player, "  probe again in a few seconds to measure movement")
    end
    brain.probeX, brain.probeY = x, y

    note(player, string.format("  suppress: clearTarget=%s useless=%s inactive=%s",
        tostring(BNS.Suppress.clearTarget), tostring(BNS.Suppress.useless),
        tostring(BNS.Suppress.inactive)))
end

-- Flip one of the unverified "calm the shell" engine calls, so whether
-- either is what stops NPCs walking can be answered in game.
function BNS.Debug.setSuppress(player, args)
    local key = args.key
    if BNS.Suppress[key] == nil then
        note(player, "unknown suppression flag: " .. tostring(key))
        return
    end
    BNS.Suppress[key] = not BNS.Suppress[key]
    note(player, "suppress." .. key .. " = " .. tostring(BNS.Suppress[key])
        .. " (applies to shells spawned or ticked from now on)")
end

function BNS.Debug.teleport(player, args)
    local shell = BNS.Debug.findNPC(args.id)
    if not shell then note(player, "NPC not loaded") return end
    if args.bring then
        local sq = freeSquareNear(player, 2, 4)
        if sq then
            shell:setX(sq:getX()); shell:setY(sq:getY()); shell:setZ(sq:getZ())
            shell:setLastX(sq:getX()); shell:setLastY(sq:getY())
            BNS.Persistence.syncFromShell(shell)
        end
        note(player, "brought " .. tostring(args.id) .. " here")
    else
        player:setX(shell:getX() + 1); player:setY(shell:getY())
        player:setZ(shell:getZ())
        player:setLastX(shell:getX() + 1); player:setLastY(shell:getY())
        note(player, "teleported to " .. tostring(args.id))
    end
end

function BNS.Debug.killNPC(player, args)
    local shell = BNS.Debug.findNPC(args.id)
    if shell then
        shell:setHealth(0)
        shell:Kill(player)
    end
    BNS.Persistence.remove(args.id)
    note(player, "killed " .. tostring(args.id))
end

function BNS.Debug.clearNPCs(player)
    local state = BNS.Persistence.getState()
    local n = 0
    for _, shell in pairs(liveShells()) do
        shell:removeFromWorld()
        shell:removeFromSquare()
        n = n + 1
    end
    state.npcs = {}
    note(player, "cleared all NPCs (" .. n .. " live)")
end

function BNS.Debug.launchRaid(player)
    BNS.Raids.launchRaid({ x = math.floor(player:getX()), y = math.floor(player:getY()),
        hits = 999, lastRaid = 0 })
    note(player, "raid launched on your position")
end

function BNS.Debug.claimPOI(player)
    local state = BNS.Persistence.getState()
    local best, bestD = nil, math.huge
    for _, poi in ipairs(BNS.POIs) do
        local d = BNS.dist(player:getX(), player:getY(), poi.x, poi.y)
        if d < bestD and not state.bases[poi.name] then best, bestD = poi, d end
    end
    if not best then note(player, "no unclaimed POI left") return end
    state.bases[best.name] = { name = best.name, x = best.x, y = best.y, z = best.z,
        radius = best.radius, stockedSquares = {} }
    BNS.Bases.createGarrison(state, best)
    note(player, "militia claimed " .. best.name .. " (" .. math.floor(bestD) .. " tiles away)")
    -- Which ground cues this build can actually place. A pool showing
    -- "none of N candidates" is a cue being covered by another pool
    -- rather than appearing; a pool that resolved says which id is real,
    -- so the candidate list in BNS_Signs can be cut down to it.
    if BNS.Signs and BNS.Signs.report then
        for _, line in ipairs(BNS.Signs.report()) do note(player, "  " .. line) end
    end
end

-- Jump to any point of interest by name, fortified or not.
function BNS.Debug.gotoPOI(player, args)
    local target = nil
    for _, poi in ipairs(BNS.POIs) do
        if poi.name == args.name then target = poi break end
    end
    if not target then
        note(player, "unknown POI: " .. tostring(args.name))
        return
    end
    player:setX(target.x)
    player:setY(target.y)
    player:setZ(target.z or 0)
    player:setLastX(target.x)
    player:setLastY(target.y)
    local claimed = BNS.Persistence.getState().bases[target.name] ~= nil
    note(player, "teleported to " .. target.name
        .. (claimed and " (fortified)" or " (unclaimed)"))
end

function BNS.Debug.giveVehicle(player, args)
    local shell = BNS.Debug.findNPC(args.id)
    if not shell then note(player, "NPC not loaded") return end
    local brain = BNS.brain(shell)
    local sq = freeSquareNear(player, 3, 6)
    local vehicle = BNS.Vehicles.spawnVehicle(args.script or "Base.PickUpTruck", sq)
    if not vehicle then note(player, "vehicle spawn failed (addVehicleDebug unavailable)") return end
    if vehicle.getModData then
        vehicle:getModData().BNS_Owner = brain.squad or brain.id
    end
    brain.vehicle = { x = math.floor(vehicle:getX()), y = math.floor(vehicle:getY()),
        script = args.script or "Base.PickUpTruck" }
    BNS.Persistence.syncFromShell(shell)
    note(player, brain.name .. " given a vehicle")
end

-- Ring real zombies around a target to exercise the 4:1 overwhelm rule.
function BNS.Debug.spawnZombies(player, args)
    local count = math.min(args.count or 8, 40)
    local cx, cy, cz = player:getX(), player:getY(), player:getZ()
    local shell = args.id and BNS.Debug.findNPC(args.id) or nil
    if shell then cx, cy, cz = shell:getX(), shell:getY(), shell:getZ() end
    local spawned = 0
    for i = 1, count do
        local angle = (i / count) * 2 * math.pi
        local x = math.floor(cx + math.cos(angle) * 3)
        local y = math.floor(cy + math.sin(angle) * 3)
        local sq = getCell():getGridSquare(x, y, math.floor(cz))
        if sq then
            local list = addZombiesInOutfit(x, y, math.floor(cz), 1, nil, 50)
            if list and list:size() > 0 then spawned = spawned + 1 end
        end
    end
    note(player, "spawned " .. spawned .. " zombies around "
        .. (shell and BNS.brain(shell).name or "you"))
end

-- Drop a stocked container nearby so scavenging has something to find.
function BNS.Debug.spawnLootBox(player)
    local sq = freeSquareNear(player, 3, 6)
    if not sq then note(player, "no free square") return end
    local container = nil
    for i = 0, sq:getObjects():size() - 1 do
        local obj = sq:getObjects():get(i)
        if obj.getContainer and obj:getContainer() then container = obj:getContainer() break end
    end
    if not container then
        local ok = pcall(function()
            sq:AddWorldInventoryItem("Base.Crate", 0.5, 0.5, 0)
        end)
        -- No usable container object: scatter the items instead so the
        -- tester still has something to look at.
        if ok then
            for _, entry in ipairs({ "Base.Antibiotics", "Base.TinnedBeans", "Base.Bullets9mm",
                    "Base.CrumpledPaper", "Base.Spoon", "Base.HuntingKnife" }) do
                sq:AddWorldInventoryItem(entry, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
            end
        end
        note(player, "no container on that square - items scattered at "
            .. sq:getX() .. "," .. sq:getY())
        return
    end
    for _, entry in ipairs({ "Base.Antibiotics", "Base.TinnedBeans", "Base.HuntingKnife",
            "Base.Bullets9mm", "Base.CrumpledPaper", "Base.Spoon", "Base.Plank" }) do
        local id = BNS.Loadouts.item(entry)
        if id then container:AddItem(id) end
    end
    sq:getModData().BNS_Looted = nil
    note(player, "stocked a container at " .. sq:getX() .. "," .. sq:getY())
end

-- Live sandbox override, so toggles can be tested without a restart.
function BNS.Debug.setOption(player, args)
    SandboxVars = SandboxVars or {}
    SandboxVars.BNS = SandboxVars.BNS or {}
    SandboxVars.BNS[args.name] = args.value
    note(player, "option " .. tostring(args.name) .. " = " .. tostring(args.value))
end

-- Scenarios -----------------------------------------------------------------

-- Each scenario stages the situation and says what to watch for; the
-- overlay (program text above heads) shows whether it plays out.
BNS.Debug.Scenarios = {
    -- The two things a person looking at the game can settle that no
    -- offline suite can: is a shell playing player clips, and is it
    -- actually walking.
    animwalk = {
        label = "Human animation + walking",
        watch = "bandit stands with the player idle (not the zombie sway), "
            .. "ambles off on its own, and swings its weapon like a player; "
            .. "if not, select it on the NPCs tab and hit PROBE in the Anim lab",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "thug", count = 1 })
            local shell = ids and ids[1] and BNS.Debug.findNPC(ids[1])
            if shell then
                local brain = BNS.brain(shell)
                brain.program = BNS.Program.WANDER
                brain.restUntil = nil
                BNS.Debug.animProbe(player, { id = ids[1] })
            end
        end,
    },
    firefight = {
        label = "Firefight (magazine + reload)",
        watch = "militia fires in bursts, runs the magazine dry, calls "
            .. "\"reloading\" and breaks contact, then comes back on; out of "
            .. "spares they draw a blade and close",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "exmilitary", count = 1 })
            local shell = ids and ids[1] and BNS.Debug.findNPC(ids[1])
            if not shell then return end
            local brain = BNS.brain(shell)
            -- Guarantee the gun, and a thin belt so the reload and the
            -- run dry both happen inside a minute rather than eventually.
            brain.weapon = { item = "Base.Pistol", dmg = 0.30, range = 10,
                sound = "9mmShot", hit = 45, gun = true }
            brain.backup = BNS.Spawner.rollMelee(brain.tier, brain.archetype)
            brain.ammo = BNS.Combat.gunProfile(brain)
            brain.ammo.mag, brain.ammo.left, brain.ammo.spares = 4, 4, 1
            brain.warned, brain.warnTimer = true, nil
            brain.program = BNS.Program.ATTACK
        end,
    },
    living = {
        label = "Living look + voice",
        watch = "the bandit's skin is a person's, not a corpse's, and they "
            .. "make no zombie noise; PROBE on the Anim lab prints what the "
            .. "visual says about itself and which restyling ops landed",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "cityfolk", count = 2 })
            for _, id in ipairs(ids or {}) do
                local shell = BNS.Debug.findNPC(id)
                if shell then
                    local brain = BNS.brain(shell)
                    brain.program = BNS.Program.WANDER
                    BNS.Look.apply(shell, brain)
                    note(player, "  " .. tostring(brain.name) .. ": "
                        .. BNS.Look.describe(shell))
                end
            end
            for _, line in ipairs(BNS.Look.report()) do note(player, "  " .. line) end
        end,
    },
    stagger = {
        label = "Stagger + always clothed",
        watch = "hit them: a solid one knocks them off their beat, takes "
            .. "the swing they were part way through and buys you the next "
            .. "hit. PROBE reports worn= for what they have on -- it should "
            .. "never be 0",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "thug", count = 2 })
            for _, id in ipairs(ids or {}) do
                local shell = BNS.Debug.findNPC(id)
                if shell then
                    local brain = BNS.brain(shell)
                    brain.warned, brain.warnTimer = true, nil
                    brain.program = BNS.Program.ATTACK
                    note(player, "  " .. tostring(brain.name) .. ": "
                        .. BNS.Look.describe(shell))
                end
            end
            note(player, string.format(
                "every tier plays by the same rules now: rob %d%%, break off "
                    .. "below %d%% health, %d%% stand their ground, %d damage a bash",
                BNS.Behaviour.robChance,
                math.floor(BNS.Behaviour.fleeHealth * 100),
                BNS.Behaviour.standChance, BNS.Behaviour.bashDamage))
        end,
    },
    squads = {
        label = "Squad cohesion",
        watch = "every bandit group, its spread, and anyone who has "
            .. "wandered further than the cohesion distance from it. A "
            .. "member out past it should be walking back, not away",
        run = function(player)
            local state = BNS.Persistence.getState()
            local groups = {}
            for _, rec in pairs(state.npcs) do
                if rec.squad and BNS.Squads.get(rec.squad) then
                    local g = groups[rec.squad] or { n = 0, out = 0, worst = 0, live = 0 }
                    local ax, ay = BNS.Squads.anchor(rec.squad)
                    local d = BNS.dist(rec.x, rec.y, ax, ay)
                    g.n = g.n + 1
                    if rec.live then g.live = g.live + 1 end
                    if d > BNS.Squads.COHESION then g.out = g.out + 1 end
                    g.worst = math.max(g.worst, d)
                    groups[rec.squad] = g
                end
            end
            local names = {}
            for id in pairs(groups) do table.insert(names, id) end
            table.sort(names)
            if #names == 0 then note(player, "no managed squads right now") return end
            for _, id in ipairs(names) do
                local g = groups[id]
                note(player, string.format(
                    "%s: %d members (%d live), furthest %d tiles out, %d beyond %d",
                    id, g.n, g.live, math.floor(g.worst), g.out, BNS.Squads.COHESION))
            end
        end,
    },
    virtual = {
        label = "Virtual boundary",
        watch = "every NPC out there and why it has or has not got a body. "
            .. "Walk towards a [virtual] one: it should become live as soon "
            .. "as its square streams in, and go back to [virtual] behind you",
        run = function(player)
            local state = BNS.Persistence.getState()
            local live, waiting, offmap, capped = 0, 0, 0, 0
            for _, rec in pairs(state.npcs) do
                if rec.live then live = live + 1
                elseif rec.capped then capped = capped + 1
                elseif BNS.squareLoaded(rec.x, rec.y, rec.z) then waiting = waiting + 1
                else offmap = offmap + 1 end
            end
            note(player, string.format(
                "%d live, %d off the loaded map, %d on loaded ground waiting to embody, "
                    .. "%d held back by the cap (ceiling %d)",
                live, offmap, waiting, capped, BNS.recordCeiling()))
            note(player, "a record on loaded ground should not stay waiting: "
                .. "that is the failure this boundary replaced")
        end,
    },
    standoff = {
        label = "Melee standoff (hostile vs neutral)",
        watch = "stand right against each of them. The bandit swings at "
            .. "you; the survivor just stands there. Neither lunges, and "
            .. "neither gets stuck in one -- PROBE should show 0 jammed",
        run = function(player)
            BNS.Debug.spawnNPC(player, { archetype = "thug", count = 1 })
            local ids = BNS.Debug.spawnNPC(player, { role = BNS.Role.SURVIVOR, count = 1 })
            for _, id in ipairs(ids or {}) do
                local shell = BNS.Debug.findNPC(id)
                if shell then
                    local brain = BNS.brain(shell)
                    brain.program = BNS.Program.TRADE
                    note(player, "  " .. tostring(brain.name) .. " is a survivor: "
                        .. "hostile=" .. tostring(BNS.isHostile(brain)))
                end
            end
        end,
    },
    muzzle = {
        label = "Walk into a gunner's muzzle",
        watch = "get right up against them: they shove you off and bring "
            .. "the gun back up rather than lunging at you like a zombie. "
            .. "PROBE should show zero zombie states entered",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "police", count = 1 })
            local shell = ids and ids[1] and BNS.Debug.findNPC(ids[1])
            if not shell then return end
            local brain = BNS.brain(shell)
            brain.weapon = { item = "Base.Pistol", dmg = 0.30, range = 10,
                sound = "9mmShot", hit = 45, gun = true }
            brain.backup = BNS.Spawner.rollMelee(brain.tier, brain.archetype)
            brain.ammo = BNS.Combat.gunProfile(brain)
            brain.warned, brain.warnTimer = true, nil
            brain.program = BNS.Program.ATTACK
            BNS.Anim.equip(shell, brain)
        end,
    },
    shove = {
        label = "Shove + stomp",
        watch = "shoving the bandit puts them on the floor and costs them "
            .. "no health at all; they stop swinging until they are up. "
            .. "Health only moves when you stomp or swing at them down there",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "thug", count = 1 })
            local shell = ids and ids[1] and BNS.Debug.findNPC(ids[1])
            if not shell then return end
            local brain = BNS.brain(shell)
            brain.weapon = { item = "Base.BaseballBat", dmg = 0.16, range = 1.4, gun = false }
            brain.warned, brain.warnTimer = true, nil
            brain.program = BNS.Program.ATTACK
            note(player, string.format("%s at %d%% health -- watch the NPCs tab",
                brain.name, math.floor((brain.health or 1) * 100)))
        end,
    },
    duel = {
        label = "Melee duel (windup + recovery)",
        watch = "the axe comes up before it comes down -- step back during "
            .. "the windup and it whiffs, and the whiff leaves a longer "
            .. "opening than a hit does; they tire and give ground",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "firefighter", count = 1 })
            local shell = ids and ids[1] and BNS.Debug.findNPC(ids[1])
            if not shell then return end
            local brain = BNS.brain(shell)
            brain.weapon = { item = "Base.Axe", dmg = 0.24, range = 1.3, gun = false }
            brain.warned, brain.warnTimer = true, nil
            brain.program = BNS.Program.ATTACK
        end,
    },
    warning = {
        label = "Warning shot + 4s hold",
        watch = "militia fires one round past you, holds aim 4s, then engages",
        run = function(player)
            BNS.Debug.spawnNPC(player, { archetype = "exmilitary", count = 1 })
        end,
    },
    robbery = {
        label = "Robbery",
        watch = "civilian demands your items, takes some, then flees",
        run = function(player)
            BNS.Debug.setOption(player, { name = "RobberyEnabled", value = true })
            BNS.Debug.spawnNPC(player, { archetype = "cityfolk", count = 1 })
        end,
    },
    doors = {
        label = "Door rattle + open",
        watch = "bandit rattles an unlocked door ~3s before it opens",
        run = function(player)
            BNS.Debug.spawnNPC(player, { archetype = "thug", count = 1 })
        end,
    },
    lockbash = {
        label = "Locked door bash",
        watch = "bandit bashes a locked door; damage scales with door strength",
        run = function(player)
            player:getInventory():AddItem(BNS.Locks.PADLOCK_FULL)
            BNS.Debug.spawnNPC(player, { archetype = "exmilitary", count = 2 })
        end,
    },
    overwhelm = {
        label = "Zombie overwhelm (4:1)",
        watch = "NPC fights, then flees when zombies outnumber 4:1 (rare last stand)",
        run = function(player)
            local ids = BNS.Debug.spawnNPC(player, { archetype = "cityfolk", count = 1 })
            BNS.Debug.spawnZombies(player, { id = ids[1], count = 8 })
        end,
    },
    scavenge = {
        label = "Scavenge + evidence",
        watch = "NPC rifles the container, takes valuables, junk left on the floor",
        run = function(player)
            BNS.Debug.setOption(player, { name = "ScavengingEnabled", value = true })
            BNS.Debug.spawnLootBox(player)
            BNS.Debug.spawnNPC(player, { role = BNS.Role.SURVIVOR, count = 1 })
        end,
    },
    trade = {
        label = "Trader barter",
        watch = "right-click the trader for Trade; offer items against their stock",
        run = function(player)
            BNS.Debug.spawnNPC(player, { role = BNS.Role.TRADER, count = 1 })
        end,
    },
    vehicle = {
        label = "Vehicle haul",
        watch = "NPC fills its pack, walks to its vehicle and loads the trunk",
        run = function(player)
            BNS.Debug.setOption(player, { name = "NPCVehiclesEnabled", value = true })
            local ids = BNS.Debug.spawnNPC(player, { role = BNS.Role.SURVIVOR, count = 1 })
            BNS.Debug.giveVehicle(player, { id = ids[1] })
            BNS.Debug.spawnLootBox(player)
        end,
    },
    raid = {
        label = "Base raid (+ convoy)",
        watch = "squad marches in, smashes and steals, may load a truck and withdraw",
        run = function(player) BNS.Debug.launchRaid(player) end,
    },
    poi = {
        label = "Fortify nearest POI",
        watch = "nearest point of interest gets a militia garrison and supplies",
        run = function(player) BNS.Debug.claimPOI(player) end,
    },
    poisigns = {
        label = "POI in-world cues",
        watch = "casings and rags on the approach, camp noise, a shouted challenge before anyone fires",
        run = function(player)
            BNS.Debug.setOption(player, { name = "POISignsEnabled", value = true })
            BNS.Debug.claimPOI(player)
        end,
    },
}

function BNS.Debug.runScenario(player, args)
    local sc = BNS.Debug.Scenarios[args.name]
    if not sc then note(player, "unknown scenario: " .. tostring(args.name)) return end
    sc.run(player)
    note(player, sc.label .. " -- watch for: " .. sc.watch)
end

-- Dispatch -------------------------------------------------------------------

local HANDLERS = {
    debugSnapshot = function(p) BNS.Debug.snapshot(p) end,
    debugSpawn    = BNS.Debug.spawnNPC,
    debugProgram  = BNS.Debug.forceProgram,
    debugAnim     = BNS.Debug.forceAnim,
    debugAnimProbe = BNS.Debug.animProbe,
    debugSuppress = BNS.Debug.setSuppress,
    debugTeleport = BNS.Debug.teleport,
    debugKill     = BNS.Debug.killNPC,
    debugClear    = function(p) BNS.Debug.clearNPCs(p) end,
    debugRaid     = function(p) BNS.Debug.launchRaid(p) end,
    debugPOI      = function(p) BNS.Debug.claimPOI(p) end,
    debugGotoPOI  = BNS.Debug.gotoPOI,
    debugVehicle  = BNS.Debug.giveVehicle,
    debugZombies  = BNS.Debug.spawnZombies,
    debugLootBox  = function(p) BNS.Debug.spawnLootBox(p) end,
    debugOption   = BNS.Debug.setOption,
    debugScenario = BNS.Debug.runScenario,
}

function BNS.Debug.handle(command, player, args)
    local handler = HANDLERS[command]
    if not handler then return false end
    -- The real gate: never trust the client's own permission check.
    if not BNS.Debug.isAllowed(player) then
        BNS.log("refused debug command '" .. tostring(command) .. "' from "
            .. tostring(player and player:getUsername() or "?"))
        return true
    end
    handler(player, args or {})
    return true
end
