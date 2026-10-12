--!strict
-- Window half: palette commands that open the manager, or focus the one already open.
local platform = require("./platform")

local commands = {}

local GROUP = "Agent Sessions"
local KIND = "tern-sessions.manager"

-- The focused pane's working directory ("" when unknown or on another machine).
function commands.focused_cwd(cx: WindowCx): (string, string?)
	local okh, host = pcall(function()
		return cx.hosts:current()
	end)
	if okh and type(host) == "table" and (host :: any).kind == "remote" then
		return "", "That pane is on another machine. Pick a folder on this " .. platform.machine() .. "."
	end
	local okp, info = pcall(function(): PaneInfo?
		local pane = cx.session:focused()
		if pane == nil then
			return nil
		end
		return cx.session:pane(pane)
	end)
	if okp and info ~= nil and type(info.cwd) == "string" then
		return info.cwd, nil
	end
	return "", nil
end

-- Opens the manager in `mode`. An open manager already in that mode (detail counts as either) is
-- focused; one in the other mode is closed and replaced, so there is never a second manager.
local function open(cx: WindowCx, mode: string)
	local ok, entries = pcall(function()
		return tern.kv.get("managers")
	end)
	if ok and type(entries) == "table" then
		for _, e in entries do
			-- Legacy entries were bare pane id strings with no mode.
			local id = if type(e) == "table" then e.id else e
			local have = if type(e) == "table" then e.mode else nil
			local okr, pane = pcall(function()
				return cx.session:resolve(tostring(id))
			end)
			if okr and pane ~= nil then
				if have == mode or have == "detail" then
					cx.layout:focus(pane)
					return
				end
				cx.layout:close(pane)
			end
		end
	end
	local cwd = commands.focused_cwd(cx)
	cx:new_block(KIND, { mode, cwd }, "tab")
end

local registered = false

function commands.register()
	if registered then
		return
	end
	registered = true
	tern.command({
		id = "open",
		title = "Search sessions",
		icon = "search",
		group = GROUP,
		keys = { "ctrl+alt+shift+h" },
		run = function(cx: WindowCx)
			open(cx, "search")
		end,
	})
	tern.command({
		id = "spend",
		title = "Show spend",
		icon = "chart",
		group = GROUP,
		run = function(cx: WindowCx)
			open(cx, "spend")
		end,
	})
end

return commands
