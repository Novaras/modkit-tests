-- Ingame tests for the `Ship` API (`scripts/custom_code/lib/modkit-ship.lua` and `modkit-base.lua`). Run with `test ship` in the console.
--
-- Spawns its own ships for `SHIP_TEST.player` around `SHIP_TEST.origin` (move it if that's crowded on your map), and removes them
-- afterwards. Most tests need game time (ships only register on their first `update`, and orders take time to play out), so close the
-- console once they begin. The "combat" suite needs an enemy player (i.e a skirmish against a CPU), and is skipped without one.

-- helpers (on a global table: Lua 4 upvalues only reach one function out, so file-level locals can't be used inside `it` callbacks)
SHIP_TEST = {
	origin = { 0, 3000, 0 },
	player = 0,
};

--- Spawns a `ship_type` for `options.player` (default `SHIP_TEST.player`) at `options.offset` from `SHIP_TEST.origin`, and sets it as
--- `ctx[key]` once modkit registers it. Spawned ships are kept in `ctx.spawned`, for `SHIP_TEST.cleanup`.
---
---@param ctx table
---@param key string
---@param ship_type string
---@param options? { player?: integer, offset?: Vec3Like }
---@return EventChain
function SHIP_TEST.spawn(ctx, key, ship_type, options)
	options = options or {};
	ctx.spawned = ctx.spawned or {};
	ctx.home = ctx.home or {};
	local where = Vec3(SHIP_TEST.origin) + Vec3(options.offset or { 0, 0, 0 });
	ctx.home[key] = where;

	return modkit.ships():spawnShips({
		ship_type = ship_type,
		player_index = options.player or SHIP_TEST.player,
		where = where,
	}):next(function (res, rej, state)
		local _, ship = next(state._previous_result or {}, nil);
		if (ship == nil) then
			return rej("no " .. %ship_type .. " was spawned");
		end
		ship:ROE(PassiveROE); -- (so it doesn't wander off to fight)
		%ctx[%key] = ship;
		%ctx.spawned[getn(%ctx.spawned) + 1] = ship;
		res(ship);
	end);
end

--- Spawns each of `ship_types` (`{ [key] = ship_type }`) with `SHIP_TEST.spawn`, spaced out along x; resolves once they're all registered.
---
---@param ctx table
---@param ship_types table<string, string>
---@param options? { player?: integer, offset?: Vec3Like }
---@return Event
function SHIP_TEST.spawnAll(ctx, ship_types, options)
	options = options or {};
	local offset = Vec3(options.offset or { 0, 0, 0 });
	local i = 0;
	for key, ship_type in ship_types do
		SHIP_TEST.spawn(ctx, key, ship_type, { player = options.player, offset = offset + { i * 800, 0, 0 } })
			:catch(function (message) %ctx.spawn_error = message; end);
		i = i + 1;
	end

	return waitFor(function ()
		if (%ctx.spawn_error) then
			fail("spawning failed: " .. %ctx.spawn_error);
		end
		for key, _ in %ship_types do
			if (%ctx[key] == nil) then
				return nil;
			end
		end
		return 1;
	end, { timeout = 20, message = "the spawned ships never registered" });
end

--- Puts the ship `ctx[key]` back where it spawned, stopped and at full HP.
---
---@param ctx table
---@param key string
function SHIP_TEST.reset(ctx, key)
	local ship = ctx[key];
	if (ship and not ship._destroyed) then
		ship:stop();
		ship:HP(1);
		ship:position(ctx.home[key]);
	end
end

--- Quietly removes every ship in `ctx.spawned`.
---
---@param ctx table
function SHIP_TEST.cleanup(ctx)
	for _, ship in ctx.spawned or {} do
		if (not ship._destroyed and ship:count() > 0) then
			ship:die(1);
		end
	end
	ctx.spawned = {};
end

describe("Ship", function ()
	before(function (ctx)
		return SHIP_TEST.spawnAll(ctx, {
			scout = "kus_scout",
			interceptor = "kus_interceptor",
			frigate = "kus_assaultfrigate",
			carrier = "kus_carrier",
		});
	end, { timeout = 30 });

	after(function (ctx)
		SHIP_TEST.cleanup(ctx);
	end);

	describe("registration", function ()
		it("spawnShips resolves with the ships, registered in GLOBAL_SHIPS under their ids", function (ctx)
			expect(GLOBAL_SHIPS:get(ctx.scout.id) == ctx.scout, "GLOBAL_SHIPS:get(id) isn't the spawned Ship");
		end);

		it("knows its type, player and group", function (ctx)
			local scout = ctx.scout;
			expectEq(scout.ship_type, "kus_scout");
			expectEq(scout.type_group, "kus_scout");
			expectEq(scout.player.id, SHIP_TEST.player);
			expectEq(SobGroup_GetPlayerOwner(scout.own_group), SHIP_TEST.player, "engine's owner");
			expectEq(scout:count(), 1);
			expectEq(scout:squadSize(), 1);
		end);

		it("ticks on each update", function (ctx)
			local start = ctx.scout:tick();
			return waitFor(function () return %ctx.scout:tick() > %start; end, { message = "tick didn't increase" });
		end);

		it("age is the game time since it was created", function (ctx)
			expect(ctx.scout.created_at <= Universe_GameTime(), "created in the future");
			expectNear(ctx.scout:age(), Universe_GameTime() - ctx.scout.created_at, 0.01);
		end);

		it("racePrefix and raceName come from the ship type", function (ctx)
			expectEq(ctx.scout:racePrefix(), "kus");
			expectEq(type(ctx.scout:raceName()), "string");
		end);

		it("batchSize, buildCost and buildTime read the ship type's static data", function (ctx)
			expect(ctx.interceptor:batchSize() >= 1, "batchSize " .. tostring(ctx.interceptor:batchSize()));
			expect(ctx.interceptor:buildCost() > 0, "buildCost " .. tostring(ctx.interceptor:buildCost()));
			expect(ctx.interceptor:buildTime() > 0, "buildTime " .. tostring(ctx.interceptor:buildTime()));
		end);

		it("modkit.ships():find finds a Ship by itself", function (ctx)
			expect(modkit.ships():find(ctx.scout) == ctx.scout, "didn't find the scout");
		end);

		it("modkit.ships():findType finds a ship of the type", function ()
			expectEq(modkit.ships():findType("kus_carrier").ship_type, "kus_carrier");
		end);
	end);

	describe("health", function ()
		beforeEach(function (ctx)
			ctx.frigate:HP(1);
		end);

		it("HP sets and reads the HP fraction", function (ctx)
			expectNear(ctx.frigate:HP(0.5), 0.5, 0.01);
			expectNear(ctx.frigate:HP(), 0.5, 0.01);
		end);

		it("HP leaves the HP alone for a value that isn't a number", function (ctx)
			expectNear(ctx.frigate:HP("lots"), 1, 0.01);
		end);

		it("takeDamage takes a fraction of the max HP", function (ctx)
			expectNear(ctx.frigate:takeDamage(0.25), 0.75, 0.01);
		end);

		it("takeDamage with absolute takes that many HP", function (ctx)
			local max_hp = ctx.frigate:maxActualHP();
			expect(max_hp > 0, "maxActualHP " .. tostring(max_hp));
			ctx.frigate:takeDamage(max_hp / 4, { absolute = 1 });
			expectNear(ctx.frigate:currentActualHP(), max_hp * 0.75, max_hp * 0.01);
		end);

		it("currentActualHP is the HP fraction of maxActualHP", function (ctx)
			ctx.frigate:HP(0.4);
			expectNear(ctx.frigate:currentActualHP() / ctx.frigate:maxActualHP(), 0.4, 0.01);
		end);

		it("alive is 1 while it has HP", function (ctx)
			expectTruthy(ctx.frigate:alive());
		end);

		it("invulnerable sets and reads the flag", function (ctx)
			expectTruthy(ctx.frigate:invulnerable(1));
			expectNil(ctx.frigate:invulnerable(0));
			expectNil(ctx.frigate:invulnerable());
		end);
	end);

	describe("dying", function ()
		before(function (ctx)
			return SHIP_TEST.spawnAll(ctx, { victim = "kus_scout", quiet_victim = "kus_scout" }, { offset = { 0, 1500, 0 } });
		end, { timeout = 30 });

		it("die kills it: it's dropped from GLOBAL_SHIPS and marked destroyed", function (ctx)
			local id = ctx.victim.id;
			ctx.victim:die();
			expectNil(ctx.victim:alive());
			return sequence(
				waitFor(function () return GLOBAL_SHIPS:get(%id) == nil; end, { message = "still in GLOBAL_SHIPS" }),
				function () expectTruthy(%ctx.victim._destroyed, "_destroyed"); end
			);
		end);

		it("die(1) despawns it first, then kills it", function (ctx)
			local id = ctx.quiet_victim.id;
			ctx.quiet_victim:die(1);
			return waitFor(function () return GLOBAL_SHIPS:get(%id) == nil; end, { message = "still in GLOBAL_SHIPS" });
		end);
	end);

	describe("position", function ()
		beforeEach(function (ctx)
			SHIP_TEST.reset(ctx, "scout");
			SHIP_TEST.reset(ctx, "interceptor");
		end);

		it("position sets the position straight away", function (ctx)
			local target = ctx.home.scout + { 500, 0, 0 };
			ctx.scout:position(target);
			expectNear(ctx.scout:position(), target, 10);
		end);

		it("distanceTo a position is the distance to it", function (ctx)
			expectNear(ctx.scout:distanceTo(ctx.scout:position() + { 300, 400, 0 }), 500, 1);
		end);

		it("distanceTo a ship is about the distance between them", function (ctx)
			ctx.interceptor:position(ctx.scout:position() + { 2000, 0, 0 });
			-- (the engine measures between groups, which may not be exactly centre to centre)
			expectNear(ctx.scout:distanceTo(ctx.interceptor), 2000, 200);
		end);

		it("isNear is 1 within the threshold, nil beyond it", function (ctx)
			local pos = ctx.scout:position();
			expectTruthy(ctx.scout:isNear(pos + { 500, 0, 0 }, 1000));
			expectNil(ctx.scout:isNear(pos + { 5000, 0, 0 }, 1000));
		end);

		it("positionEq compares positions, with an optional leeway", function (ctx)
			local pos = ctx.scout:position();
			expectTruthy(ctx.scout:positionEq(pos));
			expectNil(ctx.scout:positionEq(pos + { 50, 0, 0 }));
			expectTruthy(ctx.scout:positionEq(pos + { 50, 0, 0 }, 100));
			expectTruthy(ctx.scout:positionEq(pos + { 50, 0, 0 }, { x = 100 }));
		end);

		it("rotateHorizontal rotates it around a point, by radians", function (ctx)
			local centre = ctx.home.scout;
			ctx.scout:position(centre + { 1000, 0, 0 });
			ctx.scout:rotateHorizontal(PI / 2, centre);
			expectNear(ctx.scout:position(), centre + { 0, 0, 1000 }, 10);
		end);

		it("getShipsInRadius finds nearby ships, filtered by type", function (ctx)
			ctx.interceptor:position(ctx.scout:position() + { 400, 0, 0 });
			local id = ctx.interceptor.id;
			local isInterceptor = function (ship) return ship.id == %id; end;
			local player = { GLOBAL_PLAYERS:get(SHIP_TEST.player) };

			expectTruthy(modkit.table.findVal(ctx.scout:getShipsInRadius(1000, nil, player), isInterceptor), "not found in radius");
			expectTruthy(modkit.table.findVal(ctx.scout:getShipsInRadius(1000, { "kus_interceptor" }, player), isInterceptor), "not found by type");
			expectNil(modkit.table.findVal(ctx.scout:getShipsInRadius(1000, { "kus_carrier" }, player), isInterceptor), "found by the wrong type");
		end);
	end);

	describe("movement", function ()
		beforeEach(function (ctx)
			SHIP_TEST.reset(ctx, "scout");
			ctx.scout:speed(1);
		end);
		after(function (ctx)
			SHIP_TEST.reset(ctx, "scout");
		end);

		it("move resolves with the ship once it arrives", function (ctx)
			local target = ctx.scout:position() + { 3000, 0, 0 };
			return sequence(
				ctx.scout:move(target),
				function (ship)
					expect(ship == %ctx.scout, "resolved with " .. MK_TEST.show(ship));
					expectTruthy(%ctx.scout:isNear(%target, 1500));
				end
			);
		end, { timeout = 40 });

		it("a new move rejects the previous move's event", function (ctx)
			local first = ctx.scout:move(ctx.scout:position() + { 3000, 0, 0 });
			ctx.scout:move(ctx.scout:position() + { 0, 0, 3000 });
			expectEq(first.event.status, EVENT_STATUS.REJECTED);
			expectTruthy(strfind(first.event.error, "superseded", 1, 1), "error: " .. tostring(first.event.error));
		end);

		it("moving is 1 while it moves, and nil after stop", function (ctx)
			ctx.scout:move(ctx.scout:position() + { 4000, 0, 0 }, { no_event = 1 });
			return sequence(
				wait(1),
				function ()
					expectTruthy(%ctx.scout:moving(), "moving");
					expectTruthy(%ctx.scout:isDoingAbility(AB_Move), "isDoingAbility(AB_Move)");
					%ctx.scout:stop();
				end,
				waitFor(function () return not %ctx.scout:moving(); end, { timeout = 5, message = "still moving after stop" })
			);
		end);

		it("speed sets and reads the speed multiplier", function (ctx)
			expectNear(ctx.scout:speed(0.5), 0.5, 0.01);
			expectNear(ctx.scout:speed(1), 1, 0.01);
		end);
	end);

	describe("settings", function ()
		it("ROE sets and reads the rules of engagement", function (ctx)
			for _, roe in { OffensiveROE, DefensiveROE, PassiveROE } do
				expectEq(ctx.scout:ROE(roe), roe);
			end
		end);

		it("stance sets and reads the stance", function (ctx)
			for _, stance in { AggressiveStance, EvasiveStance, NeutralStance } do
				expectEq(ctx.scout:stance(stance), stance);
			end
		end);

		it("autoLaunch sets and reads the auto-launch behaviour", function (ctx)
			expectEq(ctx.carrier:autoLaunch(0), 0);
			expectEq(ctx.carrier:autoLaunch(1), 1);
		end);

		it("tumble sets and clears the tracked tumble", function (ctx)
			expectEq(ctx.scout:tumble({ 1, 0, 0 }), { 1, 0, 0 });
			expectEq(ctx.scout:tumble(0), { 0, 0, 0 });
		end);

		it("damageMult sets and reads the damage multiplier", function (ctx)
			expectEq(ctx.scout:damageMult(2), 2);
			expectEq(ctx.scout:damageMult(1), 1);
		end);

		it("ghost turns no-clip on and off", function (ctx)
			expectTruthy(ctx.scout:ghost(1));
			expectNil(ctx.scout:ghost(0));
		end);

		it("hidden hides and shows it", function (ctx)
			expectTruthy(ctx.scout:hidden(1));
			expectNil(ctx.scout:hidden(0));
		end);

		it("selectable sets and reads whether it can be selected", function (ctx)
			expectNil(ctx.scout:selectable(0));
			expectTruthy(ctx.scout:selectable(1));
		end);

		it("selected selects and deselects it", function (ctx)
			expectTruthy(ctx.scout:selected(1));
			expectNil(ctx.scout:selected(0));
		end);

		it("capturableModifier sets and reads the modifier", function (ctx)
			expectEq(ctx.frigate:capturableModifier(0), 0);
			expectEq(ctx.frigate:capturableModifier(1), 1);
		end);

		it("visibility sets the default, and per-player overrides", function (ctx)
			expectEq(ctx.scout:visibility(VisFull), VisFull);
			expectEq(ctx.scout:visibility(VisSecondary, 1), VisSecondary);
			expectEq(ctx.scout:visibility(), VisFull, "default after a per-player override");
			ctx.scout:visibility(VisNone);
		end);

		it("stunned sets and reads the stunned state", function (ctx)
			expectEq(ctx.scout:stunned(1), 1);
			expectEq(ctx.scout:stunned(0), 0);
		end);

		it("canDoAbility turns an ability off and on", function (ctx)
			expectEq(ctx.scout:canDoAbility(AB_Move, 0), 0);
			expectEq(ctx.scout:canDoAbility(AB_Move, 1), 1);
		end);
	end);

	describe("type and family queries", function ()
		it("attackFamily is the ship's attack family", function (ctx)
			expectEq(type(ctx.interceptor:attackFamily()), "string");
		end);

		it("isFighter, isFrigate and isCapital match their families", function (ctx)
			expectTruthy(ctx.interceptor:isFighter(), "interceptor isFighter (family " .. tostring(ctx.interceptor:attackFamily()) .. ")");
			expectNil(ctx.interceptor:isFrigate(), "interceptor isFrigate");
			expectTruthy(ctx.frigate:isFrigate(), "frigate isFrigate (family " .. tostring(ctx.frigate:attackFamily()) .. ")");
			expectTruthy(ctx.carrier:isCapital(), "carrier isCapital (family " .. tostring(ctx.carrier:attackFamily()) .. ")");
			expectNil(ctx.carrier:isFighter(), "carrier isFighter");
		end);

		it("isAnyTypeOf gives the matching type, or nil", function (ctx)
			expectEq(ctx.scout:isAnyTypeOf({ "kus_interceptor", "kus_scout" }), "kus_scout");
			expectNil(ctx.scout:isAnyTypeOf({ "kus_interceptor" }));
		end);

		it("isCarrier and isDestroyer match their types", function (ctx)
			expectTruthy(ctx.carrier:isCarrier());
			expectNil(ctx.scout:isCarrier());
			expectNil(ctx.carrier:isDestroyer());
		end);

		it("hasSubsystem is nil for a subsystem it doesn't have", function (ctx)
			expectNil(ctx.scout:hasSubsystem("not_a_subsystem"));
		end);
	end);

	describe("spawn / despawn", function ()
		after(function (ctx)
			if (ctx.scout_despawned) then -- (only if the test didn't get as far as spawning it again)
				ctx.scout:spawn(1);
			end
			SHIP_TEST.reset(ctx, "scout");
		end);

		it("spawn(0) despawns it, and spawn(1) brings it back where it was", function (ctx)
			local pos = ctx.scout:position();
			return sequence(
				function ()
					%ctx.scout_despawned = 1;
					expectEq(type(%ctx.scout:spawn(0)), "string", "despawn volume");
				end,
				wait(1),
				function ()
					%ctx.scout:spawn(1);
					%ctx.scout_despawned = nil;
				end,
				wait(1),
				function () expectNear(%ctx.scout:position(), %pos, 500); end
			);
		end);
	end);

	describe("docking", function ()
		before(function (ctx)
			SHIP_TEST.reset(ctx, "interceptor");
			SHIP_TEST.reset(ctx, "carrier");
			ctx.interceptor:position(ctx.carrier:position() + { 1000, 0, 0 });
		end);
		after(function (ctx)
			SHIP_TEST.reset(ctx, "interceptor");
		end);

		it("dock docks it with the target, and the target's launch launches it", function (ctx)
			ctx.interceptor:dock(ctx.carrier);
			return sequence(
				waitFor(function () return %ctx.interceptor:docked(%ctx.carrier); end, { timeout = 40, message = "never docked" }),
				function ()
					expectTruthy(%ctx.interceptor:docked(), "docked with anything");
					%ctx.carrier:launch(%ctx.interceptor);
				end,
				waitFor(function () return not %ctx.interceptor:docked(); end, { timeout = 20, message = "never launched" })
			);
		end, { timeout = 70 });
	end);

	describe("cloak", function ()
		before(function (ctx)
			return SHIP_TEST.spawnAll(ctx, { cloaker = "kus_cloakedfighter" }, { offset = { 0, -1500, 0 } });
		end, { timeout = 30 });

		it("cloak(1) cloaks it, cloak(0) uncloaks it", function (ctx)
			ctx.cloaker:cloak(1);
			return sequence(
				waitFor(function () return %ctx.cloaker:isCloaked(); end, { timeout = 5, message = "never cloaked" }),
				function () %ctx.cloaker:cloak(0); end,
				waitFor(function () return not %ctx.cloaker:isCloaked(); end, { timeout = 5, message = "never uncloaked" })
			);
		end, { timeout = 15 });

		it("cloak(0) leaves an uncloaked ship uncloaked", function (ctx)
			ctx.cloaker:cloak(0);
			return sequence(
				wait(2),
				function () expectNil(%ctx.cloaker:isCloaked()); end
			);
		end);

		it("cloak() toggles it", function (ctx)
			ctx.cloaker:cloak();
			return sequence(
				waitFor(function () return %ctx.cloaker:isCloaked(); end, { timeout = 5, message = "never cloaked" }),
				function () %ctx.cloaker:cloak(0); end
			);
		end, { timeout = 10 });
	end);

	describe("combat", function ()
		before(function (ctx)
			local me = GLOBAL_PLAYERS:get(SHIP_TEST.player);
			local enemy = modkit.table.findVal(GLOBAL_PLAYERS:alive(), function (player)
				return not player:alliedWith(%me);
			end);
			if (enemy == nil) then
				skip("no enemy player");
			end
			ctx.enemy = enemy;
			SHIP_TEST.reset(ctx, "interceptor");
			return SHIP_TEST.spawnAll(ctx, { target = "kus_scout" }, { player = enemy.id, offset = { 0, 0, 1500 } });
		end, { timeout = 30 });
		after(function (ctx)
			if (ctx.interceptor) then
				ctx.interceptor:ROE(PassiveROE);
				SHIP_TEST.reset(ctx, "interceptor");
			end
		end);

		it("alliedWith is 1 for its own player's ships, and nil for the enemy's", function (ctx)
			expectTruthy(ctx.interceptor:alliedWith(ctx.scout));
			expectNil(ctx.interceptor:alliedWith(ctx.target));
			expectNil(ctx.interceptor:alliedWith(ctx.enemy));
		end);

		it("attack makes it attack the target, which is then under attack", function (ctx)
			ctx.target:invulnerable(1); -- (so it lives long enough to check)
			ctx.target:ROE(PassiveROE);
			ctx.interceptor:ROE(OffensiveROE);
			ctx.interceptor:attack(ctx.target);
			return sequence(
				waitFor(function () return %ctx.interceptor:attacking(%ctx.target); end, { message = "never attacking the target" }),
				function () expectTruthy(%ctx.interceptor:attacking(), "attacking anything"); end,
				waitFor(function () return %ctx.target:underAttack(); end, { timeout = 20, message = "the target was never under attack" }),
				function () expectTruthy(%ctx.target:underAttack(%ctx.interceptor), "under attack by the interceptor"); end
			);
		end, { timeout = 40 });
	end);
end);
