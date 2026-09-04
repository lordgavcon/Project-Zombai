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
BNS.Body.stats = { snapshots = 0, rows = 0, lastSnapshotTick = -1, ticks = 0 }
BNS.Body.hideVerified = nil -- true / false / nil (build gives us no way to check)
BNS.Body.attachVia = nil  -- which registration call put proxies in the world

local LERP = 0.35 -- how fast a proxy catches up to its puppet per tick

-- Candidate engine calls -------------------------------------------------
--
-- The exact B42.20 names for hiding a character and for driving player
-- attack/aim animation cannot be verified outside the game. Each action
-- lists the plausible calls in order; the debug panel's animation lab
-- steps through them in-game so the working one can be pinned here.

-- `needs` names the method the candidate calls, so one that this build
-- does not have is skipped instead of called blind. A pcall stops the
-- error propagating but Kahlua still dumps a full stack trace to
-- console.txt, so "just guard it" is not enough -- don't make the call.
BNS.Body.HideCandidates = {
    { name = "setAlphaAndTarget(0)", needs = "setAlphaAndTarget",
      apply = function(z) z:setAlphaAndTarget(0) end },
    { name = "setInvisible(true)", needs = "setInvisible",
      apply = function(z) z:setInvisible(true) end },
    { name = "setModelVisible(false)", needs = "setModelVisible",
      apply = function(z) z:setModelVisible(false) end },
}

-- Can this candidate even be tried on this object?
function BNS.Body.candidateAvailable(candidate, obj)
    if not obj then return false end
    if not candidate.needs then return true end
    return obj[candidate.needs] ~= nil
end

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
    if BNS.Body.supported == false then return end
    BNS.Body.supported = false
    BNS.Body.lastError = reason
    BNS.log("player bodies unavailable (" .. tostring(reason) .. "); using restyled shells")
    -- Say it on screen once: a silent fallback is indistinguishable from
    -- the feature simply not working, which is exactly what happened.
    local player = getSpecificPlayer(0)
    if player then
        pcall(function()
            player:setHaloNote("Project Zombai: player bodies unavailable - "
                .. tostring(reason), 255, 180, 80, 400)
        end)
    end
    BNS.Body.clearAll()
end

-- Puppet lookup ------------------------------------------------------------

-- Clients cannot read a puppet's brain, so NPCs are matched by the
-- online id the server sends with each row.
-- Online ids are unreliable in single player (often -1 for every
-- zombie), so try the strongest match first: in SP the client shares the
-- process and can read the brain straight from mod data.
function BNS.Body.findPuppet(oid, id, x, y)
    local cell = getCell()
    local list = cell and cell:getZombieList() or nil
    if not list then return nil, "no cell" end

    if id then
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            local ok, brain = pcall(function() return BNS.brain(z) end)
            if ok and brain and brain.id == id then return z, "modData" end
        end
    end
    if oid and oid ~= -1 then
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            if z:getOnlineID() == oid then return z, "onlineId" end
        end
    end
    if x and y then
        local best, bestD = nil, 2.0
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            local d = BNS.dist(x, y, z:getX(), z:getY())
            if d < bestD then best, bestD = z, d end
        end
        if best then return best, "position" end
    end
    return nil, "not found"
end

-- Hide the puppet, learning which call this build supports. Returns
-- false if none of them work, which disables the whole layer.
-- Did the puppet actually become invisible? Returns true/false, or nil
-- when this build gives us no way to check.
function BNS.Body.verifyHidden(zombie)
    if zombie.getAlpha then
        local ok, alpha = pcall(function() return zombie:getAlpha() end)
        if ok and type(alpha) == "number" then return alpha <= 0.05 end
    end
    if zombie.isInvisible then
        local ok, inv = pcall(function() return zombie:isInvisible() end)
        if ok and type(inv) == "boolean" then return inv end
    end
    return nil
end

-- A call that merely does not error is not proof of anything: alpha in
-- particular is re-driven by the engine every frame. Verify where the
-- build lets us, and never claim success for a missing method.
function BNS.Body.hidePuppet(zombie)
    if not zombie then return false end -- no puppet, no proxy: never draw both
    if BNS.Body.hideFn then
        pcall(function() BNS.Body.hideFn.apply(zombie) end)
        return true
    end
    for _, candidate in ipairs(BNS.Body.HideCandidates) do
        local ok = BNS.Body.candidateAvailable(candidate, zombie)
            and pcall(function() candidate.apply(zombie) end)
        if ok then
            local hidden = BNS.Body.verifyHidden(zombie)
            if hidden ~= false then
                BNS.Body.hideFn = candidate
                BNS.Body.hideVerified = hidden -- true, or nil when unverifiable
                BNS.log("hiding puppets with " .. candidate.name
                    .. (hidden == nil and " (unverified)" or " (verified)"))
                return true
            end
        end
    end
    return false
end

-- Proxy construction ---------------------------------------------------------

local function buildDescriptor(look)
    if not SurvivorFactory or not SurvivorFactory.CreateSurvivor then
        error("SurvivorFactory.CreateSurvivor is missing on this build", 0)
    end
    local desc = SurvivorFactory.CreateSurvivor()
    if not desc then error("CreateSurvivor returned nil", 0) end
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

-- Getting the constructed character *into the world* is the step that was
-- missing entirely. IsoPlayer.new allocates a character but does not
-- register it with a square, so nothing ever drew or updated it -- which
-- is why NPCs kept rendering as their shells, with zombie animations,
-- even though the probe reported proxies alive.
--
-- Which registration call this build wants cannot be checked offline, so
-- they are candidates, applied in order until membership actually
-- verifies. `available` keeps us from calling a method the build lacks.
BNS.Body.AttachCandidates = {
    {
        name = "setCurrent(square)",
        available = function(p) return p.setCurrent ~= nil end,
        apply = function(p, sq) p:setCurrent(sq) end,
    },
    {
        name = "square:addMovingObject(proxy)",
        available = function(p, sq) return sq.addMovingObject ~= nil end,
        apply = function(p, sq) sq:addMovingObject(p) end,
    },
    {
        name = "square:getMovingObjects():add(proxy)",
        available = function(p, sq) return sq.getMovingObjects ~= nil end,
        apply = function(p, sq) sq:getMovingObjects():add(p) end,
    },
    {
        name = "cell:addToProcessIsoObject(proxy)",
        available = function(p, sq, cell) return cell.addToProcessIsoObject ~= nil end,
        apply = function(p, sq, cell) cell:addToProcessIsoObject(p) end,
    },
}

-- Membership, not just "the call did not error". A constructor may well
-- set a current square on its own, so asking getCurrentSquare() alone
-- would report success for a character the renderer never sees -- the
-- same false positive that made hiding look like it worked.
function BNS.Body.verifyAttached(proxy)
    local ok, found = pcall(function()
        local sq = proxy:getCurrentSquare()
        if not sq or not sq.getMovingObjects then return false end
        local list = sq:getMovingObjects()
        for i = 0, list:size() - 1 do
            if list:get(i) == proxy then return true end
        end
        return false
    end)
    return ok and found == true
end

-- Apply candidates cumulatively: they are complementary registrations,
-- not alternatives, so stop at the first point membership verifies.
function BNS.Body.attachProxy(proxy, x, y, z)
    local cell = getCell()
    local sq = getSquare and getSquare(math.floor(x), math.floor(y), z or 0) or nil
    if not sq or not cell then return false, "no square at " .. tostring(x) .. "," .. tostring(y) end
    if BNS.Body.verifyAttached(proxy) then
        BNS.Body.attachVia = BNS.Body.attachVia or "constructor"
        return true
    end
    local tried = {}
    for _, candidate in ipairs(BNS.Body.AttachCandidates) do
        local usable = false
        pcall(function() usable = candidate.available(proxy, sq, cell) == true end)
        if usable then
            table.insert(tried, candidate.name)
            pcall(function() candidate.apply(proxy, sq, cell) end)
            if BNS.Body.verifyAttached(proxy) then
                if not BNS.Body.attachVia then
                    BNS.Body.attachVia = table.concat(tried, " + ")
                    BNS.log("proxies attached to the world with " .. BNS.Body.attachVia)
                end
                return true
            end
        end
    end
    return false, "tried " .. (#tried > 0 and table.concat(tried, ", ") or "nothing usable")
end

function BNS.Body.createProxy(row)
    local cell = getCell()
    if not cell then return nil end
    -- Kept separate so the failure names the real culprit rather than
    -- blaming IsoPlayer for a missing SurvivorFactory.
    local okDesc, desc = pcall(buildDescriptor, row.look)
    if not okDesc then
        disable("descriptor: " .. tostring(desc))
        return nil
    end
    if not IsoPlayer or not IsoPlayer.new then
        disable("IsoPlayer.new is missing on this build")
        return nil
    end
    local okProxy, proxy = pcall(function()
        return IsoPlayer.new(cell, desc, row.x, row.y, row.z or 0)
    end)
    if not okProxy or not proxy then
        disable("IsoPlayer.new: " .. tostring(proxy))
        return nil
    end
    neutralise(proxy)
    if row.look and row.look.outfit then
        pcall(function() proxy:dressInNamedOutfit(row.look.outfit) end)
        pcall(function() proxy:resetModelNextFrame() end)
    end
    local attached, why = BNS.Body.attachProxy(proxy, row.x, row.y, row.z)
    if not attached then
        pcall(function() proxy:removeFromWorld() end)
        -- No square yet is a timing problem, not a broken build: the
        -- chunk may still be streaming in. Retry on a later snapshot
        -- instead of writing the whole layer off.
        if why and why:find("no square") then return nil end
        disable("proxy cannot be added to the world (" .. tostring(why) .. ")")
        return nil
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
    if not args then return end
    -- Count every snapshot, even when the layer is off: the probe needs
    -- to distinguish "the server never sent anything" from "we refused".
    BNS.Body.stats.snapshots = BNS.Body.stats.snapshots + 1
    BNS.Body.stats.rows = BNS.Body.stats.rows + #(args.rows or {})
    BNS.Body.stats.lastSnapshotTick = BNS.Body.stats.ticks
    if not enabled() then return end
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
    local entryHow = nil
    if not entry then
        local puppet, how = BNS.Body.findPuppet(row.oid, row.id, row.x, row.y)
        if not puppet then
            -- The shell isn't loaded here yet; try again on a later
            -- snapshot rather than disabling the whole layer.
            return
        end
        entryHow = how
        -- Build and attach the replacement body *first*. Hiding the shell
        -- before knowing a proxy will actually be drawn leaves the NPC
        -- invisible -- or, since the engine re-drives zombie alpha every
        -- frame, flickering.
        local proxy = BNS.Body.createProxy(row)
        if not proxy then return end
        if not BNS.Body.hidePuppet(puppet) then
            pcall(function() proxy:removeFromWorld() end)
            disable("cannot hide puppets (tried "
                .. #BNS.Body.HideCandidates .. " methods)")
            return
        end
        entry = { puppet = puppet }
        -- A proxy standing over a hidden puppet is the layer working.
        -- Record that: `supported` was previously only ever set to false,
        -- so the probe reported "not yet attempted" even with live
        -- proxies on screen -- which reads exactly like a broken layer.
        if BNS.Body.supported == nil then
            BNS.Body.supported = true
            BNS.log("player bodies active (proxy created, puppet hidden with "
                .. (BNS.Body.hideFn and BNS.Body.hideFn.name or "?") .. ")")
        end
        entry.proxy, entry.row, entry.tx, entry.ty = proxy, {}, row.x, row.y
        entry.puppetOid, entry.matchedBy = row.oid, entryHow
        BNS.Body.proxies[row.id] = entry
    end

    -- Rows are deltas: merge what arrived onto what we already knew.
    for key, value in pairs(row) do entry.row[key] = value end
    if row.x then entry.tx = row.x end
    if row.y then entry.ty = row.y end
    if row.oid then entry.puppetOid = row.oid end
    -- Refresh the cached puppet reference; the per-frame tick re-asserts
    -- the hide, because at 5Hz the engine fades the shell back in between
    -- snapshots and the NPC visibly flickers.
    local stale = true
    if entry.puppet then
        local ok, dead = pcall(function() return entry.puppet:isDead() end)
        stale = (not ok) or dead == true
    end
    if stale then
        entry.puppet = BNS.Body.findPuppet(entry.puppetOid, row.id, entry.tx, entry.ty)
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
    BNS.Body.stats.ticks = BNS.Body.stats.ticks + 1
    if BNS.Body.supported == false then return end
    for _, entry in pairs(BNS.Body.proxies) do
        local p = entry.proxy
        local ok = pcall(function()
            local x, y = p:getX(), p:getY()
            local nx = x + (entry.tx - x) * LERP
            local ny = y + (entry.ty - y) * LERP
            p:setX(nx); p:setY(ny)
            p:setLastX(nx); p:setLastY(ny)
            local z = entry.row.z or 0
            if entry.row.z then p:setZ(z) end
            -- Moving a character by coordinates alone leaves it registered
            -- to the square it started on, so it renders in the wrong
            -- place and never migrates. Follow it across squares.
            if p.setCurrent and getSquare then
                local sq = getSquare(math.floor(nx), math.floor(ny), z)
                if sq and sq ~= p:getCurrentSquare() then p:setCurrent(sq) end
            end
        end)
        if not ok then return end
        -- Re-assert the hide every frame. The engine re-drives a zombie's
        -- alpha each frame, so hiding at snapshot rate (5Hz) lets the
        -- shell fade back in between updates -- read in-game as flicker.
        if entry.puppet then
            pcall(function() BNS.Body.hidePuppet(entry.puppet) end)
        end
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

-- Probe -------------------------------------------------------------------------------
--
-- "Bandits still look like zombies" is the same symptom whether the
-- layer failed, never ran, or switched itself off — so this reports a
-- pass/fail line for every step of the pipeline, and is the fastest way
-- to turn a vague symptom into a specific missing engine call.

local function mark(ok) return ok and "[ok]" or "[NO]" end

function BNS.Body.probe()
    local out = {}
    local function add(line) table.insert(out, line) end

    add("--- Project Zombai: player-body probe ---")

    -- 1. Is the server even talking to us?
    local st = BNS.Body.stats
    local age = st.lastSnapshotTick >= 0 and (st.ticks - st.lastSnapshotTick) or -1
    add(string.format("%s visual snapshots received: %d (%d rows)%s",
        mark(st.snapshots > 0), st.snapshots, st.rows,
        age >= 0 and (", last " .. age .. " ticks ago") or ", never"))
    if st.snapshots == 0 then
        add("     -> nothing is arriving from the server. Either no NPC is within")
        add("        60 tiles, or the sandbox option 'Player bodies for NPCs' is off.")
    end

    -- 2. Character construction: the most likely thing missing on B42.
    local hasFactory = SurvivorFactory ~= nil and SurvivorFactory.CreateSurvivor ~= nil
    add(mark(hasFactory) .. " SurvivorFactory.CreateSurvivor exists")
    local desc = nil
    if hasFactory then
        local ok, d = pcall(function() return SurvivorFactory.CreateSurvivor() end)
        desc = ok and d or nil
        add(mark(ok and d ~= nil) .. " CreateSurvivor() returns a descriptor"
            .. ((not ok) and (" - " .. tostring(d)) or ""))
    end

    local hasIsoPlayer = IsoPlayer ~= nil and IsoPlayer.new ~= nil
    add(mark(hasIsoPlayer) .. " IsoPlayer.new exists")
    if hasIsoPlayer and desc then
        local player = getSpecificPlayer(0)
        local ok, made = pcall(function()
            return IsoPlayer.new(getCell(), desc,
                player and player:getX() or 0, player and player:getY() or 0,
                player and player:getZ() or 0)
        end)
        add(mark(ok and made ~= nil) .. " IsoPlayer.new(cell, desc, x, y, z) constructs"
            .. ((not ok) and (" - " .. tostring(made)) or ""))
        if ok and made then
            pcall(function() made:removeFromWorld() end)
            pcall(function() made:removeFromSquare() end)
        end
    end

    -- 3. Can we find and hide a puppet?
    local cell = getCell()
    local list = cell and cell:getZombieList() or nil
    local npc, how = nil, nil
    if list then
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            local ok, brain = pcall(function() return BNS.brain(z) end)
            if ok and brain then npc, how = z, "modData" break end
        end
    end
    if not npc then
        for id, entry in pairs(BNS.Body.proxies) do
            npc, how = BNS.Body.findPuppet(entry.puppetOid, id, entry.tx, entry.ty)
            if npc then break end
        end
    end
    add(mark(npc ~= nil) .. " found an NPC puppet to test"
        .. (npc and (" (by " .. tostring(how) .. ")") or " - spawn a bandit first"))

    if npc then
        for _, candidate in ipairs(BNS.Body.HideCandidates) do
            if not BNS.Body.candidateAvailable(candidate, npc) then
                add("[--] hide via " .. candidate.name .. " - not on this build")
            else
                local ok = pcall(function() candidate.apply(npc) end)
                local verified = ok and BNS.Body.verifyHidden(npc) or nil
                add(string.format("%s hide via %s%s", mark(ok), candidate.name,
                    ok and (verified == true and " (verified invisible)"
                        or (verified == false and " (call worked but still visible)"
                        or " (cannot verify on this build)")) or ""))
            end
        end
    end

    -- 4. Where we ended up.
    local n = 0
    for _ in pairs(BNS.Body.proxies) do n = n + 1 end
    -- Whether a proxy is actually registered with a square is the
    -- difference between "player bodies" and "a hidden shell": an
    -- unattached character is never drawn or animated by the engine.
    local attachedCount, proxyCount = 0, 0
    for _, entry in pairs(BNS.Body.proxies) do
        proxyCount = proxyCount + 1
        if BNS.Body.verifyAttached(entry.proxy) then
            attachedCount = attachedCount + 1
        end
    end
    if proxyCount > 0 then
        add(mark(attachedCount == proxyCount) .. string.format(
            " proxies registered with a square: %d of %d%s",
            attachedCount, proxyCount,
            attachedCount == 0 and " - nothing will be drawn or animated" or ""))
    end
    add("     attach method: " .. tostring(BNS.Body.attachVia or "none yet"))
    add(string.format("state: %s, proxies %d, hiding %s",
        BNS.Body.supported == false and ("DISABLED - " .. tostring(BNS.Body.lastError))
            or (BNS.Body.supported == true and "enabled" or "not yet attempted"),
        n, BNS.Body.hideFn and BNS.Body.hideFn.name or "untested"))
    add("(shells are restyled to look alive either way - see the server's [BNS] log)")

    for _, line in ipairs(out) do BNS.log(line) end
    return out
end
