-- Dumps every global in each Lua scope modkit can reach, to the game log, for checking the wiki's `Dictionary;-Scope` page and the
-- exe mapping (`.dev/exe/lua-scopes.tsv`) against what the game really has. Run with `test scopes` in the console, in a game launched
-- with `-luatrace`; then compare with `python3 .dev/exe/tools/compare_globals.py <HwRM.log> .dev/exe/lua-scopes.tsv`.
--
-- - Rules (gamerule) scope: dumped by the test itself (the tests run in this scope).
-- - UI scope: queued as UI code when this file loads (while the console is open), so it runs as the console closes to start the tests.
-- - Ship custom code scope: a `test_globals_dump` ship dumps it on its first update (`scripts/custom_code/test_globals_dump.lua`).
-- The dump is `tests/lib/globals_dump.lua`: one `[globals] <scope>\t<name>\t<kind>` line per global.

dofilepath("data:scripts/modkit/tests/lib/globals_dump.lua");
dofilepath("data:scripts/modkit/tests/lib/ships.lua"); -- (`SHIP_TEST`: spawning and cleanup helpers)

-- (reset the counts the UI and ship dumps report back, then queue the UI dump)
hyperTableHandle()({ globals_dump_UI = 0, globals_dump_CustomCode = 0 });
hyperTableQueueUiCode('dofilepath("data:scripts/modkit/tests/lib/globals_dump.lua"); MK_GLOBALS_DUMP("UI");');

SCOPES_TEST = {
	--- Returns a `waitFor` for the hypertable's `globals_dump_<scope>` count to be set by that scope's dump.
	waitForDump = function (scope, message)
		return waitFor(function ()
			return (hyperTableHandle()()["globals_dump_" .. %scope] or 0) > 0;
		end, { timeout = 30, message = message });
	end,
};

describe("globals dump (one per scope)", function ()
	after(function (ctx)
		SHIP_TEST.cleanup(ctx);
	end);

	it("Rules: dumps its globals", function ()
		local count = MK_GLOBALS_DUMP("Rules");
		print("[test scopes] Rules: " .. count .. " globals");
		expect(count > 0, "the rules scope has no globals?");
	end);

	it("UI: its dump ran (queued when the test file loaded, run as the console closed)", function ()
		return sequence(
			SCOPES_TEST.waitForDump("UI", "the UI dump never ran: it runs when the console closes, so run `test scopes` from an open "
				.. "console and close it to start the tests"),
			function ()
				print("[test scopes] UI: " .. hyperTableHandle()().globals_dump_UI .. " globals");
			end
		);
	end, { timeout = 40 });

	it("CustomCode: a test_globals_dump ship dumps the ship custom code scope", function (ctx)
		return sequence(
			SHIP_TEST.spawn(ctx, "dumper", "test_globals_dump"),
			SCOPES_TEST.waitForDump("CustomCode", "the test_globals_dump ship never dumped its scope (is `test` in "
				.. "modkit.custom_code_dirs?)"),
			function ()
				print("[test scopes] CustomCode: " .. hyperTableHandle()().globals_dump_CustomCode .. " globals");
			end
		);
	end, { timeout = 60 });
end);
