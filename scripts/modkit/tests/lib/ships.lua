-- Helpers for ingame tests that spawn ships (`SHIP_TEST`), used by `tests/ship.lua` and `tests/engine/*.lua`. Test files load this with
-- `dofilepath`; the `test` command doesn't load `tests/lib/` itself.
--
-- Spawned ships belong to `SHIP_TEST.player`, around `SHIP_TEST.origin` (move it if that's crowded on your map).

-- (on a global table: Lua 4 upvalues only reach one function out, so file-level locals can't be used inside `it` callbacks)
SHIP_TEST = {
	origin = { 0, 3000, 0 },
	player = 0,
	--- The sandbox level's (`modkit_sandbox.level`) inner world bounds, which the camera can't scroll past: `setWorldBoundsInner`'s
	--- second argument, which is the distance from the centre on each axis (stock start positions go up to 0.89 of it, never past).
	--- Tests run in the sandbox, so every ship stays inside these (less `bounds_margin`), where it can be watched.
	bounds = { 24500, 8750, 52500 },
	bounds_centre = { 0, 0, 0 },
	bounds_margin = 1000,
};

--- Fails (the hook or test) if `where` is outside the sandbox's inner world bounds, less `SHIP_TEST.bounds_margin`.
---
---@param where Vec3Like
---@param what string What's being placed there, for the failure message.
function SHIP_TEST.checkInBounds(where, what)
	where = Vec3(where);
	for i = 1, 3 do
		local limit = SHIP_TEST.bounds[i] - SHIP_TEST.bounds_margin;
		if (abs(where[i] - SHIP_TEST.bounds_centre[i]) > limit) then
			fail(what .. " would be outside the world bounds: " .. Vec3:toStr(where) .. " (axis " .. i .. " limit is ±" .. limit .. ")");
		end
	end
end

--- Spawns a `ship_type` for `options.player` (default `SHIP_TEST.player`) at `options.offset` from `SHIP_TEST.origin`, and sets it as
--- `ctx[key]` once modkit registers it. Spawned ships are kept in `ctx.spawned`, for `SHIP_TEST.cleanup`.
---
---@param ctx table
---@param key string
---@param ship_type string
---@param options? { player?: integer, offset?: Vec3Like }
---@return Event
function SHIP_TEST.spawn(ctx, key, ship_type, options)
	options = options or {};
	ctx.spawned = ctx.spawned or {};
	ctx.home = ctx.home or {};
	local where = Vec3(SHIP_TEST.origin) + Vec3(options.offset or { 0, 0, 0 });
	SHIP_TEST.checkInBounds(where, "spawning " .. key .. " (" .. ship_type .. ")");
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
		modkit.table.push(%ctx.spawned, ship);
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

--- Returns a player who isn't allied with `SHIP_TEST.player`, or `nil` if there's none.
---
---@return Player|nil
function SHIP_TEST.enemy()
	local me = GLOBAL_PLAYERS:get(SHIP_TEST.player);
	return modkit.table.findVal(GLOBAL_PLAYERS:alive(), function (player)
		return not player:alliedWith(%me);
	end);
end

--- Describes `ship`'s state for failure messages: its current command, distance from `ctx.home[key]`, HP and whether it's under attack.
---
---@param ctx table
---@param key string
---@return string
function SHIP_TEST.describe(ctx, key)
	local ship = ctx[key];
	if (ship == nil or ship._destroyed or ship:count() == 0) then
		return key .. " is gone";
	end
	return key .. ": command " .. tostring(ship:currentCommand())
		.. ", " .. floor(ship:distanceTo(ctx.home[key])) .. " from home"
		.. ", HP " .. format("%.2f", ship:HP())
		.. ", underAttack " .. tostring(ship:underAttack());
end
