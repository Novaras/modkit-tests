-- Ingame tests of engine behaviour (movement: `SobGroup_GetActualSpeed`).
-- Part of `test engine` (see `tests/engine.lua`), or run alone with `test engine/movement`.

dofilepath("data:scripts/modkit/tests/lib/ships.lua"); -- (`SHIP_TEST`: spawning and cleanup helpers)

-- `SobGroup_GetActualSpeed` returns the speed **squared** (x² + y² + z² of the velocity, no square root; modkit's `actualSpeedSq`
-- already says so). Checked by flying a ship in a straight line and timing it.
describe("SobGroup_GetActualSpeed", function ()
	before(function (ctx)
		return SHIP_TEST.spawnAll(ctx, { flyer = "kus_scout" }, { offset = { 0, 2500, -3000 } });
	end, { timeout = 30 });

	after(function (ctx)
		SHIP_TEST.cleanup(ctx);
	end);

	it("is the square of the speed the ship is actually flying at", function (ctx)
		ctx.flyer:move(ctx.flyer:position() + { 12000, 0, 0 }, { no_event = 1 }); -- (it covers about 3000 in the test; inside the bounds)
		return sequence(
			wait(4), -- (up to cruising speed)
			function ()
				%ctx.p1 = %ctx.flyer:position();
				%ctx.t1 = Universe_GameTime();
				%ctx.sq1 = %ctx.flyer:actualSpeedSq();
			end,
			wait(2),
			function ()
				local measured = Vec3:magnitude(%ctx.flyer:position() - %ctx.p1) / (Universe_GameTime() - %ctx.t1);
				local reported = (%ctx.sq1 + %ctx.flyer:actualSpeedSq()) / 2;
				print("[test engine] measured speed " .. format("%.1f", measured) .. ", GetActualSpeed " .. format("%.1f", reported)
					.. " (measured² " .. format("%.1f", measured * measured) .. ")");
				expect(measured > 50, "the ship should be moving: measured " .. measured);
				expect(abs(reported - measured * measured) < 0.25 * measured * measured,
					"GetActualSpeed " .. reported .. " should be about measured² " .. (measured * measured) .. " (measured " .. measured .. ")");
			end
		);
	end, { timeout = 30 });
end);
