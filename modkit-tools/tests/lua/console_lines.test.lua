-- Offline unit tests for how the console splits text into lines (`strToConsoleLines`, `scripts/modkit/console/main.lua`). Run with
-- `npm test` in `modkit-tools`.

dofile("modkit-tools/tests/lua/harness.lua");

loadQuietly("scripts/modkit/table_util.lua");
loadQuietly("scripts/modkit/console/main.lua");

--- `strToConsoleLines` with a line length of `max`.
function wrap(str, max)
	MK_CONSOLE_LINE_LENGTH = max;
	return strToConsoleLines(str);
end

describe("strToConsoleLines", function ()
	it("keeps a short line as it is", function ()
		expectEq(wrap("hello there", 20), { "hello there" });
	end);
	it("gives nothing for an empty string", function ()
		expectEq(wrap("", 20), {});
	end);
	it("breaks at the last space that fits, dropping it, and repeats nothing", function ()
		expectEq(wrap("aaa bbb ccc ddd", 8), { "aaa bbb", "ccc ddd" });
		expectEq(wrap("aaa bbb ccc", 7), { "aaa bbb", "ccc" });
	end);
	it("cuts a word with no space to break at", function ()
		expectEq(wrap("abcdefghij", 4), { "abcd", "efgh", "ij" });
	end);
	it("doesn't count markup tags, and never cuts inside one", function ()
		expectEq(wrap("<c=ff0000>aaaa</c> <b>bbbb</b>", 9), { "<c=ff0000>aaaa</c> <b>bbbb</b>" });
		expectEq(wrap("<c=ff0000>aaaa bbbb</c>", 6), { "<c=ff0000>aaaa", "bbbb</c>" });
	end);
	it("treats a `<` with no `>` as text", function ()
		expectEq(wrap("a < b", 10), { "a < b" });
	end);
end);

finish();
