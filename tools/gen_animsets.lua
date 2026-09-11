-- Project Zombai — AnimSet overlay generator.
--
-- The overlays that make an NPC shell animate like a person are the same
-- fifteen nodes repeated across every AnimState the shell can be in, so
-- they are generated from one table rather than maintained by hand.
--
-- Two things this file exists to get right:
--
-- 1. A STRING condition is <m_Type>STRING</m_Type> paired with
--    <m_StringValue>. That is the form the game's own AnimSets use
--    (media/AnimSets/player-vehicle/actions/*.xml, and every published
--    animation-framework template). <m_Value> parses into nothing, so a
--    node written that way silently never plays -- which is exactly what
--    "bandits use the zombie idle" looked like.
--
-- 2. An AnimNode only competes inside the AnimState directory it lives
--    in. The shell's engine state is *not* correlated with the mode we
--    ask for: BNS suppresses the zombie's target, so it never enters
--    AttackState, and a swing pulse lands while the shell is standing or
--    walking a path. A node that only existed under attack/ could never
--    play. So every node is emitted into every state the shell can
--    plausibly be in, and node names carry the state so no two nodes
--    share an identifier.
--
-- 3. XML forbids "--" inside a comment. The generator's own header
--    comment used to contain one, and the game's parser rejects the
--    whole file on it -- so all ninety nodes failed to load with
--    "The string \"--\" is not permitted within comments" and NPCs kept
--    the vanilla zombie clips, exactly as if the nodes were never
--    written. Comments are sanitised on the way out and the suite fails
--    if any generated file carries the sequence.
--
-- Usage:  lua5.1 tools/gen_animsets.lua [output-mod-root]
-- Default output root is the repository's 42/ folder.

local NODES = {
    { key = "bns_idle", anim = "Bob_Idle", looped = true, priority = 10,
      mode = "idle",
      comment = "NPC shells stand like players, not with the zombie sway." },

    { key = "bns_aim", anim = "Bob_IdleAim1Hand", looped = true, priority = 11,
      mode = "aim",
      comment = "generic aim stance for anything else held out." },
    { key = "bns_aim_handgun", anim = "Bob_IdleAimHandgun", looped = true,
      priority = 12, mode = "aim", weapon = "handgun",
      comment = "pistol aim stance while warning or covering a player." },
    { key = "bns_aim_firearm", anim = "Bob_IdleAimRifle", looped = true,
      priority = 12, mode = "aim", weapon = "firearm",
      comment = "long-gun aim stance." },

    { key = "bns_walk", anim = "Bob_Walk", looped = true, priority = 10,
      mode = "walk",
      comment = "player walk cycle instead of the zombie shamble." },
    { key = "bns_run", anim = "Bob_Run", looped = true, priority = 11,
      mode = "run",
      comment = "player run cycle." },

    { key = "bns_hit", anim = "Bob_HitReact_01", looped = false, priority = 16,
      mode = "hit",
      comment = "player flinch when something lands a hit (one-shot pulse)." },
    { key = "bns_grabbed", anim = "Bob_BiteDefend", looped = true, priority = 17,
      mode = "grabbed",
      comment = "struggling while a zombie has hold of them." },

    { key = "bns_swing", anim = "Bob_Attack1Hand01_Hit", looped = false,
      priority = 19, mode = "swing",
      comment = "one-handed swing; the fallback when no weapon class matched." },
    { key = "bns_swing_bat", anim = "Bob_AttackBat01_Hit", looped = false,
      priority = 20, mode = "swing", weapon = "2handed",
      comment = "two-handed blunt swing (bats, planks, crowbars)." },
    { key = "bns_swing_heavy", anim = "Bob_Attack2H_Heavy01_Hit", looped = false,
      priority = 20, mode = "swing", weapon = "heavy",
      comment = "heavy two-handed swing (axes, sledgehammers)." },
    { key = "bns_swing_knife", anim = "Bob_AttackKnife01_NoBlade", looped = false,
      priority = 20, mode = "swing", weapon = "knife",
      comment = "knife/machete stab." },
    { key = "bns_swing_spear", anim = "Bob_AttackFloorSpear", looped = false,
      priority = 20, mode = "swing", weapon = "spear",
      comment = "spear and pitchfork thrust." },

    { key = "bns_shoot", anim = "Bob_AttackRifle", looped = false, priority = 20,
      mode = "shoot",
      comment = "long-gun shot." },
    { key = "bns_shoot_handgun", anim = "Bob_AttackHandgun", looped = false,
      priority = 21, mode = "shoot", weapon = "handgun",
      comment = "pistol shot, with the player's recoil." },
}

-- The AnimState directories a driven shell can be in. `idle` /
-- `zombieidle` cover standing, `pathfind` / `walktoward` / `walktowards`
-- cover walking a path issued by pathToLocationF, and `attack` is kept
-- for the case where the engine does put a shell into its own attack
-- state. A directory the build does not use is simply never read; a
-- missing one is a mode that silently never plays, which is the failure
-- worth insuring against. The debug panel's ANIM PROBE prints the shell's
-- live state name so the real set can be read off a running game.
--
-- `lunge`, `staggerback` and `thump` are the states a shell can be thrown
-- into by the engine rather than by BNS -- a zombie lunging at a player
-- being the one that got reported -- and an uncovered state means vanilla
-- *zombie* clips play there. BNS suppresses the target that causes a
-- lunge (BNS_Brain), but covering the state as well means even a frame of
-- it looks like a person.
--
-- The on-ground family (onground / getup / falldown) is deliberately NOT
-- here: there is no player clip name for a prone body among the ones
-- verified against the game's own media/AnimSets/player, and standing a
-- knocked-down NPC's idle clip up on the floor would look worse than the
-- vanilla get-up does. Add those states here once the clip names are read
-- off a real install -- never guessed (CLAUDE.md).
local STATES = {
    "idle", "zombieidle", "pathfind", "walktoward", "walktowards",
    "attack", "lunge", "staggerback", "thump",
}

local M = { NODES = NODES, STATES = STATES }

-- XML comments may not contain "--" anywhere, and a file that breaks
-- that rule does not load at all. Every comment written here goes
-- through this.
local function comment(text)
    return "<!-- " .. text:gsub("%-%-+", "-"):gsub("^%s+", ""):gsub("%s+$", "") .. " -->"
end
M.comment = comment

local function condition(name, value)
    return table.concat({
        "\t<m_Conditions>",
        "\t\t<m_Name>" .. name .. "</m_Name>",
        "\t\t<m_Type>STRING</m_Type>",
        "\t\t<m_StringValue>" .. value .. "</m_StringValue>",
        "\t</m_Conditions>",
    }, "\n")
end

-- The XML for one node in one state directory.
function M.render(node, state)
    local lines = {
        '<?xml version="1.0" encoding="utf-8"?>',
        comment("BNS (" .. state .. "): " .. node.comment),
        comment("Generated by tools/gen_animsets.lua. Edit that, not this."),
        "<animNode>",
        "\t<m_Name>" .. M.nodeName(node, state) .. "</m_Name>",
        "\t<m_AnimName>" .. node.anim .. "</m_AnimName>",
        "\t<m_Looped>" .. tostring(node.looped) .. "</m_Looped>",
        "\t<m_BlendTime>0.15</m_BlendTime>",
        "\t<m_Priority>" .. node.priority .. "</m_Priority>",
        condition("BNSNPC", "true"),
        condition("BNSAnim", node.mode),
    }
    if node.weapon then table.insert(lines, condition("Weapon", node.weapon)) end
    table.insert(lines, "</animNode>")
    return table.concat(lines, "\n") .. "\n"
end

function M.nodeName(node, state)
    return node.key .. "_" .. state
end

-- Every file the overlay set consists of: { path = contents }, paths
-- relative to the mod root (the 42/ folder).
function M.files()
    local out = {}
    for _, state in ipairs(STATES) do
        for _, node in ipairs(NODES) do
            local path = "media/AnimSets/zombie/" .. state .. "/"
                .. M.nodeName(node, state) .. ".xml"
            out[path] = M.render(node, state)
        end
    end
    return out
end

-- Written as a script rather than required: regenerate the tree.
if arg and arg[0] and arg[0]:find("gen_animsets") then
    local here = arg[0]:match("^(.*)/[^/]+$") or "."
    local root = arg[1] or (here .. "/../42")
    local files = M.files()
    local paths = {}
    for path in pairs(files) do table.insert(paths, path) end
    table.sort(paths)
    -- Start from a clean tree so a renamed node cannot leave a stale file
    -- behind that the game would still load.
    os.execute('rm -rf "' .. root .. '/media/AnimSets/zombie"')
    for _, path in ipairs(paths) do
        local dir = root .. "/" .. path:match("^(.*)/[^/]+$")
        os.execute('mkdir -p "' .. dir .. '"')
        local f = assert(io.open(root .. "/" .. path, "w"))
        f:write(files[path])
        f:close()
    end
    print("wrote " .. #paths .. " overlay nodes ("
        .. #NODES .. " nodes x " .. #STATES .. " states) under " .. root)
end

return M
