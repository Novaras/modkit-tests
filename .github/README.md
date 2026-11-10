# modkit-tests

The test suites for [modkit](https://github.com/Novaras/modkit), kept out of the framework so mods built on modkit don't carry them.

modkit itself keeps only what a mod author needs to write their own tests: the `test` console command and the harness
(`scripts/modkit/test_harness.lua`: `describe` / `it` / `expect...`). This repo has modkit's own suites, and the ships and weapons they use.

## Getting them

The files go at the same paths in a modkit folder, so they're copied on top of it with [degit](https://www.npmjs.com/package/degit). From
`modkit-tools`:

```
npm run tests                # latest
npm run tests -- #some-branch  # or a branch, tag or commit
```

modkit's `.gitignore` covers every path here, so fetching them leaves modkit's working tree clean.

## What's here

- **In-game suites** (`scripts/modkit/tests/`), run from the console with `test <name>` (i.e. `test ship`, `test engine/weapons/basics`,
  or `test` for everything):
  - `ship.lua`, `objectives.lua`: modkit's `Ship` and objectives APIs.
  - `engine/`: what the game engine does (weapon lead, accuracy and miss behaviour, bursts, combat, movement, volumes). Used to check
    findings for the [Karos Graveyard wiki](https://github.com/HWRM/KarosGraveyard/wiki).
  - `scopes.lua`: dumps each Lua scope's globals to the log, for checking which functions each scope has.
  - `lib/`: helpers for the suites (ship spawning, the weapon rig, the lead suite, the globals dump).
- **Test assets**: the `test` race (`scripts/races/test*`), and its `ship/test_*`, `weapon/test_*` and `subsystem/test_*` files, plus the
  custom code for `test_globals_dump` (`scripts/custom_code/test_globals_dump.lua`).
- **Offline unit tests** (`modkit-tools/tests/`, run by `modkit-tools/test.js`): modkit's pure-Lua code, run with a Lua 4.0 interpreter:
  `npm test` in `modkit-tools` (see `test.js` for setting up Lua 4.0).

The in-game suites need game time, so close the console once they begin. Launch the game with `-luatrace` to get full results in the log.
