--***********************************************************************
-- Project Zombai — player bodies (client)
--
-- Bandits are IsoZombie puppets under the hood: the engine paths them,
-- collides them, damages them and replicates them to every client. That
-- is what makes the mod work in multiplayer, and it is not negotiable.
-- But a zombie can only ever animate like a zombie.
--
-- So the puppet is hidden and what you actually see is an IsoPlayer
-- proxy mirroring it. Because the proxy is a real player character,
-- its animation comes from the player state machine for free: hand it
-- the weapon and the swing is that weapon's own animation, move it and
-- it walks and runs like a player, and it wears player skin and hair.
--
-- Everything the engine might not support on a given build is guarded.
-- If proxies or puppet-hiding do not work, the whole layer switches off
-- and the old shell rendering (AnimSet overlays) carries on — you never
-- get a player body and a zombie drawn on top of each other.
--***********************************************************************

require "BNS/BNS_Core"

BNS.Body = {}

BNS.Body.proxies = {}     -- npc id -> { proxy, row, tx, ty, weapon }
BNS.Body.supported = nil  -- nil = untested, true/false once known
BNS.Body.hideFn = nil     -- the puppet-hiding call that worked here
BNS.Body.lastError = nil

local LERP = 0.35 -- how fast a proxy catches up to its puppet per tick

-- Candidate engine calls -------------------------------------------------
--
-- The exact B42.20 names for hiding a character and for driving player
-- attack/aim animation cannot be verified outside the game. Each action
-- lists the plausible calls in order; the debug panel's animation lab
-- steps through them in-game so the working one can be pinned here.

BNS.Body.HideCandidates = {
    { name = "setAlphaAndTarget(0)", apply = function(z) z:setAlphaAndTarget(0) end },
    { name = "setInvisible(true)",   apply = function(z) z:setInvisible(true) end },
    { name = "setModelVisible(false)", apply = function(z) z:setModelVisible(false) end },
}

BNS.Body.ActionCandidates = {
    swing = {
        { name = "var StartedAttack", apply = function(p) p:setVariable("StartedAttack", "true") end },
        { name = "var bAttacking",    apply = function(p) p:setVariable("bAttacking", "true") end },
        { name = "playAnim Attack",   apply = function(p) p:playAnimation("Attack") end },
        { name = "DoAttack",          apply = function(p) p:DoAttack(1) end },
    },
    shoot = {
        { name = "aim+StartedAttack", apply = function(p)
            p:setVariable("isAiming", "true"); p:setVariable("StartedAttack", "true") end },
        { name = "var bShooting",     apply = function(p) p:setVariable("bShooting", "true") end },
        { name = "playAnim Fire",     apply = function(p) p:playAnimation("Fire") end },
    },
    hit = {
        { name = "var HitReaction",   apply = function(p) p:setVariable("HitReaction", "true") end },
        { name = "playAnim HitReaction", apply = function(p) p:playAnimation("HitReaction") end },
    },
    grabbed = {
        { name = "var bGrabbed",      apply = function(p) p:setVariable("bGrabbed", "true") end },
        { name = "playAnim Grabbed",  apply = function(p) p:playAnimation("Grabbed") end },
    },
}

-- Which candidate is currently in use per action (1-based).
BNS.Body.chosen = { swing = 1, shoot = 1, hit = 1, grabbed = 1 }

local function enabled()
    local sv = SandboxVars and SandboxVars.BNS
    if sv and sv.PlayerBodiesEnabled == false then return false end
    return BNS.Body.supported ~= false
end

local function disable(reason)
    BNS.Body.supported = false
    BNS.Body.lastError = reason
    BNS.log("player bodies unavailable (" .. tostring(reason) .. "); using shell rendering")
    BNS.Body.clearAll()
end

-- Puppet lookup ------------------------------------------------------------

-- Clients cannot read a puppet's brain, so NPCs are matched by the
-- online id the server sends with each row.
function BNS.Body.findPuppet(oid)
    local cell = getCell()
    local list = cell and cell:getZombieList() or nil
    if not list or not oid then return nil end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z:getOnlineID() == oid then return z end
    end
    return nil
end

-- Hide the puppet, learning which call this build supports. Returns
-- false if none of them work, which disables the whole layer.
function BNS.Body.hidePuppet(zombie)
    if not zombie then return true end
    if BNS.Body.hideFn then
        pcall(function() BNS.Body.hideFn.apply(zombie) end)
        return true
    end
    for _, candidate in ipairs(BNS.Body.HideCandidates) do
        local ok = pcall(function() candidate.apply(zombie) end)
        if ok then
            BNS.Body.hideFn = candidate
            BNS.log("hiding puppets with " .. candidate.name)
            return true
        end
    end
    return false
end

-- Proxy construction ---------------------------------------------------------

local function buildDescriptor(look)
    local desc = SurvivorFactory.CreateSurvivor()
    if not desc or not look then return desc end
    pcall(function() desc:setFemale(look.female == true) end)
    pcall(function()
        local visual = desc:getHumanVisual()
        if not visual then return end
        if look.skin then visual:setSkinTextureIndex(look.skin) end
        if look.hair then visual:setHairModel(look.hair) end
        if look.beard and look.female ~= true then visual:setBeardModel(look.beard) end
    end)
    return desc
end

local function neutralise(proxy)
    -- A proxy must never behave like a player: it takes no damage, blocks
    -- nothing, and never appears in player lists. Attacks pass through it
    -- to the puppet underneath, which owns health and the brain.
    for _, fn in ipairs({
        function() proxy:setGodMod(true) end,
        function() proxy:setInvincible(true) end,
        function() proxy:setGhostMode(true) end,
        function() proxy:setNoClip(true) end,
        function() proxy:setSceneCulled(false) end,
        function() proxy:setInvisible(false) end,
    }) do
        pcall(fn)
    end
end

function BNS.Body.createProxy(row)
    local cell = getCell()
    if not cell then return nil end
    local ok, proxy = pcall(function()
        local desc = buildDescriptor(row.look)
        return IsoPlayer.new(cell, desc, row.x, row.y, row.z or 0)
    end)
    if not ok or not proxy then
        disable("IsoPlayer.new failed")
        return nil
    end
    neutralise(proxy)
    if row.look and row.look.outfit then
        pcall(function() proxy:dressInNamedOutfit(row.look.outfit) end)
        pcall(function() proxy:resetModelNextFrame() end)
    end
    return proxy
end

-- Weapon in hand is what makes swings weapon-correct: the player
-- animation system picks the attack from the item's own script.
local function equip(entry, fullType)
    if entry.weapon == fullType then return end
    entry.weapon = fullType
    pcall(function()
        if not fullType then
            entry.proxy:setPrimaryHandItem(nil)
            return
        end
        local item = instanceItem(fullType)
        if item then
            entry.proxy:setPrimaryHandItem(item)
            if item.isTwoHandWeapon and item:isTwoHandWeapon() then
                entry.proxy:setSecondaryHandItem(item)
            end
        end
    end)
end

-- Server messages ---------------------------------------------------------------

function BNS.Body.onVisual(args)
    if not enabled() or not args then return end
    for _, row in ipairs(args.rows or {}) do
        BNS.Body.applyRow(row)
        if BNS.Body.supported == false then return end
    end
    for _, id in ipairs(args.gone or {}) do
        BNS.Body.remove(id)
    end
end

function BNS.Body.applyRow(row)
    local entry = BNS.Body.proxies[row.id]
    if not entry then
        -- Prove we can hide the puppet before drawing anything on top of
        -- it: a player body over a visible zombie is worse than neither.
        local puppet = BNS.Body.findPuppet(row.oid)
        if not BNS.Body.hidePuppet(puppet) then
            disable("cannot hide puppets")
            return
        end
        local proxy = BNS.Body.createProxy(row)
        if not proxy then return end
        entry = { proxy = proxy, row = {}, tx = row.x, ty = row.y, puppetOid = row.oid }
        BNS.Body.proxies[row.id] = entry
    end

    -- Rows are deltas: merge what arrived onto what we already knew.
    for key, value in pairs(row) do entry.row[key] = value end
    if row.x then entry.tx = row.x end
    if row.y then entry.ty = row.y end
    if row.oid then
        entry.puppetOid = row.oid
        BNS.Body.hidePuppet(BNS.Body.findPuppet(row.oid))
    end
    if row.weapon ~= nil or entry.weapon == nil then equip(entry, entry.row.weapon) end
    if row.anim then BNS.Body.applyAnim(entry, row.anim) end
    if row.dir then
        pcall(function()
            if IsoDirections and IsoDirections[row.dir] then
                entry.proxy:setDir(IsoDirections[row.dir])
            end
        end)
    end
end

-- Sustained state: gait and stance come from the player's own system,
-- we only tell it what the NPC is doing.
function BNS.Body.applyAnim(entry, anim)
    local p = entry.proxy
    local moving = (anim == "walk" or anim == "run")
    pcall(function()
        p:setVariable("bMoving", moving)
        p:setVariable("bRunning", anim == "run")
        p:setVariable("bSprinting", false)
        p:setVariable("isAiming", anim == "aim")
    end)
end

-- One-shot actions pushed the moment they happen.
function BNS.Body.onAnim(args)
    if not enabled() or not args then return end
    local entry = BNS.Body.proxies[args.id]
    if not entry then return end
    BNS.Body.playAction(entry, args.action)
end

function BNS.Body.playAction(entry, action)
    local list = BNS.Body.ActionCandidates[action]
    if not list then return false end
    local candidate = list[BNS.Body.chosen[action] or 1]
    if not candidate then return false end
    local ok = pcall(function() candidate.apply(entry.proxy) end)
    if not ok then
        BNS.log("action '" .. action .. "' via " .. candidate.name .. " failed")
    end
    return ok
end

-- Lifecycle ------------------------------------------------------------------------

function BNS.Body.remove(id)
    local entry = BNS.Body.proxies[id]
    if not entry then return end
    pcall(function() entry.proxy:removeFromWorld() end)
    pcall(function() entry.proxy:removeFromSquare() end)
    BNS.Body.proxies[id] = nil
end

function BNS.Body.clearAll()
    for id, _ in pairs(BNS.Body.proxies) do BNS.Body.remove(id) end
    BNS.Body.proxies = {}
end

-- Smooth the 5Hz snapshots into continuous motion so proxies walk
-- rather than teleport between updates.
function BNS.Body.tick()
    if BNS.Body.supported == false then return end
    for _, entry in pairs(BNS.Body.proxies) do
        local p = entry.proxy
        local ok = pcall(function()
            local x, y = p:getX(), p:getY()
            local nx = x + (entry.tx - x) * LERP
            local ny = y + (entry.ty - y) * LERP
            p:setX(nx); p:setY(ny)
            p:setLastX(nx); p:setLastY(ny)
            if entry.row.z then p:setZ(entry.row.z) end
        end)
        if not ok then return end
    end
end

if Events and Events.OnTick then
    Events.OnTick.Add(BNS.Body.tick)
end

-- Animation lab ---------------------------------------------------------------------
--
-- The candidate lists above are informed guesses. These helpers let the
-- debug panel step through them in-game and report which call actually
-- moves the model, so the winner can be pinned as the default.

function BNS.Body.labStatus()
    local lines = {}
    local n = 0
    for _ in pairs(BNS.Body.proxies) do n = n + 1 end
    table.insert(lines, "player bodies: " .. (BNS.Body.supported == false
        and ("DISABLED - " .. tostring(BNS.Body.lastError))
        or (n > 0 and "active" or "waiting for an NPC in range")))
    table.insert(lines, "proxies: " .. n
        .. "   puppet hiding: " .. (BNS.Body.hideFn and BNS.Body.hideFn.name or "untested"))
    for action, list in pairs(BNS.Body.ActionCandidates) do
        local idx = BNS.Body.chosen[action] or 1
        table.insert(lines, string.format("  %-8s [%d/%d] %s",
            action, idx, #list, list[idx] and list[idx].name or "?"))
    end
    return lines
end

function BNS.Body.labCycle(action)
    local list = BNS.Body.ActionCandidates[action]
    if not list then return nil end
    BNS.Body.chosen[action] = ((BNS.Body.chosen[action] or 1) % #list) + 1
    return list[BNS.Body.chosen[action]].name
end

-- Fire an action on every visible proxy so the tester can watch it.
function BNS.Body.labTest(action)
    local list = BNS.Body.ActionCandidates[action]
    if not list then return false, "unknown action" end
    local candidate = list[BNS.Body.chosen[action] or 1]
    local tried = 0
    for _, entry in pairs(BNS.Body.proxies) do
        BNS.Body.playAction(entry, action)
        tried = tried + 1
    end
    if tried == 0 then return false, "no proxy in range - spawn an NPC first" end
    return true, action .. " via " .. candidate.name .. " on " .. tried .. " proxy(s)"
end
