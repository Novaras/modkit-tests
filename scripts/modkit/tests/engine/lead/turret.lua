-- Ingame tests of engine behaviour: `setBallistics`' lead against moving targets, from `AnimatedTurret` guns (turrets that turn to
-- track their target; the stock `kus_assaultgun` turret, as `subsystem/test_turret*_subs`) at lead 1, 0.9 (as the stock lead weapons) and 0 (the turret's
-- own aim). Run with `test engine/lead/turret` (not part of `test engine`). About 25 minutes of game time (its three guns run each set-up at once). The suite is
-- described in `tests/lib/lead_suite.lua`.

dofilepath("data:scripts/modkit/tests/lib/lead_suite.lua");

ENGINE_TEST.leadSuite("lead against moving targets: turret guns (test weapons)", {
	{ key = "turret_lead", ship = "test_turret_lead", subsystem = "test_turret_lead_subs", hardpoint = "Weapon_Gun0", label = "turret, full lead" },
	{ key = "turret_lead09", ship = "test_turret_lead09", subsystem = "test_turret_lead09_subs", hardpoint = "Weapon_Gun0", label = "turret, lead 0.9" },
	{ key = "turret", ship = "test_turret", subsystem = "test_turret_subs", hardpoint = "Weapon_Gun0", label = "turret, no lead" },
});
