--***********************************************************************
-- Project Zombai — NPC vehicles (server)
--
-- NPCs claim parked vehicles, haul scavenged loot into their real
-- trunks, and use them to travel. IsoZombie shells can't run vehicle
-- physics, so there is deliberately no fake driving near players:
-- vehicle travel happens through the live/virtual layer (an NPC that
-- despawns next to its vehicle takes it along and moves at driving
-- speed while unloaded, the vehicle reappearing parked where they
-- surface), and near players NPCs are seen parked, walking to, or
-- loading their vehicle. Trunks are genuine containers — players can
-- raid them or steal the whole vehicle, loot and all.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"
require "BNS/BNS_Anim"
require "BNS/BNS_Programs"
require "BNS/BNS_Scavenge"

BNS.Vehicles = {}

local CLAIM_RADIUS  = 20  -- tiles: how far an NPC looks for a vehicle
local ABOARD_RANGE  = 5   -- tiles: this close to the vehicle = travelling with it
local TRUNK_CAP     = 40  -- items the NPCs will stack into one trunk
local FALLBACK_CAR  = "Base.CarNormal"

-- The tag written into a vehicle's mod data: squads share their convoy.
local function ownerTag(brain)
    return brain.squad or brain.id
end

-- Guarded engine access ---------------------------------------------------

function BNS.Vehicles.getTrunk(vehicle)
    if not vehicle or not vehicle.getPartById then return nil end
    local ok, part = pcall(function() return vehicle:getPartById("TruckBed") end)
    if not ok or not part or not part.getItemContainer then return nil end
    local ok2, container = pcall(function() return part:getItemContainer() end)
    if ok2 then return container end
    return nil
end

local function scriptNameOf(vehicle)
    if vehicle.getScriptName then
        local ok, name = pcall(function() return vehicle:getScriptName() end)
        if ok and name then return name end
    end
    return FALLBACK_CAR
end

local function vehicleList()
    local cell = getCell()
    if not cell or not cell.getVehicles then return nil end
    local ok, list = pcall(function() return cell:getVehicles() end)
    if ok then return list end
    return nil
end

function BNS.Vehicles.spawnVehicle(script, sq)
    if not sq or type(addVehicleDebug) ~= "function" then return nil end
    local ok, vehicle = pcall(function()
        local dir = IsoDirections and IsoDirections.S or nil
        return addVehicleDebug(script or FALLBACK_CAR, dir, nil, sq)
    end)
    if ok then return vehicle end
    return nil
end

-- Claiming -----------------------------------------------------------------

local function isClaimable(vehicle)
    local md = vehicle.getModData and vehicle:getModData() or nil
    if md and md.BNS_Owner then return false end
    -- Skip obvious wrecks; anything the engine can't answer for passes.
    if vehicle.isEngineWorking then
        local ok, working = pcall(function() return vehicle:isEngineWorking() end)
        if ok and working == false then return false end
    end
    return true
end

-- The vehicle this brain (or its squad) owns, near a position.
function BNS.Vehicles.findOwned(brain, x, y, radius)
    local list = vehicleList()
    if not list then return nil end
    local tag = ownerTag(brain)
    for i = 0, list:size() - 1 do
        local v = list:get(i)
        local md = v and v.getModData and v:getModData() or nil
        if md and md.BNS_Owner == tag
                and BNS.dist(x, y, v:getX(), v:getY()) <= (radius or 40) then
            return v
        end
    end
    return nil
end

-- Claim a nearby parked vehicle. Player driveways are off limits (same
-- base-exclusion rule as scavenging).
function BNS.Vehicles.tryClaim(zombie, brain)
    if not BNS.Options().vehicles then return false end
    if brain.vehicle then return true end
    local list = vehicleList()
    if not list then return false end
    local x, y = zombie:getX(), zombie:getY()
    for i = 0, list:size() - 1 do
        local v = list:get(i)
        if v and BNS.dist(x, y, v:getX(), v:getY()) <= CLAIM_RADIUS
                and isClaimable(v)
                and not BNS.Scavenge.isNearPlayerBase(v:getX(), v:getY()) then
            if v.getModData then v:getModData().BNS_Owner = ownerTag(brain) end
            brain.vehicle = {
                x = math.floor(v:getX()),
                y = math.floor(v:getY()),
                script = scriptNameOf(v),
            }
            BNS.log("NPC " .. brain.id .. " claimed vehicle " .. brain.vehicle.script)
            return true
        end
    end
    return false
end

-- Hauling ------------------------------------------------------------------

-- Empty the NPC's pack into the trunk (or, if the trunk API is
-- unavailable, into a pile beside the vehicle).
function BNS.Vehicles.stow(zombie, brain, vehicle)
    if not brain.loot then return end
    local trunk = BNS.Vehicles.getTrunk(vehicle)
    local sq = zombie:getCurrentSquare()
    for i = #brain.loot, 1, -1 do
        local fullType = brain.loot[i]
        if trunk and trunk:getItems():size() < TRUNK_CAP then
            trunk:AddItem(fullType)
            table.remove(brain.loot, i)
        elseif not trunk and sq then
            sq:AddWorldInventoryItem(fullType, 0.5, 0.5, 0)
            table.remove(brain.loot, i)
        else
            break -- trunk full: keep the rest in the pack
        end
    end
    zombie:playSound("VehicleTrunkCloseGeneric")
end

BNS.Programs[BNS.Program.HAUL] = function(zombie, brain, ctx)
    local vinfo = brain.vehicle
    if not vinfo or not brain.loot or #brain.loot == 0 then
        brain.program = brain.postHaul or BNS.Program.WANDER
        brain.postHaul = nil
        return
    end
    if BNS.dist(zombie:getX(), zombie:getY(), vinfo.x, vinfo.y) > 2 then
        BNS.Programs.walkTo(zombie, vinfo.x, vinfo.y, 0, false)
        return
    end
    BNS.Anim.set(zombie, brain, "idle")
    local vehicle = BNS.Vehicles.findOwned(brain, zombie:getX(), zombie:getY(), 10)
    BNS.Vehicles.stow(zombie, brain, vehicle)
    brain.program = brain.postHaul or BNS.Program.WANDER
    brain.postHaul = nil
end

-- Called by BNS_Scavenge when a pack fills: head for the vehicle if one
-- is claimed and in reach, else try to claim one on the spot.
function BNS.Vehicles.wantsHaul(zombie, brain)
    if not BNS.Options().vehicles then return false end
    if not brain.loot or #brain.loot < BNS.Scavenge.PACK_CAP then return false end
    if not brain.vehicle then BNS.Vehicles.tryClaim(zombie, brain) end
    local vinfo = brain.vehicle
    if not vinfo then return false end
    if BNS.dist(zombie:getX(), zombie:getY(), vinfo.x, vinfo.y) > 60 then return false end
    brain.program = BNS.Program.HAUL
    return true
end

-- Live/virtual boundary ----------------------------------------------------

-- On dematerialise: an NPC standing at its vehicle takes it along —
-- trunk contents are mirrored into the record and the world vehicle is
-- removed, to reappear wherever the NPC surfaces. Otherwise the vehicle
-- stays parked where it was left.
function BNS.Vehicles.onDematerialise(zombie, brain, rec)
    if not brain.vehicle then return end
    rec.vehicle = brain.vehicle
    local vehicle = BNS.Vehicles.findOwned(brain, zombie:getX(), zombie:getY(), CLAIM_RADIUS)
    if not vehicle then
        rec.aboard = false
        return
    end
    rec.vehicle.x = math.floor(vehicle:getX())
    rec.vehicle.y = math.floor(vehicle:getY())
    if BNS.dist(zombie:getX(), zombie:getY(), vehicle:getX(), vehicle:getY()) > ABOARD_RANGE then
        rec.aboard = false
        return
    end
    -- Aboard: record the trunk and take the vehicle off the map.
    local trunk = BNS.Vehicles.getTrunk(vehicle)
    if trunk then
        rec.trunk = {}
        local items = trunk:getItems()
        for i = 0, items:size() - 1 do
            table.insert(rec.trunk, items:get(i):getFullType())
        end
    end
    if vehicle.permanentlyRemove then
        pcall(function() vehicle:permanentlyRemove() end)
    end
    rec.aboard = true
end

-- On materialise: put the vehicle back — the still-parked one if it's
-- around, otherwise respawn it beside the NPC with the trunk refilled.
function BNS.Vehicles.onMaterialise(zombie, brain, rec)
    if not rec.vehicle then return end
    brain.vehicle = rec.vehicle
    local vehicle = BNS.Vehicles.findOwned(brain, rec.vehicle.x, rec.vehicle.y, CLAIM_RADIUS)
    if not vehicle and rec.aboard then
        vehicle = BNS.Vehicles.spawnVehicle(rec.vehicle.script, zombie:getCurrentSquare())
        if vehicle then
            if vehicle.getModData then vehicle:getModData().BNS_Owner = ownerTag(brain) end
            local trunk = BNS.Vehicles.getTrunk(vehicle)
            if trunk and rec.trunk then
                for _, fullType in ipairs(rec.trunk) do trunk:AddItem(fullType) end
            end
            rec.trunk = nil
        end
    end
    if vehicle then
        brain.vehicle.x = math.floor(vehicle:getX())
        brain.vehicle.y = math.floor(vehicle:getY())
    end
end
