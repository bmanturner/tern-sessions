--!strict
-- The Agent Sessions manager block (host half): search, detail and spend modes. The views live in
-- lib/v_*.luau; this file owns the lifecycle, mode switching, focus and event routing.
-- Args: {"search" | "spend", <cwd or "">, <query?>}.
-- Focus: search owns "main.query"; spend and detail own the hidden dock input (U.KEYS_ID); the
-- budget overlay owns "layer.budget.amount" (v_spend focuses it).
local U = require("../lib/ui")
local S = require("../lib/v_search")
local D = require("../lib/v_detail")
local P = require("../lib/v_spend")
local app = require("../lib/app")
local textfield = require("../lib/textfield")

type State = U.State

local function focus_owner(state: State)
	U.refocus(state)
end

local function set_mode(state: State, mode: "search" | "spend" | "detail")
	state.mode = mode
	app.set_mode(state.pane_id, mode)
	focus_owner(state)
end

local function to_search(state: State)
	state.notice = nil
	set_mode(state, "search")
	if state.results == nil and not state.searching then
		S.run(state)
	end
end

local function to_spend(state: State)
	state.notice = nil
	set_mode(state, "spend")
	P.refresh_if_stale(state)
end

-- Runs a view handler that may change the mode (opening or leaving the detail, spend -> search),
-- then publishes and refocuses when it did.
local function delegate(state: State, handler: (State) -> boolean): boolean
	local before = state.mode
	local changed = handler(state)
	if state.mode ~= before then
		set_mode(state, state.mode)
		if state.mode == "search" and state.results == nil and not state.searching then
			S.run(state)
		end
	end
	return changed
end

local function selected_top_id(state: State): string?
	local spend: any = state.spend
	local top: any = if type(spend) == "table" then spend.top else nil
	local row: any = if type(top) == "table" then top[state.spend_sel] else nil
	return if type(row) == "table" and type(row.id) == "string" then row.id else nil
end

local def: BlockDef<State> = {
	init = function(cx, args, saved)
		local s: any = if type(saved) == "table" then saved else {}
		local mode: "search" | "spend" = if s.mode == "spend" or (s.mode ~= "search" and args[1] == "spend") then "spend" else "search"
		local cwd = args[2]
		local text = if type(s.query) == "string" then s.query elseif type(args[3]) == "string" then args[3] else ""
		local state: State = {
			cx = cx,
			pane_id = string.format("%.0f", cx.pane),
			mode = mode,
			back = "search",
			q = textfield.new(text),
			sel_idx = 1,
			searching = false,
			pending = false,
			launching = false,
			seq = 0,
			debounce = 0,
			spend_at = 0,
			spend_sel = 1,
			spend_loading = false,
			prompt_sel = 1,
			sel_id = if type(s.sel) == "string" then s.sel else nil,
			spend_sel_id = if type(s.spend_sel) == "string" then s.spend_sel else nil,
			cwd_hint = if type(cwd) == "string" and cwd ~= "" then cwd else nil,
		}
		app.add(state)
		app.prune()
		app.set_mode(state.pane_id, mode)
		if mode == "spend" then
			P.load(state, false)
		else
			S.run(state)
		end
		focus_owner(state)
		return state
	end,

	title = function(state)
		if state.mode == "detail" then
			local t = D.title(state)
			if t then
				return "Agent Sessions › " .. D.clip(t, 28)
			end
		end
		return "Agent Sessions"
	end,

	save = function(state)
		local sel = S.selected(state)
		return {
			mode = if state.mode == "detail" then state.back else state.mode,
			query = state.q.text,
			sel = if sel ~= nil then sel.id else state.sel_id,
			spend_sel = selected_top_id(state) or state.spend_sel_id,
		}
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
			return delegate(state, function(s)
				return D.key(s, k)
			end)
		elseif state.mode == "spend" then
			if plain and k.name == "escape" then
				to_search(state)
				return true
			end
			return delegate(state, function(s)
				return P.key(s, k)
			end)
		end
		return delegate(state, function(s)
			return S.key(s, k)
		end)
	end,

	event = function(state, ev, _cx)
		local kind = ev.ev
		if kind == "action" and (ev.act == "tab_spend" or ev.act == "tab_search") then
			if state.budget_edit == nil then
				if ev.act == "tab_spend" and state.mode ~= "spend" then
					to_spend(state)
				elseif ev.act == "tab_search" and (state.mode :: string) ~= "search" then
					to_search(state)
				else
					focus_owner(state)
				end
			end
			return
		end
		if kind == "select" and (ev.item == "search" or ev.item == "spend") then
			if state.budget_edit ~= nil then
				return
			end
			if ev.item == "spend" then
				if state.mode ~= "spend" then
					to_spend(state)
				else
					focus_owner(state)
				end
			elseif state.mode ~= "search" then
				to_search(state)
			else
				focus_owner(state)
			end
		elseif kind == "select" or kind == "activate" then
			local list, key = U.parse_item(ev.item)
			if list == "results" and state.mode == "search" and state.results then
				for i, r in state.results :: { any } do
					if r.id == key then
						state.sel_idx = i
					end
				end
				if kind == "activate" then
					delegate(state, function(s)
						return S.act(s, "open")
					end)
				else
					U.focus_later(state.cx, "main.query")
				end
			elseif list == "top" and state.mode == "spend" and type(state.spend) == "table" then
				local top: any = (state.spend :: any).top
				for i, r in (if type(top) == "table" then top else {}) :: { any } do
					if r.id == key then
						state.spend_sel = i
					end
				end
				if kind == "activate" then
					delegate(state, function(s)
						return P.act(s, "open")
					end)
				else
					focus_owner(state)
				end
			end
		elseif kind == "action" then
			local act = ev.act
			if state.budget_edit ~= nil then
				delegate(state, function(s)
					return P.act(s, act)
				end)
			elseif state.mode == "detail" then
				delegate(state, function(s)
					return D.act(s, act)
				end)
			elseif state.mode == "spend" then
				delegate(state, function(s)
					return P.act(s, act)
				end)
			else
				delegate(state, function(s)
					return S.act(s, act)
				end)
			end
		elseif kind == "focus" then
			local owner = if state.budget_edit ~= nil then "layer.budget.amount" elseif state.mode == "search" then "main.query" else U.KEYS_ID
			if ev.id ~= owner then
				U.focus_later(state.cx, owner)
			end
		end
	end,
}

return def
