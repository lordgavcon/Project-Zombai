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
- Client code (`42/media/lua/client/BNS/`) only renders speech/UI and sends
  commands; the server validates everything (trades, locks).
- The `BNS` Lua namespace and `BNS_*` file names are internal and kept from
  the original project — do not mass-rename them.
- Player animations come from AnimSet overlay XMLs in
  `42/media/AnimSets/zombie/`, gated on `BNSNPC`/`BNSAnim` variables set by
  `BNS_Anim.lua`.
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
door/lock methods) cannot be verified offline — they are best-effort against
B42.20 and are listed in README "Known limitations". In-game errors appear
as `[BNS]` lines in the game's `console.txt`.
