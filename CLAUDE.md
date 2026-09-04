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
- **Puppet + proxy rendering.** The shell is the puppet: it paths, collides,
  takes damage and replicates to MP clients for free — that replication is
  the whole reason the shell design exists and must not be traded away.
  What players see is a client-side `IsoPlayer` proxy (`BNS_Body.lua`)
  mirroring it, fed by `BNS_Visual.lua` (clients cannot read a puppet's
  brain — mod data does not replicate — so the server sends id, online id,
  position, gait, weapon and appearance). Two invariants: **never draw a
  proxy over a visible puppet** (prove hiding works first — a `pcall` that
  merely does not error proves nothing, since alpha is re-driven each frame —
  else disable the layer), and **every engine call in that layer is
  `pcall`-guarded** with a clean fallback to shell rendering.
- Appearance does *not* depend on proxies: `BNS_Look.lua` restyles the shell
  itself (living skin, no blood/wounds, clean clothing) so NPCs look human
  even where player bodies are unavailable. Keep those two concerns separate.
- When something in this layer doesn't work in-game, extend
  `BNS.Body.probe()` rather than guessing: it prints a pass/fail line per
  pipeline step, including whether the server's snapshots arrive at all.
- Client code (`42/media/lua/client/BNS/`) only renders speech/UI and sends
  commands; the server validates everything (trades, locks).
- The `BNS` Lua namespace and `BNS_*` file names are internal and kept from
  the original project — do not mass-rename them.
- The AnimSet overlay XMLs in `42/media/AnimSets/zombie/` (gated on
  `BNSNPC`/`BNSAnim` set by `BNS_Anim.lua`) are now the *fallback* look, used
  only when player-body proxies are off or unsupported.
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

Engine names that cannot be checked offline (attack/aim variables, character
hiding, hair models) belong in a *candidate list* driven by the debug panel's
Anim lab rather than a single guess in the code — see `BNS.Body.ActionCandidates`.
Once a candidate is confirmed in-game, make it the default.

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
