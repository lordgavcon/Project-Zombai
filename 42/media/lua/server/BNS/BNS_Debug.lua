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
require "BNS/BNS_Archetypes"
require "BNS/BNS_POIs"
require "BNS/BNS_Persistence"
require "BNS/BNS_Spawner"
require "BNS/BNS_Programs"
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
            loot = (brain and brain.loot and #brain.loot) or (rec.loot and #rec.loot) or 0,
            stock = (brain and brain.stock and #brain.stock) or (rec.stock and #rec.stock) or 0,
            vehicle = (brain and brain.vehicle ~= nil) or (rec.vehicle ~= nil),
            squad = rec.squad,
            weapon = rec.weapon and rec.weapon.item or nil,
            gun = rec.weapon and rec.weapon.gun or false,
            warned = brain and brain.warned or false,
            grabbed = brain and brain.grabbedTimer ~= nil or false,
            door = brain and brain.door ~= nil or false,
        })
    end
    table.sort(npcs, function(a, b) return a.dist < b.dist end)

    local bases = {}
    for name, base in pairs(state.bases) do
        table.insert(bases, { name = name, x = base.x, y = base.y,
            dist = math.floor(BNS.dist(px, py, base.x, base.y)) })
    end

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
    if args.program == BNS.Program.FLEE then brain.fleeUntil = 600 end
    if args.program == BNS.Program.SCAVENGE and BNS.Scavenge then
        BNS.Scavenge.tryStart(shell, brain)
    end
    note(player, brain.name .. " -> " .. tostring(args.program))
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
        container:AddItem(entry)
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
    warning = {
        label = "Warning shout + first-shot miss",
        watch = "militia shouts, aims ~2.5s, opening shot usually misses",
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
    debugTeleport = BNS.Debug.teleport,
    debugKill     = BNS.Debug.killNPC,
    debugClear    = function(p) BNS.Debug.clearNPCs(p) end,
    debugRaid     = function(p) BNS.Debug.launchRaid(p) end,
    debugPOI      = function(p) BNS.Debug.claimPOI(p) end,
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
