-- Offline unit tests for `scripts/modkit/hypertable.lua` (the hypertable, shared between Lua scopes through a hidden dropdown).
-- Run with `npm test` in `modkit-tools`.
--
-- The dropdown is stubbed as a list of custom data strings, with the engine's quirk that reading an empty one is an error (in game,
-- an access violation).

dofile("modkit-tools/tests/lua/harness.lua");

-- engine stubs
function Universe_GameTime() return 0; end
DROPDOWN = { items = {}, selected = nil };
function UI_AddDropDownListboxItem(_, _, _, _, _, data)
	DROPDOWN.items[modkit.table.length(DROPDOWN.items) + 1] = data;
end
function UI_ClearDropDownListbox() DROPDOWN.items = {}; end
function UI_SelectDropDownListboxItemIndex(_, _, index) DROPDOWN.selected = index + 1; end
function UI_GetDropdownListBoxSelectedCustomDataString()
	local item = DROPDOWN.items[DROPDOWN.selected or 0];
	if (item == nil) then
		error("read an empty dropdown (an access violation in game)");
	end
	return item;
end

loadQuietly("scripts/modkit/table_util.lua");
loadQuietly("scripts/modkit/hypertable.lua");

H = MK_HYPERTABLE;

function fresh()
	DROPDOWN = { items = {}, selected = nil };
end

--- Serialises then reads back `value`, the way a write then a read does.
function roundTrip(value)
	return H.read(H.write(value));
end

--- Runs `fn` with `print` quietened (for expected warnings), returning its result and what it printed.
function quietly(fn)
	local saved = print;
	PRINTED = {};
	print = function (line) PRINTED[modkit.table.length(PRINTED) + 1] = line; end;
	local result = fn();
	print = saved;
	return result;
end

describe("encode / decode", function ()
	it("round-trips every byte", function ()
		local all = "";
		for byte = 1, 255 do
			all = all .. strchar(byte);
		end
		expectEq(H.decode(H.encode(all)), all);
	end);
	it("escapes only %, backslash, double quote, control characters and non-ASCII bytes, as %XX", function ()
		expectEq(H.encode("a{[1]=x}, 'ok' %\\\"\n\200"), "a{[1]=x}, 'ok' %25%5C%22%0A%C8");
	end);
	it("refuses unescaped unsafe characters, or a % not starting an escape", function ()
		expectEq(H.decode("{[1]=2}"), "{[1]=2}");
		expectNil(H.decode("\"quoted\""));
		expectNil(H.decode("line\nbreak"));
		expectNil(H.decode("100%"));
		expectNil(H.decode("%4G"));
		expectNil(H.decode(nil));
	end);
end);

describe("serialise / read", function ()
	it("round-trips strings with quotes, backslashes and newlines", function ()
		local tricky = "say \"hi\"\\n\nnext line\r\ttab 'single' ]] [[";
		expectEq(roundTrip({ s = tricky }), { s = tricky });
	end);
	it("round-trips numbers, including negative and decimal ones", function ()
		expectEq(roundTrip({ a = 1, b = -2.5, c = 0, d = 1000000 }), { a = 1, b = -2.5, c = 0, d = 1000000 });
	end);
	it("round-trips nested tables, and number and string keys", function ()
		local value = { GLOBAL_SHIPS = { [12] = "kus_scout-12,0,kus_scout,3.5" }, queue = { "a", "b" }, ["key with spaces"] = { x = { y = 1 } } };
		expectEq(roundTrip(value), value);
	end);
	it("drops functions, and keys that aren't strings or numbers", function ()
		local key = {};
		local value = { keep = 1, fn = function () end };
		value[key] = "dropped";
		expectEq(roundTrip(value), { keep = 1 });
	end);
	it("stops at max_depth, so a table containing itself doesn't loop forever", function ()
		local loop = { name = "loop" };
		loop.self = loop;
		local result = roundTrip(loop);
		expectEq(result.name, "loop");
		expectEq(result.self.self.name, "loop");
	end);
	it("reads stored data that isn't a valid table as {}, with a warning", function ()
		expectEq(quietly(function () return H.read("{\"unescaped\"}"); end), {}, "unescaped quotes");
		expectEq(modkit.table.length(PRINTED), 1);
		expectEq(quietly(function () return H.read(H.encode("return 1 +")); end), {}, "not Lua");
		expectEq(quietly(function () return H.read(H.encode("5")); end), {}, "not a table");
	end);
end);

describe("hyperTableHandle", function ()
	it("reads an empty dropdown as {}, without reading an empty list", function ()
		fresh();
		expectEq(hyperTableHandle()(), {});
	end);
	it("stores what it's given, encoded, and leaves exactly one item", function ()
		fresh();
		local handle = hyperTableHandle();
		handle({ a = "b\"c\nd" });
		expectEq(modkit.table.length(DROPDOWN.items), 1);
		expectNil(strfind(DROPDOWN.items[1], "[\"\\%c]"), "the stored string should have no quotes, backslashes or control characters");
		expectEq(handle(), { a = "b\"c\nd" });
		expectEq(modkit.table.length(DROPDOWN.items), 1);
	end);
	it("merges new state in deeply, and `override` replaces a key", function ()
		fresh();
		local handle = hyperTableHandle();
		handle({ a = 1, list = { "x" } });
		handle({ b = 2, list = { [2] = "y" } });
		expectEq(handle(), { a = 1, b = 2, list = { "x", "y" } });
		handle({}, { override = { list = {} } });
		expectEq(handle(), { a = 1, b = 2, list = {} });
	end);
	it("replaces everything with `overwrite`", function ()
		fresh();
		local handle = hyperTableHandle();
		handle({ a = 1 });
		handle({ b = 2 }, nil, 1);
		expectEq(handle(), { b = 2 });
	end);
	it("returns a copy, so changing it doesn't change the hypertable", function ()
		fresh();
		local handle = hyperTableHandle();
		handle({ a = 1 });
		local copy = handle();
		copy.a = 2;
		expectEq(handle(), { a = 1 });
	end);
	it("is nil where the UI can't be reached (no Universe_GameTime)", function ()
		local saved = Universe_GameTime;
		Universe_GameTime = nil;
		local handle = hyperTableHandle();
		Universe_GameTime = saved;
		expectNil(handle);
	end);
end);

describe("UI-scope code queue", function ()
	it("runs queued code once, in order, including code with quotes", function ()
		fresh();
		RAN = {};
		hyperTableQueueUiCode("RAN[modkit.table.length(RAN) + 1] = \"first\"");
		hyperTableQueueUiCode("RAN[modkit.table.length(RAN) + 1] = 'second'");
		hyperTableRunUiCode();
		hyperTableRunUiCode();
		expectEq(RAN, { "first", "second" });
	end);
end);

finish();
