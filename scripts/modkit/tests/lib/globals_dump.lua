-- `MK_GLOBALS_DUMP(scope)`: logs every global in the current Lua scope, one per line, for `test scopes` (`tests/scopes.lua`) and the
-- load-time dumps. Loaded in each scope:
-- - by `test scopes`: the rules scope (the test), the UI scope (queued UI code) and the ship custom code scope (the `test_globals_dump`
--   ship, `scripts/custom_code/test/globals-dump.lua`);
-- - at load, while `MK_SCOPE_DUMPS_AT_LOAD` is set (each file ends with the same 3-line hook, naming its scope):
--   - Level: `modkit_sandbox.level`; Object: `test_globals_dump.ship`; Madstate: `test_globals_dump.madstate`;
--   - AI: `ai/default.lua` and ATI: `ui/ati/ati.lua` (copies of the stock files with the hook added: delete or keep identical
--     to stock once done);
--   - Campaign: `modkit_sandbox.campaign` (plus CampaignPostload, from its mission's `postload`);
--   - GameSetup: `scripts/rules/deathmatch.lua` when the file is read outside the Rules scope (the front end);
--   - Races: `scripts/races/test.lua`; SpeechLogic: `soundscripts/speechlogic/zz_modkit_globals_dump.lua` (a loader wildcard);
--   - UIScreen: `ui/newui/mk_consolescreen.lua` (no `globals()` there: falls back to globals_probe.lua, known names only);
--   - Autoexec / AutoexecEnd: `.dev/autoexec/autoexec*.lua`, copied beside the exe (`Bin/Release`) by hand.
--
-- Each line is `[globals] <scope>\t<name>\t<kind>`, between `[globals] <scope> begin` and `[globals] <scope> end <count>` lines.
-- `<kind>` is the value's type, except for functions when the scope has `getinfo` (Lua's debug library): `cfunction` for a C
-- (engine) function, or `lua <source>` for a Lua one. The log is parsed by `.dev/exe/tools/compare_globals.py`. Logs with `print`
-- (needs the game launched with `-luatrace`), or `_ALERT` in scopes without `print`. Uses only base functions, since some scopes
-- may not have the string library.

--- While set, the Level, object file and AI scopes dump their globals as they load (see above). Turn off (`nil`) once the dumps have
--- been taken: they add a few thousand log lines to every game load (and remove the autoexec files from `Bin/Release`).
MK_SCOPE_DUMPS_AT_LOAD = nil;

if (MK_GLOBALS_DUMP == nil) then
	--- Logs the current scope's globals (see the file header), and records the count in the hypertable as `globals_dump_<scope>`
	--- (when the hypertable is loaded in this scope). Returns the count.
	---
	---@param scope string
	---@return integer
	MK_GLOBALS_DUMP = function (scope)
		if (globals == nil) then
			-- (a restricted state, e.g. a UI screen file: check known names instead; see globals_probe.lua)
			local log = print;
			local sink = "print";
			if (log == nil) then
				log = function (line) _ALERT(line .. "\n"); end;
				sink = "_ALERT";
			end
			dofilepath("data:scripts/modkit/tests/lib/globals_probe.lua");
			if (MK_GLOBALS_PROBE == nil) then
				log("[globals] " .. scope .. " no dump (no globals, and globals_probe.lua didn't load)");
				return 0;
			end
			log("[globals] " .. scope .. " begin (probe: no globals(), known names only, via " .. sink .. ")");
			local found, candidates = MK_GLOBALS_PROBE(scope, log);
			log("[globals] " .. scope .. " end " .. found .. " (of " .. candidates .. " candidates)");
			return found;
		end

		-- (collected first: logging and the hypertable write below mustn't run while `globals()` is being traversed)
		local names = {};
		local values = {};
		local count = 0;
		for name, value in globals() do
			count = count + 1;
			names[count] = name;
			values[count] = value;
		end

		local log = print;
		local sink = "print";
		if (log == nil) then
			log = function (line) _ALERT(line .. "\n"); end;
			sink = "_ALERT";
		end
		local escape = function (line) return line; end;
		if (gsub) then
			-- (print treats its text as a format string: double any `%`)
			escape = function (line)
				local escaped = gsub(line, "%%", "%%%%");
				return escaped;
			end;
		end

		local has_getinfo = getinfo ~= nil;
		local yes_no = function (x) if (x) then return "yes"; end return "no"; end;
		log("[globals] " .. scope .. " begin (getinfo: " .. yes_no(has_getinfo) .. ", via " .. sink .. ")");
		for i = 1, count do
			local value = values[i];
			local kind = type(value);
			if (kind == "function" and has_getinfo) then
				local info = getinfo(value, "S");
				if (info and info.what == "C") then
					kind = "cfunction";
				elseif (info) then
					kind = "lua " .. (info.source or "?");
				end
			end
			local name = names[i];
			if (type(name) ~= "string") then
				name = "(" .. type(name) .. " key)";
			end
			log(escape("[globals] " .. scope .. "\t" .. name .. "\t" .. kind));
		end
		log("[globals] " .. scope .. " end " .. count);

		if (hyperTableHandle) then
			local update = {};
			update["globals_dump_" .. scope] = count;
			hyperTableHandle()(update);
		end
		return count;
	end
end
