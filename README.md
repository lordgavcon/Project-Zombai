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
- **The living vs the dead** — all NPCs (bandits, survivors, traders) treat zombies as the real enemy. Zombies within 5 tiles pre-empt whatever an NPC was doing — even a firefight with you — and get put down with the NPC's actual weapon (gunfire draws more zombies in, so it escalates). Zombies hurt NPCs back: adjacent zombies claw and **grab** them, with player-style flinch and held-struggle reactions, and can kill them. The overwhelm rule is 1 living NPC per 4 zombies within a 5-tile radius: worse odds and they break off and run from the mob — except the rare last-stander (~5% of civilians, ~10% of thugs, ~15% of militia) who plants their feet and fights to the end.
- **Doors & combination locks** — bandits can get through closed doors, never silently: an unlocked door takes ~3 seconds (sandbox-tunable) of audible handle-rattling before it opens, so anyone inside gets a warning. Your counter is a **combination lock**: attach a vanilla combination padlock to any door (right-click), and bandits can't open it — a bandit in pursuit or on a raid has to *break the door down*, and bashing works against the door's actual durability: each swing deals tier-based damage (militia hit hardest, half again more with an axe or sledgehammer in hand), so a flimsy interior door falls in seconds while a metal or high-level-carpentry door takes *much* longer — and after ~90 seconds of futile hammering the bandit gives up. Partial damage persists, every bash is loud enough to warn the whole street and draw zombies, and wandering bandits just give up and go around. The lock gives **quick entry to its owner and everyone in the owner's clan** (MP faction) via a right-click "Open/Close (combination)" option, while everyone else is locked out. Owners/clanmates can remove the lock and get the padlock back; a smashed door takes the lock with it.
- **Scavenging** — NPCs loot buildings for supplies and equipment as they travel. They take the valuables (weapons, ammo, food, meds) and leave the evidence: low-value items stay in the container and a piece or two ends up scattered on the floor, so a half-emptied cupboard with junk around it tells you someone living has been through. Looted spots are skipped for a few in-game days, kill a scavenger and their haul drops with them, and traders convert what they find into sale stock — so trader inventories genuinely restock from the world. Player bases are never quietly scavenged; only raids touch your stuff. Sandbox-toggleable.
- **Survivors & traders** — neutral NPCs wander the world. Right-click a survivor to talk (they drop rumours, including militia base warnings); right-click a trader to open a barter window and trade your goods against their stock, valued item-for-item.
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

- NPCs play **player animation clips** (idle, walk, run, aim, melee swing,
  pistol fire) through AnimSet overlay nodes in `media/AnimSets/zombie/`,
  conditioned on `BNSNPC`/`BNSAnim` animation variables that the Lua brain
  sets — zombies and players share a skeleton, so player clips apply
  cleanly. Attack outcomes are still simulated server-side (hit rolls,
  gunshot sounds and noise that attracts zombies, body-part damage through
  `BodyDamage`); the animations are the visual layer on top.
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
                squads, sabotage) · BNS_Commands (validated trade/talk) ·
                BNS_Main (director: population, live/virtual boundary)
  client/BNS/   BNS_Client (server commands, floating speech) ·
                BNS_ContextMenu (Talk/Trade) · BNS_TradeWindow (barter UI)
```

## Known limitations / TODO

- Not yet play-tested against 42.20 — B42's Lua API is still moving, and a
  few calls (e.g. `setUseless`, `IsoBarricade.AddBarricadeToObject`,
  outfit names) may need renaming against the current javadocs. Everything
  is guarded where practical; check `console.txt` for `[BNS]` lines.
- The `Bob_*` animation clip names in `media/AnimSets/zombie/*/bns_*.xml`
  are best-known guesses; if NPCs still move like zombies in-game, correct
  those names against the game's `media/anims_X/Bob/` clips first.
- Animation variables are set server-side; if they turn out not to sync to
  MP clients on 42.20, a client-side mirror pass fed by a periodic server
  broadcast is the planned fallback.
- Environment detection reads the map's meta-grid zone types (Farm,
  TownZone, Forest…); if zone lookup fails it falls back to the baseline
  weights. Military site coordinates in `BNS_POIs.lua` are approximate —
  adjust them if ex-military squads cluster in the wrong place, and append
  entries for map mods. Outfit names (`Police`, `Fireman`, `Ghillie`…) and
  item ids (`Base.GardenFork`, `Base.WoodAxe`…) should be verified against
  42.20's scripts if a specific archetype spawns in default clothes or
  bare-handed.
- NPCs don't use vehicles.
- Raids target the learned base centre; sprawling multi-building bases are
  only partially swept.
