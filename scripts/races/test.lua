-- modkit's test race: owns the assets used by modkit's ingame tests (`scripts/modkit/tests/`), all named `test_*`. Not for play.
-- Most things (turrets, subsystems, building, research...) only work if they belong to a known race and their name has its
-- prefix: a turret subsystem named without one is attached but has no weapon (found 2026-11-08). Kept out of race selection
-- (`cfg_race_is_playable = 0` in `test/props/default.lua`, and its own filter tags).
Path_Name = "Test"
Symbolic_Name = "Test"
Display_Name = "Test (modkit)"
Prefix = "TEST_"

ExtFilter = "races_mk_test"
Tags = "race_mk_test"

SG_Pass_Tags = "sgf_common"
