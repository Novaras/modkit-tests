-- Ingame diagnostic: how far a steered shot marked as a 'hit' can turn to home in. A fixed gun fires along its axis, so a still
-- target `n` degrees off that axis needs each shot to turn `n` degrees. Run with `test engine/weapons/homing` (~8 min of game time);
-- `test engine/weapons` runs it with the rest of the folder, but `test engine` doesn't.
--
-- First run (2026-11-08, `test engine/weapons`): 30 degrees: 8 of 8 shots struck; 80 degrees: 3 of 8; 100 degrees: none. So
-- homing may be limited before 90 degrees (or by distance), not only by the target being ahead of the shot. (That run's targets
-- were still drifting at up to 5/s; they now settle first.)

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

HOMING_TEST = {
	ANGLES = { 30, 50, 60, 70, 80, 85, 95 },
	RUNS = 2,
};

describe("setBallistics: how far a steered 'hit' shot turns to home in (diagnostic)", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		return sequence(
			ENGINE_TEST.spawnGuns(ctx, {
				baseline = "test_fixed",
				steered = "test_fixed_steered",
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

	it("(rig) one 'hit' strike's damage, against a still target dead ahead", function (ctx)
		return sequence(
			ENGINE_TEST.firstStrike(ctx, "baseline", ENGINE_TEST.ahead().at),
			function ()
				ENGINE_TEST.hit_damage = %ctx.strike;
			end
		);
	end, { timeout = 60 });

	for i = 1, modkit.table.length(HOMING_TEST.ANGLES) do
		local angle = HOMING_TEST.ANGLES[i];
		it("(diagnostic: logs only) steered 'hit' shots vs a still target " .. angle .. " degrees off-axis, 2500 away, repeated", function (ctx)
			return ENGINE_TEST.fireRepeated(ctx, "steered", { at = ENGINE_TEST.atAngle(%angle), label = "still, " .. %angle .. " degrees off-axis" }, HOMING_TEST.RUNS);
		end, { timeout = 120 });
	end
end);
