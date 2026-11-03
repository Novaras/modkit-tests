-- Offline unit tests for `scripts/modkit/tests/lib/harness.lua` (`MK_TEST`, the ingame tests' harness). Run with `npm test` in `modkit-tools`.
--
-- The game clock is faked (`NOW`), and runs are driven like the rules scope drives events: a tick every 0.1s.
-- `MK_TEST`'s functions are called through `T` rather than installed, since this file's own `describe`/`it` are the offline harness's.
-- Hooks and tests record what happened in the global `RECORD` (globals avoid Lua 4's upvalue limits in nested callbacks).

dofile("modkit-tools/tests/lua/harness.lua");

-- engine stubs
NOW = 0;
function Universe_GameTime() return NOW; end
function Rule_AddInterval() end

loadQuietly("scripts/modkit/tests/lib/harness.lua"); -- (also loads events, table_util and protected_call)

T = MK_TEST;
E = modkit.events;

--- Fails unless `value` is non-nil (the offline harness has no plain `expect`).
function expect(value, label)
	if (value == nil) then
		fail(label or "expectation failed");
	end
end

function record(value)
	RECORD[getn(RECORD) + 1] = value;
end

--- Collects the suites `fn` describes and begins running them, with a fresh clock, events and `RECORD`. Output lines go to `LINES`.
function startRun(fn)
	E:reset();
	NOW = 0;
	RECORD = {};
	LINES = {};
	T.reset();
	fn();
	return T.run({
		name = "offline",
		output = function (line) LINES[getn(LINES) + 1] = line; end,
	});
end

--- Advances the clock up to `seconds` (in 0.1s ticks), stopping early once `run` is done.
--- Quietens `print` and the "game's" error handler meanwhile, since failing hooks and tests are expected to raise errors.
function drive(run, seconds)
	local saved_handler = _ERRORMESSAGE;
	_ERRORMESSAGE = function () end;
	print = function () end;
	for _ = 1, floor(seconds * 10 + 0.5) do
		if (run.done) then
			break;
		end
		NOW = NOW + 0.1;
		modkit_events_driver();
	end
	print = HARNESS_PRINT;
	_ERRORMESSAGE = saved_handler;
	return run;
end

--- Runs the suites `fn` describes to completion (failing if they take over `seconds`, default 30).
function runSuites(fn, seconds)
	local run = drive(startRun(fn), seconds or 30);
	if (not run.done) then
		fail("the run didn't finish");
	end
	return run;
end

function counts(run)
	return { passed = run.passed, failed = run.failed, skipped = run.skipped };
end

describe("results", function ()
	it("counts passing, failing and erroring tests, with the failures' messages", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("passes", function () end);
				T.it("fails an expectation", function () T.expectEq(1, 2); end);
				T.it("errors", function () error("boom"); end);
			end);
		end);
		expectEq(counts(run), { passed = 1, failed = 2, skipped = 0 });
		expectEq(run.failures[1], { name = "suite > fails an expectation", message = "expected 2, got 1" });
		expectEq(run.failures[2].message, "boom");
	end);
	it("logs a summary, then each failure again", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("fails", function () T.fail("nope"); end);
			end);
		end);
		local n = getn(LINES);
		expectTruthy(strfind(LINES[n - 1], "offline: 0 passed, 1 failed, 0 skipped", 1, 1), "summary line");
		expectTruthy(strfind(LINES[n], "suite > fails: nope", 1, 1), "failure recap line");
	end);
	it("cuts long lines in the output", function ()
		runSuites(function ()
			T.describe("suite", function ()
				T.it("fails", function () T.fail(strrep("x", 500)); end);
			end);
		end);
		for i = 1, getn(LINES) do
			expect(strlen(LINES[i]) <= T.console_line_length, "line " .. i .. " is too long");
		end
	end);
	it("calls onFinish with the run", function ()
		RECORD = {};
		E:reset();
		T.reset();
		T.describe("suite", function () T.it("passes", function () end); end);
		local run = T.run({ output = function () end, onFinish = function (finished) record(finished); end });
		drive(run, 5);
		expectEq(getn(RECORD), 1);
		expect(RECORD[1] == run, "onFinish should get the run");
	end);
end);

describe("hooks", function ()
	it("run in mocha's order: before, then beforeEach (outermost first), the test, afterEach (innermost first), then after", function ()
		runSuites(function ()
			T.describe("outer", function ()
				T.before(function () record("before"); end);
				T.beforeEach(function () record("outer beforeEach"); end);
				T.afterEach(function () record("outer afterEach"); end);
				T.after(function () record("after"); end);
				T.it("one", function () record("one"); end);
				T.describe("inner", function ()
					T.beforeEach(function () record("inner beforeEach"); end);
					T.afterEach(function () record("inner afterEach"); end);
					T.it("two", function () record("two"); end);
				end);
			end);
		end);
		expectEq(RECORD, {
			"before",
			"outer beforeEach", "one", "outer afterEach",
			"outer beforeEach", "inner beforeEach", "two", "inner afterEach", "outer afterEach",
			"after",
		});
	end);
	it("share ctx with the tests in their top-level describe (including nested ones), but not with other top-level describes", function ()
		runSuites(function ()
			T.describe("a", function ()
				T.before(function (ctx) ctx.value = "a"; end);
				T.describe("nested", function ()
					T.it("sees a's ctx", function (ctx) record(ctx.value); end);
				end);
			end);
			T.describe("b", function ()
				T.it("has its own ctx", function (ctx) record(ctx.value or "none"); end);
			end);
		end);
		expectEq(RECORD, { "a", "none" });
	end);
	it("a failing before skips its suite's tests (and nested suites), but still runs its after, and other suites", function ()
		local run = runSuites(function ()
			T.describe("broken", function ()
				T.before(function () error("setup failed"); end);
				T.after(function () record("after"); end);
				T.it("one", function () record("one"); end);
				T.describe("nested", function ()
					T.before(function () record("nested before"); end);
					T.after(function () record("nested after"); end);
					T.it("two", function () record("two"); end);
				end);
			end);
			T.describe("fine", function ()
				T.it("three", function () record("three"); end);
			end);
		end);
		expectEq(RECORD, { "after", "three" });
		expectEq(counts(run), { passed = 1, failed = 1, skipped = 2 });
		expectEq(run.failures[1], { name = "broken > \"before\" hook", message = "setup failed" });
	end);
	it("a failing beforeEach skips only that test, and still runs afterEach", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.beforeEach(function (ctx)
					ctx.n = (ctx.n or 0) + 1;
					if (ctx.n == 1) then error("first setup failed"); end
				end);
				T.afterEach(function () record("afterEach"); end);
				T.it("one", function () record("one"); end);
				T.it("two", function () record("two"); end);
			end);
		end);
		expectEq(RECORD, { "afterEach", "two", "afterEach" });
		expectEq(counts(run), { passed = 1, failed = 1, skipped = 1 });
	end);
	it("a failing after or afterEach is a failure", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.afterEach(function () error("cleanup failed"); end);
				T.after(function () error("teardown failed"); end);
				T.it("one", function () end);
			end);
		end);
		expectEq(counts(run), { passed = 1, failed = 2, skipped = 0 });
		expectEq(run.failures[1].name, "suite > \"afterEach\" hook for \"one\"");
		expectEq(run.failures[2].name, "suite > \"after\" hook");
	end);
	it("an async before is waited on before the tests run", function ()
		runSuites(function ()
			T.describe("suite", function ()
				T.before(function (ctx)
					return T.sequence(T.wait(1), function () %ctx.ready = NOW; end);
				end);
				T.it("one", function (ctx) record(ctx.ready); end);
			end);
		end);
		expect(RECORD[1] and RECORD[1] >= 1, "the test ran before the hook's event finished");
	end);
end);

describe("async tests", function ()
	it("pass once the event they return resolves", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("waits", function () return T.wait(2); end);
				T.it("after", function () record(NOW); end);
			end);
		end);
		expectEq(run.passed, 2);
		expect(RECORD[1] >= 2, "the next test ran before the wait finished");
	end);
	it("can return a chain, rather than an event", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("chains", function ()
					return T.wait(0.5)():next(function (res) record("next"); res(); end);
				end);
			end);
		end);
		expectEq(run.passed, 1);
		expectEq(RECORD, { "next" });
	end);
	it("fail with the message when the event rejects", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("rejects", function ()
					return E:make(function (_, rej) rej("nope"); end);
				end);
			end);
		end);
		expectEq(run.failures[1].message, "nope");
	end);
	it("time out (in game time), stopping the events they made", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("never finishes", function ()
					LEFTOVER = E:make(function () end);
					LEFTOVER:begin();
					return T.waitFor(function () return nil; end, { timeout = 100 });
				end, { timeout = 1 });
			end);
		end);
		expectEq(run.failures[1].message, "timed out after 1s");
		expectEq(LEFTOVER.status, EVENT_STATUS.REJECTED);
		expect(NOW >= 1 and NOW < 2, "timed out at " .. NOW);
	end);
	it("default to MK_TEST.default_timeout", function ()
		local saved = T.default_timeout;
		T.default_timeout = 0.5;
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("never finishes", function () return T.waitFor(function () return nil; end, { timeout = 100 }); end);
			end);
		end);
		T.default_timeout = saved;
		expectEq(run.failures[1].message, "timed out after 0.5s");
	end);
end);

describe("skipping", function ()
	it("skip() skips a test", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("skips", function () T.skip("not today"); record("ran on"); end);
			end);
		end);
		expectEq(counts(run), { passed = 0, failed = 0, skipped = 1 });
		expectEq(RECORD, {});
		expectTruthy(strfind(LINES[2], "SKIP", 1, 1));
		expectTruthy(strfind(LINES[2], "not today", 1, 1));
	end);
	it("skip() in a before skips the suite's tests, without a failure", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.before(function () T.skip("no enemy player"); end);
				T.it("one", function () record("one"); end);
				T.it("two", function () record("two"); end);
			end);
		end);
		expectEq(counts(run), { passed = 0, failed = 0, skipped = 2 });
		expectEq(RECORD, {});
	end);
	it("an event rejected by skip() skips the test", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("skips later", function ()
					return T.sequence(T.wait(0.5), function () T.skip("later"); end);
				end);
			end);
		end);
		expectEq(counts(run), { passed = 0, failed = 0, skipped = 1 });
	end);
	it("xit counts as skipped, without running any hooks for it", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.beforeEach(function () record("beforeEach"); end);
				T.xit("not written yet");
			end);
		end);
		expectEq(counts(run), { passed = 0, failed = 0, skipped = 1 });
		expectEq(RECORD, {});
	end);
end);

describe("describe", function ()
	it("an error in its callback is a failure, and other suites still run", function ()
		local run = runSuites(function ()
			T.describe("broken", function ()
				T.it("one", function () record("one"); end);
				error("bad file");
			end);
			T.describe("fine", function ()
				T.it("two", function () record("two"); end);
			end);
		end);
		expectEq(RECORD, { "two" });
		expectEq(run.failures[1], { name = "broken > describe", message = "bad file" });
	end);
	it("names nested suites' tests by their whole path", function ()
		local run = runSuites(function ()
			T.describe("a", function ()
				T.describe("b", function ()
					T.it("c", function () T.fail("x"); end);
				end);
			end);
		end);
		expectEq(run.failures[1].name, "a > b > c");
	end);
	it("runs a lot of synchronous tests without waiting on game time for each", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				for i = 1, 100 do
					T.it("test " .. i, function () end);
				end
			end);
		end, 2);
		expectEq(run.passed, 100);
	end);
end);

describe("sequence", function ()
	it("runs functions and events in turn, passing each value on, and resolves with the last", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("sequences", function ()
					return T.sequence(
						function () return 1; end,
						function (value) return value + 1; end,
						T.wait(0.5), -- (resolves with the value it's begun with)
						function (value) record(value); return value * 10; end
					)():next(function (res, _, state) record(state._previous_result); res(); end);
				end);
			end);
		end);
		expectEq(run.passed, 1);
		expectEq(RECORD, { 2, 20 });
	end);
	it("waits on an event a function returns, continuing with its result", function ()
		runSuites(function ()
			T.describe("suite", function ()
				T.it("sequences", function ()
					return T.sequence(
						function () return T.waitFor(function () if (NOW >= 1) then return "done"; end end); end,
						function (value) record(value); record(NOW); end
					);
				end);
			end);
		end);
		expectEq(RECORD[1], "done");
		expect(RECORD[2] >= 1, "continued before the returned event finished");
	end);
	it("rejects when a function errors, without running the rest", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("sequences", function ()
					return T.sequence(
						function () T.expectEq("a", "b"); end,
						function () record("ran on"); end
					);
				end);
			end);
		end);
		expectEq(run.failures[1].message, "expected \"b\", got \"a\"");
		expectEq(RECORD, {});
	end);
	it("rejects when an event rejects", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("sequences", function ()
					return T.sequence(T.waitFor(function () return nil; end, { timeout = 1, message = "never" }));
				end);
			end);
		end);
		expectEq(run.failures[1].message, "waited 1s: never");
	end);
	it("rejects a step which isn't a function or event", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("sequences", function () return T.sequence(5); end);
			end);
		end);
		expectEq(run.failures[1].message, "sequence step 1 isn't a function or an event (got 5)");
	end);
end);

describe("waitFor", function ()
	it("resolves with the predicate's value once it's non-nil", function ()
		runSuites(function ()
			T.describe("suite", function ()
				T.it("waits", function ()
					return T.sequence(
						T.waitFor(function () if (NOW >= 1) then return NOW; end end),
						function (value) record(value); end
					);
				end);
			end);
		end);
		expect(RECORD[1] >= 1, "resolved early");
	end);
	it("rejects with its message after its timeout", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("waits", function ()
					return T.waitFor(function () return nil; end, { timeout = 2, message = "it never docked" });
				end);
			end);
		end);
		expectEq(run.failures[1].message, "waited 2s: it never docked");
	end);
end);

describe("stop", function ()
	it("ends a run straight away, rejecting the events its current step made", function ()
		local run = startRun(function ()
			T.describe("suite", function ()
				T.it("waits", function ()
					WAITING = T.waitFor(function () return nil; end, { timeout = 100 });
					return WAITING;
				end, { timeout = 100 });
				T.it("never runs", function () record("ran"); end);
			end);
		end);
		drive(run, 1);
		T.stop(run);
		drive(run, 1);
		expect(run.done, "the run should be done");
		expectEq(WAITING.status, EVENT_STATUS.REJECTED);
		expectEq(run.event.status, EVENT_STATUS.REJECTED);
		expectEq(RECORD, {});
	end);
end);

describe("assertions", function ()
	it("expectEq compares tables deeply", function ()
		T.expectEq({ 1, { a = 2 } }, { 1, { a = 2 } });
		expectError(function () T.expectEq({ 1 }, { 2 }); end);
	end);
	it("expectNear allows a tolerance, for numbers and positions", function ()
		T.expectNear(1.0005, 1);
		T.expectNear({ 10, 20, 30 }, { 11, 19, 30 }, 1);
		expectError(function () T.expectNear(1.1, 1); end);
		expectError(function () T.expectNear({ 10, 20, 30 }, { 10, 20, 32 }, 1); end);
		expectError(function () T.expectNear("1", 1); end);
	end);
	it("expect, expectNil, expectTruthy check for nil", function ()
		T.expect(1);
		T.expectNil(nil);
		T.expectTruthy(0);
		expectError(function () T.expect(nil); end);
		expectError(function () T.expectNil(0); end);
		expectError(function () T.expectTruthy(nil); end);
	end);
	it("expectError fails unless the function errors", function ()
		local saved = _ERRORMESSAGE;
		_ERRORMESSAGE = function () end; -- (protectedCall passes the expected error on to the "game's" handler)
		T.expectError(function () error("x"); end);
		local passed = protectedCall(T.expectError, { function () end });
		_ERRORMESSAGE = saved;
		expectNil(passed);
	end);
	it("show names ships and events, and doesn't go deep into tables", function ()
		expectEq(T.show({ own_group = "kus_scout-12", player = {} }), "Ship(kus_scout-12)");
		expectEq(T.show({ __is_event = 1, name = "ev", status = "running" }), "Event(ev, running)");
		expectEq(T.show({ a = { b = { c = 1 } } }), "{[\"a\"]={[\"b\"]={...}}}");
	end);
	it("cleanMessage removes rejected events' name prefixes", function ()
		expectEq(T.cleanMessage("[event_3]: [kus_scout_1_move_2]: interrupted"), "interrupted");
		expectEq(T.cleanMessage("no prefix [here]: ok"), "no prefix [here]: ok");
	end);
end);

describe("install", function ()
	it("makes the exported globals", function ()
		local saved = {};
		for _, name in T.exports do
			saved[name] = rawget(globals(), name);
		end
		T.install();
		local missing = {};
		for _, name in T.exports do
			if (rawget(globals(), name) ~= T[name]) then
				missing[getn(missing) + 1] = name;
			end
		end
		for _, name in T.exports do -- (put the offline harness's back)
			rawset(globals(), name, saved[name]);
		end
		expectEq(missing, {});
	end);
end);

finish();
