--!strict
-- lib/v_spend.luau : the spend ledger: today / week / month, 14 daily bars, the costliest projects,
-- models and sessions of the last 30 days, and the daily budget (edited in an overlay).
local U = require("./ui")
local D = require("./v_detail")
local budget = require("./budget")
local cards = require("./cards")
local db = require("./db")
local query = require("./query")
local settings = require("./settings")
local sync = require("./sync")
local textfield = require("./textfield")

type State = U.State

local P = {}

local STALE_MS = 60000

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

local function money(n: any): string
	return string.format("$%.2f", num(n) or 0)
end


local NO_STATS = {
	kind = "no_stats",
	message = "omp records costs once you've run omp stats.",
}

function P.load(state: State, force: boolean)
	if state.spend_loading then
		return
	end
	if not db.has_history() then
		local paths = db.paths()
		state.spend = nil
		state.spend_err = { kind = "no_history", message = "Run omp once and your sessions will appear here.", detail = paths.history }
		U.render(state)
		return
	end
	state.spend_loading = true
	sync.run(force, function(note)
		state.spend_note = note
		if not db.has_stats() then
			state.spend_loading = false
			state.spend = nil
			state.spend_err = NO_STATS
			U.refocus(state)
			U.render(state)
			return
		end
		db.run(query.spend_sql(), function(v, err)
			state.spend_loading = false
			if err == nil and type(v) == "table" then
				state.spend = v
				state.spend_err = nil
				state.spend_at = tern.now()
				if type(v.today) == "number" then
					state.today = v.today
				end
			else
				local e: any = err or { kind = "failed", message = "Couldn't read omp's database." }
				state.spend_err = e
				if state.spend ~= nil then
					U.toast(state, "error", "Couldn't refresh spend", e.message)
				end
			end
			U.refocus(state)
			U.render(state)
		end)
	end)
	U.render(state)
end

-- Loads when there is nothing yet or it is over a minute old.
function P.refresh_if_stale(state: State)
	if state.spend == nil or tern.now() - state.spend_at > STALE_MS then
		P.load(state, false)
	end
end

local function top(state: State): { any }
	local s: any = state.spend
	return if type(s) == "table" and type(s.top) == "table" then s.top else {}
end

local function day_label(d: string): string
	local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
	if y == nil then
		return d
	end
	local t = os.time({ year = tonumber(y) :: number, month = tonumber(m) :: number, day = tonumber(dd) :: number, hour = 12 })
	return (os.date("%a %d %b", t) :: string)
end

local function bars(days: { any }, limit: number): { Node }
	local ui = tern.ui
	local maxc, total = 0, 0
	for _, d in days do
		local c = num(d.c) or 0
		maxc = math.max(maxc, c)
		total += c
	end
	local out: { Node } = {}
	for i, d in days do
		local c = num(d.c) or 0
		local bucket = if maxc > 0 then math.floor(20 * c / maxc + 0.5) else 0
		local outcome = if c == 0 then "zero" elseif limit > 0 and c > limit then "over" elseif i == #days then "today" else "day"
		table.insert(
			out,
			ui.el("div", {
				key = "d" .. i,
				class = "tsn-bar",
				title = day_label(tostring(d.d)) .. " · " .. money(c),
				attrs = { ["data-h"] = bucket, ["data-o"] = outcome, ["aria-hidden"] = "true" },
			})
		)
	end
	local nodes: { Node } = {
		ui.el("div", { key = "bars", class = "tsn-bars", attrs = { role = "img", ["aria-label"] = "Daily spend, last 14 days" } }, out),
	}
	if #days > 0 then
		table.insert(
			nodes,
			ui.node("row", { key = "bars-axis", justify = "between" }, {
				U.text({ ui.span(day_label(tostring(days[1].d)), "muted") }, "axis-first"),
				U.text({ ui.span("Today", "muted") }, "axis-last"),
			})
		)
	end
	table.insert(
		nodes,
		U.text({ ui.span(string.format("%d days · %s · avg %s/day", #days, money(total), money(if #days > 0 then total / #days else 0)), "muted") }, "bars-sum")
	)
	return nodes
end

-- One breakdown column: a labelled rule over a table of name, cost and share of the 30-day total.
local function breakdown(key: string, head: string, rows: { any }, total30: number, name: (any) -> string): Node
	local ui = tern.ui
	local trows: { any } = {}
	for i, r in rows do
		local c = num(r.c) or 0
		table.insert(trows, {
			id = tostring(i),
			cells = {
				name = name(r),
				cost = money(c),
				share = { meter = { value = if total30 > 0 then c / total30 else 0, title = string.format("%d%% of 30 days", math.floor(100 * (if total30 > 0 then c / total30 else 0) + 0.5)) } },
			},
		})
	end
	return ui.node("col", { key = key, grow = 1, basis = 0.45, min = { w = "36ch" } }, {
		U.with(ui.rule({ ui.span(head, "dim") }), { key = "rule" }),
		ui.node("table", {
			key = "tbl",
			cols = {
				{ id = "name", grow = 1, truncate = "middle", priority = 3 } :: any,
				{ id = "cost", align = "end", priority = 2 },
				{ id = "share", priority = 1 },
			},
			rows = trows,
		}),
	})
end

local function today_of(state: State): number
	local s: any = state.spend
	return num(state.today) or (if type(s) == "table" then num(s.today) else nil) or 0
end

function P.view(state: State): (Node, Node, Node?)
	local ui = tern.ui
	local now = os.time()
	local limit = settings.get().daily_budget
	local children: { Node } = { U.header(state, { busy = if state.spend_loading then "Updating…" else nil }) }
	local s: any = state.spend
	local err: any = state.spend_err
	if err ~= nil and s == nil then
		if err.kind == "no_stats" then
			table.insert(children, cards.with(cards.error("No spend data yet", err.message, { fixes = { "omp stats" }, retry = "refresh" }), { key = "err" }))
		else
			table.insert(children, U.error_card(err, "refresh"))
		end
	elseif type(s) ~= "table" then
		table.insert(children, cards.with(cards.loading("Loading spend…"), { key = "loading" }))
	else
		local today = today_of(state)
		local today_token = if limit > 0 and today >= limit then "strong error" elseif limit > 0 and today >= 0.8 * limit then "strong warning" else "strong"
		table.insert(
			children,
			U.with(
				ui.kv({
					{ { ui.span("Today", "muted") }, { ui.span(money(today), today_token) } },
					{ { ui.span("This week", "muted") }, { ui.span(money(s.week)) } },
					{ { ui.span("This month", "muted") }, { ui.span(money(s.month)) } },
				}),
				{ key = "totals", layout = "inline" }
			)
		)
		if limit > 0 then
			table.insert(
				children,
				U.with(ui.meter(today / limit, { ui.span(string.format("%s of %s today", money(today), money(limit)), "muted") }), {
					key = "meter",
					size = "md",
					thresholds = { warn = 0.8, bad = 1 },
					max = { w = "60ch" },
				})
			)
		end
		table.insert(children, U.text({ ui.span("Estimated API cost, from omp stats.", "muted") }, "note"))
		if state.spend_note then
			table.insert(children, U.text({ ui.span(state.spend_note :: string, "warning") }, "sync-note"))
		end
		if err ~= nil then
			table.insert(children, U.text({ ui.span("Couldn't refresh: " .. tostring(err.message), "warning") }, "refresh-err"))
		end

		local days: { any } = if type(s.days) == "table" then s.days else {}
		for _, n in bars(days, limit) do
			table.insert(children, n)
		end

		local folders: { any } = if type(s.folders) == "table" then s.folders else {}
		local models: { any } = if type(s.models) == "table" then s.models else {}
		local total30 = num(s.total30) or 0
		local cols: { Node } = {}
		if #folders > 0 then
			table.insert(cols, breakdown("folders", "BY FOLDER · 30 DAYS", folders, total30, function(r)
				return if str(r.cwd) then U.tilde(r.cwd) else tostring(r.f)
			end))
		end
		if #models > 0 then
			table.insert(cols, breakdown("models", "BY MODEL · 30 DAYS", models, total30, function(r)
				return str(r.m) or "unknown"
			end))
		end
		if #cols > 0 then
			table.insert(children, ui.node("row", { key = "breakdowns", gap = "lg", wrap = true, align = "start" }, cols))
		end
		local list = top(state)
		if #list > 0 then
			table.insert(children, U.with(ui.rule({ ui.span("TOP SESSIONS · 30 DAYS", "dim") }), { key = "h-top" }))
			local items: { Node } = {}
			for _, r in list do
				local parts: { string } = {}
				if str(r.cwd) then
					table.insert(parts, U.tilde(r.cwd))
				end
				if num(r.started) then
					table.insert(parts, U.when_text(r.started, now))
				end
				table.insert(
					items,
					ui.node("item", {
						key = r.id,
						label = { ui.span(D.clip(str(r.title) or "Untitled session", 80)) },
						detail = { ui.span(table.concat(parts, " · "), "muted") },
						value = { ui.span(U.cost_text(r.cost), "strong") },
					})
				)
			end
			local sel = list[state.spend_sel]
			table.insert(
				children,
				ui.node("list", {
					key = "top",
					selected = if sel then U.item_id("top", sel.id) else nil,
				}, items)
			)
		end
	end

	local dock = U.dock(state, {
		notice = state.notice,
		actions = {
			{ label = "Open", key = "enter", act = "open", primary = true, hidden = top(state)[state.spend_sel] == nil },
			{ label = "Budget", key = "b", act = "budget", hidden = state.spend == nil },
			{ label = "Refresh", key = "shift+r", act = "refresh" },
			{ label = "Search", key = "tab", act = "tab_search" },
		},
	})

	local layer: Node? = nil
	local f = state.budget_edit
	if f ~= nil then
		local body: { Node } = {
			ui.node("input", {
				key = "amount",
				text = f.text,
				cursor = textfield.utf16(f),
				placeholder = "25",
				prompt = { ui.span("$ ", "muted") },
				aria = "Daily budget in dollars",
			}),
		}
		if state.budget_err then
			table.insert(body, U.text({ ui.span(state.budget_err :: string, "error") }, "err"))
		end
		table.insert(body, U.text({ ui.span("0 turns alerts off.", "muted") }, "helper"))
		table.insert(body, U.text({ ui.span("You'll get one desktop notification the first time a day goes over this.") }, "about"))
		if type(s) == "table" then
			table.insert(body, U.text({ ui.span("Today so far " .. money(today_of(state)), "muted") }, "today"))
		end
		table.insert(
			body,
			ui.node("row", { key = "buttons", gap = "sm" }, {
				U.badge("Save", "accent", "budget_save", "b-save"),
				U.badge("Cancel", "neutral", "budget_cancel", "b-cancel"),
			})
		)
		layer = ui.col({ ui.node("overlay", { key = "budget", head = "Daily budget", aria = "Daily budget", size = "sm", modal = true }, body) })
	end
	return ui.col(children), dock, layer
end

function P.edit_budget(state: State)
	local limit = settings.get().daily_budget
	state.budget_edit = textfield.new(if limit > 0 then tostring(limit) else "")
	state.budget_err = nil
	U.focus_later(state.cx, "layer.budget.amount")
end

local function close_budget(state: State)
	state.budget_edit = nil
	state.budget_err = nil
	U.focus_later(state.cx, U.KEYS_ID)
end

local function save_budget(state: State)
	local f = state.budget_edit
	if f == nil then
		return
	end
	local n = tonumber((f.text:gsub("[$,%s]", "")))
	if f.text:match("^%s*$") then
		n = 0
	end
	if n == nil or n < 0 or n ~= n or n == math.huge then
		state.budget_err = "Enter an amount like 25, or 0 to turn it off."
		return
	end
	settings.set({ daily_budget = n })
	close_budget(state)
	local over = n > 0 and type(state.spend) == "table" and today_of(state) >= n
	U.toast(
		state,
		"success",
		if n > 0 then "Daily budget set to " .. money(n) else "Budget alerts off",
		if over then "Today is already over it, so you'll get one alert now." else nil
	)
	budget.check()
end

local function budget_key(state: State, k: Key): boolean
	local f = state.budget_edit :: textfield.Field
	if k.name == "escape" then
		close_budget(state)
		return true
	elseif k.name == "enter" then
		save_budget(state)
		return true
	end
	if textfield.key(f, k, false) then
		state.budget_err = nil
		return true
	end
	return false
end

local PAGE = 5

local function move_to(state: State, to: number): boolean
	local n = #top(state)
	if n == 0 then
		return false
	end
	local i = math.clamp(to, 1, n)
	if i == state.spend_sel then
		return false
	end
	state.spend_sel = i
	return true
end

function P.act(state: State, act: string): boolean
	if act == "budget_save" then
		if state.budget_edit == nil then
			return false
		end
		save_budget(state)
	elseif act == "budget_cancel" then
		if state.budget_edit == nil then
			return false
		end
		close_budget(state)
	elseif state.budget_edit ~= nil then
		return false
	elseif act == "budget" then
		P.edit_budget(state)
	elseif act == "refresh" then
		if state.spend_loading then
			return false
		end
		P.load(state, true)
	elseif act == "open" then
		local sel = top(state)[state.spend_sel]
		if sel == nil then
			return false
		end
		D.open(state, sel.id, "spend")
	else
		return false
	end
	return true
end

function P.key(state: State, k: Key): boolean
	if state.budget_edit ~= nil then
		return budget_key(state, k)
	end
	local name = k.name
	if k.ctrl or k.meta or k.alt then
		return false
	elseif name == "up" then
		return move_to(state, state.spend_sel - 1)
	elseif name == "down" then
		return move_to(state, state.spend_sel + 1)
	elseif name == "page_up" then
		return move_to(state, state.spend_sel - PAGE)
	elseif name == "page_down" then
		return move_to(state, state.spend_sel + PAGE)
	elseif name == "home" then
		return move_to(state, 1)
	elseif name == "end" then
		return move_to(state, #top(state))
	elseif name == "enter" then
		return P.act(state, "open")
	elseif name == "b" then
		return state.spend ~= nil and P.act(state, "budget")
	elseif name == "R" or (name == "r" and k.shift) then
		return P.act(state, "refresh")
	end
	return false
end

return P
