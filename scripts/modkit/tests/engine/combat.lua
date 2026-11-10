-- Ingame tests of engine behaviour (combat status: `SobGroup_UnderAttack`).
-- Part of `test engine` (see `tests/engine.lua`), or run alone with `test engine/combat`.

dofilepath("data:scripts/modkit/tests/lib/ships.lua"); -- (`SHIP_TEST`: spawning and cleanup helpers)

-- (a global table: Lua 4 upvalues only reach one function out, so file-level locals can't be used inside `it` callbacks; shared by
-- the files in `tests/engine/`, which also run alone)
ENGINE_TEST = ENGINE_TEST or {};

--- Orders `ctx.attacker` to attack `ctx[key]`, noting when (for `ENGINE_TEST.logFlagged`).
---
---@param ctx table
---@param key string
function ENGINE_TEST.attack(ctx, key)
	ctx.attacker:ROE(OffensiveROE);
	ctx.attacker:attack(ctx[key]);
	ctx.ordered_at = Universe_GameTime();
end

--- Logs how long after the attack order `ctx[key]` was flagged as under attack, how far away the attacker was, and its HP (to 6
--- places, since one hit on a big ship barely moves it).
---
---@param ctx table
---@param key string
function ENGINE_TEST.logFlagged(ctx, key)
	print("[test engine] " .. key .. " under attack " .. format("%.1f", Universe_GameTime() - ctx.ordered_at) .. "s after the order"
		.. ", attacker " .. floor(ctx.attacker:distanceTo(ctx[key])) .. " away"
		.. ", HP " .. format("%.6f", ctx[key]:HP()));
end

-- What makes `SobGroup_UnderAttack` true (2026-11-07). Known so far: a passive (invulnerable or not) ship being attacked is under
-- attack, its attacker isn't, and it clears about 10s after the attack stops. A ship is flagged each time a weapon fires at it, after
-- the weapon's range/arc checks and before any hit (see `SobGroup_UnderAttack` in `hwrm.lua`); the out-of-range test and the
-- `logFlagged` lines check that in game. Needs an enemy player, so it's skipped without one.
describe("under attack (SobGroup_UnderAttack)", function ()
	before(function (ctx)
		ctx.enemy = SHIP_TEST.enemy();
		if (ctx.enemy == nil) then
			skip("no enemy player");
		end
		SHIP_TEST.spawnAll(ctx, { attacker = "kus_interceptor" }, { offset = { 0, 2500, 0 } });
		return SHIP_TEST.spawnAll(ctx, {
			bystander = "kus_scout",
			shielded = "kus_scout",
			frigate = "kus_assaultfrigate",
		}, { player = ctx.enemy.id, offset = { 0, 2500, 1500 } });
	end, { timeout = 30 });

	beforeEach(function (ctx)
		ctx.attacker:ROE(PassiveROE);
		ctx.attacker:speed(1);
		for _, key in { "attacker", "bystander", "shielded", "frigate" } do
			SHIP_TEST.reset(ctx, key);
		end
		ctx.shielded:invulnerable(1);
		-- (the targets are pinned in place, in case a CPU's AI takes over ships spawned for it and flies them off; tests are meant for the
		-- sandbox, which has no AI, but this keeps them working elsewhere)
		ctx.shielded:speed(0);
		ctx.frigate:speed(0);
	end);

	after(function (ctx)
		SHIP_TEST.cleanup(ctx);
	end);

	it("a ship nobody is attacking isn't under attack", function (ctx)
		expectNil(ctx.bystander:underAttack());
	end);

	it("an attacker held out of range doesn't put its target under attack", function (ctx)
		-- (pinned 6000 from the target, beyond an interceptor's weapons)
		ctx.attacker:speed(0);
		ctx.attacker:position(ctx.home.shielded + Vec3({ 0, 0, -6000 }));
		ENGINE_TEST.attack(ctx, "shielded");
		return sequence(
			wait(15),
			function ()
				print("[test engine] out of range: shielded underAttack " .. tostring(%ctx.shielded:underAttack()) .. " 15s after the order, "
					.. SHIP_TEST.describe(%ctx, "attacker"));
				expectNil(%ctx.shielded:underAttack(), "under attack from 6000 away: the order alone sets it");
			end
		);
	end, { timeout = 30 });

	it("a passive, invulnerable ship being attacked is under attack (no damage or firing back needed)", function (ctx)
		ENGINE_TEST.attack(ctx, "shielded");
		return sequence(
			waitFor(function () return %ctx.shielded:underAttack(); end, { timeout = 20, message = function ()
				return "never under attack (" .. SHIP_TEST.describe(%ctx, "attacker") .. "; " .. SHIP_TEST.describe(%ctx, "shielded") .. ")";
			end }),
			function ()
				ENGINE_TEST.logFlagged(%ctx, "shielded");
				expectNear(%ctx.shielded:HP(), 1, 0.001, "invulnerable, so its HP");
			end
		);
	end, { timeout = 30 });

	-- (two runs, 2026-11-07, found the frigate under attack at HP 1.000, which a single hit could still round to)
	it("a passive ship being attacked is under attack, and still is once it's damaged; its attacker isn't", function (ctx)
		ENGINE_TEST.attack(ctx, "frigate");
		return sequence(
			waitFor(function () return %ctx.frigate:underAttack(); end, { timeout = 20, message = function ()
				return "never under attack (" .. SHIP_TEST.describe(%ctx, "attacker") .. "; " .. SHIP_TEST.describe(%ctx, "frigate") .. ")";
			end }),
			function ()
				ENGINE_TEST.logFlagged(%ctx, "frigate");
			end,
			waitFor(function () return %ctx.frigate:HP() < 1; end, { timeout = 20, message = function ()
				return "never took damage (" .. SHIP_TEST.describe(%ctx, "attacker") .. "; " .. SHIP_TEST.describe(%ctx, "frigate") .. ")";
			end }),
			function ()
				expect(%ctx.frigate:underAttack(), "still under attack once damaged: " .. SHIP_TEST.describe(%ctx, "frigate"));
				expectNil(%ctx.attacker:underAttack(), "the attacker (its target is passive)");
			end
		);
	end, { timeout = 50 });

	it("it clears once the attack stops (prints how long that took)", function (ctx)
		ENGINE_TEST.attack(ctx, "shielded");
		return sequence(
			waitFor(function () return %ctx.shielded:underAttack(); end, { timeout = 20, message = "never under attack" }),
			function ()
				%ctx.attacker:ROE(PassiveROE);
				%ctx.attacker:stop();
				%ctx.stopped_at = Universe_GameTime();
			end,
			waitFor(function () return not %ctx.shielded:underAttack(); end, { timeout = 30, message = "still under attack 30s after the attack stopped" }),
			function ()
				print("[test engine] under attack cleared " .. format("%.1f", Universe_GameTime() - %ctx.stopped_at) .. "s after the attack stopped");
			end
		);
	end, { timeout = 60 });
end);
