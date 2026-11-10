-- Offline unit tests for `Volume_Fresh` (`scripts/modkit/sobgroup.lua`). Run with `npm test` in `modkit-tools`.
--
-- The engine's volumes are stubbed the way the game handles them (see the "VOLUME STUFF" notes in `scripts/modkit/hwrm.lua`): adding
-- never checks for an existing name, deleting only flags the volume and queues it (removed by `endFrame()`), and lookups by name return
-- the first match, flagged or not.

dofile("modkit-tools/tests/lua/harness.lua");

VOLUMES = {};
function Volume_AddSphere(name, position, radius)
	VOLUMES[listLength(VOLUMES) + 1] = { name = name, position = { position[1], position[2], position[3] }, radius = radius };
end
function Volume_AddCube(name, position, size)
	Volume_AddSphere(name, position, size);
end
function findVolume(name)
	for i = 1, listLength(VOLUMES) do
		if (VOLUMES[i].name == name) then
			return VOLUMES[i];
		end
	end
	return nil;
end
function Volume_Delete(name)
	local volume = findVolume(name);
	if (volume) then
		volume.deleted = 1;
	end
end
function Volume_GetPosition(name)
	local volume = findVolume(name);
	if (volume == nil) then
		return { 0, 0, 0 };
	end
	return volume.position;
end
--- Removes the deleted volumes, as the engine does after the frame.
function endFrame()
	local kept = {};
	for i = 1, listLength(VOLUMES) do
		if (not VOLUMES[i].deleted) then
			kept[listLength(kept) + 1] = VOLUMES[i];
		end
	end
	VOLUMES = kept;
end

function SobGroup_CreateIfNotExist() end -- (sobgroup.lua makes a default group as it loads)
function SobGroup_Clear() end

loadQuietly("scripts/modkit/table_util.lua");
loadQuietly("scripts/modkit/vec3.lua");
loadQuietly("scripts/modkit/sobgroup.lua");

function fresh()
	VOLUMES = {};
	MK_VOLUME_VERSIONS = {};
end

describe("the engine stub", function ()
	it("keeps lookups on the old volume when a deleted name is re-added in the same frame (the bug Volume_Fresh avoids)", function ()
		fresh();
		Volume_AddSphere("v", { 1, 0, 0 }, 10);
		Volume_Delete("v");
		Volume_AddSphere("v", { 2, 0, 0 }, 10);
		expectEq(Volume_GetPosition("v"), { 1, 0, 0 });
		endFrame();
		expectEq(Volume_GetPosition("v"), { 2, 0, 0 });
	end);
end);

describe("Volume_Fresh", function ()
	it("uses the name as given the first time", function ()
		fresh();
		expectEq(Volume_Fresh("v", { 1, 2, 3 }), "v");
		expectEq(Volume_GetPosition("v"), { 1, 2, 3 });
	end);
	it("gives each re-creation a new name, at the new position straight away", function ()
		fresh();
		local first = Volume_Fresh("v", { 1, 0, 0 });
		local second = Volume_Fresh("v", { 2, 0, 0 });
		local third = Volume_Fresh("v", { 3, 0, 0 });
		expectEq({ first, second, third }, { "v", "v#2", "v#3" });
		expectEq(Volume_GetPosition(second), { 2, 0, 0 });
		expectEq(Volume_GetPosition(third), { 3, 0, 0 });
	end);
	it("deletes the previous version, so volumes don't pile up", function ()
		fresh();
		Volume_Fresh("v", { 1, 0, 0 });
		Volume_Fresh("v", { 2, 0, 0 });
		Volume_Fresh("v", { 3, 0, 0 });
		endFrame();
		expectEq(listLength(VOLUMES), 1);
		expectEq(VOLUMES[1].name, "v#3");
	end);
	it("treats a name it returned (with a #n suffix) as its base name", function ()
		fresh();
		local second = Volume_Fresh(Volume_Fresh("v", { 1, 0, 0 }), { 2, 0, 0 });
		local third = Volume_Fresh(second, { 3, 0, 0 });
		expectEq({ second, third }, { "v#2", "v#3" });
		endFrame();
		expectEq(listLength(VOLUMES), 1);
	end);
	it("counts each base name separately", function ()
		fresh();
		Volume_Fresh("a");
		expectEq(Volume_Fresh("b"), "b");
		expectEq(Volume_Fresh("a"), "a#2");
	end);
	it("gives unnamed volumes unique names", function ()
		fresh();
		local a = Volume_Fresh(nil, { 1, 0, 0 });
		local b = Volume_Fresh(nil, { 2, 0, 0 });
		expect(a ~= b, "unnamed volumes should get different names");
		expectEq(Volume_GetPosition(b), { 2, 0, 0 });
	end);
	it("defaults to { 0, 0, 0 } and radius 10", function ()
		fresh();
		Volume_Fresh("v");
		expectEq(VOLUMES[1].position, { 0, 0, 0 });
		expectEq(VOLUMES[1].radius, 10);
	end);
end);

finish();
