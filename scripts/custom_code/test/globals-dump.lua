-- The `test_globals_dump` test ship: dumps the ship custom code scope's globals on its first update, for `test scopes`
-- (`scripts/modkit/tests/scopes.lua`; the dump is `scripts/modkit/tests/lib/globals_dump.lua`).

if (MK_GLOBALS_DUMP == nil) then
	dofilepath("data:scripts/modkit/tests/lib/globals_dump.lua");
end

---@class TestGlobalsDump: Ship
test_globals_dump_proto = {};

function test_globals_dump_proto:update()
	if (self:tick() == 1) then
		MK_GLOBALS_DUMP("CustomCode");
	end
end

modkit.compose:addShipProto("test_globals_dump", test_globals_dump_proto);
