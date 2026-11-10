-- Ingame tests of engine behaviour: `setBallistics`' lead against moving targets, from a `Fixed` gun (it never aims itself, so
-- every shot's direction comes from lead alone). Run with `test engine/lead/fixed` (not part of `test engine`). Slow: about 35
-- minutes of game time. The suite is described in `tests/lib/lead_suite.lua`.

dofilepath("data:scripts/modkit/tests/lib/lead_suite.lua");

ENGINE_TEST.leadSuite("lead against moving targets: fixed gun (test weapons)", {
	{ key = "lead", ship = "test_fixed_lead", label = "fixed, full lead" },
}, { world_centre = 1 });
