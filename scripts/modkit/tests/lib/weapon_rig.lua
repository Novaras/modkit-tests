-- The weapon test rig, shared by `tests/engine/weapons/basics.lua` and `tests/engine/bursts.lua` (which load it with `dofilepath`; the `test`
-- command doesn't load `tests/lib/` itself).
--
-- - The guns (`ship/test_*`) can't move or turn, and carry one weapon each on `Weapon_Gun3`. Ships spawn facing a fixed
--   direction, so a gun's hardpoint always points the same way: along its forward axis `ENGINE_TEST.F`, which `ENGINE_TEST.calibrate`
--   reads with `SobGroup_GetCoordSys` (working out first which of its axes is forward).
-- - The targets (`ship/test_target`, `test_target_tough`) are assault frigates with no weapons, spawned fresh for each test,
--   with no HP regeneration, so HP lost counts strikes.

dofilepath("data:scripts/modkit/tests/lib/ships.lua"); -- (`SHIP_TEST`: spawning and cleanup helpers)

-- (a global table: Lua 4 upvalues only reach one function out, so file-level locals can't be used inside `it` callbacks; shared by
-- the files in `tests/engine/`, which also run alone)
ENGINE_TEST = ENGINE_TEST or {};

--- The target's (`test_target`) `mainEngineMaxSpeed`.
ENGINE_TEST.TARGET_MAX_SPEED = 206;
--- How far from its gun a stationary target is placed.
ENGINE_TEST.RANGE = 1500;
--- How far off a gun's forward axis an "off-axis" target is, in degrees.
ENGINE_TEST.OFF_AXIS_DEGREES = 30;
--- How long `ENGINE_TEST.fire` has the gun fire (the test guns fire every 1s, so about this many shots).
ENGINE_TEST.FIRE_SECONDS = 8;
--- How long `ENGINE_TEST.fire` keeps watching after the gun stops, for shots still in flight (5s covers 3000 at 600/s).
ENGINE_TEST.TAIL_SECONDS = 6;
--- How many runs the lead diagnostics repeat each set-up for (single runs vary a lot).
ENGINE_TEST.REPEATS = 10;
--- A target counts as still below this speed. (It was 5/s: targets moved there were often still drifting at ~5/s when firing began,
--- and against those, full lead lost runs of shots while the same target at 0/s was struck by all of them.)
ENGINE_TEST.STILL_SPEED = 0.5;
--- How long a still target is left after being moved, before a gun fires at it (see `ENGINE_TEST.fire`).
ENGINE_TEST.SETTLE_SECONDS = 5;

-- ===[ Orientation ]===

--- Returns the 6 candidate axes in `SobGroup_GetCoordSys(group)`'s matrix (its 3 rows, then its 3 columns, as `Vec3`s), and the
--- matrix as a flat list of 9 numbers. Takes either shape the binding might return: 9 numbers, or 3 rows of 3.
---
---@param group string
---@return Vec3[], number[]
function ENGINE_TEST.axes(group)
	local matrix = SobGroup_GetCoordSys(group);
	if (type(matrix) ~= "table") then
		fail("SobGroup_GetCoordSys returned " .. tostring(matrix) .. ", not a table");
	end
	local flat = {};
	if (type(matrix[1]) == "table") then
		for row = 1, 3 do
			for column = 1, 3 do
				flat[(row - 1) * 3 + column] = matrix[row][column];
			end
		end
	else
		for i = 1, 9 do
			flat[i] = matrix[i];
		end
	end
	local axes = {};
	for i = 1, 3 do
		axes[i] = Vec3({ flat[(i - 1) * 3 + 1], flat[(i - 1) * 3 + 2], flat[(i - 1) * 3 + 3] }); -- (row i)
		axes[3 + i] = Vec3({ flat[i], flat[3 + i], flat[6 + i] }); -- (column i)
	end
	return axes, flat;
end

--- Describes a flat 3x3 matrix, for the log.
---
---@param flat number[]
---@return string
function ENGINE_TEST.describeMatrix(flat)
	local out = "";
	for i = 1, 9 do
		out = out .. format("%.3f", flat[i] or 0);
		if (i == 3 or i == 6) then
			out = out .. " | ";
		elseif (i < 9) then
			out = out .. ", ";
		end
	end
	return out;
end

-- ===[ Firing ]===

--- Spawns each of `guns` (`{ [key] = ship_type }`) for our player, and resolves once they're all registered. By default they're
--- stacked 500 apart vertically, centred on `SHIP_TEST.origin` (no gun is in another's line of fire, whichever way they face, and
--- up to 20 fit inside the world bounds). With `spread`, they're on a grid of 5 across (9000 apart) and up to 2 deep (12000 apart)
--- instead, so every other gun's target is out of range (weapons pick other enemies in range by themselves).
---
---@param ctx table
---@param guns table<string, string>
---@param spread? 1
---@return Event
function ENGINE_TEST.spawnGuns(ctx, guns, spread)
	local count = 0;
	for _, _ in guns do
		count = count + 1;
	end
	local i = 0;
	for key, ship_type in guns do
		local offset = { 0, (i - (count - 1) / 2) * 500, 4000 };
		if (spread) then
			offset = { (mod(i, 5) - 2) * 9000, 0, 4000 - floor(i / 5) * 12000 };
		end
		SHIP_TEST.spawn(ctx, key, ship_type, { offset = offset })
			:catch(function (message) %ctx.spawn_error = message; end);
		i = i + 1;
	end
	return waitFor(function ()
		if (%ctx.spawn_error) then
			fail("spawning failed: " .. %ctx.spawn_error);
		end
		for key, _ in %guns do
			if (%ctx[key] == nil) then
				return nil;
			end
		end
		return 1;
	end, { timeout = 30, message = "the guns never registered" });
end

--- Puts `ship` at `start` and gets it moving along `direction` at `speed` times its max speed (`max_speed`, default
--- `ENGINE_TEST.TARGET_MAX_SPEED`), or fails. First it turns to face `direction` at full speed (a ship's speed multiplier slows
--- its turning too: at 10-15% a target took over 30s to turn around), brought to a stop (it keeps its velocity when moved: a
--- target moved back mid-turn drifted sideways, and its first run was never struck), put back at `start`, and set going at `speed`.
--- Resolves once it's within 5% of that speed (or steady: see below), has flown straight along the line for a second, and is
--- within 30 of the line.
---
---@param ship Ship
---@param start Vec3
---@param direction Vec3
---@param speed number
---@param max_speed? number
---@return Event
function ENGINE_TEST.runUp(ship, start, direction, speed, max_speed)
	local state = { target_speed = (max_speed or ENGINE_TEST.TARGET_MAX_SPEED) * speed };
	-- (far enough that it's still flying when the test ends: 40s at its speed, between 3000 and 8000; a fixed 8000 took slow
	-- targets of the outer guns outside the world bounds)
	local destination = start + direction * min(8000, max(3000, state.target_speed * 40));
	SHIP_TEST.checkInBounds(start, "the target's run-up start");
	SHIP_TEST.checkInBounds(destination, "the target's destination");
	ship:position(start);
	ship:speed(1);
	ship:move(destination, { no_event = 1 });
	return sequence(
		-- (forward is row 3 of `SobGroup_GetCoordSys`: see `ENGINE_TEST.calibrate`'s log)
		waitFor(function ()
			local axes = ENGINE_TEST.axes(%ship.own_group);
			%state.facing = Vec3:dot(axes[3], %direction);
			return %state.facing > 0.995;
		end, { timeout = 30, message = function ()
			return "the target never turned to face its line (forward . direction " .. format("%.3f", %state.facing or -2) .. ")";
		end }),
		function ()
			%ship:stop();
		end,
		waitFor(function ()
			return sqrt(%ship:actualSpeedSq()) < ENGINE_TEST.STILL_SPEED;
		end, { timeout = 30, message = "the target never stopped after turning" }),
		function ()
			%ship:position(%start);
			%ship:speed(%speed);
			%ship:move(%destination, { no_event = 1 });
		end,
		-- (within 5% of the asked-for speed; or, since the speed multiplier doesn't scale linearly at low values (10% gave ~half), a
		-- steady speed: moving, and within 5% (or 1/s) of the newest reading at least 2s old; or failing that, moving for 15s)
		waitFor(function ()
			local speed = sqrt(%ship:actualSpeedSq());
			local now = Universe_GameTime();
			if (abs(speed - %state.target_speed) <= 0.05 * %state.target_speed) then
				return 1;
			end
			%state.history = %state.history or {};
			modkit.table.push(%state.history, { now, speed });
			if (speed > 3) then
				%state.moving_since = %state.moving_since or now;
			else
				%state.moving_since = nil;
			end
			local older = nil;
			for i = 1, modkit.table.length(%state.history) do
				if (now - %state.history[i][1] >= 2) then
					older = %state.history[i]; -- (the list is in time order, so the last match is the newest)
				end
			end
			if (older and speed > 3 and abs(speed - older[2]) <= max(0.05 * speed, 1)) then
				return 1;
			end
			if (%state.moving_since and now - %state.moving_since >= 15) then
				return 1;
			end
			return nil;
		end, { timeout = 30, message = function ()
			return "the target never got up to speed (" .. format("%.0f", sqrt(%ship:actualSpeedSq())) .. "/s of "
				.. format("%.0f", %state.target_speed) .. "/s)";
		end }),
		function ()
			%state.from = %ship:position();
		end,
		wait(1),
		function ()
			local travelled = %ship:position() - %state.from;
			local straightness = Vec3:dot(travelled, %direction) / Vec3:magnitude(travelled);
			if (straightness < 0.98) then
				fail("the target isn't flying straight along its line yet (" .. format("%.3f", straightness) .. ")");
			end
			local offset = %ship:position() - %start;
			local off_line = Vec3:magnitude(offset - %direction * Vec3:dot(offset, %direction));
			if (off_line > 30) then
				fail("the target is " .. format("%.0f", off_line) .. " off its line");
			end
		end
	);
end

--- Brings `ship` (a test target, just moved) to a stop, upright, then pins it there with its speed at 0. Resolves once it's slower
--- than `ENGINE_TEST.STILL_SPEED` and its up axis is within ~6 degrees of the world's (row 2 of `SobGroup_GetCoordSys`; the guns'
--- is the identity). Targets used to be pinned at speed 0 straight after being moved, and some stayed tilted (seen in game): a
--- pinned ship can't turn back upright. Logs it if the ship was tilted.
---
---@param ship Ship
---@return Event
function ENGINE_TEST.holdStill(ship)
	ship:speed(1);
	ship:stop();
	local state = { start = Universe_GameTime() };
	local axes, flat = ENGINE_TEST.axes(ship.own_group);
	state.first_up = Vec3:dot(axes[2], { 0, 1, 0 });
	state.first = ENGINE_TEST.describeMatrix(flat);
	return sequence(
		waitFor(function ()
			local axes = ENGINE_TEST.axes(%ship.own_group);
			%state.up = Vec3:dot(axes[2], { 0, 1, 0 });
			%state.speed = sqrt(%ship:actualSpeedSq());
			return %state.speed < ENGINE_TEST.STILL_SPEED and %state.up > 0.995;
		end, { timeout = 30, message = function ()
			return "the target never settled (speed " .. format("%.1f", %state.speed or -1) .. ", up axis . world up "
				.. format("%.3f", %state.up or -1) .. ")";
		end }),
		function ()
			%ship:speed(0);
			if (%state.first_up <= 0.995) then
				print("[test engine] the target was tilted when moved (up axis . world up " .. format("%.3f", %state.first_up) .. ", coordsys "
					.. %state.first .. "); upright after " .. format("%.1f", Universe_GameTime() - %state.start) .. "s");
			end
		end
	);
end

--- Places `ctx.target` relative to the gun `ctx[gun_key]` (`placement.at`, an offset from the gun), either holding still or (with
--- `placement.direction`) flying along that direction at `placement.speed` (default 1) times its max speed, after a run-up. Then
--- has the gun fire at it for `ENGINE_TEST.FIRE_SECONDS`, and watches for `ENGINE_TEST.TAIL_SECONDS` more (shots still in flight).
--- Sets `ctx.drop` (the target's HP lost, a fraction), `ctx.fired` (whether it fired at all: the target is flagged as under attack
--- for 10s after each shot) and `ctx.strike_times` (when each strike landed, in seconds after the attack order; the target's HP is
--- polled every 0.1s, and the guns fire every 1s, so each poll sees at most one strike). Fails if the gun never fired, or a moving
--- target slowed down.
---
---@param ctx table
---@param gun_key string
---@param placement { at: Vec3, direction?: Vec3, speed?: number, max_speed?: number, label: string }
---@return Event
function ENGINE_TEST.fire(ctx, gun_key, placement)
	local gun = ctx[gun_key];
	local target = ctx.target;
	local start = ctx.home[gun_key] + placement.at;
	ctx.gun_key = gun_key;
	ctx.placement = placement;
	ctx.target_speed = nil;
	ctx.end_speed = nil;
	ctx.fired = nil;
	ctx.drop = nil;

	local ready = nil;
	if (placement.direction) then
		ready = ENGINE_TEST.runUp(target, start, placement.direction, placement.speed or 1, placement.max_speed);
	else
		SHIP_TEST.checkInBounds(start, "the target");
		target:position(start);
		-- (then a wait: ballistic lead lost the early shots (up to ~3s after the attack order) of the first run against a target
		-- just moved, even once it was still and upright, and none in later runs at the same spot)
		ready = sequence(ENGINE_TEST.holdStill(target), wait(ENGINE_TEST.SETTLE_SECONDS));
	end

	return sequence(
		ready,
		function ()
			%target:HP(1); -- (a target reused within a test starts each burst at full HP)
			%ctx.target_speed = sqrt(%target:actualSpeedSq());
			%ctx.distance = %target:distanceTo(%gun);
			%ctx.hp_before = %target:HP();
			%ctx.strike_times = {};
			%ctx.samples = {};
			%ctx.next_sample = 0;
			%ctx.last_hp = %ctx.hp_before;
			%ctx.leftover_drop = 0;
			%ctx.leftovers = 0;
			%ctx.stopped = nil;
			%ctx.fire_start = Universe_GameTime();
			%gun:ROE(OffensiveROE);
			%gun:attack(%target);
		end,
		waitFor(function ()
			local now = Universe_GameTime() - %ctx.fire_start;
			local hp = %target:HP();
			if (hp < %ctx.last_hp) then
				-- (a still target can't be struck by a shot fired after the attack order sooner than its flight time: earlier strikes
				-- are leftovers, fired before the order (seen after `firstStrike`, whose gun went on firing for a while), so they're
				-- left out of `ctx.drop`)
				-- (`ctx.shot_speeds[gun_key]`, if set, overrides the shot speed; 0 turns this off, e.g. for beams and missiles)
				local shot_speed = ENGINE_TEST.SHOT_SPEED;
				if (%ctx.shot_speeds and %ctx.shot_speeds[%ctx.gun_key]) then
					shot_speed = %ctx.shot_speeds[%ctx.gun_key];
				end
				if (not %ctx.placement.direction and shot_speed > 0 and now < %ctx.distance / shot_speed - 0.3) then
					%ctx.leftover_drop = %ctx.leftover_drop + (%ctx.last_hp - hp);
					%ctx.leftovers = %ctx.leftovers + 1;
				else
					modkit.table.push(%ctx.strike_times, now);
				end
			end
			%ctx.last_hp = hp;
			if (%ctx.placement.direction and not %ctx.stopped and now >= %ctx.next_sample) then
				%ctx.next_sample = %ctx.next_sample + 1;
				modkit.table.push(%ctx.samples, ENGINE_TEST.aimModel(%ctx, %gun, %target, now));
			end
			if (not %ctx.stopped and now >= ENGINE_TEST.FIRE_SECONDS) then
				%ctx.stopped = 1;
				%ctx.fired = %target:underAttack();
				%ctx.end_speed = sqrt(%target:actualSpeedSq());
				%gun:ROE(PassiveROE);
				%gun:stop();
			end
			return now >= ENGINE_TEST.FIRE_SECONDS + ENGINE_TEST.TAIL_SECONDS;
		end, { timeout = ENGINE_TEST.FIRE_SECONDS + ENGINE_TEST.TAIL_SECONDS + 10, message = "the firing window never ended" }),
		function ()
			%ctx.drop = %ctx.hp_before - %target:HP() - %ctx.leftover_drop;
			print("[test engine] " .. ENGINE_TEST.describeShot(%ctx));
			if (%ctx.leftovers > 0) then
				print("[test engine]   (left out: " .. %ctx.leftovers .. " strikes too soon after the attack order to be from its shots)");
			end
			if (modkit.table.length(%ctx.samples) > 0) then
				local line = "";
				for i = 1, modkit.table.length(%ctx.samples) do
					line = line .. %ctx.samples[i] .. "; ";
				end
				print("[test engine]   lead model (t: distance, predicted miss if lead uses the live distance / the distance at the attack order; + = ahead of the target's centre): " .. line);
			end
			local placement = %ctx.placement;
			if (placement.direction and %ctx.end_speed < 0.9 * %ctx.target_speed) then -- (against its speed when firing began)
				fail("the target slowed down while the gun fired: " .. ENGINE_TEST.describeShot(%ctx));
			end
			if (not %ctx.fired) then
				fail("the gun never fired: " .. ENGINE_TEST.describeShot(%ctx));
			end
		end
	);
end

--- The test weapons' shot speed.
ENGINE_TEST.SHOT_SPEED = 600;

--- For a shot fired now at `target` by `gun` with full lead, returns how far ahead of the target's centre the shot would pass
--- (negative: behind), along the target's direction of travel, under a model of lead: aim at where the target will be after a flight
--- time worked out from `distance` (the shot then arrives early if that point is nearer than `distance`, late if further).
---
---@param gun_pos Vec3
---@param target_pos Vec3
---@param velocity Vec3
---@param distance number
---@return number
function ENGINE_TEST.leadMiss(gun_pos, target_pos, velocity, distance)
	local flight = distance / ENGINE_TEST.SHOT_SPEED;
	local aim = target_pos + velocity * flight;
	local actual = Vec3:magnitude(aim - gun_pos) / ENGINE_TEST.SHOT_SPEED;
	return Vec3:magnitude(velocity) * (flight - actual);
end

--- One sample for `ENGINE_TEST.fire`'s log, `now` seconds after the attack order: the target's distance, and `ENGINE_TEST.leadMiss`
--- under two models: the flight time from the live distance, and from the distance at the attack order (`ctx.distance`).
---
---@param ctx table
---@param gun Ship
---@param target Ship
---@param now number
---@return string
function ENGINE_TEST.aimModel(ctx, gun, target, now)
	local gun_pos = gun:position();
	local target_pos = target:position();
	local velocity = Vec3:unit(ctx.placement.direction) * sqrt(target:actualSpeedSq());
	local distance = Vec3:magnitude(target_pos - gun_pos);
	return format("%.0f", now) .. "s: " .. format("%.0f", distance) .. ", "
		.. format("%+.0f", ENGINE_TEST.leadMiss(gun_pos, target_pos, velocity, distance)) .. " / "
		.. format("%+.0f", ENGINE_TEST.leadMiss(gun_pos, target_pos, velocity, ctx.distance));
end

--- Places `ctx.target` (holding still) at `at` from the gun `ctx[gun_key]`, has the gun attack it for 8s, and adds a line to
--- `ctx.probe_lines`: whether the gun fired (the target was flagged as under attack) and the HP it lost. Then stops the gun and waits
--- for the under-attack flag to clear (it lasts 10s after a shot), so the next probe starts clean. Never fails on its own.
---
---@param ctx table
---@param gun_key string
---@param at Vec3
---@param label string
---@return Event
function ENGINE_TEST.probe(ctx, gun_key, at, label)
	local gun = ctx[gun_key];
	local target = ctx.target;
	local where = ctx.home[gun_key] + at;
	SHIP_TEST.checkInBounds(where, "the target");
	target:position(where);
	local state = {};
	return sequence(
		ENGINE_TEST.holdStill(target),
		function ()
			%target:HP(1);
			%state.hp_before = %target:HP();
			%state.start = Universe_GameTime();
			%gun:ROE(OffensiveROE);
			%gun:attack(%target);
		end,
		waitFor(function ()
			if (%target:underAttack()) then
				%state.fired = 1;
			end
			return Universe_GameTime() - %state.start >= 8;
		end, { timeout = 20, message = "the probe never finished" }),
		function ()
			local drop = %state.hp_before - %target:HP();
			%gun:ROE(PassiveROE);
			%gun:stop();
			%ctx.probe_lines = %ctx.probe_lines or {};
			modkit.table.push(%ctx.probe_lines, %gun_key .. ", target " .. %label .. ": fired " .. tostring(%state.fired)
				.. ", HP lost " .. format("%.4f", drop));
		end,
		waitFor(function () return %target:underAttack() == nil; end, { timeout = 15, message = "the target stayed under attack" })
	);
end

--- Places `ctx.target` (holding still) at `at` from the gun `ctx[gun_key]`, has the gun fire until the target is first struck, and
--- sets `ctx.strike` to the HP that strike took (a fraction). The guns fire every 1s, so one poll only ever sees one strike.
---
---@param ctx table
---@param gun_key string
---@param at Vec3
---@return Event
function ENGINE_TEST.firstStrike(ctx, gun_key, at)
	local gun = ctx[gun_key];
	local target = ctx.target;
	SHIP_TEST.checkInBounds(ctx.home[gun_key] + at, "the target");
	target:position(ctx.home[gun_key] + at);
	return sequence(
		ENGINE_TEST.holdStill(target),
		function ()
			%ctx.hp_before = %target:HP();
			%gun:ROE(OffensiveROE);
			%gun:attack(%target);
		end,
		waitFor(function () return %target:HP() < %ctx.hp_before; end, { timeout = 20, message = function ()
			return "never struck (" .. SHIP_TEST.describe(%ctx, "target") .. ")";
		end }),
		function ()
			%ctx.strike = %ctx.hp_before - %target:HP();
			%gun:ROE(PassiveROE);
			%gun:stop();
		end
	);
end

--- Describes the last `ENGINE_TEST.fire`, for logs and failure messages.
---
---@param ctx table
---@return string
function ENGINE_TEST.describeShot(ctx)
	local strikes = "";
	if (ENGINE_TEST.hit_damage and ctx.drop) then
		strikes = " (" .. format("%.1f", ctx.drop / ENGINE_TEST.hit_damage) .. " hits' worth)";
	end
	return ctx.gun_key .. " vs a target " .. ctx.placement.label
		.. " (at " .. format("%.0f", ctx.target_speed or 0) .. "/s, then " .. format("%.0f", ctx.end_speed or 0) .. "/s; "
		.. format("%.0f", ctx.distance or 0) .. " away): fired " .. tostring(ctx.fired) .. ", HP lost " .. format("%.6f", ctx.drop or 0)
		.. strikes .. ENGINE_TEST.describeStrikeTimes(ctx);
end

--- Describes `ctx.strike_times` (from `ENGINE_TEST.fire`) as the times the shots that struck were fired: each strike's time minus
--- the shot's flight time (`ctx.distance` / 600, the test weapons' shot speed), so with a gun firing every 1s, shots that didn't
--- strike show as gaps.
---
---@param ctx table
---@return string
function ENGINE_TEST.describeStrikeTimes(ctx)
	if (ctx.strike_times == nil) then
		return "";
	end
	local flight = (ctx.distance or 0) / 600;
	local out = "; struck by shots fired at ~";
	local count = modkit.table.length(ctx.strike_times);
	if (count == 0) then
		return out .. "(none)";
	end
	for i = 1, count do
		out = out .. format("%.1f", ctx.strike_times[i] - flight) .. "s ";
	end
	return out;
end

--- Runs `ENGINE_TEST.fire(ctx, gun_key, placement)` `runs` times in a row (a fresh attack order each time, so a fresh aim), and
--- prints each run's strikes (one 'hit' strike's damage each) and a summary. Sets `ctx.run_strikes` (strikes per run) and
--- `ctx.run_speeds` (the target's speed as each run's firing began).
---
---@param ctx table
---@param gun_key string
---@param placement table
---@param runs integer
---@return Event
function ENGINE_TEST.fireRepeated(ctx, gun_key, placement, runs)
	ctx.run_strikes = {};
	ctx.run_speeds = {};
	return ENGINE_TEST.fireRun(ctx, gun_key, placement, runs, 1);
end

--- One run of `ENGINE_TEST.fireRepeated`, which chains the next (each run's set-up has to happen once the previous one ends).
---@param ctx table
---@param gun_key string
---@param placement table
---@param runs integer
---@param i integer
---@return Event
function ENGINE_TEST.fireRun(ctx, gun_key, placement, runs, i)
	return sequence(
		ENGINE_TEST.fire(ctx, gun_key, placement),
		function ()
			local strikes = %ctx.drop / (ENGINE_TEST.hit_damage or %ctx.drop);
			modkit.table.push(%ctx.run_strikes, strikes);
			modkit.table.push(%ctx.run_speeds, %ctx.target_speed or 0);
			if (%i < %runs) then
				return ENGINE_TEST.fireRun(%ctx, %gun_key, %placement, %runs, %i + 1);
			end
			local total = 0;
			local list = "";
			for r = 1, %runs do
				total = total + %ctx.run_strikes[r];
				list = list .. format("%.1f", %ctx.run_strikes[r]) .. " ";
			end
			print("[test engine] summary: " .. %gun_key .. " vs a target " .. %placement.label .. ", " .. %runs .. " runs of "
				.. ENGINE_TEST.FIRE_SECONDS .. "s: strikes per run " .. list .. "(total " .. format("%.1f", total) .. ")");
		end
	);
end

--- Moves the gun `ctx[gun_key]` to `where` (world), and makes that its home, which `ENGINE_TEST.fire`'s placements are relative to.
--- (The test guns can't move or turn, but can be put anywhere: they keep facing `ENGINE_TEST.F`.)
---
---@param ctx table
---@param gun_key string
---@param where Vec3
function ENGINE_TEST.placeGun(ctx, gun_key, where)
	where = Vec3(where);
	SHIP_TEST.checkInBounds(where, gun_key);
	ctx[gun_key]:position(where);
	ctx.home[gun_key] = where;
end

--- Has the gun `ctx[gun_key]` fire at `ctx.target`, still `ENGINE_TEST.RANGE` dead ahead, with a still `test_target` (the
--- "blocker", owned by `player`) halfway between them. Fails unless the blocker is struck and the target isn't. The blocker is
--- killed afterwards.
---
---@param ctx table
---@param gun_key string
---@param player integer
---@return Event
function ENGINE_TEST.fireWithBlocker(ctx, gun_key, player)
	local at = ENGINE_TEST.F * (ENGINE_TEST.RANGE / 2);
	return sequence(
		SHIP_TEST.spawn(ctx, "blocker", "test_target", { player = player, offset = ctx.home[gun_key] + at - Vec3(SHIP_TEST.origin) }),
		function ()
			local blocker = %ctx.blocker;
			blocker:speed(0);
			blocker:stop();
			blocker:position(%ctx.home[%gun_key] + %at);
			%ctx.blocker_hp = blocker:HP();
			return ENGINE_TEST.fire(%ctx, %gun_key, ENGINE_TEST.ahead());
		end,
		function ()
			local blocker = %ctx.blocker;
			local blocker_drop = %ctx.blocker_hp - blocker:HP();
			local where = Vec3:magnitude(blocker:position() - (%ctx.home[%gun_key] + %at));
			blocker:die(1);
			print("[test engine] the ship in the way (player " .. %player .. ") lost HP " .. format("%.6f", blocker_drop)
				.. " and moved " .. format("%.0f", where) .. " from its spot");
			expect(blocker_drop > 0, "the ship in the way should have been struck: " .. ENGINE_TEST.describeShot(%ctx));
			expect(%ctx.drop == 0, "the target behind it shouldn't have been struck: " .. ENGINE_TEST.describeShot(%ctx));
		end
	);
end

--- Where the sandbox level puts its one asteroid (`Asteroid_4`, in `modkit_sandbox.level`'s `DetermChunk`), far from the test
--- ships' usual area, but at their height (3000: ships moved far up or down end up pitched, and test targets can't level out). Keep
--- the two in step. Asteroids can't be spawned during the game.
ENGINE_TEST.ASTEROID = { 12000, 3000, -30000 };

--- Moves the gun `ctx[gun_key]` 1200 short of `ENGINE_TEST.ASTEROID` along its line of fire (`sideways` 0), or `sideways` to one side
--- of that line (a control, with nothing in the way), and has it fire at `ctx.target` held still 1200 beyond the asteroid (2400
--- ahead of the gun). The target is spawned there afresh (one moved there from far away ended up turned, and ~40 off its spot).
--- Logs where the gun and target ended up, against where they were put, and the target's orientation. Then puts the gun back.
---
---@param ctx table
---@param gun_key string
---@param sideways number
---@return Event
function ENGINE_TEST.fireAcrossAsteroid(ctx, gun_key, sideways)
	local home = ctx.home[gun_key];
	local label = "still, 2400 dead ahead, behind the asteroid";
	if (sideways ~= 0) then
		label = "still, 2400 dead ahead, " .. sideways .. " to the side of the asteroid";
	end
	local spot = Vec3(ENGINE_TEST.ASTEROID) - ENGINE_TEST.F * 1200 + ENGINE_TEST.R * sideways;
	ENGINE_TEST.placeGun(ctx, gun_key, spot);
	print("[test engine] " .. gun_key .. " put at " .. Vec3:toStr(spot) .. ", " .. sideways .. " to the side of the asteroid's line ("
		.. Vec3:toStr(ENGINE_TEST.ASTEROID) .. "); now at " .. Vec3:toStr(ctx[gun_key]:position()));
	if (ctx.target and not ctx.target._destroyed) then
		ctx.target:die(1);
	end
	ctx.target = nil;
	return sequence(
		SHIP_TEST.spawn(ctx, "target", "test_target", { player = ctx.enemy.id, offset = spot + ENGINE_TEST.F * 2400 - Vec3(SHIP_TEST.origin) }),
		function ()
			return ENGINE_TEST.fire(%ctx, %gun_key, { at = ENGINE_TEST.F * 2400, label = %label });
		end,
		function ()
			local gun = %ctx[%gun_key];
			local target_spot = %spot + ENGINE_TEST.F * 2400;
			local _, flat = ENGINE_TEST.axes(%ctx.target.own_group);
			print("[test engine]   afterwards: " .. %gun_key .. " " .. format("%.0f", Vec3:magnitude(gun:position() - %spot))
				.. " from where it was put; the target " .. format("%.0f", Vec3:magnitude(%ctx.target:position() - target_spot))
				.. " from where it was put (" .. Vec3:toStr(%ctx.target:position()) .. "), coordsys " .. ENGINE_TEST.describeMatrix(flat)
				.. " (the guns' is the identity)");
			ENGINE_TEST.placeGun(%ctx, %gun_key, %home);
		end
	);
end

-- ===[ Lanes ]=== (running several guns at once, each against its own target)

--- Makes a lane: a context for `ENGINE_TEST.fire`, `fireRepeated` and `firstStrike` with the gun `ctx[gun_key]` against its own
--- target `ctx[target_key]`, so several can run at once (`parallel`) without sharing state. It shares the suite's `enemy` and
--- `shot_speeds`; its results (`drop`, `run_strikes` etc.) stay on the lane.
---
---@param ctx table
---@param gun_key string
---@param target_key string
---@return table
function ENGINE_TEST.makeLane(ctx, gun_key, target_key)
	local lane = { home = {}, enemy = ctx.enemy, shot_speeds = ctx.shot_speeds, gun_key = gun_key };
	lane[gun_key] = ctx[gun_key];
	lane.home[gun_key] = ctx.home[gun_key];
	lane.target = ctx[target_key];
	return lane;
end

--- Spawns a target (`ship_types[key]`, default `test_target`) for each of `keys`, as `ctx["target_" .. key]`, parked 12000 beyond
--- and 3000 above its gun `ctx[key]` (out of every gun's range); resolves once they're all registered.
---
---@param ctx table
---@param keys string[]
---@param ship_types? table<string, string>
---@return Event
function ENGINE_TEST.spawnLaneTargets(ctx, keys, ship_types)
	ship_types = ship_types or {};
	local branches = { n = 0 };
	for i = 1, modkit.table.length(keys) do
		local key = keys[i];
		local offset = ctx.home[key] - Vec3(SHIP_TEST.origin) + Vec3({ 0, 3000, 12000 });
		branches.n = branches.n + 1;
		branches[branches.n] = SHIP_TEST.spawn(ctx, "target_" .. key, ship_types[key] or "test_target", { player = ctx.enemy.id, offset = offset });
	end
	return call(parallel, branches);
end

--- Kills the lane targets `ENGINE_TEST.spawnLaneTargets` made for `keys`.
---
---@param ctx table
---@param keys string[]
function ENGINE_TEST.killLaneTargets(ctx, keys)
	for i = 1, modkit.table.length(keys) do
		local target = ctx["target_" .. keys[i]];
		if (target and not target._destroyed) then
			target:die(1);
		end
		ctx["target_" .. keys[i]] = nil;
	end
end

-- ===[ Placements ]=== (set in the suite's `before`, once the guns' forward axis is known)

--- A target holding still `ENGINE_TEST.RANGE` straight ahead of its gun.
---@return table
function ENGINE_TEST.ahead()
	return { at = ENGINE_TEST.F * ENGINE_TEST.RANGE, label = "still, dead ahead" };
end

--- A target holding still `ENGINE_TEST.RANGE` from its gun, `ENGINE_TEST.OFF_AXIS_DEGREES` off its forward axis.
---@return table
function ENGINE_TEST.offAxis()
	local angle = ENGINE_TEST.OFF_AXIS_DEGREES; -- (Lua 4's `sin` and `cos` take degrees)
	return {
		at = (ENGINE_TEST.F * cos(angle) + ENGINE_TEST.R * sin(angle)) * ENGINE_TEST.RANGE,
		label = "still, " .. angle .. " degrees off-axis",
	};
end

--- A target flying straight away from its gun along its forward axis, at full speed.
---@return table
function ENGINE_TEST.away()
	return { at = ENGINE_TEST.F * 600, direction = ENGINE_TEST.F, label = "flying straight away" };
end

--- A target 3000 ahead of its gun and 1200 to one side, flying (at `speed` times its max speed) straight across in front of the gun
--- (`"straight across"`, along `ENGINE_TEST.R`), or at 45 degrees towards it (`"approaching"`) or away from it (`"receding"`).
---@param kind string
---@param speed number
---@return table
function ENGINE_TEST.lane(kind, speed)
	local F = ENGINE_TEST.F;
	local R = ENGINE_TEST.R;
	local direction = R;
	if (kind == "approaching") then
		direction = (R - F) * (1 / sqrt(2));
	elseif (kind == "receding") then
		direction = (R + F) * (1 / sqrt(2));
	end
	return {
		at = F * 3000 - R * 1200,
		direction = direction,
		speed = speed,
		label = "flying " .. kind .. " at " .. floor(speed * 100) .. " percent speed",
	};
end

--- A target flying straight across in front of its gun, 3000 ahead, at `speed` times its max speed. It starts far enough to one side
--- (9s of flight) to pass straight ahead around the middle of `ENGINE_TEST.fire`'s firing window: the run-up (turn, stop, move back,
--- accelerate, then 1s of straight flight) covers about 4s of it, so 5s (as it was) had it dead ahead as firing began, and the
--- "crossing" was really a target moving away to the side (2026-11-09: 3011 away at the first shot, ~3550 at the last). (Before
--- that, it started 63 degrees off-axis and never got in front of the gun.)
---@param speed number
---@return table
function ENGINE_TEST.across(speed)
	return {
		at = ENGINE_TEST.F * 3000 - ENGINE_TEST.R * (ENGINE_TEST.TARGET_MAX_SPEED * speed * 9),
		direction = ENGINE_TEST.R,
		speed = speed,
		label = "crossing at " .. floor(speed * 100) .. " percent speed", -- (no `%`: the game's `print` reads it as a format code)
	};
end

--- Works out the guns' forward axis `ENGINE_TEST.F` (and a sideways one, `ENGINE_TEST.R`), unless that's already been done in this
--- scope (ships always spawn facing the same way). Flies a calibration target straight along +x, finds which of
--- `SobGroup_GetCoordSys`'s axes matches its direction of travel, and reads that axis off the gun `ctx[gun_key]`. Needs `ctx.enemy`.
---
---@param ctx table
---@param gun_key string
---@return Event|nil
function ENGINE_TEST.calibrate(ctx, gun_key)
	if (ENGINE_TEST.F) then
		return nil;
	end
	return sequence(
		SHIP_TEST.spawn(ctx, "calibration", "test_target", { player = ctx.enemy.id, offset = { 0, 2000, -6000 } }),
		function ()
			return ENGINE_TEST.runUp(%ctx.calibration, %ctx.home.calibration, Vec3({ 1, 0, 0 }), 1);
		end,
		function ()
			local axes, flat = ENGINE_TEST.axes(%ctx.calibration.own_group);
			local best, best_dot = nil, 0;
			for i = 1, 6 do
				local dot = Vec3:dot(axes[i], { 1, 0, 0 });
				if (abs(dot) > abs(best_dot)) then
					best, best_dot = i, dot;
				end
			end
			print("[test engine] a ship flying along +x has coordsys " .. ENGINE_TEST.describeMatrix(flat) .. "; forward is axis "
				.. tostring(best) .. " (1-3 rows, 4-6 columns), dot " .. format("%.3f", best_dot));
			if (abs(best_dot) < 0.95) then
				fail("couldn't tell which of SobGroup_GetCoordSys's axes is forward: " .. ENGINE_TEST.describeMatrix(flat));
			end
			%ctx.calibration:die(1);

			local gun = %ctx[%gun_key];
			local gun_axes, gun_flat = ENGINE_TEST.axes(gun.own_group);
			ENGINE_TEST.F = Vec3:unit(gun_axes[best] * (best_dot / abs(best_dot)));
			local side = Vec3:cross(ENGINE_TEST.F, { 0, 1, 0 });
			if (Vec3:magnitude(side) < 0.1) then -- (facing straight up or down)
				side = Vec3:cross(ENGINE_TEST.F, { 1, 0, 0 });
			end
			ENGINE_TEST.R = Vec3:unit(side);
			print("[test engine] the guns' coordsys " .. ENGINE_TEST.describeMatrix(gun_flat) .. "; forward " .. Vec3:toStr(ENGINE_TEST.F)
				.. ", side " .. Vec3:toStr(ENGINE_TEST.R));
		end
	);
end

-- ===[ Bursts ]===

--- How far ahead of its gun a burst test's target is (inside every test gun's range).
ENGINE_TEST.BURST_RANGE = 2500;
--- How long a gun takes to open fire after its attack order (seen: 0.8 to 6.0s), before the first burst is expected.
ENGINE_TEST.BURST_STARTUP = 7;

--- Has the gun `ctx[gun_key]` fire at a still `ctx.target` `ENGINE_TEST.BURST_RANGE` straight ahead of it (in its line of fire) for
--- `seconds`, timing every strike (every time the target loses HP; it's topped back up when low), then analyses them into bursts
--- (`ENGINE_TEST.analyseBursts`). `period` is the gun's fire time (from its `.wepn`), so the bursts expected in the window are known
--- however many go missing. Sets `ctx.bursts`.
---
---@param ctx table
---@param gun_key string
---@param seconds number
---@param period number
---@return Event
function ENGINE_TEST.watchBursts(ctx, gun_key, seconds, period)
	local gun = ctx[gun_key];
	local target = ctx.target;
	local where = ctx.home[gun_key] + ENGINE_TEST.F * ENGINE_TEST.BURST_RANGE;
	local state = { gun_key = gun_key, seconds = seconds, period = period, strikes = {}, where = where };
	ctx.bursts = state;
	SHIP_TEST.checkInBounds(where, "the target");
	target:position(where);
	return sequence(
		ENGINE_TEST.holdStill(target),
		function ()
			%target:HP(1);
			%state.last_hp = %target:HP();
			%state.start = Universe_GameTime();
			%gun:ROE(OffensiveROE);
			%gun:attack(%target);
		end,
		waitFor(function ()
			local now = Universe_GameTime() - %state.start;
			local hp = %target:HP();
			if (hp < %state.last_hp) then
				modkit.table.push(%state.strikes, now);
			end
			if (%target:underAttack()) then -- (the flag only lasts 10s after a shot, so it's watched throughout)
				%state.fired = 1;
			end
			if (hp < 0.5) then -- (topped up, so it never dies)
				%target:HP(1);
				hp = %target:HP();
			end
			%state.last_hp = hp;
			return now >= %seconds;
		end, { timeout = seconds + 30, message = "the burst watch never finished" }),
		function ()
			%state.drift = Vec3:magnitude(%target:position() - %state.where);
			%gun:ROE(PassiveROE);
			%gun:stop();
			ENGINE_TEST.analyseBursts(%state);
			print("[test engine] " .. ENGINE_TEST.describeBursts(%state));
		end
	);
end

--- Groups `state.strikes` (strike times) into bursts (strikes within 0.5s of each other), and finds the gun's firing rhythm and how
--- many bursts went missing: each gap over 1.5x the rhythm counts as `round(gap / rhythm) - 1` missed bursts. The rhythm is the
--- lower-quartile gap between bursts, not the median, since missing bursts make gaps longer (a gun missing every other burst would
--- otherwise look like one firing half as often). Sets `state.bursts` (start times), `state.median` (the rhythm), `state.missed`
--- and `state.long_gaps`.
---
---@param state table
function ENGINE_TEST.analyseBursts(state)
	local bursts = {};
	local previous = nil;
	for i = 1, modkit.table.length(state.strikes) do
		local t = state.strikes[i];
		if (previous == nil or t - previous > 0.5) then
			modkit.table.push(bursts, t);
		end
		previous = t;
	end
	local gaps = {};
	for i = 2, modkit.table.length(bursts) do
		modkit.table.push(gaps, bursts[i] - bursts[i - 1]);
	end
	-- (sorted by hand: no table library functions)
	local sorted = {};
	for i = 1, modkit.table.length(gaps) do
		local value = gaps[i];
		local j = modkit.table.length(sorted);
		while (j > 0 and sorted[j] > value) do
			sorted[j + 1] = sorted[j];
			j = j - 1;
		end
		sorted[j + 1] = value;
	end
	local count = modkit.table.length(sorted);
	local median = nil;
	if (count > 0) then
		median = sorted[floor((count + 3) / 4)]; -- (the lower quartile, see above)
	end
	local missed = 0;
	local long_gaps = {};
	if (median and median > 0) then
		for i = 1, count do
			if (gaps[i] > 1.5 * median) then
				missed = missed + floor(gaps[i] / median + 0.5) - 1;
				modkit.table.push(long_gaps, format("%.1f", gaps[i]) .. "s after " .. format("%.1f", bursts[i]) .. "s");
			end
		end
	end
	state.bursts = bursts;
	state.median = median;
	state.missed = missed;
	state.long_gaps = long_gaps;
	if (state.period) then -- (expected from the gun's fire time: works however many bursts are missing)
		state.expected = floor((state.seconds - ENGINE_TEST.BURST_STARTUP) / state.period) + 1;
		state.missed = max(0, state.expected - modkit.table.length(bursts));
	end
end

--- Describes a burst watch, for logs and failure messages.
---
---@param state table
---@return string
function ENGINE_TEST.describeBursts(state)
	local starts = "";
	for i = 1, modkit.table.length(state.bursts or {}) do
		starts = starts .. format("%.1f", state.bursts[i]) .. " ";
	end
	local gaps = "";
	for i = 1, modkit.table.length(state.long_gaps or {}) do
		gaps = gaps .. "; " .. state.long_gaps[i];
	end
	local expected = "";
	if (state.expected) then
		expected = " of " .. state.expected .. " expected (one every " .. state.period .. "s)";
	end
	return "bursts: " .. state.gun_key .. " over " .. state.seconds .. "s: " .. modkit.table.length(state.bursts or {}) .. expected
		.. " struck (at " .. starts .. "s), usual gap " .. format("%.1f", state.median or 0) .. "s, " .. tostring(state.missed)
		.. " missed" .. gaps .. "; fired " .. tostring(state.fired) .. ", target drifted " .. format("%.0f", state.drift or 0)
		.. ", ended " .. format("%.0f", state.end_distance or 0) .. " from the gun";
end

--- Spawns a fresh `test_target_tough` for each of `specs` (kept as `ctx["watch_target_" .. i]`, and in `ctx.extra_targets` for
--- `afterEach` to remove) and places it: `{ label =, gun = gun key, at = target offset from the gun, direction? =, speed? = }`. A
--- target with a `direction` flies along it at `speed` times its max speed; resolves once every target is still or up to speed.
--- Sets `ctx.watches` (one burst state per spec).
---
---@param ctx table
---@param specs table[]
---@param seconds number
---@param period number
---@return Event
function ENGINE_TEST.placeTargets(ctx, specs, seconds, period)
	local count = modkit.table.length(specs);
	ctx.extra_targets = ctx.extra_targets or {};
	ctx.watches = {};
	for i = 1, count do
		local spec = specs[i];
		local start = ctx.home[spec.gun] + spec.at;
		SHIP_TEST.checkInBounds(start, "the target for " .. spec.label);
		if (spec.direction) then
			SHIP_TEST.checkInBounds(start + spec.direction * 5000, "the destination for " .. spec.label); -- (it covers ~3500 in a watch)
		end
		ctx.watches[i] = { gun_key = spec.label, seconds = seconds, period = period, strikes = {}, where = start };
		ctx["watch_target_" .. i] = nil; -- (an earlier test's target, now dead, would otherwise count as already spawned)
		-- (parked far from every gun, where nothing will pick it as a target)
		SHIP_TEST.spawn(ctx, "watch_target_" .. i, "test_target_tough", { player = ctx.enemy.id, offset = { 0, 4000, -30000 - i * 700 } })
			:catch(function (message) %ctx.spawn_error = message; end);
	end
	return sequence(
		waitFor(function ()
			if (%ctx.spawn_error) then
				fail("spawning failed: " .. %ctx.spawn_error);
			end
			for i = 1, %count do
				if (%ctx["watch_target_" .. i] == nil) then
					return nil;
				end
			end
			return 1;
		end, { timeout = 30, message = "the targets never registered" }),
		function ()
			for i = 1, %count do
				local spec = %specs[i];
				local target = %ctx["watch_target_" .. i];
				local start = %ctx.watches[i].where;
				modkit.table.push(%ctx.extra_targets, target);
				target:position(start);
				if (spec.direction) then
					target:speed(spec.speed or 1);
					target:move(start + spec.direction * 5000, { no_event = 1 });
				else
					target:speed(0);
					target:stop();
				end
			end
		end,
		waitFor(function ()
			for i = 1, %count do
				local spec = %specs[i];
				local speed = sqrt(%ctx["watch_target_" .. i]:actualSpeedSq());
				if (spec.direction and speed < 0.95 * ENGINE_TEST.TARGET_MAX_SPEED * (spec.speed or 1)) then
					return nil;
				elseif (spec.direction == nil and speed >= 5) then
					return nil;
				end
			end
			return 1;
		end, { timeout = 40, message = function ()
			local speeds = "";
			for i = 1, %count do
				speeds = speeds .. %specs[i].label .. ": " .. format("%.0f", sqrt(%ctx["watch_target_" .. i]:actualSpeedSq())) .. "/s; ";
			end
			return "the targets never got still / up to speed (" .. speeds .. ")";
		end }),
		wait(1)
	);
end

--- Records a strike on watch `i`'s target if it lost HP since the last poll (topping it up when low), and whether it's under attack.
---
---@param ctx table
---@param i integer
---@param now number Seconds since the watch began.
function ENGINE_TEST.pollWatch(ctx, i, now)
	local target = ctx["watch_target_" .. i];
	local state = ctx.watches[i];
	local hp = target:HP();
	if (hp < state.last_hp) then
		modkit.table.push(state.strikes, now);
	end
	if (hp < 0.5) then
		target:HP(1);
		hp = target:HP();
	end
	state.last_hp = hp;
	if (target:underAttack()) then
		state.fired = 1;
	end
end

--- Like `ENGINE_TEST.watchBursts`, for several guns at once, each with its own target (see `ENGINE_TEST.placeTargets` for `specs`).
--- Sets `ctx.watches` (one burst state per spec).
---
---@param ctx table
---@param specs table[]
---@param seconds number
---@param period number The guns' fire time.
---@return Event
function ENGINE_TEST.watchMany(ctx, specs, seconds, period)
	local count = modkit.table.length(specs);
	return sequence(
		ENGINE_TEST.placeTargets(ctx, specs, seconds, period),
		function ()
			for i = 1, %count do
				local target = %ctx["watch_target_" .. i];
				local gun = %ctx[%specs[i].gun];
				target:HP(1);
				%ctx.watches[i].last_hp = target:HP();
				gun:ROE(OffensiveROE);
				gun:attack(target);
			end
			%ctx.watch_start = Universe_GameTime();
		end,
		waitFor(function ()
			local now = Universe_GameTime() - %ctx.watch_start;
			for i = 1, %count do
				ENGINE_TEST.pollWatch(%ctx, i, now);
			end
			return now >= %seconds;
		end, { timeout = seconds + 30, message = "the burst watch never finished" }),
		function ()
			for i = 1, %count do
				local gun = %ctx[%specs[i].gun];
				local state = %ctx.watches[i];
				gun:ROE(PassiveROE);
				gun:stop();
				state.drift = Vec3:magnitude(%ctx["watch_target_" .. i]:position() - state.where);
				state.end_distance = %ctx["watch_target_" .. i]:distanceTo(gun); -- (a target out of range can't be struck)
				ENGINE_TEST.analyseBursts(state);
				print("[test engine] " .. ENGINE_TEST.describeBursts(state));
			end
		end
	);
end

--- Like `ENGINE_TEST.watchMany`, but in `cycles` short engagements: each gun is ordered to attack its target, fires for `on`
--- seconds, is stopped for `off` seconds, and so on. Logs, per gun, each cycle's strikes and the delay to its first strike (if wild
--- shots come at the start of an engagement, some cycles start late or strike less). Sets `ctx.watches`, each with `cycle_strikes`
--- and `cycle_first` (per cycle).
---
---@param ctx table
---@param specs table[]
---@param cycles integer
---@param on number
---@param off number
---@return Event
function ENGINE_TEST.watchCycles(ctx, specs, cycles, on, off)
	local count = modkit.table.length(specs);
	local length = on + off;
	return sequence(
		ENGINE_TEST.placeTargets(ctx, specs, cycles * length, nil),
		function ()
			for i = 1, %count do
				local target = %ctx["watch_target_" .. i];
				target:HP(1);
				%ctx.watches[i].last_hp = target:HP();
				%ctx.watches[i].cycle_strikes = {};
				%ctx.watches[i].cycle_first = {};
				%ctx.watches[i].cycle_times = {};
			end
			%ctx.watch_start = Universe_GameTime();
			%ctx.cycle = 0;
			%ctx.firing = nil;
		end,
		waitFor(function ()
			local now = Universe_GameTime() - %ctx.watch_start;
			local cycle = floor(now / %length) + 1;
			local firing = (now - (cycle - 1) * %length) < %on;
			if (cycle <= %cycles and (cycle ~= %ctx.cycle or firing ~= %ctx.firing)) then -- (each change: attack, or stop)
				for i = 1, %count do
					local gun = %ctx[%specs[i].gun];
					if (firing) then
						gun:ROE(OffensiveROE);
						gun:attack(%ctx["watch_target_" .. i]);
					else
						gun:ROE(PassiveROE);
						gun:stop();
					end
				end
				%ctx.cycle = cycle;
				%ctx.firing = firing;
			end
			for i = 1, %count do
				local before = modkit.table.length(%ctx.watches[i].strikes);
				ENGINE_TEST.pollWatch(%ctx, i, now);
				if (modkit.table.length(%ctx.watches[i].strikes) > before and cycle <= %cycles) then
					local state = %ctx.watches[i];
					state.cycle_strikes[cycle] = (state.cycle_strikes[cycle] or 0) + 1;
					state.cycle_times[cycle] = (state.cycle_times[cycle] or "") .. format("%.1f", now - (cycle - 1) * %length) .. " ";
					if (state.cycle_first[cycle] == nil) then
						state.cycle_first[cycle] = now - (cycle - 1) * %length;
					end
				end
			end
			return now >= %cycles * %length;
		end, { timeout = cycles * length + 30, message = "the cycles never finished" }),
		function ()
			for i = 1, %count do
				local gun = %ctx[%specs[i].gun];
				local state = %ctx.watches[i];
				gun:ROE(PassiveROE);
				gun:stop();
				local per_cycle = "";
				for c = 1, %cycles do
					local first = "-";
					if (state.cycle_first[c]) then
						first = format("%.1f", state.cycle_first[c]) .. "s";
					end
					per_cycle = per_cycle .. tostring(state.cycle_strikes[c] or 0) .. " (first " .. first .. ") ";
				end
				print("[test engine] cycles: " .. state.gun_key .. ", " .. %cycles .. " x (" .. %on .. "s firing, " .. %off
					.. "s stopped): strikes per cycle: " .. per_cycle .. "; fired " .. tostring(state.fired));
				for c = 1, %cycles do -- (each strike's time within its cycle; ~4.2s of each is flight time)
					print("[test engine]   " .. state.gun_key .. " cycle " .. c .. " strikes at: " .. (state.cycle_times[c] or "none"));
				end
			end
		end
	);
end

--- A target offset `ENGINE_TEST.BURST_RANGE` from its gun, `degrees` off the gun's forward axis (towards `ENGINE_TEST.R`).
---
---@param degrees number
---@return Vec3
function ENGINE_TEST.atAngle(degrees)
	return (ENGINE_TEST.F * cos(degrees) + ENGINE_TEST.R * sin(degrees)) * ENGINE_TEST.BURST_RANGE;
end

