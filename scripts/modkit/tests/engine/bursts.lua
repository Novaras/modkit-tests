-- Ingame tests of engine behaviour (weapons: bursts fired at empty points in space).
-- Part of `test engine` (see `tests/engine.lua`), or run alone with `test engine/bursts`.
--
-- A known bug (see the wiki's `setBallistics` page): weapons sometimes fire a burst at an empty point in space, far off their
-- target, even after earlier bursts hit it. Seen in tests with a lead weapon, and in play with the Vaygr Battlecruiser's forward
-- gun and possibly ion cannons. These tests measure it: each gun fires at a still target straight ahead of it, in its line of fire,
-- for a while; every strike is timed and grouped into bursts, and a gap of more than 1.5x the gun's usual gap between bursts means
-- bursts went missing ("N missed" in the log). The guns are copies of the stock weapons, on ships that can't move or turn. The rig
-- is in `tests/lib/weapon_rig.lua`.

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

-- Needs an enemy player (for the target), so it's skipped without one. Slow: the whole suite is about 6 minutes of game time.
describe("bursts at empty points (test weapons)", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		return sequence(
			ENGINE_TEST.spawnGuns(ctx, {
				control = "test_fixed",
				lead = "test_fixed_lead",
				bc = "test_bc_gun",
				bc_accurate = "test_bc_gun_accurate",
				ion = "test_ion_gun",
				-- (more lead guns, firing at once, since its wild shots are rare)
				lead_a = "test_fixed_lead",
				lead_b = "test_fixed_lead",
				lead_c = "test_fixed_lead",
				lead_d = "test_fixed_lead",
				lead_e = "test_fixed_lead",
			}, 1), -- (spread out, so each gun's only enemy in range is its own target)
			function ()
				for key, _ in %ctx.home do
					%ctx[key]:invulnerable(1);
				end
				return ENGINE_TEST.calibrate(%ctx, "control");
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
		return SHIP_TEST.spawn(ctx, "target", "test_target_tough", { player = ctx.enemy.id, offset = { 0, 4000, -30000 } }); -- (parked far from the guns)
	end, { timeout = 30 });

	afterEach(function (ctx)
		if (ctx.target and not ctx.target._destroyed) then
			ctx.target:die(1);
		end
		for _, target in (ctx.extra_targets or {}) do
			if (not target._destroyed) then
				target:die(1);
			end
		end
		ctx.extra_targets = {};
	end);

	after(function (ctx)
		SHIP_TEST.cleanup(ctx);
	end);

	it("(control) a fixed gun's shots all strike a still target in its line of fire: no missed bursts", function (ctx)
		return sequence(
			ENGINE_TEST.watchBursts(ctx, "control", 30, 1),
			function ()
				local bursts = %ctx.bursts;
				expect(modkit.table.length(bursts.bursts) > 0, "it should have struck: " .. ENGINE_TEST.describeBursts(bursts));
				expect(bursts.missed == 0, "the method shouldn't find missed bursts here: " .. ENGINE_TEST.describeBursts(bursts));
			end
		);
	end, { timeout = 90 });

	it("(diagnostic: logs missed bursts) a fixed gun with full lead", function (ctx)
		return sequence(
			ENGINE_TEST.watchBursts(ctx, "lead", 60, 1),
			function ()
				local bursts = %ctx.bursts;
				expect(bursts.fired and modkit.table.length(bursts.bursts) > 0, "it should have fired and struck: " .. ENGINE_TEST.describeBursts(bursts));
			end
		);
	end, { timeout = 120 });

	it("(diagnostic: logs missed bursts) the Vaygr Battlecruiser's forward gun", function (ctx)
		return sequence(
			ENGINE_TEST.watchBursts(ctx, "bc", 150, 15),
			function ()
				local bursts = %ctx.bursts;
				-- (only that it fired: with 40% accuracy, a run with no bursts struck happens; 12 of 40 over the first four runs)
				expect(bursts.fired, "it should have fired: " .. ENGINE_TEST.describeBursts(bursts));
			end
		);
	end, { timeout = 210 });

	-- (the stock gun has 0.4 accuracy against Frigates, i.e this target: a shot that fails its roll is fired off-target within the
	-- miss cone, so its missing bursts may just be misses. This copy differs only in accuracy 1)
	it("(diagnostic: logs missed bursts) the Vaygr Battlecruiser's forward gun, with accuracy 1", function (ctx)
		return sequence(
			ENGINE_TEST.watchBursts(ctx, "bc_accurate", 150, 15),
			function ()
				local bursts = %ctx.bursts;
				expect(bursts.fired and modkit.table.length(bursts.bursts) > 0, "it should have fired and struck: " .. ENGINE_TEST.describeBursts(bursts));
			end
		);
	end, { timeout = 210 });

	it("(diagnostic: logs missed bursts) the Hiigaran ion cannon", function (ctx)
		return sequence(
			ENGINE_TEST.watchBursts(ctx, "ion", 90, 7),
			function ()
				local bursts = %ctx.bursts;
				expect(bursts.fired and modkit.table.length(bursts.bursts) > 0, "it should have fired and struck: " .. ENGINE_TEST.describeBursts(bursts));
			end
		);
	end, { timeout = 150 });

	-- The lead gun's wild shots: rare, so several lead guns fire at once. Targets near and beyond 90 degrees off the gun's axis are
	-- included, in case the edge of the gun's arc is what triggers them.
	it("(diagnostic: logs missed bursts) lead guns against still targets 0, 45, 80, 100 and 135 degrees off their axis", function (ctx)
		local specs = {};
		local angles = { 0, 45, 80, 100, 135 };
		local guns = { "lead_a", "lead_b", "lead_c", "lead_d", "lead_e" };
		for i = 1, 5 do
			specs[i] = { label = "lead at " .. angles[i] .. " degrees", gun = guns[i], at = ENGINE_TEST.atAngle(angles[i]) };
		end
		return sequence(
			ENGINE_TEST.watchMany(ctx, specs, 60, 1),
			function ()
				for i = 1, 2 do -- (0 and 45 degrees: well inside the cone, as 30 degrees was before)
					local state = %ctx.watches[i];
					expect(modkit.table.length(state.bursts) > 0, "it should have struck: " .. ENGINE_TEST.describeBursts(state));
				end
				for i = 1, 5 do
					expect(%ctx.watches[i].fired, "it should have fired: " .. ENGINE_TEST.describeBursts(%ctx.watches[i]));
				end
			end
		);
	end, { timeout = 180 });

	-- Relative motion, at 25% speed (15% flying away), where lead still strikes a crossing target: flying straight away along the line
	-- of fire (a prediction error along that line can't make it miss, so missed bursts there are wild), crossing in front, and passing
	-- the gun's side from 45 to 135 degrees (strikes stop as it nears 90 degrees, about 18s in).
	it("(diagnostic: logs missed bursts) lead guns against targets flying away, crossing, and passing their side", function (ctx)
		local F = ENGINE_TEST.F;
		local R = ENGINE_TEST.R;
		local specs = {
			-- (slower, from closer, so it stays inside the gun's 5000 range for the whole minute: at 25% it flew out of range at ~37s)
			{ label = "lead, target flying away", gun = "lead_a", at = F * 800, direction = F, speed = 0.15 },
			{ label = "lead, target crossing", gun = "lead_b", at = F * 2500 - R * 1500, direction = R, speed = 0.25 },
			{ label = "lead, target passing its side", gun = "lead_c", at = F * 1500 + R * 1500, direction = F * -1, speed = 0.25 },
		};
		return sequence(
			ENGINE_TEST.watchMany(ctx, specs, 60, 1),
			function ()
				for i = 1, 3 do
					expect(%ctx.watches[i].fired, "it should have fired: " .. ENGINE_TEST.describeBursts(%ctx.watches[i]));
				end
			end
		);
	end, { timeout = 180 });

	-- Whether the lead gun's wild shots come at the start of an engagement: many short engagements (attack, stop, attack again) at
	-- the angles where clusters were seen (45 and 80 degrees), with one dead ahead as a control.
	it("(diagnostic: logs strikes per engagement) lead guns in repeated short engagements, at 0, 45 and 80 degrees", function (ctx)
		local specs = {
			{ label = "lead at 0 degrees", gun = "lead_a", at = ENGINE_TEST.atAngle(0) },
			{ label = "lead at 45 degrees", gun = "lead_b", at = ENGINE_TEST.atAngle(45) },
			{ label = "lead at 45 degrees (2)", gun = "lead_c", at = ENGINE_TEST.atAngle(45) },
			{ label = "lead at 80 degrees", gun = "lead_d", at = ENGINE_TEST.atAngle(80) },
			{ label = "lead at 80 degrees (2)", gun = "lead_e", at = ENGINE_TEST.atAngle(80) },
		};
		return sequence(
			ENGINE_TEST.watchCycles(ctx, specs, 8, 12, 4),
			function ()
				for i = 1, 5 do
					expect(%ctx.watches[i].fired, "it should have fired (" .. %ctx.watches[i].gun_key .. ")");
				end
			end
		);
	end, { timeout = 200 });
end);
