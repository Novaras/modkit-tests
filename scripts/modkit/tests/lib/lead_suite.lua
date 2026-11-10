-- The lead test suite (`setBallistics`' lead against moving targets), shared by `tests/engine/lead/fixed.lua`, `gimbal.lua` and
-- `turret.lua`, one per weapon mount. Each defines its suite with `ENGINE_TEST.leadSuite`. These are long diagnostics (20-35 min
-- of game time each; every gun runs each set-up at once), so they're kept out of `test engine` (its scan doesn't go into `tests/engine/lead/`).
--
-- All the guns fire a 600/s shot every 1s, accuracy 1 (every shot is marked as a 'hit'), from assault frigates that can't move or
-- turn; they differ in their mount and their lead. Every set-up is repeated `ENGINE_TEST.REPEATS` times, since single runs of ~8
-- shots vary a lot. Each run logs when the shots that struck were fired (shots that didn't strike show as gaps), and each second a
-- "lead model" line: the target's distance, and how far ahead of the target's centre a shot would pass if lead worked out the
-- shot's flight time from the live distance, or from the distance when the attack was ordered. The rig is in
-- `tests/lib/weapon_rig.lua`.
--
-- What the fixed gun showed (see `.dev` notes and the wiki's `setBallistics` page):
-- 1. Fast targets: shots pass in front of an approaching target and behind a receding one. Lead aims at where the target will be
--    after the flight time to where it is *now* (the live distance: confirmed 2026-11-08), so it's exact only if the distance
--    doesn't change. A shot strikes this frigate within about 65 of its centre.
-- 2. Slow targets: ~3-20% of shots miss, singly, sometimes alternating, against crossing targets but not one flying straight away.
--    Hypothesis: some shots are fired with no lead (tested by the slow crossings: an unled shot would still strike a target at
--    ~10/s, ~50 behind, but not one at ~20/s, ~100 behind). It varied by gun; "some shots use the gun's distance from the world's centre" was
--    refuted (2026-11-08: guns 3000, 5000 and ~12369 from the centre lost 14, 5 and 2 of 80 shots).
-- With full lead, the weapon's own aim should drop out, so gimbals and turrets should match the fixed gun; lead 0 shows how well a
-- mount's own aim leads (a turret turns; a gimbal doesn't, it fires anywhere in its cone), and 0.9 is what the stock lead
-- weapons use.

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

--- The set-ups each gun is tested against, in order. `kind`: `"lane"` (`ENGINE_TEST.lane(lane, speed)`), `"across"`
--- (`ENGINE_TEST.across(speed)`) or `"away"` (straight away along the line of fire, from 2500 ahead).
ENGINE_TEST.LEAD_SETUPS = {
	{ kind = "lane", lane = "approaching", speed = 0.5, label = "approaching at 45 degrees at 50 percent speed" },
	{ kind = "lane", lane = "receding", speed = 0.5, label = "receding at 45 degrees at 50 percent speed" },
	{ kind = "across", speed = 1, label = "crossing at 100 percent speed" },
	{ kind = "away", speed = 0.15, label = "flying slowly straight away along the line of fire" },
	-- (the speed multiplier breaks down below ~15%: 10% gave ~9-10/s, not 21/s, and 5% didn't move at all, while 15% and 25% gave
	-- 31/s and 51/s; the logs show the actual speed. At ~10/s an unled shot would still strike, ~50 off; at 31/s it wouldn't, ~150)
	{ kind = "across", speed = 0.1, label = "crossing at 10 percent speed (about 10/s)" },
	{ kind = "across", speed = 0.15, label = "crossing at 15 percent speed" },
	{ kind = "across", speed = 0.25, label = "crossing at 25 percent speed" },
};

--- The placement for one of `ENGINE_TEST.LEAD_SETUPS` (only once the guns' axes are known, i.e inside a test).
---@param setup table
---@return table
function ENGINE_TEST.leadPlacement(setup)
	if (setup.kind == "lane") then
		return ENGINE_TEST.lane(setup.lane, setup.speed);
	elseif (setup.kind == "away") then
		return {
			at = ENGINE_TEST.F * 2500,
			direction = ENGINE_TEST.F,
			speed = setup.speed,
			label = "flying straight away at " .. floor(setup.speed * 100) .. " percent speed",
		};
	end
	return ENGINE_TEST.across(setup.speed);
end

--- Defines a lead suite: spawns `guns` (a list of `{ key, ship, label, subsystem?, hardpoint? }`; `subsystem` and `hardpoint` for
--- turret guns, whose turret is checked for, and created if missing) side by side at world `x` = 0, ±9000, ... (8000 apart for more than three guns; `y` 3000, `z`
--- 4000; each beyond the others' 5000 range, and so are their targets), checks each strikes a still target dead ahead, then runs
--- every set-up in `ENGINE_TEST.LEAD_SETUPS` against all the guns at once, each gun with its own target (a lane: see
--- `ENGINE_TEST.makeLane`). With `options.world_centre`, also spawns two more `test_fixed_lead` guns 3000 and ~12369 from the
--- world's centre (the fixed suite's earlier per-gun samples), each fired at a 25% crossing, one after the other (they're within
--- range of the main gun's area).
---
---@param title string
---@param guns table
---@param options? { world_centre?: 1 }
function ENGINE_TEST.leadSuite(title, guns, options)
	options = options or {};
	local count = modkit.table.length(guns);
	-- (the suite's guns get a target of their own before each test; the world-centre guns only in their own tests, so their
	-- targets aren't parked near the other guns the rest of the time)
	local keys = {};
	for i = 1, count do
		keys[i] = guns[i].key;
	end
	local all_keys = { "lead_centre", "lead_far" };
	for i = 1, count do
		all_keys[i + 2] = guns[i].key;
	end
	describe(title, function ()
		-- (Lua 4 upvalues only reach one function out, so each level re-declares what the next needs)
		local guns = %guns;
		local count = %count;
		local options = %options;
		local keys = %keys;
		local all_keys = %all_keys;

		before(function (ctx)
			local guns = %guns;
			local count = %count;
			ctx.enemy = SHIP_TEST.enemy();
			if (ctx.enemy == nil) then
				skip("no enemy player");
			end
			local origin = Vec3(SHIP_TEST.origin);
			local steps = { n = 0 };
			-- (9000 apart; 8000 for more than three, so the outer targets' run-ups stay inside the world bounds)
			local spacing = 9000;
			if (count > 3) then
				spacing = 8000;
			end
			for i = 1, count do
				local where = Vec3({ (i - (count + 1) / 2) * spacing, 3000, 4000 });
				steps.n = steps.n + 1;
				steps[steps.n] = SHIP_TEST.spawn(ctx, guns[i].key, guns[i].ship, { offset = where - origin });
			end
			if (%options.world_centre) then
				-- (world positions, 3000 and ~12369 from the world's centre; each 3000+ from the others and their targets)
				steps.n = steps.n + 1;
				steps[steps.n] = SHIP_TEST.spawn(ctx, "lead_centre", "test_fixed_lead", { offset = Vec3({ -3000, 0, 0 }) - origin });
				steps.n = steps.n + 1;
				steps[steps.n] = SHIP_TEST.spawn(ctx, "lead_far", "test_fixed_lead", { offset = Vec3({ -3000, 0, -12000 }) - origin });
			end
			steps.n = steps.n + 1;
			steps[steps.n] = function ()
				for key, _ in %ctx.home do
					%ctx[key]:invulnerable(1);
					print("[test engine] " .. key .. " is " .. format("%.0f", Vec3:magnitude(%ctx.home[key])) .. " from the world's centre");
				end
				-- (turret guns: check the ship got its turret subsystem; if not, try creating it, and report)
				for i = 1, modkit.table.length(%guns) do
					local gun = %guns[i];
					if (gun.subsystem) then
						local ship = %ctx[gun.key];
						local has = SobGroup_HasSubsystem(ship.own_group, gun.subsystem);
						local health = SobGroup_GetHardPointHealth(ship.own_group, gun.hardpoint);
						if (has ~= 1) then
							SobGroup_CreateSubSystem(ship.own_group, gun.subsystem);
							print("[test engine] " .. gun.key .. " had no " .. gun.subsystem .. " subsystem (hardpoint " .. gun.hardpoint
								.. " health " .. tostring(health) .. "); tried creating it: now has it " .. tostring(SobGroup_HasSubsystem(ship.own_group, gun.subsystem))
								.. ", hardpoint health " .. tostring(SobGroup_GetHardPointHealth(ship.own_group, gun.hardpoint)));
						else
							print("[test engine] " .. gun.key .. " has its " .. gun.subsystem .. " subsystem (hardpoint " .. gun.hardpoint .. " health "
								.. tostring(health) .. ")");
						end
					end
				end
				return ENGINE_TEST.calibrate(%ctx, %guns[1].key);
			end;
			return call(sequence, steps);
		end, { timeout = 120 });

		beforeEach(function (ctx)
			for key, _ in ctx.home do
				if (ctx[key] and not ctx[key]._destroyed) then
					ctx[key]:ROE(PassiveROE);
					ctx[key]:stop();
				end
			end
			return ENGINE_TEST.spawnLaneTargets(ctx, %keys);
		end, { timeout = 30 });

		afterEach(function (ctx)
			ENGINE_TEST.killLaneTargets(ctx, %all_keys);
		end);

		after(function (ctx)
			SHIP_TEST.cleanup(ctx);
		end);

		-- (rig) every gun can fire at, and strike, a still target dead ahead; the first measures one 'hit' strike's damage
		for i = 1, count do
			local key = guns[i].key;
			local first = (i == 1);
			it("(rig) " .. guns[i].label .. " strikes a still target dead ahead", function (ctx)
				local key = %key;
				local first = %first;
				local lane = ENGINE_TEST.makeLane(ctx, key, "target_" .. key);
				return sequence(
					ENGINE_TEST.firstStrike(lane, key, ENGINE_TEST.ahead().at),
					function ()
						if (%first) then
							ENGINE_TEST.hit_damage = %lane.strike;
						end
						print("[test engine] " .. %key .. ": one 'hit' strike: " .. format("%.6f", %lane.strike) .. " of the target's HP");
					end
				);
			end, { timeout = 60 });
		end

		-- every set-up, against all the guns at once
		for j = 1, modkit.table.length(ENGINE_TEST.LEAD_SETUPS) do
			local setup = ENGINE_TEST.LEAD_SETUPS[j];
			it("(diagnostic: logs only) every gun at once, target " .. setup.label .. ", repeated", function (ctx)
				local guns = %guns;
				local branches = { n = 0 };
				for i = 1, modkit.table.length(guns) do
					local key = guns[i].key;
					local lane = ENGINE_TEST.makeLane(ctx, key, "target_" .. key);
					branches.n = branches.n + 1;
					branches[branches.n] = ENGINE_TEST.fireRepeated(lane, key, ENGINE_TEST.leadPlacement(%setup), ENGINE_TEST.REPEATS);
				end
				return call(parallel, branches);
			end, { timeout = 600 });
		end

		if (options.world_centre) then
			local samples = {
				{ key = "lead_centre", label = "fixed, full lead, 3000 from the world's centre" },
				{ key = "lead_far", label = "fixed, full lead, ~12369 from the world's centre" },
			};
			for i = 1, 2 do
				local key = samples[i].key;
				it("(diagnostic: logs only) " .. samples[i].label .. ", target crossing at 25 percent speed, repeated", function (ctx)
					local key = %key;
					return sequence(
						ENGINE_TEST.spawnLaneTargets(ctx, { key }),
						function ()
							local lane = ENGINE_TEST.makeLane(%ctx, %key, "target_" .. %key);
							return ENGINE_TEST.fireRepeated(lane, %key, ENGINE_TEST.across(0.25), ENGINE_TEST.REPEATS);
						end
					);
				end, { timeout = 600 });
			end
		end
	end);
end
