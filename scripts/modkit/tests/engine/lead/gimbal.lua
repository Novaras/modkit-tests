-- Ingame tests of engine behaviour: `setBallistics`' lead against moving targets, from `Gimble` guns (they aim themselves within a
-- cone) at lead 1, 0.9 (as the stock lead weapons) and 0 (the gimbal's own aim). Run with `test engine/lead/gimbal` (not part of
-- `test engine`). About 25 minutes of game time (its five guns run each set-up at once). The suite is described in `tests/lib/lead_suite.lua`.

dofilepath("data:scripts/modkit/tests/lib/lead_suite.lua");

ENGINE_TEST.leadSuite("lead against moving targets: gimbal guns (test weapons)", {
	{ key = "gimbal_lead", ship = "test_gimbal_lead", label = "gimbal, full lead" },
	{ key = "gimbal_lead09", ship = "test_gimbal_lead09", label = "gimbal, lead 0.9" },
	{ key = "gimbal", ship = "test_gimbal", label = "gimbal, no lead" },
	-- (reference: the same gun on the stock `frontal_frigate` attack style, which the other test guns no longer use: its random
	-- actions while firing lose blocks of ~3 shots in ~1/3 of attacks (2026-11-09))
	{ key = "gimbal_frontal", ship = "test_gimbal_frontal", label = "gimbal, no lead, frontal_frigate attack style (reference)" },
	-- (and without the gimbal's own lead (`iUseVelocityPred` 0): it aims at where the target is now)
	{ key = "gimbal_nopred", ship = "test_gimbal_nopred", label = "gimbal, no lead, no native lead" },
});
