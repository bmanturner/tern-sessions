--!strict
-- lib/v_search.luau : the search view: a query field over ranked sessions.
local U = require("./ui")
local D = require("./v_detail")
local db = require("./db")
local query = require("./query")
local textfield = require("./textfield")
local cards = require("./cards")

type State = U.State

local S = {}

local DEBOUNCE_MS = 200
local LIMIT = 100

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

function S.run(state: State)
	state.seq += 1
	local my = state.seq
	state.searching = true
	local parsed = query.parse(state.q.text)
	state.parsed = parsed
	db.run(query.search_sql(parsed, db.has_stats()), function(v, err)
		if state.seq ~= my then
			return
		end
		state.searching = false
		if err ~= nil then
			state.err = err
			state.results = nil
		else
			state.err = nil
			state.results = if type(v) == "table" then v else {}
		end
		local n = if state.results then #(state.results :: { any }) else 0
		state.sel_idx = math.clamp(state.sel_idx, 1, math.max(1, n))
		U.render(state)
	end)
end

-- Runs the search once typing pauses.
function S.schedule(state: State)
	state.debounce += 1
	local my = state.debounce
	tern.timer(DEBOUNCE_MS, function()
		if state.debounce == my then
			S.run(state)
		end
	end)
end

function S.selected(state: State): any?
	local list = state.results
	if list == nil then
		return nil
	end
	return list[state.sel_idx]
end

local function filtered(p: any): boolean
	return type(p) == "table"
		and (#p.words > 0 or #p.repo > 0 or #p.model > 0 or p.after ~= nil or p.before ~= nil or p.cost_min ~= nil or p.cost_max ~= nil)
end

-- The header shared by the search and spend views: title, tab badges, a status.
function S.header(state: State, status: string): Node
	local ui = tern.ui
	local on = if state.mode == "spend" then "spend" else "search"
	return U.with(
		ui.row({
			U.text({ ui.span("Agent Sessions", "strong") }, "title"),
			U.badge("Search", if on == "search" then "accent" else "neutral", "tab", "t-search", "search"),
			U.badge("Spend", if on == "spend" then "accent" else "neutral", "tab", "t-spend", "spend"),
			U.text({ ui.span(status, "muted") }, "status"),
		}),
		{ key = "header", gap = "sm" }
	)
end

local function item(r: any, words: { string }, now: number, tier: number): Node
	local ui = tern.ui
	local title = str(r.title) or "Untitled session"
	local detail: { Span | string }
	if str(r.snip) then
		-- Recap text comes back whole; prompt snippets are already marked by FTS.
		detail = U.snippet_spans(if r.hit == "recap" then U.mark(r.snip, words) else r.snip)
	else
		local parts: { string } = {}
		if tier >= 2 and str(r.cwd) then
			table.insert(parts, U.tilde(r.cwd))
		end
		if str(r.models) then
			table.insert(parts, ((r.models :: string):match("^[^,]+") or ""))
		end
		if tier >= 4 and num(r.requests) then
			table.insert(parts, tostring(r.requests) .. " requests")
		end
		detail = { ui.span(table.concat(parts, " · "), "muted") }
	end
	local started = num(r.started)
	local value = if started then U.when_text(started, now) else ""
	if num(r.cost) then
		value ..= " · " .. U.cost_text(r.cost)
	end
	return ui.node("item", {
		key = r.id,
		label = { ui.span(title, "strong") },
		detail = if tier >= 2 then detail else nil,
		value = { ui.span(value, "muted") },
		icon = if r.hit == "prompt" then "message" elseif r.hit == "recap" then "note" else "history",
		aria = title,
	})
end

function S.view(state: State): (Node, Node)
	local ui = tern.ui
	local now = os.time()
	local tier = U.tier(state.cx.cols)
	local results = state.results
	local status = if results then string.format("%d session%s", #results, if #results == 1 then "" else "s") else ""
	if state.searching then
		status ..= (if status ~= "" then " · " else "") .. "searching…"
	end
	local children: { Node } = { S.header(state, status) }
	table.insert(
		children,
		ui.node("input", {
			key = "query",
			text = state.q.text,
			cursor = textfield.utf16(state.q),
			placeholder = "Search sessions: words, repo:app, model:opus, after:2026-10-01, cost>5",
			prompt = { ui.span("/ ", "muted") },
		})
	)
	local p: any = state.parsed
	if type(p) == "table" and #p.errors > 0 then
		table.insert(children, U.text({ ui.span(table.concat(p.errors, " · "), "warning") }, "perr"))
	end
	if state.err ~= nil then
		table.insert(children, cards.error("Search failed", state.err :: string))
	elseif results ~= nil then
		if #results == 0 then
			if filtered(p) then
				table.insert(children, U.text({ ui.span("No sessions match.", "muted") }, "none"))
			else
				table.insert(children, cards.empty("No omp sessions yet", "Sessions appear here after you use omp."))
			end
		else
			local items: { Node } = {}
			local words: { string } = if type(p) == "table" then p.words else {}
			for _, r in results do
				table.insert(items, item(r, words, now, tier))
			end
			local sel = S.selected(state)
			table.insert(
				children,
				ui.node("list", { key = "results", selected = if sel then U.item_id("results", sel.id) else nil }, items)
			)
			if #results >= LIMIT then
				table.insert(children, U.text({ ui.span("Showing the best 100. Add words or filters to narrow it.", "muted") }, "limit"))
			end
		end
	end

	local dock: { Node } = {}
	local sel: any = S.selected(state)
	if state.notice then
		table.insert(dock, U.text({ ui.span(state.notice :: string, "muted") }, "notice"))
	elseif sel ~= nil then
		local parts: { string } = {}
		if str(sel.cwd) then
			table.insert(parts, U.tilde(sel.cwd))
		end
		if num(sel.started) then
			table.insert(parts, U.abs(sel.started))
		end
		if num(sel.started) and num(sel.ended) then
			table.insert(parts, U.duration_text(sel.ended - sel.started))
		end
		table.insert(
			dock,
			U.text({ ui.span(D.clip(str(sel.title) or "Untitled session", 80)), ui.span("  " .. table.concat(parts, " · "), "muted") }, "context")
		)
	end
	if sel ~= nil then
		table.insert(
			dock,
			U.with(ui.row({ U.badge("Open ⏎", "accent", "open", "b-open"), U.badge("Resume ^R", "neutral", "resume", "b-resume") }), { key = "acts" })
		)
	end
	table.insert(dock, U.hints({ { "⏎", "details" }, { "^R", "resume" }, { "^F", "this folder" }, { "⇥", "spend" }, { "esc", "clear" } }))
	return ui.col(children), ui.col(dock)
end

-- Adds or removes `repo:<this folder>` in the query.
local function toggle_folder(state: State): boolean
	local cwd = state.cwd_hint
	local base = if type(cwd) == "string" then cwd:match("([^/]+)/*$") else nil
	if base == nil then
		state.notice = "No folder to filter by."
		return true
	end
	-- A token can't hold spaces; the longest space-free part still narrows to that folder.
	local best = ""
	for part in base:gmatch("%S+") do
		if #part > #best then
			best = part
		end
	end
	local tok = "repo:" .. best
	local words: { string } = {}
	local had = false
	for w in state.q.text:gmatch("%S+") do
		if w:lower() == tok:lower() then
			had = true
		else
			table.insert(words, w)
		end
	end
	if not had then
		table.insert(words, tok)
	end
	textfield.set(state.q, table.concat(words, " ") .. (if had then "" else " "))
	state.notice = nil
	S.run(state)
	return true
end

function S.move(state: State, delta: number): boolean
	local list = state.results
	if list == nil or #list == 0 then
		return false
	end
	local i = math.clamp(state.sel_idx + delta, 1, #list)
	if i == state.sel_idx then
		return false
	end
	state.sel_idx = i
	return true
end

function S.act(state: State, act: string): boolean
	local sel = S.selected(state)
	if act == "open" then
		if sel == nil then
			return false
		end
		D.open(state, sel.id, "search")
	elseif act == "resume" then
		if sel == nil then
			return false
		end
		D.launch(state, sel, "resume")
	else
		return false
	end
	return true
end

function S.key(state: State, k: Key): boolean
	local name = k.name
	if name == "up" then
		return S.move(state, -1)
	elseif name == "down" then
		return S.move(state, 1)
	elseif name == "pageup" then
		return S.move(state, -10)
	elseif name == "pagedown" then
		return S.move(state, 10)
	elseif name == "enter" then
		return S.act(state, "open")
	elseif name == "escape" then
		if state.q.text == "" and state.notice == nil then
			return false
		end
		state.notice = nil
		if state.q.text ~= "" then
			textfield.set(state.q, "")
			S.run(state)
		end
		return true
	elseif k.ctrl and name == "r" then
		return S.act(state, "resume")
	elseif k.ctrl and name == "f" then
		return toggle_folder(state)
	elseif (k.ctrl or k.meta or k.alt) and not (name == "backspace" or name == "left" or name == "right" or name == "paste") then
		return false
	end
	if textfield.key(state.q, k, false) then
		state.notice = nil
		state.sel_idx = 1
		S.schedule(state)
		return true
	end
	return false
end

return S
