--***********************************************************************
-- Project Zombai — visual state broadcast (server)
--
-- NPC bodies are IsoZombie puppets: they path, collide, take damage and
-- replicate to multiplayer clients for free. What players actually see
-- is a client-side IsoPlayer proxy (BNS_Body.lua) mirroring the puppet,
-- which is how bandits get real player animation and appearance.
--
-- This module is the wire between them. Clients cannot read a puppet's
-- brain (mod data is not replicated), so the server tells them which
-- zombies are NPCs, what they look like, and what they are doing.
-- Sustained state goes out at a few hertz and delta-encoded; one-shot
-- actions (a swing, a shot) are pushed the moment they happen.
--***********************************************************************

if isClient() then return end

require "BNS/BNS_Core"

BNS.Visual = {}

local RANGE      = 60 -- tiles: only NPCs this close to a player are drawn
local SNAP_TICKS = 12 -- engine ticks between snapshots (~5Hz)

-- What each viewer was last told, so unchanged NPCs cost nothing.
-- player username -> npc id -> compact row
local lastSent = {}
local tickCounter = 0

local function rowFor(zombie, brain)
    return {
        id = brain.id,
        oid = zombie:getOnlineID(),
        x = zombie:getX(),
        y = zombie:getY(),
        z = zombie:getZ(),
        dir = tostring(zombie:getDir()),
        anim = brain.animMode or "idle",
        weapon = brain.weapon and brain.weapon.item or nil,
        look = brain.look,
        hp = brain.health or 1.0,
    }
end

-- Only fields that actually moved/changed are worth sending.
local function delta(prev, row)
    if not prev then return row end
    local out, changed = { id = row.id, oid = row.oid }, false
    for _, key in ipairs({ "x", "y", "z", "dir", "anim", "weapon", "hp" }) do
        if prev[key] ~= row[key] then
            out[key] = row[key]
            changed = true
        end
    end
    -- Appearance is sent once; it never changes for a given NPC.
    if prev.look == nil and row.look then
        out.look = row.look
        changed = true
    end
    if not changed then return nil end
    return out
end

local function liveNPCs()
    local out = {}
    local cell = getCell()
    local list = cell and cell:getZombieList() or nil
    if not list then return out end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if BNS.isNPC(z) and not z:isDead() then
            local brain = BNS.brain(z)
            if brain then table.insert(out, { zombie = z, brain = brain }) end
        end
    end
    return out
end

local function send(player, command, args)
    if isServer() then
        sendServerCommand(player, BNS.CommandModule, command, args)
    elseif BNS.Client and BNS.Client.onServerCommand then
        BNS.Client.onServerCommand(BNS.CommandModule, command, args)
    end
end

-- Build and send one viewer's update.
function BNS.Visual.sendTo(player, npcs)
    local key = player:getUsername() or "player"
    lastSent[key] = lastSent[key] or {}
    local sentToThis = lastSent[key]

    local rows, seen = {}, {}
    local px, py = player:getX(), player:getY()
    for _, entry in ipairs(npcs) do
        local z = entry.zombie
        if BNS.dist(px, py, z:getX(), z:getY()) <= RANGE then
            local row = rowFor(z, entry.brain)
            seen[row.id] = true
            local d = delta(sentToThis[row.id], row)
            if d then table.insert(rows, d) end
            sentToThis[row.id] = row
        end
    end

    -- Anything previously drawn that is gone or out of range.
    local gone = {}
    for id, _ in pairs(sentToThis) do
        if not seen[id] then
            table.insert(gone, id)
            sentToThis[id] = nil
        end
    end

    if #rows > 0 or #gone > 0 then
        send(player, "npcVisual", { rows = rows, gone = gone })
    end
end

-- Called every engine tick from BNS_Brain; throttles itself.
function BNS.Visual.tick()
    if not BNS.Options().playerBodies then return end
    tickCounter = tickCounter + 1
    if tickCounter % SNAP_TICKS ~= 0 then return end

    local players = BNS.getPlayers()
    if #players == 0 then return end
    local npcs = liveNPCs()
    for _, player in ipairs(players) do
        BNS.Visual.sendTo(player, npcs)
    end
end

-- One-shot action (swing / shoot / hit / grabbed): pushed immediately so
-- attacks look responsive rather than waiting for the next snapshot.
function BNS.Visual.pulse(brain, action)
    if not BNS.Options().playerBodies then return end
    if not brain or not brain.id then return end
    local args = { id = brain.id, action = action }
    if isServer() then
        sendServerCommand(BNS.CommandModule, "npcAnim", args)
    elseif BNS.Client and BNS.Client.onServerCommand then
        BNS.Client.onServerCommand(BNS.CommandModule, "npcAnim", args)
    end
end

-- A viewer who logs out (or an NPC wipe) should not leave stale memory.
function BNS.Visual.forget(id)
    for _, sent in pairs(lastSent) do sent[id] = nil end
end

function BNS.Visual.reset()
    lastSent = {}
    tickCounter = 0
end
