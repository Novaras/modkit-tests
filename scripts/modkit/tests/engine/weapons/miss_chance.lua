-- Ingame diagnostics of the chance that a steered shot marked as a 'miss' strikes a slow ship (see the wiki's `setBallistics`
-- page, "Steered shots"). Run with `test engine/weapons/miss_chance` (~6 min of game time: every set-up runs at once, each gun with its own target); `test engine/weapons` runs it with the
-- rest of the folder, but `test engine` doesn't.
--
-- A steered gun whose every shot is marked as a 'miss' (with no miss cone, so they all fly along its axis) fires at a target
-- flying straight at it, at a few speeds; a ballistic one (whose 'miss' shots always strike) counts how many shots a run fires.
-- The rig is in `tests/lib/weapon_rig.lua`.
--
-- Read from the exe (to be checked): under 5% of the ship's `mainEngineMaxSpeed` always struck, over 30% never, and in between
-- `(0.30 - speed / max speed) / 0.25`, rolled once per collision. In game (2026-11-08, 5 runs of 8 shots each, approaching from
-- 4500, 600/s shots): 9.8% 0.95 (formula 0.81), 14.8% 0.82 (0.61), 24.7% 0.77 (0.21), 34.8% 0.35 (0); a ship with max speed 1000
-- at 14.8% (148/s): 0.97. So it is judged against the ship's own max speed, but struck far more often than the formula says, even
-- past 30%. If the roll is repeated every update while the shot is inside the hull, slower shots (longer inside) would be struck
-- more: hence the 150/s vs 600/s comparison.
--
-- Found since (2026-11-08): the max speed it's judged against is `mainEngineMaxSpeed` divided by `Formation.VelocityMultiplier`
-- (`scripts/tuning.lua`, 0.7), so the limits are ~7% and ~43% of `mainEngineMaxSpeed`. That fits most of the shares above; the rest
-- fit two rolls per pass. The logs now give both.

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

MISS_CHANCE_TEST = {
	RUNS = 5,
	--- A target flying straight at its gun from `from` (default 4500) ahead, at `speed` times `max_speed` (default the test target's).
	approaching = function (speed, max_speed, from)
		return {
			at = ENGINE_TEST.F * (from or 4500),
			direction = ENGINE_TEST.F * -1,
			speed = speed,
			max_speed = max_speed,
			label = "flying straight at the gun from " .. (from or 4500) .. " at " .. floor(speed * 100) .. " percent speed",
		};
	end,
	--- The game's `Formation.VelocityMultiplier` (`scripts/tuning.lua`: 0.7 in the stock game). The speed check judges a ship against
	--- its `mainEngineMaxSpeed` divided by this (found 2026-11-08: the in-game shares fit it).
	VELOCITY_MULTIPLIER = 0.7,
	--- The chance of one roll striking a ship at `speed` with `max_speed` (`mainEngineMaxSpeed`).
	expected = function (speed, max_speed)
		local fraction = speed / (max_speed / MISS_CHANCE_TEST.VELOCITY_MULTIPLIER);
		if (fraction < 0.05) then
			return 1;
		elseif (fraction > 0.30) then
			return 0;
		end
		return (0.30 - fraction) / 0.25;
	end,
	--- One gun per set-up, all run at once (each a lane with its own target: see `ENGINE_TEST.makeLane`). `control` is a ballistic
	--- 'miss' gun, whose shots always strike: it counts the shots per run. The rest fire steered 'miss' shots at a target approaching
	--- at `speed` times `max_speed` (default the test target's) from `from` (default 4500).
	LANES = {
		{ key = "control", ship = "test_fixed_miss", speed = 0.25 },
		{ key = "s10", ship = "test_fixed_steered_miss", speed = 0.1 },
		{ key = "s15", ship = "test_fixed_steered_miss", speed = 0.15 },
		{ key = "s25", ship = "test_fixed_steered_miss", speed = 0.25 },
		{ key = "s35", ship = "test_fixed_steered_miss", speed = 0.35 },
		-- (`test_target_fast`: max speed 1000. At ~150/s a test_target (max 206) would be at 73 percent, and at 35 percent (72/s)
		-- one was struck by about a third of the shots, so far more than that here means it's the ship's own max speed that counts)
		{ key = "fast", ship = "test_fixed_steered_miss", speed = 0.15, max_speed = 1000, target = "test_target_fast" },
		-- (600/s against 150/s shots, from 2500: a slow shot spends 4x as long inside the hull)
		{ key = "near25", ship = "test_fixed_steered_miss", speed = 0.25, from = 2500 },
		{ key = "near35", ship = "test_fixed_steered_miss", speed = 0.35, from = 2500 },
		{ key = "slow25", ship = "test_fixed_steered_miss_slow", speed = 0.25, from = 2500 },
		{ key = "slow35", ship = "test_fixed_steered_miss_slow", speed = 0.35, from = 2500 },
	},
	--- Logs a lane's share of shots that struck (against the control's shot count) beside the one- and two-roll chances, and
	--- returns the share.
	summarise = function (lane, spec, shots)
		local max_speed = spec.max_speed or ENGINE_TEST.TARGET_MAX_SPEED;
		local strikes, measured = 0, 0;
		for i = 1, MISS_CHANCE_TEST.RUNS do
			strikes = strikes + lane.run_strikes[i];
			measured = measured + lane.run_speeds[i] / MISS_CHANCE_TEST.RUNS;
		end
		local share = strikes / shots;
		local one = MISS_CHANCE_TEST.expected(measured, max_speed);
		print("[test engine] " .. spec.key .. " (" .. spec.ship .. ", from " .. (spec.from or 4500) .. ") vs a target at " .. format("%.0f", measured)
			.. "/s (" .. format("%.1f", measured / max_speed * 100) .. " percent of its max " .. max_speed .. "/s): struck by "
			.. format("%.1f", strikes) .. " of ~" .. format("%.1f", shots) .. " shots (" .. format("%.2f", share) .. "); one roll gives "
			.. format("%.2f", one) .. ", two rolls " .. format("%.2f", 1 - (1 - one) * (1 - one)));
		return share;
	end,
};

describe("setBallistics: the chance a steered 'miss' strikes a slow ship", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		-- (150/s shots take up to ~8s to reach a target 1700 away: watch longer after firing stops)
		MISS_CHANCE_TEST.tail = ENGINE_TEST.TAIL_SECONDS;
		ENGINE_TEST.TAIL_SECONDS = 10;
		local guns = {};
		for i = 1, modkit.table.length(MISS_CHANCE_TEST.LANES) do
			guns[MISS_CHANCE_TEST.LANES[i].key] = MISS_CHANCE_TEST.LANES[i].ship;
		end
		return sequence(
			ENGINE_TEST.spawnGuns(ctx, guns, 1), -- (spread out: 9000 apart, out of each other's range)
			function ()
				for key, _ in %ctx.home do
					%ctx[key]:invulnerable(1);
				end
				return ENGINE_TEST.calibrate(%ctx, "control");
			end
		);
	end, { timeout = 120 });

	beforeEach(function (ctx)
		local keys, types = {}, {};
		for i = 1, modkit.table.length(MISS_CHANCE_TEST.LANES) do
			local spec = MISS_CHANCE_TEST.LANES[i];
			keys[i] = spec.key;
			types[spec.key] = spec.target;
			if (ctx[spec.key] and not ctx[spec.key]._destroyed) then
				ctx[spec.key]:ROE(PassiveROE);
				ctx[spec.key]:stop();
			end
		end
		MISS_CHANCE_TEST.keys = keys;
		return ENGINE_TEST.spawnLaneTargets(ctx, keys, types);
	end, { timeout = 30 });

	afterEach(function (ctx)
		ENGINE_TEST.killLaneTargets(ctx, MISS_CHANCE_TEST.keys);
	end);

	after(function (ctx)
		ENGINE_TEST.TAIL_SECONDS = MISS_CHANCE_TEST.tail or ENGINE_TEST.TAIL_SECONDS;
		SHIP_TEST.cleanup(ctx);
	end);

	-- (strikes are counted in one 'miss' strike's damage: every gun's 'miss' shots deal the same half damage)
	it("(rig) one 'miss' strike's damage, measured against a still target dead ahead", function (ctx)
		local lane = ENGINE_TEST.makeLane(ctx, "control", "target_control");
		return sequence(
			ENGINE_TEST.firstStrike(lane, "control", ENGINE_TEST.ahead().at),
			function ()
				ENGINE_TEST.hit_damage = %lane.strike;
				print("[test engine] one 'miss' strike: " .. format("%.6f", %lane.strike) .. " of the target's HP");
			end
		);
	end, { timeout = 60 });

	it("every set-up at once (logs the shares); a ship with max speed 1000 at 150/s (15 percent) is struck by most shots", function (ctx)
		local lanes = {};
		local branches = { n = 0 };
		for i = 1, modkit.table.length(MISS_CHANCE_TEST.LANES) do
			local spec = MISS_CHANCE_TEST.LANES[i];
			lanes[i] = ENGINE_TEST.makeLane(ctx, spec.key, "target_" .. spec.key);
			branches.n = branches.n + 1;
			branches[branches.n] = ENGINE_TEST.fireRepeated(lanes[i], spec.key,
				MISS_CHANCE_TEST.approaching(spec.speed, spec.max_speed, spec.from), MISS_CHANCE_TEST.RUNS);
		end
		return sequence(
			call(parallel, branches),
			function ()
				local shots = 0;
				for r = 1, MISS_CHANCE_TEST.RUNS do
					shots = shots + %lanes[1].run_strikes[r];
				end
				print("[test engine] control: " .. format("%.1f", shots) .. " shots in " .. MISS_CHANCE_TEST.RUNS .. " runs (all strike)");
				expect(shots > MISS_CHANCE_TEST.RUNS * 4, "expected at least 4 shots a run from the control (" .. format("%.1f", shots) .. ")");
				local fast_share = nil;
				for i = 2, modkit.table.length(MISS_CHANCE_TEST.LANES) do
					local spec = MISS_CHANCE_TEST.LANES[i];
					local share = MISS_CHANCE_TEST.summarise(%lanes[i], spec, shots);
					if (spec.key == "fast") then
						fast_share = share;
					end
				end
				expect(fast_share > 0.6, "most shots should have struck the max-1000 target (" .. format("%.2f", fast_share) .. ")");
			end
		);
	end, { timeout = 600 });
end);
