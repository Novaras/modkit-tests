-- Ingame tests of engine behaviour (weapons: `setBallistics`).
-- Part of `test engine` (see `tests/engine.lua`) and `test engine/weapons` (the whole folder), or run alone with
-- `test engine/weapons/basics`.
--
-- Each test weapon differs from the baseline (`test_fixed`: a `Fixed` mount, which fires along its hardpoint and never aims
-- itself; ballistic, no lead, every shot marked as a 'hit') in one setting. Whether a shot physically struck the target shows as
-- HP lost, counted in strikes of one 'hit' shot's damage. The rig is in `tests/lib/weapon_rig.lua`.

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

-- What `setBallistics` does (see the wiki's `setBallistics` page). Needs an enemy player (for the target), so it's skipped without
-- one. Slow: about 20s of game time per test.
describe("setBallistics (test weapons)", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		return sequence(
			ENGINE_TEST.spawnGuns(ctx, {
				baseline = "test_fixed",
				steered = "test_fixed_steered",
				lead = "test_fixed_lead",
				halflead = "test_fixed_halflead",
				miss = "test_fixed_miss",
				steered_miss = "test_fixed_steered_miss",
				steered_miss_damage = "test_fixed_steered_miss_damage",
				steered_miss_damage_first = "test_fixed_steered_miss_damage_first",
				steered_miss_damage_half = "test_fixed_steered_miss_damage_half",
				steered_miss_damage_negative = "test_fixed_steered_miss_damage_negative",
				steered_miss_damage_zero = "test_fixed_steered_miss_damage_zero",
				steered_miss_damage_case = "test_fixed_steered_miss_damage_case",
				steered_miss_damage_string = "test_fixed_steered_miss_damage_string",
				steered_miss_damage_alone = "test_fixed_steered_miss_damage_alone",
				leadrange = "test_fixed_leadrange",
				lead_miss = "test_fixed_lead_miss",
				miss_results = "test_fixed_miss_results",
				hit_missresult = "test_fixed_hit_missresult",
				missburst = "test_fixed_missburst",
			}),
			function ()
				for key, _ in %ctx.home do
					%ctx[key]:invulnerable(1);
				end
				return ENGINE_TEST.calibrate(%ctx, "baseline");
			end
		);
	end, { timeout = 90 });

	beforeEach(function (ctx)
		for key, _ in ctx.home do
			if (ctx[key] and not ctx[key]._destroyed) then
				ctx[key]:ROE(PassiveROE);
				ctx[key]:stop();
			end
		end
		ctx.target = nil;
		return SHIP_TEST.spawn(ctx, "target", "test_target", { player = ctx.enemy.id, offset = { 0, 2000, -9000 } });
	end, { timeout = 30 });

	afterEach(function (ctx)
		if (ctx.target and not ctx.target._destroyed) then
			ctx.target:die(1);
		end
	end);

	after(function (ctx)
		SHIP_TEST.cleanup(ctx);
	end);

	-- calibration: the rig works as intended

	it("(rig) the gun strikes a target dead ahead (and one 'hit' shot's damage is measured)", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "baseline", ENGINE_TEST.ahead().at),
			function ()
				ENGINE_TEST.hit_damage = %ctx.strike;
				print("[test engine] one 'hit' strike: " .. format("%.6f", %ctx.strike) .. " of the target's HP");
			end
		);
	end, { timeout = 60 });

	it("(rig) the gun fires along its forward axis, not at the target: it never strikes one off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "baseline", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	-- steering and lead (all with stationary targets)

	it("a steered shot marked as a 'hit' turns towards its target: it strikes one off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("full lead aims a shot marked as a 'hit' at the (predicted) target: it strikes a still one off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "lead", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("half lead aims halfway between the gun's axis and the target: it doesn't strike a still one off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "halflead", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	-- shots marked as a 'miss'

	it("a shot marked as a 'miss' that strikes deals setMissProperties' damage fraction (half)", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "miss", ENGINE_TEST.ahead().at),
			function ()
				print("[test engine] one 'miss' strike: " .. format("%.6f", %ctx.strike) .. " ('hit' strike: " .. format("%.6f", ENGINE_TEST.hit_damage or 0) .. ")");
				expect(ENGINE_TEST.hit_damage, "needs the first test's measured 'hit' strike");
				expectNear(%ctx.strike / ENGINE_TEST.hit_damage, 0.5, 0.05, "a 'miss' strike's damage, as a fraction of a 'hit' strike's");
			end
		);
	end, { timeout = 60 });

	-- a Bullet weapon with any "Miss" result doesn't strike: each shot flies into its target and ends once past the target's centre,
	-- applying only its "Miss" results there, so its "Hit" results never apply (found 2026-11-09: these guns did no
	-- damage, their shells visibly reaching the target)

	it("a gun with a \"Miss\" result never strikes: a 'miss' gun with \"Hit\" and \"Miss\" damage does no damage", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "miss_results", ENGINE_TEST.ahead()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been damaged: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a gun with a \"Miss\" result never strikes, even with every shot marked as a 'hit'", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "hit_missresult", ENGINE_TEST.ahead()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been damaged: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a \"Miss\" SpawnWeaponFire result spawns its burst where the shot ends, at the target: the burst damages it", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "missburst", ENGINE_TEST.ahead()),
			function ()
				expect(%ctx.drop > 0, "the target should have been damaged by the bursts: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a steered shot marked as a 'miss' strikes a stationary ship", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss", ENGINE_TEST.ahead()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a steered shot marked as a 'miss' flies through a ship moving at full speed", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("a ballistic shot marked as a 'miss' strikes a ship moving at full speed", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "miss", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("setAccuracy's `damage` flag makes a steered shot marked as a 'miss' strike that family even at full speed", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	-- the `damage` flag's form: each against the same full-speed target as above, so only the flag decides whether it's struck

	it("the `damage` flag works written before the family: `{ damage = 1, Frigate = ... }`", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage_first", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("the `damage` flag works with a fractional value: `damage = 0.5`", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage_half", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("the `damage` flag works with a negative value: `damage = -1`", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage_negative", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("`damage = 0` doesn't flag the family: the shot flies through", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage_zero", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("the `damage` flag's case doesn't matter: `Damage = 1`", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage_case", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("a `damage` value that isn't a number doesn't flag the family: `damage = \"yes\"`", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage_string", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("`damage` in an entry of its own doesn't flag anything: `{ Frigate = ... }, { damage = 1 }`", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered_miss_damage_alone", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	-- ballistic lead's range, and shots marked as a 'miss' (all with still targets)

	it("a shot marked as a 'miss' gets no ballistic lead: with full lead, it doesn't strike a still target off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "lead_miss", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	-- (full lead strikes this target, and half lead never does (tests above), so with a lead fraction picked between 0.8 and 1 for
	-- each shot, only the shots that get close to full lead strike: some, but not all. Shots per run vary with how soon the gun
	-- opens fire, so full lead's strikes over the same number of runs are the reference)
	it("lead_min to lead_max: each shot gets its own random fraction: some, but not all, strike a still target off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fireRepeated(ctx, "lead", ENGINE_TEST.offAxis(), 4),
			function ()
				%ctx.full_total = 0;
				for i = 1, 4 do
					%ctx.full_total = %ctx.full_total + %ctx.run_strikes[i];
				end
				return ENGINE_TEST.fireRepeated(%ctx, "leadrange", ENGINE_TEST.offAxis(), 4);
			end,
			function ()
				local total = 0;
				for i = 1, 4 do
					total = total + %ctx.run_strikes[i];
				end
				print("[test engine] lead 0.8 to 1: " .. format("%.1f", total) .. " strikes; full lead: " .. format("%.1f", %ctx.full_total));
				expect(total > 0.5, "some shots should have struck (lead 0.8 to 1: " .. format("%.1f", total) .. ")");
				expect(total < 0.8 * %ctx.full_total, "fewer shots should have struck than with full lead (lead 0.8 to 1: "
					.. format("%.1f", total) .. "; full lead: " .. format("%.1f", %ctx.full_total) .. ")");
			end
		);
	end, { timeout = 480 });

	-- steered shots marked as a 'hit' home in only while the target is ahead of them. A fixed gun fires along its axis, so a still
	-- target more than 90 degrees off that axis is behind each shot as it's fired

	it("a steered shot marked as a 'hit' homes in on a still target 80 degrees off-axis (still ahead of the shot)", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered", { at = ENGINE_TEST.atAngle(80), label = "still, 80 degrees off-axis" }),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a steered shot marked as a 'hit' doesn't home in on a still target 100 degrees off-axis (behind the shot)", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "steered", { at = ENGINE_TEST.atAngle(100), label = "still, 100 degrees off-axis" }),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	-- ships in the way: a still ship halfway between the gun and its still target, dead ahead

	it("a ballistic shot marked as a 'hit' strikes an enemy ship in the way, not its target", function (ctx)
		return ENGINE_TEST.fireWithBlocker(ctx, "baseline", ctx.enemy.id);
	end, { timeout = 90 });

	it("a ballistic shot marked as a 'hit' strikes a friendly ship in the way, not its target", function (ctx)
		return ENGINE_TEST.fireWithBlocker(ctx, "baseline", SHIP_TEST.player);
	end, { timeout = 90 });

	-- (ballistic lead against moving targets: `tests/engine/lead/`; the chance of a steered 'miss' striking a slow ship:
	-- `tests/engine/weapons/miss_chance.lua`; asteroids in the way: `tests/engine/weapons/asteroid.lua`; homing by angle:
	-- `tests/engine/weapons/homing.lua`)
end);
