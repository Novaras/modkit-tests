-- Ingame tests of `setBallistics` on fire types other than `Bullet` (see the wiki's `setBallistics` page, "Other fire types"): beams
-- (`InstantHit`), a missile, and sphere bursts. Run with `test engine/weapons/fire_types` (~10 min of game time);
-- `test engine/weapons` runs it with the rest of the folder, but `test engine` doesn't.
--
-- All on the test guns' Fixed mount, firing every 1s for 100 damage, like the baseline (`test_fixed`). Sphere bursts can't be fired
-- by themselves (the stock ones are spawned by another weapon's result), so each burst gun is a bullet gun whose shots deal no
-- damage but spawn a 300-radius burst where they strike (`AddWeaponResult(..., "SpawnWeaponFire", ...)`): the target's HP lost is
-- the burst's. Not tested: `Mine` (mines are laid by an ability, not fired at a target).

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

FIRE_TYPES_TEST = {
	--- A target flying straight at its gun from 4500 ahead, at full speed (so a steered 'miss' passes through it).
	approaching = function ()
		return {
			at = ENGINE_TEST.F * 4500,
			direction = ENGINE_TEST.F * -1,
			speed = 1,
			label = "flying straight at the gun at full speed",
		};
	end,
};

describe("setBallistics: other fire types (test weapons)", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		return sequence(
			ENGINE_TEST.spawnGuns(ctx, {
				baseline = "test_fixed",
				beam = "test_beam",
				beam_lead = "test_beam_lead",
				beam_steered = "test_beam_steered",
				beam_miss = "test_beam_miss",
				beam_steered_miss = "test_beam_steered_miss",
				missile = "test_missile",
				burst_hit = "test_fixed_burst_hit",
				burst_steered_miss = "test_fixed_burst_steered_miss",
				burst_ballistic_miss = "test_fixed_burst_ballistic_miss",
				burst_parentmiss = "test_fixed_burst_parentmiss",
			}),
			function ()
				for key, _ in %ctx.home do
					%ctx[key]:invulnerable(1);
				end
				-- (beams are instant and missiles accelerate: don't leave out early strikes as leftovers; see `ENGINE_TEST.fire`)
				%ctx.shot_speeds = { beam = 0, beam_lead = 0, beam_steered = 0, beam_miss = 0, beam_steered_miss = 0, missile = 0 };
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

	it("(rig) the baseline gun strikes a target dead ahead (and one 'hit' shot's damage is measured)", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "baseline", ENGINE_TEST.ahead().at),
			function ()
				ENGINE_TEST.hit_damage = %ctx.strike;
				print("[test engine] one 'hit' strike: " .. format("%.6f", %ctx.strike) .. " of the target's HP");
			end
		);
	end, { timeout = 60 });

	-- beams (InstantHit)

	it("(rig) the beam strikes a still target dead ahead (and one 'hit' beam's damage is measured)", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "beam", ENGINE_TEST.ahead().at),
			function ()
				FIRE_TYPES_TEST.beam_damage = %ctx.strike;
				print("[test engine] one 'hit' beam strike: " .. format("%.6f", %ctx.strike) .. " of the target's HP ("
					.. format("%.2f", %ctx.strike / ENGINE_TEST.hit_damage) .. " bullet strikes' worth)");
			end
		);
	end, { timeout = 60 });

	it("a beam gets no ballistic lead: with full lead, it doesn't strike a still target off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "beam_lead", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a beam isn't steered: a steered 'hit' beam doesn't strike a still target off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "beam_steered", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	-- (a 'miss' beam points 1-2 degrees off the gun's aim: 10-20 at 600, inside the frigate's hull)
	it("a 'miss' beam that strikes deals full damage (setMissProperties' damage fraction, 0.5, isn't applied)", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "beam_miss", ENGINE_TEST.F * 600),
			function ()
				expect(FIRE_TYPES_TEST.beam_damage, "needs the beam rig test's measured strike");
				local ratio = %ctx.strike / FIRE_TYPES_TEST.beam_damage;
				print("[test engine] one 'miss' beam strike: " .. format("%.2f", ratio) .. " of a 'hit' beam strike");
				expectNear(ratio, 1, 0.1, "a 'miss' beam strike's damage, as a fraction of a 'hit' beam strike's");
			end
		);
	end, { timeout = 60 });

	-- (a 'miss' beam is 1-2 degrees off: against a target flying straight at the gun from ~3700 it struck nothing (2026-11-09), so
	-- these use the target flying away from ~1400, close enough for the offset to stay on its hull at first)
	it("a ballistic 'miss' beam strikes a ship moving at full speed", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "beam_miss", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("a steered 'miss' beam passes through a ship moving at full speed", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "beam_steered_miss", ENGINE_TEST.away()),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	-- missiles

	it("a missile ignores setBallistics: with (0, 0), it still homes in on a still target off-axis", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "missile", ENGINE_TEST.offAxis()),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	-- sphere bursts (spawned where the burst guns' shots strike)

	it("(rig) a 'hit' burst damages a still target dead ahead (and one burst's damage is measured)", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "burst_hit", ENGINE_TEST.ahead().at),
			function ()
				FIRE_TYPES_TEST.burst_damage = %ctx.strike;
				print("[test engine] one 'hit' burst: " .. format("%.6f", %ctx.strike) .. " of the target's HP ("
					.. format("%.2f", %ctx.strike / ENGINE_TEST.hit_damage) .. " bullet strikes' worth)");
			end
		);
	end, { timeout = 60 });

	it("a steered 'miss' burst damages a still target as much as a 'hit' burst (no setMissProperties damage fraction)", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "burst_steered_miss", ENGINE_TEST.ahead().at),
			function ()
				expect(FIRE_TYPES_TEST.burst_damage, "needs the burst rig test's measured damage");
				local ratio = %ctx.strike / FIRE_TYPES_TEST.burst_damage;
				print("[test engine] one steered 'miss' burst: " .. format("%.2f", ratio) .. " of a 'hit' burst");
				expectNear(ratio, 1, 0.1, "a 'miss' burst's damage, as a fraction of a 'hit' burst's");
			end
		);
	end, { timeout = 60 });

	-- (first run, 2026-11-09: the steered 'miss' burst damaged a ship at full speed (7 strikes' worth), which it shouldn't if it
	-- were marked as a 'miss'. Perhaps a spawned burst takes the mark of the shot that spawned it (these parents always fire
	-- 'hits'), rather than rolling its own accuracy. Logs only until that's known)
	it("(diagnostic: logs only) a 'miss'-accuracy steered burst, spawned by a 'hit' shot, vs a ship moving at full speed", function (ctx)
		return ENGINE_TEST.fire(ctx, "burst_steered_miss", ENGINE_TEST.away());
	end, { timeout = 90 });

	it("(diagnostic: logs only) a 'miss'-accuracy ballistic burst, spawned by a 'hit' shot, vs a ship moving at full speed", function (ctx)
		return ENGINE_TEST.fire(ctx, "burst_ballistic_miss", ENGINE_TEST.away());
	end, { timeout = 90 });

	-- (the other way round: a 'hit'-accuracy steered burst spawned by a ballistic 'miss' shot. Not damaged: the burst took the
	-- parent's 'miss' mark; damaged: it rolled its own)
	it("(diagnostic: logs only) a 'hit'-accuracy steered burst, spawned by a 'miss' shot, vs a ship moving at full speed", function (ctx)
		return ENGINE_TEST.fire(ctx, "burst_parentmiss", ENGINE_TEST.away());
	end, { timeout = 90 });
end);
