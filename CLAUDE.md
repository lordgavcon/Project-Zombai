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
  `<m_Type>STRING</m_Type>` with `<m_Value>`; pairing it with
  `<m_StringValue>` matches nothing and the node silently never plays.
  Clip names (`Bob_*`) and `Weapon` values (`1handed`, `2handed`, `heavy`,
  `knife`, `spear`, `handgun`, `firearm`, `chainsaw`, `throwing`) must come
  from the game's own `media/AnimSets/player/`, never from memory —
  `tests/test_anim.lua` enforces the form and the mode coverage.
- **Engine commands are rationed.** A shell is moved by the engine's own
  pathfinder, so every extra order restarts its movement mid-step and the
  NPC visibly skates. Path orders go through `BNS.Programs.walkTo`, which
  issues at most one per `REPATH_TICKS` brain ticks unless the goal really
  moved; `stopMoving` halts once and is a no-op while already stopped; and
  zombie suppression re-asserts a few times a second, not every frame.
  Never add a per-tick engine call to the brain without a throttle.
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
