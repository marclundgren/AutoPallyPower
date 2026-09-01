local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local T = h.T
local ROOT = os.getenv("APP_ROOT") or "."

-- WoW's Lua is sandboxed: os, io, require, dofile and loadfile are all absent.
-- Touching one throws, and by default the client swallows the error, so the
-- symptom is a command that silently does nothing rather than anything you
-- could debug. Cheap to check, expensive to miss.
local FORBIDDEN = {
	{ pattern = "[^%w_]os%s*%.", what = "os.* (no os table in WoW)" },
	{ pattern = "[^%w_]io%s*%.", what = "io.* (no io table in WoW)" },
	{ pattern = "[^%w_]require%s*%(", what = "require()" },
	{ pattern = "[^%w_]dofile%s*%(", what = "dofile()" },
	{ pattern = "[^%w_]loadfile%s*%(", what = "loadfile()" },
	{ pattern = "[^%w_]collectgarbage%s*%(", what = "collectgarbage()" },
	-- math.random exists in WoW; math.randomseed does not. Of the addons
	-- installed alongside this one, 48 call math.random and none call
	-- math.randomseed.
	{ pattern = "math%s*%.%s*randomseed", what = "math.randomseed (absent in WoW)" },
}

--- Every Lua file the .toc actually loads into the client.
local function tocFiles()
	local files = {}
	local f = assert(io.open(ROOT .. "/AutoPallyPower.toc", "r"))
	for line in f:lines() do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" and trimmed:match("%.lua$") then
			files[#files + 1] = trimmed:gsub("\\", "/")
		end
	end
	f:close()
	return files
end

local files = tocFiles()
T.check("the .toc lists Lua files", #files > 0, "found " .. #files)

for _, rel in ipairs(files) do
	local fh = io.open(ROOT .. "/" .. rel, "r")
	T.check("toc file exists: " .. rel, fh ~= nil)
	if fh then
		local n = 0
		for line in fh:lines() do
			n = n + 1
			-- Ignore comment lines; prose may mention os.time legitimately.
			local code = line:match("^%s*%-%-") and "" or line
			for _, rule in ipairs(FORBIDDEN) do
				if (" " .. code):find(rule.pattern) then
					T.check("no " .. rule.what .. " in " .. rel, false,
						("line %d: %s"):format(n, line:match("^%s*(.-)%s*$")))
				end
			end
		end
		fh:close()
	end
end
T.check("no sandbox-forbidden globals in shipped files", true)

T.report("sandbox")
