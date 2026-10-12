--!strict
-- The Agent Sessions manager block (host half): search, detail and spend modes. The views live in
-- lib/v_*.luau; this file owns the lifecycle, mode switching and event routing.
-- Args: {"search" | "spend", <cwd or "">}.
local U = require("../lib/ui")
local S = require("../lib/v_search")
local D = require("../lib/v_detail")
local P = require("../lib/v_spend")
local app = require("../lib/app")
local textfield = require("../lib/textfield")

type State = U.State

local function to_search(state: State)
	state.mode = "search"
	state.notice = nil
	U.focus(state.cx, "main.query")
end

local function to_spend(state: State)
	state.mode = "spend"
	state.notice = nil
	U.focus(state.cx, nil)
	P.refresh_if_stale(state)
end

local def: BlockDef<State> = {
	init = function(cx, args, saved)
		local s: any = if type(saved) == "table" then saved else {}
		local mode: "search" | "spend" = if s.mode == "spend" or (s.mode ~= "search" and args[1] == "spend") then "spend" else "search"
		local cwd = args[2]
		local state: State = {
			cx = cx,
			pane_id = string.format("%.0f", cx.pane),
			mode = mode,
			back = "search",
			q = textfield.new(if type(s.query) == "string" then s.query else ""),
			sel_idx = 1,
			searching = false,
			seq = 0,
			debounce = 0,
			spend_at = 0,
			spend_sel = 1,
			spend_loading = false,
			cwd_hint = if type(cwd) == "string" and cwd ~= "" then cwd else nil,
		}
		app.add(state)
		app.prune()
		S.run(state)
		if mode == "spend" then
			P.load(state, false)
		else
			tern.timer(0, function()
				U.focus(cx, "main.query")
			end)
		end
		return state
	end,

	title = function(state)
		if state.mode == "detail" then
			local t = D.title(state)
			if t then
				return "Agent Sessions › " .. D.clip(t, 40)
			end
		end
		return "Agent Sessions"
	end,

	save = function(state)
		return { mode = if state.mode == "detail" then state.back else state.mode, query = state.q.text }
	end,

	view = function(state, _cx)
		if state.mode == "detail" then
			local main, dock = D.view(state)
			return { main = main, dock = dock }
		elseif state.mode == "spend" then
			local main, dock, layer = P.view(state)
			return { main = main, dock = dock, layer = layer }
		end
		local main, dock = S.view(state)
		return { main = main, dock = dock }
	end,

	key = function(state, k, _cx)
		if state.mode == "spend" and state.budget_edit ~= nil then
			return P.key(state, k)
		end
		local plain = not (k.ctrl or k.meta or k.alt)
		if plain and k.name == "tab" and not k.shift then
			if state.mode == "search" then
				to_spend(state)
				return true
			elseif state.mode == "spend" then
				to_search(state)
				return true
			end
			return false
		end
		if state.mode == "detail" then
			return D.key(state, k)
		elseif state.mode == "spend" then
			if plain and k.name == "escape" then
				to_search(state)
				return true
			end
			return P.key(state, k)
		end
		return S.key(state, k)
	end,

	event = function(state, ev, cx)
		local kind = ev.ev
		if kind == "select" or kind == "activate" then
			local list, key = U.parse_item(ev.item)
			if list == "results" and state.mode == "search" and state.results then
				for i, r in state.results :: { any } do
					if r.id == key then
						state.sel_idx = i
					end
				end
				if kind == "activate" then
					S.act(state, "open")
				end
			elseif list == "top" and state.mode == "spend" and type(state.spend) == "table" then
				local top: any = (state.spend :: any).top
				for i, r in (if type(top) == "table" then top else {}) :: { any } do
					if r.id == key then
						state.spend_sel = i
					end
				end
				if kind == "activate" then
					P.act(state, "open")
				end
			end
		elseif kind == "action" then
			local act = ev.act
			if act == "tab" then
				if ev.value == "spend" then
					to_spend(state)
				else
					to_search(state)
				end
			elseif state.mode == "detail" then
				D.act(state, act)
			elseif state.mode == "spend" then
				P.act(state, act)
			else
				S.act(state, act)
			end
		elseif kind == "focus" then
			if ev.id == "main.query" and state.mode == "search" then
				U.focus(cx, "main.query")
			elseif ev.id == "layer.budget.amount" and state.budget_edit ~= nil then
				U.focus(cx, "layer.budget.amount")
			end
		end
	end,
}

return def
