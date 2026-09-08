# Project Zombai — development notes

This repository is the **primary home** of Project Zombai, a Project Zomboid
Build 42 mod adding persistent bandit and survivor NPCs. All new development
happens here, on `main`. (The mod's earlier history lives in
`lordgavcon/WoWVoiceoverService` on branch `claude/zomboid-bandit-survivor-mod-kaacll`
as "Bandits & Survivors" — that copy is historical; do not develop there.)

## Layout

The repo root is the mod root: `mod.info` + `42/` (B42 version folder).
See README.md for the feature list and the code-layout map. Key facts:

- NPCs are **server-controlled zombie shells** (`IsoZombie` + a Lua brain in
  mod data). All AI runs in `42/media/lua/server/BNS/`; `lua/server` also
  loads in single player, so SP and MP share one code path.

- **The shell is the character.** There is no second body. NPCs look human
  because `BNS_Look.lua` restyles the shell (living skin, no blood/wounds,
  clean clothing) and animate like players because `BNS_Anim.lua` sets
  `BNSNPC` / `BNSAnim` / `Weapon` on it and the AnimSet overlays in
  `42/media/AnimSets/zombie/` select player clips on those conditions.
  This is the approach the shipping B42 NPC mods use. A client-side
  `IsoPlayer` proxy layer was tried and removed: B42 does not render
  non-controlled `IsoPlayer` instances, and hiding the shell to make room
  for one that is never drawn is what made NPCs invisible. Do not
  reintroduce it.
- Client code (`42/media/lua/client/BNS/`) only renders speech/UI and sends
  commands; the server validates everything (trades, locks).
- The `BNS` Lua namespace and `BNS_*` file names are internal and kept from
  the original project — do not mass-rename them.
- **AnimSet XML has an exact form.** A STRING condition is
  `<m_Type>STRING</m_Type>` paired with `<m_StringValue>`. The value tag
  is named after the type (`BOOL` takes `<m_BoolValue>`), so a bare
  `<m_Value>` parses into nothing: the node loads, never matches, and the
  shell keeps playing the vanilla zombie clip. This file used to claim the
  opposite, and every overlay was written that way — which is what "the
  bandits use the zombie idle animation" was.
  Clip names (`Bob_*`) and `Weapon` values (`1handed`, `2handed`, `heavy`,
  `knife`, `spear`, `handgun`, `firearm`, `chainsaw`, `throwing`) must come
  from the game's own `media/AnimSets/player/`, never from memory —
  `tests/test_anim.lua` enforces the form and the mode coverage.
- **The overlays are parsed by a real XML parser, so they must be real
  XML.** An XML comment may not contain `--` anywhere; the generator's own
  header comment carried one and *all ninety nodes* were rejected at load
  (`The string "--" is not permitted within comments`, one stack trace per
  file in `console.txt`) — from in game that is indistinguishable from the
  nodes losing to vanilla. `tests/run_tests.sh` now parses every overlay
  with a real parser where `python3` is available, and `test_anim.lua`
  fails on `--` inside a comment regardless. A Lua string check over the
  XML is not enough: it does not see what the game's parser sees.
- **An AnimNode only competes inside its own AnimState directory**, and
  the shell's engine state has nothing to do with the mode the brain asks
  for: BNS suppresses the shell's target, so it never enters its own
  attack state, and a swing pulse lands while it is standing or walking a
  path. A swing node that only lived under `attack/` could therefore never
  play. Every node is emitted into every state a driven shell can be in
  (`idle`, `zombieidle`, `pathfind`, `walktoward`, `walktowards`,
  `attack`) from one table in **`tools/gen_animsets.lua`** — edit that and
  re-run it, never the generated XML; the suite fails if the tree has
  drifted. Which of those state names the build actually uses can be read
  off a running game with the debug panel's Anim lab **PROBE**
  (`getCurrentStateName` / `getAnimationStateName`).
- **Engine commands are rationed.** A shell is moved by the engine's own
  pathfinder, so every extra order restarts its movement mid-step and the
  NPC visibly skates. Path orders go through `BNS.Programs.walkTo`, which
  issues at most one per `REPATH_TICKS` brain ticks unless the goal really
  moved; `stopMoving` halts once and is a no-op while already stopped; and
  zombie suppression re-asserts a few times a second, not every frame.
  Never add a per-tick engine call to the brain without a throttle.
  The budget applies only while the shell is *still walking the order it
  has*: `BNS.Programs.hasEnginePath` asks it (`hasPath`/`isPathing`,
  probed once and remembered), and a dropped path is re-issued at once.
  Without that the budget is a gag — a shell whose path something else
  cancelled stands still forever while the brain declines to re-order it.
- **Suppression must not park the shell.** `BNS.Suppress` (in
  `BNS_Core.lua`) gates the calls that stop a shell behaving like a
  zombie. Only `clearTarget` is on: it is what stops them lunging at
  players and it is understood. `setUseless` and `makeInactive` were added
  on a guess and are off — a parked character cannot walk, which is what
  "bandits don't walk around" looked like. Both are switchable from the
  Anim lab so the question gets answered in game.
- Persistent NPC state lives in global mod data (`BNS_Persistence.lua`);
  never store Java object references in mod data — keep live refs in
  module-local tables (see `BNS.ZombieThreat.targets`).

## Testing

No Project Zomboid install is available in dev containers, so correctness is
covered by offline suites that load the real mod files against stubbed PZ
APIs (`tests/*.lua`). Run everything with:

    sh tests/run_tests.sh

Requires `lua5.1`/`luac5.1` (`apt-get install -y lua5.1`) — the game's Kahlua
interpreter is Lua 5.1-compatible. When adding a feature, extend or add a
suite the same way: stub the engine calls the feature touches, load the real
modules via the harness `require` shim, and assert on behaviour (timings,
counts, state transitions), not implementation details.

Engine API names (`Bob_*` animation clips, sound names, outfit/item ids,
door/lock/vehicle methods) cannot be verified offline — they are best-effort
against B42.20 and are listed in README "Known limitations". In-game errors
appear as `[BNS]` lines in the game's `console.txt`.

That gap is what the **in-game debug panel** covers (`BNS_Debug.lua` server-side,
`BNS_DebugUI.lua` / `BNS_DebugOverlay.lua` client-side): `-debug` or admin, F7,
then spawn any archetype, force any program, and run scenario tests on demand
rather than waiting for a 24h raid cooldown or a 5% last-stand roll. The overlay
draws each NPC's live program above their head. See README "Debug & testing".

When adding a behaviour, add a Scenarios entry for it in `BNS.Debug.Scenarios`
so it can be exercised in-game, alongside the offline suite.

Engine names that cannot be checked offline belong in a *candidate list*
driven by the debug panel rather than a single guess in the code (see
`BNS.Look`'s guarded ops and `BNS.Loadouts.Alternates`). Once a candidate is
confirmed in-game, make it the default. Animation names are the exception:
they *can* be checked, against the game's own `media/AnimSets/player/`, so
never guess one.

Two invariants worth keeping in mind when touching the debug code:
- Every debug command must be gated server-side in `BNS.Debug.handle` — MP
  clients can forge `sendClientCommand`, so the UI's own check is cosmetic.
- Never pick "the newest NPC" by iterating `pairs(state.npcs)`; the order is
  arbitrary. `BNS.Debug.spawnNPC` returns the ids it created — use those.
- **Engine call signatures are guesses until the game says otherwise.**
  `ItemVisual:setBlood` takes `(BloodBodyPartType, float)`, not `(float)`,
  and the wrong arity threw ~1,300 stack traces in a single session because
  `BNS.Look.apply` re-ran the failing op on every re-assertion. Two rules
  came out of that: probe both plausible forms once and cache which the
  build wants (`setOnVisual`), and **never retry an op that threw** —
  `BNS.Look.broken` locks it out for the session and the probe reports it
  as `[err]` rather than a silent `[no]`. Apply the same shape to any new
  guarded engine call that runs on a tick.
- **Item ids go through `BNS.Loadouts.item()`**, which checks the running
  build via `ScriptManager`, substitutes a known alternate from
  `BNS.Loadouts.Alternates`, or drops the line. Never hand a raw id from
  `BNS_Loadouts.lua` to `AddItem` / `instanceItem` / `AddWorldInventoryItem`.
- **A guarded call is not a free call.** `pcall` stops an error
  propagating, but Kahlua still dumps a full stack trace to `console.txt`
  every time, so probing a method that does not exist is not harmless.
  Check the method is present first, then call it.
- **A verification is only as good as what it observes.** "The call did
  not error" did not prove hiding worked; "membership in the square's
  moving-object list" did not prove the character was drawn. When the
  only real observer is a person looking at the game, build the
  observation into the debug panel and ask, rather than inferring.
- **Loot belongs in containers.** A stronghold's supplies go into real
  containers (`BNS_Bases.stockContainers` searches the square, then a few
  tiles around it) and, failing that, into a crate the code places itself
  — never onto the floor. `AddWorldInventoryItem` at a POI is for the
  ground *cues* only, and those pools are refuse by contract
  (`tests/test_signs.lua` asserts no pool offers anything worth picking
  up). Stocking is capped per POI so a stronghold doesn't become a
  warehouse.
- **A claimed POI is a building, not a circle.** `BNS_Bases` adopts the
  real building at the claim point (`getBuilding()` / `getRoom()`, its
  `BuildingDef` footprint) and re-centres the base and its garrison on it.
  "Core" is then `insideBase()` — inside the footprint *and* reporting
  that same building, because a bounding box includes outdoor corners.
  Fortifying and stocking are gated on it; the approach ring is measured
  from the building's centre. Never reintroduce a radius test for what
  counts as inside a stronghold.
- **Attack pace is one knob.** Every attack interval — both melee beats
  and the gaps between rounds — goes through `BNS.Combat.interval`, which
  divides by the `NPCAttackSpeed` sandbox option (default **0.5**, half
  speed). Never hard-code a new attack interval past it, or the sandbox
  setting starts lying. It is a *pace* knob only: accuracy, damage, reload
  length and movement speed are deliberately outside it.
- **Combat is a rhythm, not a cooldown.** A melee swing is windup ->
  contact -> recovery (`BNS.Combat.WINDUP` / `RECOVER`, scaled by the
  weapon's class through `SwingWeight`). It *commits* at the windup, so a
  target that steps out of reach before contact makes it whiff, and a
  whiff costs `WHIFF_PENALTY` times the recovery a hit does. Firearms
  carry a magazine (`BNS.Loadouts.Magazines`), fire in bursts, reload for
  real, and fall back to `brain.backup` when the spares run out.
  Accuracy ramps with `brain.aimTicks` and is reset by
  `BNS.Programs.walkTo`, so movement costs a settled aim.
  **Every combat timer is decremented in `BNS.Combat.tick` and nowhere
  else**, which BNS_Brain runs on every engine tick: that is what lets a
  reload finish while its owner is running away, and it is why no caller
  may decrement one itself. `brain.attackTimer` is *not* a combat timer
  any more — `BNS_Raids` still uses it for sabotage.
- **A one-shot clip is held for a beat, and the beat has two ends.**
  `BNS.Anim.pulse` takes the hold length from its caller; combat works it
  out with `BNS.Combat.clipHold`. Too short and the clip is visibly cut
  off part way through the swing. Too long and `BNSAnim` never leaves
  `swing` between swings — the condition never changes, the AnimNode has
  no edge to re-trigger on, and the *next* swing plays nothing at all. The
  hold is therefore always shorter than the beat that produced it
  (`HOLD_GAP` puts the shell back in its stance in between), and `RECOVER`
  is sized so there is room for the clip in the first place. The same
  applies to shots inside a burst.
- **Both hands, or one, is the weapon class's call.** `BNS.Anim.equip` is
  the only way a weapon reaches a shell's hands: it asks the item
  (`isTwoHandWeapon`, probed once) and falls back to
  `BNS.Anim.TwoHanded` over the animation class, then fills *or clears*
  the off hand. Never call `setPrimaryHandItem` directly — the spawner
  used to, filling the off hand only for guns and deciding even that by
  testing for a setter on the item, so every axe, bat, spear and rifle was
  carried and swung one-handed.
- **Being "busy" is latched, and programs must honour it.**
  `BNS.Combat.isBusy` is true while reloading or blown, and blown latches
  until `RECOVERED` — without the latch a bandit crosses back over the
  winded line by a hair, throws one swing that spends it again, and
  twitches in and out of a retreat all fight. ATTACK and FIGHTZ both back
  away while busy rather than standing there.
- **The engagement telegraph is a warning shot, not a shout.** A gun-armed
  bandit opens with `BNS.Combat.warningShot` — the real held weapon, its
  own sound via `getSwingSound()`, no damage roll — and `warnTimer` holds
  damage off for `BNS.Programs.WARN_TICKS` (240 engine ticks = 4s).
  `warnTimer` counts *engine* ticks, not brain ticks. Melee bandits close
  silently — same hold, no shot and no line. Being attacked first skips
  the telegraph entirely.
