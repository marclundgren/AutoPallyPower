-- AutoPallyPower - shared namespace bootstrap.
-- Loaded first; every other file receives this table as its second vararg.
local ADDON, APP = ...

APP.name = ADDON
APP.version = "0.1.0"

-- Subsystem tables.
APP.Blessings = APP.Blessings or {}
APP.Profiles = APP.Profiles or {}
APP.Solver = APP.Solver or {}
APP.TestRaid = APP.TestRaid or {}
APP.PP = APP.PP or {}

_G.AutoPallyPower = APP
