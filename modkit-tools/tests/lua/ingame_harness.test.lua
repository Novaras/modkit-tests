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

function record(value)
	listPush(RECORD, value);
end

--- Collects the suites `fn` describes and begins running them, with a fresh clock, events and `RECORD`. Output lines go to `LINES`.
function startRun(fn, on_suite, on_test)
	E:reset();
	NOW = 0;
	RECORD = {};
	LINES = {};
	T.reset();
	fn();
	return T.run({
		name = "offline",
		output = function (line) listPush(LINES, line); end,
		onSuite = on_suite,
		onTest = on_test,
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

describe("onTest", function ()
	it("announces each test as it begins, but not skipped ones", function ()
		EVENTS = {};
		local run = drive(startRun(function ()
			T.describe("suite", function ()
				T.it("first", function () end);
				T.xit("pending", function () end);
				T.it("second", function () T.fail("nope"); end);
			end);
		end, nil, function (run, test)
			listPush(EVENTS, test.name);
		end), 30);
		expect(run.done, "the run should finish");
		expectEq(EVENTS, { "first", "second" });
	end);
end);

describe("onSuite", function ()
	it("announces each top-level suite's beginning and end, with its own results (not nested suites)", function ()
		EVENTS = {};
		local run = drive(startRun(function ()
			T.describe("first", function ()
				T.it("passes", function () end);
				T.describe("nested", function ()
					T.it("fails", function () T.fail("nope"); end);
				end);
			end);
			T.describe("second", function ()
				T.it("passes", function () end);
				T.xit("is pending", function () end);
			end);
		end, function (run, suite, event, counts)
			local line = suite.name .. " " .. event;
			if (counts) then
				line = line .. " " .. counts.passed .. "/" .. counts.failed .. "/" .. counts.skipped;
			end
			listPush(EVENTS, line);
		end), 30);
		expect(run.done, "the run should finish");
		expectEq(EVENTS, { "first begin", "first end 1/1/0", "second begin", "second end 1/0/1" });
	end);
end);

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
		local n = listLength(LINES);
		expectTruthy(strfind(LINES[n - 1], "offline: 0 passed, 1 failed, 0 skipped", 1, 1), "summary line");
		local recap = gsub(LINES[n], "<[^>]*>", ""); -- (without the colour tags)
		expectTruthy(strfind(recap, "1) suite > fails: nope", 1, 1), "failure recap line: " .. recap);
	end);
	it("cuts long lines in the output", function ()
		runSuites(function ()
			T.describe("suite", function ()
				T.it("fails", function () T.fail(strrep("x", 500)); end);
			end);
		end);
		for i = 1, listLength(LINES) do
			local visible = gsub(LINES[i], "<[^>]*>", "");
			expect(strlen(visible) <= T.console_line_length, "line " .. i .. " is too long");
		end
	end);
	it("clip counts only visible characters, never cuts a tag, and keeps the closing tags", function ()
		expectEq(T.clip("<b>abc</b>", 3), "<b>abc</b>");
		expectEq(T.clip("<b>abcdef</b><c=fff>ghi</c>", 6), "<b>abc...</b><c=fff></c>");
		expectEq(T.clip("ab<c=fff>cdefgh</c>", 6), "ab<c=fff>c...</c>");
		expectEq(T.clip("abcdefgh", 5), "ab...");
	end);
	it("calls onFinish with the run", function ()
		RECORD = {};
		E:reset();
		T.reset();
		T.describe("suite", function () T.it("passes", function () end); end);
		local run = T.run({ output = function () end, onFinish = function (finished) record(finished); end });
		drive(run, 5);
		expectEq(listLength(RECORD), 1);
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
	it("can return a running chain", function ()
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
	it("can return a chain that hasn't begun (the harness begins it)", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("chains", function ()
					return T.wait(0.5):next(function (res) record(NOW); res(); end);
				end);
			end);
		end);
		expectEq(run.passed, 1);
		expect(RECORD[1] and RECORD[1] >= 0.5, "the chain's second event ran before its first finished");
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

describe("parallel", function ()
	it("runs its branches at once, and resolves with their values once they've all finished", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("parallels", function ()
					return T.sequence(
						T.parallel(
							T.sequence(T.wait(1), function () record("a " .. NOW); return "a"; end),
							function () return T.sequence(T.wait(1), function () record("b " .. NOW); return "b"; end); end,
							function () return 3; end
						),
						function (values) record(values[1] .. values[2] .. values[3]); record(NOW); end
					);
				end);
			end);
		end);
		expectEq(run.passed, 1);
		expectEq(RECORD[1], RECORD[2] and ("a " .. strsub(RECORD[2], 3)) or nil, "both branches should finish on the same tick");
		expectEq(RECORD[3], "ab3");
		expect(RECORD[4] >= 1 and RECORD[4] < 2, "it should take about as long as one branch, not both (" .. tostring(RECORD[4]) .. ")");
	end);
	it("waits for every branch, then rejects with each error, numbered", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("parallels", function ()
					return T.parallel(
						T.waitFor(function () return nil; end, { timeout = 0.5, message = "never" }),
						T.sequence(T.wait(1), function () record(NOW); end),
						function () T.expectEq("a", "b"); end
					);
				end);
			end);
		end);
		expectEq(run.failures[1].message, "(1) waited 0.5s: never; (3) expected \"b\", got \"a\"");
		expect(RECORD[1] and RECORD[1] >= 1, "the second branch should have finished first");
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
	it("calls a function message at the timeout, so it can describe the state then", function ()
		local run = runSuites(function ()
			T.describe("suite", function ()
				T.it("waits", function ()
					return T.waitFor(function () return nil; end, { timeout = 2, message = function () return "gave up at " .. floor(NOW); end });
				end);
			end);
		end);
		expectEq(run.failures[1].message, "waited 2s: gave up at 2");
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
	it("expectConsoleError catches consoleError output, and returns the function's result", function ()
		consoleError = function () RECORD.leaked = 1; end; -- (the real one, which mustn't be reached)
		RECORD = {};
		local result = T.expectConsoleError(function ()
			consoleError("first", "can't do that");
			return "result";
		end, "do that");
		expectEq(result, "result");
		expectNil(RECORD.leaked);
		consoleError("after");
		expectEq(RECORD.leaked, 1, "consoleError should be put back");
		consoleError = nil;
	end);
	it("expectConsoleError catches `consoleError or print` callers when there's no consoleError", function ()
		consoleError = nil;
		T.expectConsoleError(function ()
			local output = consoleError or print; -- (as modkit's code does it)
			output("oops");
		end);
		expectNil(consoleError, "should be put back to nil");
	end);
	it("expectConsoleError fails when nothing (or nothing matching) is logged, or the function errors", function ()
		local saved = _ERRORMESSAGE;
		_ERRORMESSAGE = function () end;
		expectError(function () T.expectConsoleError(function () end); end);
		expectError(function () T.expectConsoleError(function () consoleError("other"); end, "wanted"); end);
		expectError(function () T.expectConsoleError(function () consoleError("x"); error("boom"); end); end);
		_ERRORMESSAGE = saved;
		expectNil(consoleError, "should be put back after a failure too");
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
				listPush(missing, name);
			end
		end
		for _, name in T.exports do -- (put the offline harness's back)
			rawset(globals(), name, saved[name]);
		end
		expectEq(missing, {});
	end);
end);

finish();
