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
	state.debounce += 1 -- a pending debounce timer would only repeat this search
	local my = state.seq
	state.searching = true
	local parsed = query.parse(state.q.text)
	state.parsed = parsed
	db.run(query.search_sql(parsed, db.has_stats()), function(v, err)
		if state.seq ~= my then
			return
		end
		state.searching = false
		state.pending = false
		if err ~= nil then
			state.err = err
			state.results = nil
		else
			state.err = nil
			state.results = if type(v) == "table" then v else {}
		end
		local n = if state.results then #(state.results :: { any }) else 0
		state.sel_idx = math.clamp(state.sel_idx, 1, math.max(1, n))
		local queued = state.after
		state.after = nil
		if queued ~= nil then
			S.act(state, queued)
		end
		U.refocus(state)
		U.render(state)
	end, "search")
end

-- The query text changed: results are stale until the next run lands.
local function stale(state: State)
	state.pending = true
	state.after = nil
	state.sel_idx = 1
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

-- The `repo:` token for the hint folder: its last two path segments (`acme/web`) when both
-- are space-free, else the longest space-free part of its name.
local function folder_token(state: State): string?
	local cwd = state.cwd_hint
	if type(cwd) ~= "string" then
		return nil
	end
	local parent, base = cwd:match("([^/]+)/([^/]+)/*$")
	if parent ~= nil and base ~= nil and not parent:find("%s") and not base:find("%s") then
		return "repo:" .. parent .. "/" .. base
	end
	local name = cwd:match("([^/]+)/*$")
	if name == nil then
		return nil
	end
	local best = ""
	for part in name:gmatch("%S+") do
		if #part > #best then
			best = part
		end
	end
	return "repo:" .. best
end

local HIT_ICON = { title = "type", recap = "note", prompt = "message" }
local HIT_NAME = { title = "title", recap = "recap", prompt = "prompt" }

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
	local when = if started then U.when_text(started, now) else ""
	local value: string
	if num(r.cost) and (tier < 3 or when == "") then
		value = U.cost_text(r.cost)
	elseif num(r.cost) then
		value = when .. " · " .. U.cost_text(r.cost)
	else
		value = when
	end
	local label = if r.hit == "title" then U.snippet_spans(U.mark(title, words), "strong") else { ui.span(title, "strong") }
	local aria: { string } = { title }
	if str(r.cwd) then
		table.insert(aria, U.tilde(r.cwd))
	end
	if value ~= "" then
		table.insert(aria, value)
	end
	local hit = if type(r.hit) == "string" then r.hit else nil
	return ui.node("item", {
		key = r.id,
		label = label,
		detail = if tier >= 2 then detail else nil,
		value = { ui.span(value, "muted") },
		icon = if hit then HIT_ICON[hit] else nil,
		title = if hit then "Matched in " .. HIT_NAME[hit] else nil,
		tone = "muted",
		aria = table.concat(aria, ", "),
	})
end

local function count_text(results: { any }?): string?
	if results == nil or #results == 0 then
		return nil
	elseif #results >= LIMIT then
		return LIMIT .. "+ sessions"
	end
	return string.format("%d session%s", #results, if #results == 1 then "" else "s")
end

-- Input decorations for the filter tokens of the text as it is now.
local function decor(text: string): { any }
	local out: { any } = {}
	local live: any = query.parse(text)
	for _, t in live.tokens do
		table.insert(out, {
			from = U.utf16_at(text, t.from),
			to = U.utf16_at(text, t.to + 1),
			s = if t.kind == "invalid" then "warning typo" else "accent",
		})
	end
	return out
end

function S.view(state: State): (Node, Node)
	local ui = tern.ui
	local now = os.time()
	local tier = U.tier(state.cx.cols)
	local results = state.results
	local children: { Node } = {
		U.header(state, {
			count = count_text(results),
			busy = if state.pending or state.searching then "Searching…" else nil,
		}),
	}
	table.insert(
		children,
		ui.node("input", {
			key = "query",
			text = state.q.text,
			cursor = textfield.utf16(state.q),
			decor = decor(state.q.text),
			placeholder = "Search sessions, or try repo:web model:opus cost>5",
			prompt = { ui.span("/ ", "muted") },
			aria = "Search sessions",
		})
	)
	local p: any = state.parsed
	if type(p) == "table" and #p.errors > 0 then
		table.insert(children, U.text({ ui.span("⚠ " .. table.concat(p.errors, " · "), "warning") }, "perr"))
	end
	local has_filter = filtered(p)
	if state.err ~= nil then
		table.insert(children, U.error_card(state.err :: any, "retry"))
	elseif results ~= nil then
		if #results == 0 and not has_filter then
			table.insert(children, cards.empty("No omp sessions yet", "Sessions appear here after you use omp."))
		else
			local items: { Node } = {}
			local words: { string } = if type(p) == "table" then p.words else {}
			for _, r in results do
				table.insert(items, item(r, words, now, tier))
			end
			local sel = S.selected(state)
			table.insert(
				children,
				ui.node("list", {
					key = "results",
					selected = if sel then U.item_id("results", sel.id) else nil,
					max = 0.68,
					empty = {
						ui.span(
							"No sessions match “" .. U.trim(state.q.text) .. "”. Try fewer words, or remove a filter.",
							"muted"
						),
					},
				}, items)
			)
			if #results >= LIMIT then
				table.insert(children, U.text({ ui.span("Showing the first 100. Add words or filters to narrow it.", "muted") }, "limit"))
			end
		end
	end

	local sel: any = S.selected(state)
	local context: Node? = nil
	if sel ~= nil then
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
		if num(sel.requests) then
			table.insert(parts, string.format("%d request%s", sel.requests, if sel.requests == 1 then "" else "s"))
		end
		context = U.text({ ui.span(table.concat(parts, " · "), "muted") }, "context")
	end
	local dock = U.dock(state, {
		context = context,
		notice = state.notice,
		actions = {
			{ label = "Open", key = "enter", act = "open", primary = true, hidden = sel == nil },
			{
				label = if state.launching then "Resuming…" else "Resume",
				key = "ctrl+r",
				act = "resume",
				hidden = sel == nil,
			},
			{ label = "This folder", key = "ctrl+f", act = "folder", hidden = folder_token(state) == nil },
			{ label = "Spend", key = "tab", act = "tab_spend" },
			{ label = "Clear", key = "escape", act = "clear", hidden = state.q.text == "" },
		},
	})
	return ui.col(children), dock
end

function S.move(state: State, to: number): boolean
	local list = state.results
	if list == nil or #list == 0 then
		return false
	end
	local i = math.clamp(to, 1, #list)
	if i == state.sel_idx then
		return false
	end
	state.sel_idx = i
	state.notice = nil
	return true
end

-- Adds or removes `repo:<this folder>` in the query.
local function toggle_folder(state: State): boolean
	local tok = folder_token(state)
	if tok == nil then
		state.notice = "No folder to filter by."
		return true
	end
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
	stale(state)
	S.run(state)
	return true
end

function S.act(state: State, act: string): boolean
	if act == "open" or act == "resume" then
		if state.pending or state.searching then
			-- Results are about to change: act on the new row once they land.
			state.after = act :: "open" | "resume"
			if state.pending then
				S.run(state)
			end
			return true
		end
		local sel = S.selected(state)
		if sel == nil then
			return false
		end
		if act == "open" then
			D.open(state, sel.id, "search")
		else
			D.launch(state, sel, "resume")
		end
		return true
	elseif act == "folder" then
		return toggle_folder(state)
	elseif act == "clear" then
		if state.q.text == "" then
			return false
		end
		textfield.set(state.q, "")
		state.notice = nil
		stale(state)
		S.run(state)
		return true
	elseif act == "retry" then
		state.err = nil
		S.run(state)
		return true
	end
	return false
end

function S.key(state: State, k: Key): boolean
	local name = k.name
	if name == "up" then
		return S.move(state, state.sel_idx - 1)
	elseif name == "down" then
		return S.move(state, state.sel_idx + 1)
	elseif name == "page_up" then
		return S.move(state, state.sel_idx - 10)
	elseif name == "page_down" then
		return S.move(state, state.sel_idx + 10)
	elseif name == "home" then
		return S.move(state, 1)
	elseif name == "end" then
		return S.move(state, math.huge)
	elseif name == "enter" then
		return S.act(state, "open")
	elseif name == "escape" then
		if state.q.text == "" and state.notice == nil then
			return false
		end
		if state.q.text ~= "" then
			return S.act(state, "clear")
		end
		state.notice = nil
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
		stale(state)
		S.schedule(state)
		return true
	end
	return false
end

return S
