-- Ingame tests for the objectives API (`scripts/modkit/objectives.lua`, `modkit.objectives`). Run with `test objectives` in the console.
--
-- Adds objectives with sequential (engine-picked) IDs, like the skirmish rules do (mixing those with preset IDs is a FATAL EXIT), and
-- hides them all afterwards. The "on screen" suite plays out over 15s, so you can watch the objectives list.

if (modkit == nil) then modkit = {}; end
if (modkit.objectives == nil) then dofilepath("data:scripts/modkit/objectives.lua"); end

describe("objectives", function ()
	-- a fresh objective for each test, as `ctx.objective` (made from `ctx.def`)
	beforeEach(function (ctx)
		ctx.seeded = ctx.seeded or {};
		ctx.def = {
			name = "test " .. modkit.table.length(GLOBAL_OBJECTIVES._entities),
			description = "test descr.",
			state = OBJECTIVE_STATE.OS_Incomplete,
			type = OBJECTIVE_TYPE.OT_Primary,
		};
		-- no `id`, so the engine picks it
		ctx.objective = modkit.objectives:set(ctx.def);
		expectTruthy(ctx.objective, "modkit.objectives:set returned nil");
		modkit.table.push(ctx.seeded, ctx.objective);
	end);

	-- hide them, so they don't stay in the objectives list
	after(function (ctx)
		for i = 1, modkit.table.length(ctx.seeded or {}) do
			ctx.seeded[i]:off();
		end
		ctx.seeded = {};
	end);

	it("id is the engine's ID, which finds the objective again", function (ctx)
		local id = ctx.objective:id();
		expectEq(type(id), "number");
		expectEq(modkit.objectives:get(id):name(), ctx.def.name);
	end);

	it("name reads and sets the name", function (ctx)
		expectEq(ctx.objective:name(), ctx.def.name);
		expectEq(ctx.objective:name("updated name"), "updated name");
		expectEq(ctx.objective:name(), "updated name");
	end);

	it("description reads, sets, and appends to the description", function (ctx)
		expectEq(ctx.objective:description(), "test descr.");
		expectEq(ctx.objective:description("updated desc."), "updated desc.");
		expectEq(ctx.objective:description(" more", 1), "updated desc. more");
	end);

	it("visible is 1 for a new objective, and nil once hidden", function (ctx)
		expectTruthy(ctx.objective:visible());
		expectNil(ctx.objective:visible(0));
		expectNil(ctx.objective:visible());
	end);

	it("visible(1) can't show a hidden objective again (hiding is permanent)", function (ctx)
		ctx.objective:visible(0);
		local shown = expectConsoleError(function ()
			return %ctx.objective:visible(1);
		end, "can't be shown again");
		expectNil(shown);
	end);

	it("completed reads and sets whether it's complete", function (ctx)
		expectNil(ctx.objective:completed());
		expectTruthy(ctx.objective:completed(1));
		expectEq(Objective_GetState(ctx.objective:id()), OBJECTIVE_STATE.OS_Complete);
		expectNil(ctx.objective:completed(0));
		expectEq(Objective_GetState(ctx.objective:id()), OBJECTIVE_STATE.OS_Incomplete);
	end);

	it("failed fails it", function (ctx)
		expectTruthy(ctx.objective:failed());
		expectEq(Objective_GetState(ctx.objective:id()), OBJECTIVE_STATE.OS_Failed);
	end);

	it("type reads and sets the type", function (ctx)
		expectEq(ctx.objective:type(), OBJECTIVE_TYPE.OT_Primary);
		expectEq(ctx.objective:type(OBJECTIVE_TYPE.OT_Secondary), OBJECTIVE_TYPE.OT_Secondary);
	end);

	it("off hides it", function (ctx)
		expectTruthy(ctx.objective:off());
		expectNil(ctx.objective:visible());
	end);

	it("refuses a preset ID once sequential IDs are in use, rather than a FATAL EXIT", function ()
		local objective = expectConsoleError(function ()
			return modkit.objectives:set({ id = 9999, name = "preset" });
		end, "IDs are already in use");
		expectNil(objective);
	end);

	it("reads nil through an objective whose def was deleted", function (ctx)
		local id = ctx.objective:id();
		local def = GLOBAL_OBJECTIVES._entities[id];
		GLOBAL_OBJECTIVES:delete(id);
		local name_fn = expectConsoleError(function ()
			local value = %ctx.objective.name; -- (the tag method warns and gives nil, since the def is gone)
			GLOBAL_OBJECTIVES._entities[%id] = %def; -- (put back straight away, so `after` can hide it even if this test fails)
			return value;
		end, "underlying data was deleted");
		expectNil(name_fn);
	end);
end);

describe("objectives (on screen)", function ()
	after(function (ctx)
		for i = 1, modkit.table.length(ctx.objectives or {}) do
			ctx.objectives[i]:off();
		end
	end);

	it("shows objectives, hides every other one, completes one, fails one, then hides them all", function (ctx)
		local wait_time = 5;
		return sequence(
			function ()
				%ctx.objectives = {};
				for i = 1, 12 do
					%ctx.objectives[i] = modkit.objectives:set({
						type = modkit.table.randomEntry({ OT_Primary, OT_Secondary })[2],
						name = "Feature Test Objective " .. i,
						description = "Desc. for FT Objective " .. i,
					});
				end
			end,
			wait(wait_time),
			function ()
				local objectives = %ctx.objectives;
				for i = 1, modkit.table.length(objectives) do
					if (mod(i, 2) == 1) then
						objectives[i]:visible(0);
					end
				end

				local shown = {}; -- (a list, in order; `modkit.table.filter` keeps the original keys)
				for i = 1, modkit.table.length(objectives) do
					if (objectives[i]:visible()) then
						modkit.table.push(shown, objectives[i]);
					end
				end
				expectEq(modkit.table.length(shown), 6, "shown after hiding every other one");
				return shown;
			end,
			wait(wait_time),
			function (shown)
				local completed = shown[1];
				local failed = shown[2];
				completed:completed(1);
				failed:failed();
				completed:select();
				expectTruthy(completed:completed(), "completed");
				expectEq(Objective_GetState(failed:id()), OBJECTIVE_STATE.OS_Failed, "failed one's state");
			end,
			wait(wait_time),
			function ()
				local objectives = %ctx.objectives;
				for i = 1, modkit.table.length(objectives) do
					objectives[i]:off();
				end
				for i = 1, modkit.table.length(objectives) do
					expectNil(objectives[i]:visible(), "objective " .. i .. " still shown");
				end
			end
		);
	end, { timeout = 30 });
end);
