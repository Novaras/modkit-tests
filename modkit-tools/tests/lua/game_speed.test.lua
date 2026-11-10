-- Offline unit tests for `scripts/modkit/game_speed.lua` (`modkit.game_speed`), and the hypertable's UI-scope code queue it uses.
-- Run with `npm test` in `modkit-tools`.
--
-- The hypertable's dropdown is stubbed (one item's custom data string), and `SetTurboSpeed` is a recorder that copies the engine's
-- logic (1 resets, anything else multiplies, clamped to 1/16..64).

dofile("modkit-tools/tests/lua/harness.lua");

-- engine stubs
function Universe_GameTime() return 0; end
DROPDOWN = {};
function UI_AddDropDownListboxItem(_, _, _, _, _, data) DROPDOWN[modkit.table.length(DROPDOWN) + 1] = data; end
function UI_ClearDropDownListbox() DROPDOWN = {}; end
function UI_SelectDropDownListboxItemIndex() end
function UI_GetDropdownListBoxSelectedCustomDataString() return DROPDOWN[1]; end

TURBO = { speed = 1, calls = {} };
function engineSetTurboSpeed(x)
	modkit.table.push(TURBO.calls, x);
	if (x == 1) then
		TURBO.speed = 1;
	else
		TURBO.speed = max(0.0625, min(64, TURBO.speed * x));
	end
end

loadQuietly("scripts/modkit/table_util.lua");
loadQuietly("scripts/modkit/hypertable.lua");
loadQuietly("scripts/modkit/game_speed.lua");

S = modkit.game_speed;

function fresh()
	DROPDOWN = {};
	TURBO = { speed = 1, calls = {} };
	SetTurboSpeed = nil;
end

describe("effective", function ()
	it("keeps speeds from 1/16 up to 1 as they are", function ()
		expectEq(S.effective(0.5), 0.5);
		expectEq(S.effective(0.0625), 0.0625);
		expectEq(S.effective(1), 1);
	end);
	it("rounds speeds above 1 down to whole numbers, since the engine runs whole sim steps per frame", function ()
		expectEq(S.effective(1.5), 1);
		expectEq(S.effective(2.9), 2);
		expectEq(S.effective(8), 8);
	end);
	it("clamps to 1/16..64, like the engine", function ()
		expectEq(S.effective(0.01), 0.0625);
		expectEq(S.effective(100), 64);
	end);
end);

describe("set, in a scope with SetTurboSpeed", function ()
	it("resets, then multiplies up to the speed, so it's the same whatever the speed was", function ()
		fresh();
		SetTurboSpeed = engineSetTurboSpeed;
		local effective, immediate = S.set(4);
		expectEq({ effective, immediate }, { 4, 1 });
		expectEq(TURBO.speed, 4);
		S.set(2);
		expectEq(TURBO.speed, 2);
		S.set(0.5);
		expectEq(TURBO.speed, 0.5);
	end);
	it("only resets for normal speed (or anything rounding to it)", function ()
		fresh();
		SetTurboSpeed = engineSetTurboSpeed;
		S.set(1.5);
		expectEq(TURBO.calls, { 1 });
		expectEq(TURBO.speed, 1);
	end);
end);

describe("set, in a scope without SetTurboSpeed", function ()
	it("queues the call for the UI scope, which runs it (once) when the console opens or closes", function ()
		fresh();
		local effective, immediate = S.set(8);
		expectEq({ effective, immediate }, { 8, nil });
		expectEq(TURBO.calls, {});

		SetTurboSpeed = engineSetTurboSpeed; -- (now "in" the UI scope)
		hyperTableRunUiCode();
		expectEq(TURBO.speed, 8);
		hyperTableRunUiCode();
		expectEq(TURBO.calls, { 1, 8 }, "the queue should be cleared once run");
	end);
	it("runs queued calls in order, so the last speed set wins", function ()
		fresh();
		local speeds = { 2, 16, 4, 0.25, 32, 3 };
		for i = 1, 6 do -- (by index: a `for k, v in` loop's order isn't guaranteed)
			S.set(speeds[i]);
		end
		SetTurboSpeed = engineSetTurboSpeed;
		hyperTableRunUiCode();
		expectEq(TURBO.speed, 3);
	end);
end);

finish();
