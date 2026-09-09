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
- **A shell must never be seen in a zombie state — and clearing the target
  is a race BNS loses at contact range.** `OnZombieUpdate` fires early in
  `IsoZombie.updateInternal` and the engine re-acquires later in the *same*
  update, so no cadence of `setTarget(nil)` beats it with a player stood
  against the shell. Worse, **clearing it mid-state is what jams them**:
  the engine's lunge is using that target to reach its own end condition,
  and tearing it away every tick left shells frozen in the lunge pose.
  So `BNS.Brain.suppress` leaves a zombie state alone while it runs and
  clears the moment it ends (`ZSTATE_MAX` breaks out of one that outstays
  any real animation), and the actual prevention is upstream:
  `BNS.Combat.holdState` locks the engine state machine while a shell is
  *stopped* within `MELEE_HOLD_DIST` of a player, which is exactly the
  window where BNS needs no state change of its own. The lock releases the
  moment that stops being true, and latches off past `LOCK_MAX` — an
  engine flag stuck on must never park an NPC (`BNS.Suppress.lockState`
  switches the whole thing off from the Anim lab).
  The AnimSet overlays still cover `lunge`, `staggerback` and `thump` as
  the backstop. `brain.lunges` / `brain.zJams` count entries and jams, and
  PROBE prints both — they should stay at zero. The on-ground family is
  deliberately uncovered: there is no verified player clip for a prone
  body, and standing an idle up on the floor would look worse than the
  vanilla get-up. Add those states to `tools/gen_animsets.lua` only once
  the clip names are read off a real install.
- **Every bandit plays by the same rules; a tier is gear.**
  `BNS.Behaviour` (in `BNS_Core.lua`) holds them once — robbery odds,
  the health a hurt bandit breaks off at, last-stand chance, grab hold,
  bash damage, spare magazines, squad size — and every tier reads it.
  Tiers used to fork the *rules*: only civilians ran when hurt, militia
  never robbed at all, each hit doors for a different number. That made a
  bandit's tier something to learn separately rather than the same person
  with better kit, and made each of those behaviours its own code path to
  get wrong. What a tier still decides is which weapons and outfits they
  roll, how likely a firearm is, and `BNS.Toughness`. **Nothing else may
  branch on `brain.tier`.**
- **Being hit interrupts.** `BNS.Combat.stagger` is the small version of
  being knocked down: it takes the swing they were part way through, cuts
  a settled aim, plays the flinch, and gates `canAttack`/`isBusy` for
  `STAGGER_TICKS`. Without it a fight is two damage numbers trading and
  nothing the player does buys them the next hit. Zombies stagger NPCs on
  the same rule — it is not a player privilege. `setStaggerBack` is safe
  to hand a shell where the combat-action flags are not: it is a
  *reaction*, so it does not drag them into the ballistics path.
- **Hostility is a role, not a program.** `BNS.Combat.attack` refuses
  outright unless `BNS.isHostile(brain)`, so a survivor or trader stood
  against a player does nothing whatever transition put them there; a
  neutral that turns on you has had its role flipped to `BANDIT` first.
  Never gate combat on which program happens to be running.
- **A gunner's answer to someone in their face is a shove, not a lunge.**
  `BNS.Combat.shove` plays BNS's *own* clip. It does no damage,
  symmetrically with `receiveHit`: pushing is not attacking in either
  direction. Inside `SHOVE_RANGE` the ATTACK program shoves; on cooldown
  it gives ground.
- **Never hand a shell an engine combat-action flag.**
  `setPerformingShoveAnimation(true)` crashed the game to the desktop:
  it puts the shell into an engine combat action, and a shell holding a
  firearm then enters the *player-only* ballistics path —
  `updateBallistics` → `BallisticsController.update` →
  `AimingReticle.getX` → `Core.getZoom(-1)` →
  `ArrayIndexOutOfBoundsException`. The reticle is player **input** UI,
  indexed by player number, and a zombie's is -1. The same reasoning bars
  `setPerformingAttackAnimation` and anything else that makes the engine
  run a character's own combat code: BNS simulates attacks itself, and the
  shell must only ever be given animation *variables*.
  `BNS.Combat.disarmBallistics` (run from the suppression pass) is the
  standing guard — it clears `isAiming` and releases any ballistics
  controller or target the shell has picked up.
- **`BNS.Combat.flag` is a getter probe; `applyFlag` is for setters.**
  `flag` calls with no arguments, so pointing it at a setter throws, dumps
  a Kahlua stack trace *and* then reports a working method as "unusable on
  this build". That happened on every shove.
- **Suppression must not park the shell.** `BNS.Suppress` (in
  `BNS_Core.lua`) gates the calls that stop a shell behaving like a
  zombie. Only `clearTarget` is on: it is what stops them lunging at
  players and it is understood. `setUseless` and `makeInactive` were added
  on a guess and are off — a parked character cannot walk, which is what
  "bandits don't walk around" looked like. Both are switchable from the
  Anim lab so the question gets answered in game.
- **The live/virtual boundary is the loaded world, not a radius.**
  `BNS.squareLoaded` is the only honest answer to "can an NPC exist
  here", and `BNS.Main.boundaryTick` is built on it: a record gets a body
  exactly when the square under it is streamed in, and gives it back when
  that stops being true (which also captures the position a shell had
  actually walked to, instead of losing it to the chunk unloading). A
  radius was the old rule and it was the bug — the streamed area is
  neither round nor a fixed size, so records could sit *inside* the wake
  radius on unloaded ground, and the old code only stepped records
  *outside* it: embodied never, moved never, for the rest of the save.
  Every branch must therefore either embody a record or move it on;
  `WAKE_FAILS` covers loaded ground that will not take a body, and the
  population cap is the one case that deliberately leaves a record
  standing (stepping it would slide an NPC across the street you are in).
  The boundary runs on `EveryOneMinute`, not the ten-minute director tick.
- **New NPCs are created virtual, outside the loaded world.** An NPC that
  appears inside the streamed area can pop in in front of you.
  `pickSpawnSquare` steps outward until it finds ground the engine has
  *not* loaded — it does not guess a streaming distance — and
  `BNS.Spawner.scatter` re-checks each squad member, because the picked
  square being unloaded says nothing about the one two tiles east.
  Nothing calls `materialise` at spawn any more. That means the live cap
  no longer throttles creation, so `BNS.recordCeiling()`
  (`maxLive * BNS.VirtualPool`) bounds the record pool and is checked per
  *record*, not per group.
- **Bandits arrive as a group and stay one — on both sides of the
  boundary.** `BNS_Squads` owns it. A squad is *managed* exactly when it
  has an entry in `state.squads`: wandering bandit groups get one at
  spawn, POI garrisons and raid parties deliberately do not, because they
  already have somewhere to be. The anchor follows its live members and
  carries its virtual ones — stepping records one at a time off-screen is
  what pulled squads across the map within a few in-game hours, so the
  player met the survivors of a group one at a time, which looks exactly
  like bandits spawning alone. Cohesion is mostly *where they choose to
  go*: `wanderTarget` picks milling destinations inside the group's
  bubble, and only pulls someone back when they are past `COHESION`
  (returning them to `REGROUP`, not to the edge). Each member's place in
  the formation is derived from their record id, so it is stable and no
  two stand on the same tile. An emptied squad is dropped, or the anchor
  pass carries a group of nobody around for the rest of the save.
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
- **A shove is not an attack, and a downed bandit is out of the fight.**
  `BNS.Combat.receiveHit` owns the rule: a push floors them and costs no
  health, while a swing or a stomp hurts — a push at someone *already*
  down is a stomp, so there is no shoving a bandit to death. Being down is
  `brain.downTimer`, which gates `canAttack` and `isBusy` and makes
  BNS_Brain skip the whole tick; the engine owns the fall, the get-up and
  the on-ground animation (which is why the overlays cover no on-ground
  state). The engine flags behind it are narrow on purpose —
  `isOnFloor` is IsoMovingObject's "standing on a floor tile" and is true
  of everyone upright, so reading it would down every NPC — and the state
  always expires on its own timer, with `DOWN_MAX` capping how long an
  engine answer is believed. An unverified flag stuck on true must never
  park an NPC for good; that is the `setUseless` lesson.
- **A shell has to be turned towards what it is hitting.** It points
  wherever the engine last left it -- usually the way it was walking --
  so bandits swung with their back to the player until
  `BNS.Combat.faceTarget` was called at the start of a swing, at contact,
  and on a throttle in between (facing is an engine command; per-tick
  engine commands are what make NPCs skate). Shooters face on each round
  and while holding aim.
- **Never trust an outfit name; ask what they are wearing.**
  `addZombiesInOutfit` takes an outfit *name*, and a name this build does
  not have leaves the shell with nothing on rather than erroring — which
  is how bandits turned up naked. `BNS.Look`'s `clothed` op reads
  `getWornItems():size()` and, only when that is zero, dresses them with
  `dressInRandomNonSillyOutfit`, which needs no name at all. A clothed
  bandit in the wrong jacket beats a naked one in the right story. It runs
  at materialise as well as on the slow re-assert, because a naked shell
  is naked from the first frame it is drawn, and PROBE prints `worn=`.
- **Human skin is not just the skin index.** `HumanVisual` carries a
  `zombieRotStage` -- the decay variant the texture creator composites
  over the body, rolled at spawn by `pickRandomZombieRotStage` -- and
  setting a living skin *index* does not undo it. `BNS.Look` zeroes it and
  **reads it back**, because a field a build will not let Lua write would
  otherwise report as working while nothing changed; a body texture name
  is then copied off a real player (`getSkinTexture`) rather than guessed
  from a list, and `checkUpdateModelTextures` rebuilds the composite,
  without which none of it shows.
- **The moan is a named emitter sound, so stop it by name.** There is no
  "be quiet" flag on the character, but the shell will give you the name
  (`getVoiceSoundName` / `getBiteSoundName`) and `BNS.Look.hush` stops
  exactly those on its own short throttle. Never `stopAll()`: footsteps
  and BNS's own gunshots go through the same emitter.
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
