-- Ingame tests of engine behaviour (volumes).
-- Part of `test engine` (see `tests/engine.lua`), or run alone with `test engine/volumes`.

-- (a global table: Lua 4 upvalues only reach one function out, so file-level locals can't be used inside `it` callbacks; shared by
-- the files in `tests/engine/`, which also run alone)
ENGINE_TEST = ENGINE_TEST or {};

--- Bumped per run, so volume names from earlier runs (which may not be deleted) aren't reused.
ENGINE_TEST.run = ENGINE_TEST.run or 0;

--- Returns a volume name unique to this run.
---
---@param label string
---@return string
function ENGINE_TEST.volumeName(label)
	return "mk_engine_test_" .. label .. "_" .. ENGINE_TEST.run;
end

describe("volumes", function ()
	before(function (ctx)
		ENGINE_TEST.run = ENGINE_TEST.run + 1;
		ctx.volumes = {};
	end);

	after(function (ctx)
		for _, name in ctx.volumes do
			Volume_Delete(name);
		end
	end);

	it("Volume_GetPosition gives { 0, 0, 0 } for an unknown name", function ()
		expectNear(Volume_GetPosition(ENGINE_TEST.volumeName("never_added")), { 0, 0, 0 }, 0.001);
	end);

	it("Volume_GetPosition gives a new volume's position, as a plain table", function (ctx)
		local name = ENGINE_TEST.volumeName("plain");
		modkit.table.push(ctx.volumes, name);
		Volume_AddSphere(name, { 1000, 200, -300 }, 10);
		local position = Volume_GetPosition(name);
		expectNear(position, { 1000, 200, -300 }, 1);
		expect(tag(position) ~= VEC3_INSTANCE_TAG, "it shouldn't be a Vec3");
	end);

	it("re-adding a just-deleted name leaves lookups on the old volume, until the deletion is processed", function (ctx)
		local name = ENGINE_TEST.volumeName("readded");
		modkit.table.push(ctx.volumes, name);
		Volume_AddSphere(name, { 1000, 0, 0 }, 10);
		Volume_Delete(name);
		Volume_AddSphere(name, { 2000, 0, 0 }, 10);
		expectNear(Volume_GetPosition(name), { 1000, 0, 0 }, 1, "straight after re-adding");
		return sequence(
			wait(1),
			function ()
				expectNear(Volume_GetPosition(%name), { 2000, 0, 0 }, 1, "a second later");
			end
		);
	end);

	it("a second Volume_Delete in the same frame doesn't delete the re-added volume", function (ctx)
		local name = ENGINE_TEST.volumeName("deleted_twice");
		modkit.table.push(ctx.volumes, name);
		Volume_AddSphere(name, { 1000, 0, 0 }, 10);
		Volume_Delete(name);
		Volume_AddSphere(name, { 2000, 0, 0 }, 10);
		Volume_Delete(name); -- (finds the old, already flagged, volume again)
		return sequence(
			wait(1),
			function ()
				expectNear(Volume_GetPosition(%name), { 2000, 0, 0 }, 1, "the re-added volume should still exist");
			end
		);
	end);

	it("Volume_Fresh with a reused name gives a volume at the new position straight away", function (ctx)
		local base = ENGINE_TEST.volumeName("fresh");
		local first = Volume_Fresh(base, { 1000, 0, 0 });
		local second = Volume_Fresh(base, { 3000, 0, 0 });
		local third = Volume_Fresh(second, { 5000, 0, 0 }); -- (passing back a name it returned)
		modkit.table.push(ctx.volumes, third);
		expect(first ~= second and second ~= third, "each re-creation should get a new name: " .. first .. ", " .. second .. ", " .. third);
		expectNear(Volume_GetPosition(second), { 3000, 0, 0 }, 1, "second");
		expectNear(Volume_GetPosition(third), { 5000, 0, 0 }, 1, "third");
	end);
end);
