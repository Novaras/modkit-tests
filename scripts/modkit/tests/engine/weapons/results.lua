-- Ingame tests of `AddWeaponResult`'s affectee (its 4th argument, `"Target"` or `"Owner"`). Run with `test engine/weapons/results`
-- (~2 min of game time); `test engine/weapons` runs it with the rest of the folder.
--
-- The wiki's `AddWeaponResult` page said `"Owner"` might apply the effect to the firing ship (or subsystem) instead. The guns are the
-- baseline (`test_fixed`) with the damage result's affectee changed: `test_fixed_owner` ("Owner") and `test_fixed_affectee_unknown`
-- ("Self", not a recognised value). Unlike the other suites' guns, these two aren't made invulnerable, so damage to them would show.

dofilepath("data:scripts/modkit/tests/lib/weapon_rig.lua");

RESULTS_TEST = {};

describe("AddWeaponResult's affectee (test weapons)", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		return sequence(
			ENGINE_TEST.spawnGuns(ctx, {
				baseline = "test_fixed",
				owner = "test_fixed_owner",
				affectee_unknown = "test_fixed_affectee_unknown",
			}),
			function ()
				%ctx.baseline:invulnerable(1);
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

	it("(rig) the baseline gun's damage over one firing window", function (ctx)
		return sequence(
			ENGINE_TEST.fire(ctx, "baseline", ENGINE_TEST.ahead()),
			function ()
				RESULTS_TEST.baseline_drop = %ctx.drop;
				expect(%ctx.drop > 0, "the target should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			end
		);
	end, { timeout = 60 });

	it("an \"Owner\" damage result damages the ship struck, not the firing ship", function (ctx)
		ctx.owner:HP(1);
		local gun_hp = ctx.owner:HP();
		return sequence(
			ENGINE_TEST.fire(ctx, "owner", ENGINE_TEST.ahead()),
			function ()
				local gun_drop = %gun_hp - %ctx.owner:HP();
				print("[test engine] the \"Owner\" gun lost " .. format("%.6f", gun_drop) .. " of its own HP");
				expect(gun_drop == 0, "the firing ship shouldn't have been damaged: it lost " .. format("%.6f", gun_drop) .. " of its HP");
				expect(%ctx.drop > 0, "the target should have been damaged: " .. ENGINE_TEST.describeShot(%ctx));
				if (RESULTS_TEST.baseline_drop) then
					expectNear(%ctx.drop / RESULTS_TEST.baseline_drop, 1, 0.2, "the target's HP lost, as a fraction of the baseline's");
				end
			end
		);
	end, { timeout = 60 });

	it("an unrecognised affectee (\"Self\") is treated as \"Target\"", function (ctx)
		ctx.affectee_unknown:HP(1);
		local gun_hp = ctx.affectee_unknown:HP();
		return sequence(
			ENGINE_TEST.fire(ctx, "affectee_unknown", ENGINE_TEST.ahead()),
			function ()
				local gun_drop = %gun_hp - %ctx.affectee_unknown:HP();
				expect(gun_drop == 0, "the firing ship shouldn't have been damaged: it lost " .. format("%.6f", gun_drop) .. " of its HP");
				expect(%ctx.drop > 0, "the target should have been damaged: " .. ENGINE_TEST.describeShot(%ctx));
				if (RESULTS_TEST.baseline_drop) then
					expectNear(%ctx.drop / RESULTS_TEST.baseline_drop, 1, 0.2, "the target's HP lost, as a fraction of the baseline's");
				end
			end
		);
	end, { timeout = 60 });
end);
