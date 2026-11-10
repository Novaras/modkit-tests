-- Ingame tests of shots against a non-ship: the sandbox level's asteroid (`ENGINE_TEST.ASTEROID`, an `Asteroid_4` added in
-- `modkit_sandbox.level`; asteroids can't be spawned in game) between a gun and its still target. Run with
-- `test engine/weapons/asteroid` (~3 min of game time); `test engine/weapons` runs it with the rest of the folder, but `test engine` doesn't. Worth watching: the asteroid is at
-- (12000, 3000, -30000), and the gun is moved there and back for each test.
--
-- Runs (2026-11-08): the asteroid was at y -4000, and the target, moved there from y 5000, ended up turned (it can't level out) and
-- ~40 to one side of its spot, so the gun's shots passed beside it, even in the controls. Watched in game, the ballistic shots
-- struck the asteroid and the steered 'miss' shots passed through it, as expected. The asteroid is now at the test ships' height,
-- and the target is spawned at its spot.

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

describe("setBallistics: an asteroid in the way", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		return sequence(
			ENGINE_TEST.spawnGuns(ctx, {
				baseline = "test_fixed",
				miss = "test_fixed_miss",
				steered_miss = "test_fixed_steered_miss",
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

	it("(rig) at its usual spot, the gun strikes a still target 2400 dead ahead with every shot", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "baseline", ENGINE_TEST.ahead().at),
			function ()
				ENGINE_TEST.hit_damage = %ctx.strike;
			end,
			wait(ENGINE_TEST.TAIL_SECONDS), -- (shots still in flight from the first strike would otherwise land in the next count)
			function ()
				return ENGINE_TEST.fire(%ctx, "baseline", { at = ENGINE_TEST.F * 2400, label = "still, 2400 dead ahead" });
			end,
			function ()
				expect(%ctx.drop / ENGINE_TEST.hit_damage > 5.5, "the target should have been struck by most shots: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 90 });

	it("(rig) 6000 to the side of the asteroid, with nothing in the way, the gun strikes its target with every shot", function (ctx)
		return sequence(
			ENGINE_TEST.fireAcrossAsteroid(ctx, "baseline", 6000),
			function ()
				expect(%ctx.drop / ENGINE_TEST.hit_damage > 5.5, "the target should have been struck by most shots: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("(rig) 2500 to the side of the asteroid, with nothing in the way, the gun strikes its target with every shot", function (ctx)
		return sequence(
			ENGINE_TEST.fireAcrossAsteroid(ctx, "baseline", 2500),
			function ()
				expect(%ctx.drop / ENGINE_TEST.hit_damage > 5.5, "the target should have been struck by most shots: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a ballistic shot marked as a 'hit' strikes an asteroid in the way: the target behind it isn't struck", function (ctx)
		return sequence(
			ENGINE_TEST.fireAcrossAsteroid(ctx, "baseline", 0),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a ballistic shot marked as a 'miss' strikes an asteroid in the way: the target behind it isn't struck", function (ctx)
		return sequence(
			ENGINE_TEST.fireAcrossAsteroid(ctx, "miss", 0),
			function ()
				expect(%ctx.drop == 0, "the target shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("a steered shot marked as a 'miss' passes through an asteroid in the way, and strikes the still target behind it", function (ctx)
		return sequence(
			ENGINE_TEST.fireAcrossAsteroid(ctx, "steered_miss", 0),
			function ()
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });
end);
