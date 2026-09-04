# Project Zombai (Project Zomboid, Build 42)

**Project Zombai** adds persistent, world-navigating human NPCs to Build 42.20+:

- **Bandits** in three behaviour tiers:
  - **Civilians** — desperate people with makeshift weapons. They prefer robbing you (hand over some items and they leave) to fighting, and they break and run when hurt.
  - **Thugs** — organised fighters with real melee weapons and the occasional firearm; sometimes travel in pairs.
  - **Rogue militia** — squads of 2–5 with firearms. They attack on sight, launch raids on player bases, and garrison fortified strongholds.
- **Environment-themed bandit groups** — who you meet depends on where you are, weighted by proximity rather than locked to regions (every archetype has a baseline chance everywhere):
  - **Farm country & wilderness** → farmers with wood axes, pitchforks, shovels and shotguns ("Get off my land!").
  - **Towns & trailer parks** → city folk with kitchen knives, street thugs, rogue **police** with pistols/shotguns and nightsticks ("Police! Weapon on the ground, NOW!"), and **firefighters** swinging fire axes and sledgehammers.
  - **Military sites** (secret base, highway checkpoints/blockades — see `BNS_POIs.lua`) → **ex-military** squads in camo with rifles, with the pull fading linearly out to each site's radius.
  Raid squads and POI garrisons are themed the same way, based on where the base sits.
- **Base raids & sabotage** — bandit squads periodically march on player bases (MP safehouses are detected directly; elsewhere the mod learns where you spend your time). Raiders smash barricades and player-built walls, shut down and damage generators, and steal from your containers before withdrawing.
- **Fortified points of interest** — the militia claims a configurable number of known locations (fire stations, gas stations, warehouses, gun stores across Rosewood, Muldraugh, West Point, Riverside, March Ridge…). Claimed POIs get barricaded windows/doors, supply-stocked containers (food, ammo, meds, fuel, building materials) and a standing garrison. Clear the garrison and the supplies are yours.
- **You can tell a stronghold is held before you walk into it** — there are no map markers; the world tells you instead. An outer ring roughly two and a half times the stronghold's radius accumulates the evidence of armed occupation: spent casings, bloodied rags, broken junk on the approach, camp clutter and ashes closer in. Camp noise — gunfire, hammering — carries about 70 tiles (and draws zombies, so a held POI is a dangerous neighbour). And the garrison challenges you at 15–30 tiles — *"That's far enough!"*, *"This place is taken. Walk away."* — before anyone opens fire at 15. Turn back, or plan an assault. Sandbox-toggleable if you want silent, unmarked strongholds.
- **The living vs the dead** — all NPCs (bandits, survivors, traders) treat zombies as the real enemy. Zombies within 5 tiles pre-empt whatever an NPC was doing — even a firefight with you — and get put down with the NPC's actual weapon (gunfire draws more zombies in, so it escalates). Zombies hurt NPCs back: adjacent zombies claw and **grab** them, with player-style flinch and held-struggle reactions, and can kill them. The overwhelm rule is 1 living NPC per 4 zombies within a 5-tile radius: worse odds and they break off and run from the mob for about five seconds — except the rare last-stander (~5% of civilians, ~10% of thugs, ~15% of militia) who plants their feet immediately. Fleeing is deliberately short and cannot loop: once a run ends they hold their ground and fight rather than bolting again, because the mob follows them anyway. And nobody attacks at a dead sprint — NPCs close the distance running, then stop to swing or shoot.
- **Doors & combination locks** — bandits can get through closed doors, never silently: an unlocked door takes ~3 seconds (sandbox-tunable) of audible handle-rattling before it opens, so anyone inside gets a warning. Your counter is a **combination lock**: attach a vanilla combination padlock to any door (right-click), and bandits can't open it — a bandit in pursuit or on a raid has to *break the door down*, and bashing works against the door's actual durability: each swing deals tier-based damage (militia hit hardest, half again more with an axe or sledgehammer in hand), so a flimsy interior door falls in seconds while a metal or high-level-carpentry door takes *much* longer — and after ~90 seconds of futile hammering the bandit gives up. Partial damage persists, every bash is loud enough to warn the whole street and draw zombies, and wandering bandits just give up and go around. The lock gives **quick entry to its owner and everyone in the owner's clan** (MP faction) via a right-click "Open/Close (combination)" option, while everyone else is locked out. Owners/clanmates can remove the lock and get the padlock back; a smashed door takes the lock with it.
- **Scavenging** — NPCs loot buildings for supplies and equipment as they travel. They take the valuables (weapons, ammo, food, meds) and leave the evidence: low-value items stay in the container and a piece or two ends up scattered on the floor, so a half-emptied cupboard with junk around it tells you someone living has been through. Looted spots are skipped for a few in-game days, kill a scavenger and their haul drops with them, and traders convert what they find into sale stock — so trader inventories genuinely restock from the world. Player bases are never quietly scavenged; only raids touch your stuff. Sandbox-toggleable.
- **Vehicles** — NPCs claim parked vehicles (never ones at your base), stash their scavenged haul in the *real* trunk — raid the trunk or steal the whole vehicle and the loot is yours — and travel with them: while off-screen an NPC with a vehicle covers ~5× the ground of one on foot, and the pair rematerialise together, so you'll meet the same scavenger and their loaded car towns apart. Near players there's no faked driving: NPCs are found parked, walking to, or loading their vehicle, and "drive off" by despawning at it. About half of base raids arrive with a pickup truck; everything raiders steal from you goes into its trunk, so wiping out the crew before they leave gets your stuff back.
- **Survivors & traders** — neutral NPCs wander the world. Right-click a survivor to talk (they drop rumours, including militia base warnings); right-click a trader to open a barter window and trade your goods against their stock, valued item-for-item. **Traders stop and turn to face you** as soon as you get within about five tiles, so you can actually catch one; survivors halt once you're right beside them.
- **NPCs amble, they don't march** — wandering is a slow walk with pauses. On reaching somewhere an NPC usually stands around for ten to fifty seconds before picking a new destination, so a street with people on it looks lived-in rather than like a parade. Zombies nearby cancel the standing about; a player watching does not.
- **Persistence** — every NPC is a record in global mod data. NPCs near players are fully simulated ("live"); distant ones are *virtualised* — despawned but still travelling the map abstractly — and rematerialise when you come near their current position. State survives save/load and server restarts.
- **Multiplayer compatible** — all AI, combat, robbery, raid and trade logic runs on the server; clients only render speech/UI and send trade proposals, which the server validates (no client-side item forging). The same server code runs in-process in single player, so SP and MP share one code path.

## How it works (the honest version)

Build 42 still has no official NPC API. Like the well-known Bandits and
Superb Survivors mods, this mod implements NPCs as **server-controlled
zombie shells**: each NPC is an `IsoZombie` spawned in a human outfit whose
zombie instincts are suppressed every tick, driven instead by a Lua brain
stored in its mod data. That buys us the engine's real pathfinding
(`pathToLocationF`) for natural navigation, and free multiplayer position
sync (zombies already sync). Consequences you should know about:

- **The shell is what you see, restyled and re-animated.** There is no
  second character. Every shell gets living skin from its appearance seed,
  blood and dirt cleared, wounds healed and its clothing cleaned up,
  re-asserted periodically because the engine re-rolls zombie visuals — so
  bandits read as people rather than corpses. Appearance is rolled once per
  NPC and persisted, so a given bandit looks the same every time you meet
  them and identical on every client.
- **Animation comes from player clips, chosen by animation variables.**
  The brain sets `BNSAnim` (idle / walk / run / aim / swing / shoot / hit /
  grabbed) and `Weapon` (the weapon class it is holding) on the shell, and
  the AnimSet overlays in `42/media/AnimSets/zombie/` play the player's own
  clips on those conditions — so a bandit with an axe swings like a player
  with an axe, and one with a pistol takes a pistol stance. Attack
  *outcomes* are still simulated server-side (hit rolls, gunshot noise that
  draws zombies, body-part damage through `BodyDamage`).
- NPCs read as zombies to some vanilla systems (e.g. kill counts), and the
  engine never makes real zombies attack them on their own — so the
  living-vs-dead fight is driven by the mod: NPCs damage zombie engine
  health directly, while a threat scan (~1/s per NPC) makes adjacent
  zombies claw/grab the NPC (through the same damage path players' weapons
  use against NPCs) and lures the crowd onto them so hordes physically
  converge.
- **Warning shouts:** every fresh bandit engagement opens with a shouted
  warning ("Drop your weapon, NOW!") and a ~2.5 second hold during which no
  damage is dealt — gunners stand and aim, melee bandits close in without
  swinging. The first shot of an engagement also takes a 50% accuracy
  penalty, so armed bandits telegraph danger instead of instantly killing.
  A bandit you attack first skips the hold (being shot at is its own
  warning) but still shouts.

## Installation

Copy this repository's contents into a `ProjectZombai/` folder in your mods
directory (`Zomboid/Workshop/` or `Zomboid/mods/`), then enable **Project
Zombai** in the mod list. For dedicated servers add `ProjectZombai` to the
server's `Mods=` line; the mod must be installed on server **and**
clients.

## Sandbox options (page: "Project Zombai")

| Option | Default | Meaning |
|---|---|---|
| Bandit spawn rate | 3 | 0 disables bandits |
| Survivor spawn rate | 2 | 0 disables survivors/traders |
| Max live NPCs | 20 | Simulation cap; the rest are virtualised |
| Rogue militia groups | on | Top bandit tier |
| Militia firearm chance | 60% | Per squad member |
| Base raids & sabotage | on | |
| Raid cooldown | 24h | Per base, in-game hours |
| Fortified POIs | on / max 4 | Militia strongholds |
| Traders | on | |
| Robberies | on | Low-tier bandits mug instead of attack |
| NPC damage multiplier | 1.0 | Scales NPC → player damage |
| Bandit door-opening delay | 3s | Audible rattling before an unlocked door opens |
| NPC scavenging | on | NPCs loot buildings, leaving low-value evidence |
| NPC vehicles | on | Claimed vehicles, trunk hauling, raid trucks |
| Signs of bandit-held POIs | on | Approach evidence, camp noise, challenge shouts |

## Code layout

```
42/media/lua/
  shared/BNS/   BNS_Core (namespace/helpers) · BNS_Loadouts (tiers, weapons,
                loot, trader stock, barter values) · BNS_Archetypes
                (environment-themed bandit types + zone/proximity weighting) ·
                BNS_POIs (stronghold list + military sites)
  server/BNS/   BNS_Persistence (records, virtualisation) · BNS_Spawner
                (shell (de)materialisation, squads, loot drops) · BNS_Combat
                (simulated melee/gunfire) · BNS_Programs (wander/approach/rob/
                attack/flee/defend/trade) · BNS_Brain (per-tick dispatcher,
                damage & death hooks) · BNS_Bases (POI claiming, lazy
                barricading & stocking) · BNS_Raids (base detection, raid
                squads, sabotage) · BNS_ZombieThreat (living-vs-dead, 4:1 rule)
                · BNS_Doors / BNS_Locks (break-ins, combination locks) ·
                BNS_Scavenge (looting + evidence) · BNS_Vehicles (claiming,
                trunk hauling) · BNS_Commands (validated trade/talk) ·
                BNS_Debug (gated debug commands) · BNS_Anim (animation
                variables the AnimSet overlays select on) · BNS_Look
                (restyles shells into living people) · BNS_Main (director:
                population, live/virtual boundary)
  client/BNS/   BNS_Client (server commands, floating speech) ·
                BNS_ContextMenu (Talk/Trade) · BNS_TradeWindow (barter UI) ·
                BNS_LockMenu (padlocks) · BNS_DebugUI (test panel) ·
                BNS_DebugOverlay (NPC state above heads)
tests/          offline suites + run_tests.sh (see "Debug & testing")
```

## Debug & testing

Two layers: `tests/` proves the *logic* offline, the in-game debug panel proves
the *engine integration* (API names, pathfinding, animations, MP sync) that no
offline test can reach.

**Offline suites** — run `sh tests/run_tests.sh` (needs `lua5.1`/`luac5.1`; the
game's Kahlua interpreter is Lua 5.1-compatible). It syntax-checks every Lua file
and runs six suites that load the real mod modules against stubbed PZ APIs:
archetype weighting, zombie threat/overwhelm, doors & locks, scavenging, vehicles,
and the debug commands themselves.

**In-game debug panel** — start the game with the `-debug` launch option (or be an
admin on a server), then press **F7** (or right-click yourself → *Project Zombai:
Debug panel*). Five tabs:

| Tab | What it does |
|---|---|
| World | Live/virtual NPC counts, sandbox options (click a boolean to toggle it live), every known point of interest (fortified ones flagged with their garrison size) with **Teleport to POI** and Fortify nearest, and detected player bases with raid-cooldown countdowns |
| NPCs | Every NPC with program, health, archetype, distance and flags; select one to Go to / Bring here / Kill / cycle its program / give it a vehicle / swarm it with zombies. Also toggles the overlay |
| Spawn | One click per archetype (farmer, city folk, thug, police, firefighter, ex-military) plus survivor and trader, 1–5 at a time as a squad; raid me, fortify a POI, drop a loot box, spawn a horde, clear all NPCs |
| Scenarios | Ten one-click behaviour tests — warning shout, robbery, door rattle, locked-door bash, zombie overwhelm, scavenge & evidence, trader barter, vehicle haul, base raid, POI fortification — each stages the situation and tells you what to watch for |
| Anim lab | Player-body status, per-action buttons to fire and cycle the candidate engine calls for swing/shoot/hit/grabbed, and **PROBE** — a pass/fail line for every step of the pipeline (are snapshots arriving, does `SurvivorFactory` exist, does `IsoPlayer.new` construct, can a puppet be found and actually hidden), which is the fastest way to turn "bandits still look like zombies" into a specific missing call |
| Log | The mod's own `[BNS]` event log, newest first, without tailing `console.txt` |

The **overlay** (NPCs tab) is the main validation tool: it draws each NPC's current
program, health and archetype above their head, so you can watch state transitions
happen — WANDER → APPROACH → ATTACK, FIGHTZ when zombies close in, FLEE when the
4:1 rule trips, SCAVENGE and HAUL on a loot run.

Every debug command is re-checked server-side before it acts: a multiplayer client
can send whatever it likes, so the panel's own permission check is only cosmetic.
Non-admin requests are dropped and logged.

## Known limitations / TODO

- Not yet play-tested against 42.20 — B42's Lua API is still moving, and a
  few calls (e.g. `setUseless`, `IsoBarricade.AddBarricadeToObject`,
  outfit names) may need renaming against the current javadocs. Everything
  is guarded where practical; check `console.txt` for `[BNS]` lines.
- **Arming a shell trips a vanilla bug.** `setPrimaryHandItem` fires the
  engine's `OnEquipPrimary` event, and B42's own `FishingHandler.lua`
  assumes the character is a player, so it throws
  (`Object tried to call nil in handleFishing`) once per NPC that
  materialises with a weapon. The engine catches it in its own event
  `pcall`, so the weapon *is* equipped and nothing in the mod is affected —
  it is console noise from vanilla code we have no supported way to skip,
  since there is no event-free setter for a hand item.
- Item ids in `BNS_Loadouts.lua` are resolved against the running build
  through `BNS.Loadouts.item()` before anything is spawned: a renamed id
  falls back to a known alternate (B42 dropped `Base.WaterBottleFull`, for
  instance) and an id with no alternate is skipped, with one `[BNS]` line
  saying so. Add an entry to `BNS.Loadouts.Alternates` if a drop or stock
  line goes missing on your build.
- **NPC animation runs on the shell itself.** NPCs are `IsoZombie` shells
  flagged `BNSNPC`, and `BNS_Anim.lua` sets `BNSAnim` (idle / walk / run /
  aim / swing / shoot / hit / grabbed) and `Weapon` (the vanilla weapon
  classes) on them; the AnimSet overlays in `42/media/AnimSets/zombie/`
  select player clips on those conditions, so a swing matches the weapon in
  hand. Every clip name in those overlays is taken from the game's own
  `media/AnimSets/player/`, not guessed.
  A client-side `IsoPlayer` proxy layer was tried and **removed**: on
  42.20.4 every step verified — descriptor, constructor, square
  registration, puppet hiding — and the engine still never drew the
  character, which left NPCs invisible. B42 does not appear to render
  non-controlled `IsoPlayer` instances.
- Which *state directories* the zombie AnimSet exposes (`idle`,
  `walktowards`, `attack`) is still assumed rather than read from the
  game's `media/AnimSets/zombie/`. If a mode never plays, that is the first
  thing to check — the debug panel's Anim lab forces one mode at a time on
  a selected NPC so each node can be confirmed individually.
- Animation variables are set server-side. If MP clients show zombie
  animations while single player shows human ones, they are not
  replicating and the fix is a client-side mirror pass — the variables are
  the only thing that would need sending.
- Environment detection reads the map's meta-grid zone types (Farm,
  TownZone, Forest…); if zone lookup fails it falls back to the baseline
  weights. Military site coordinates in `BNS_POIs.lua` are approximate —
  adjust them if ex-military squads cluster in the wrong place, and append
  entries for map mods. Outfit names (`Police`, `Fireman`, `Ghillie`…) and
  item ids (`Base.GardenFork`, `Base.WoodAxe`…) should be verified against
  42.20's scripts if a specific archetype spawns in default clothes or
  bare-handed.
- POI approach decoration filters its item ids against what the build
  actually ships (`ScriptManager:getItem`), so an unknown id is skipped
  rather than erroring — but if a whole pool is missing, that cue quietly
  disappears; `[BNS]` logs which pool came up empty. Blood splatter and
  positional camp audio are attempted and degrade silently if 42.20's
  `addBlood` / `PlayWorldSound` signatures differ.
- NPC "driving" is park-and-dismount plus fast off-screen travel — zombie
  shells can't run real vehicle physics, so you'll never see one steering.
  The vehicle APIs used (`getPartById("TruckBed")`, `addVehicleDebug`,
  `permanentlyRemove`) are guarded but should be spot-checked against
  42.20; if trunks misbehave, loot falls back to a pile beside the car.
- Raids target the learned base centre; sprawling multi-building bases are
  only partially swept.
