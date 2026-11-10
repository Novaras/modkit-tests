-- Ingame tests of engine behaviour modkit relies on, and which `scripts/modkit/hwrm.lua` documents. A failure means a documented
-- assumption is wrong: update `hwrm.lua`, the wiki pages, and whatever modkit code relies on it.
--
-- One file per area in `tests/engine/`. `test engine` runs them all (this file loads them), plus the quick weapons tests
-- (`engine/weapons/basics.lua`); `test engine/movement` runs one. Subfolders hold the longer suites, each run as a folder
-- (`test engine/weapons`: basics, asteroid, homing and the slow-ship miss chance, ~40 min; `test engine/lead`: hours) or one file
-- (`test engine/weapons/homing`).

doscanpath(MK_TESTS_DIR .. "engine/", "*.lua");
dofilepath(MK_TESTS_DIR .. "engine/weapons/basics.lua");
