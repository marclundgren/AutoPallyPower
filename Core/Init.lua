-- AutoPallyPower - shared namespace bootstrap.
-- Loaded first; every other file receives this table as its second vararg.
local ADDON, APP = ...

APP.name = ADDON
APP.version = "0.3.0"

-- Subsystem tables.
APP.Blessings = APP.Blessings or {}
APP.Profiles = APP.Profiles or {}
APP.Solver = APP.Solver or {}
APP.TestRaid = APP.TestRaid or {}
APP.PP = APP.PP or {}

--- Run fn, and if it errors say so in chat instead of vanishing.
--
-- WoW discards errors raised inside addon callbacks unless the user has turned
-- script errors on, so a broken button reads as "nothing happens" -- which is
-- the least debuggable symptom there is. Everything the user can trigger goes
-- through here.
function APP.SafeCall(context, fn, ...)
	local results = { pcall(fn, ...) }
	if results[1] then
		return unpack(results, 2)
	end
	local message = tostring(results[2])
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(
			("|cffff2020[APP error]|r %s: %s"):format(context, message))
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cff9d9d9dRun /console scriptErrors 1 for a full traceback.|r")
	end
	return nil
end

_G.AutoPallyPower = APP
