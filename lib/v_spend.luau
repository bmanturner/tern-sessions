--!strict
-- lib/v_spend.luau : the spend ledger: today / week / month, 14 daily bars, the costliest projects,
-- models and sessions of the last 30 days, and the daily budget (edited in an overlay).
local U = require("./ui")
local D = require("./v_detail")
local S = require("./v_search")
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

function P.load(state: State, force: boolean)
	if state.spend_loading then
		return
	end
	state.spend_loading = true
	sync.run(force, function(note)
		state.spend_note = note
		if not db.has_stats() then
			state.spend_loading = false
			state.spend = nil
			state.spend_err = "No spend data yet. omp records it in ~/.omp/stats.db; run omp stats once in a terminal, then press R."
			U.render(state)
			return
		end
		db.run(query.spend_sql(), function(v, err)
			state.spend_loading = false
			if type(v) == "table" then
				state.spend = v
				state.spend_err = nil
				state.spend_at = tern.now()
				if type(v.today) == "number" then
					state.today = v.today
				end
			else
				state.spend_err = err or "No spend data."
			end
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

local function bars(days: { any }): { Node }
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
		table.insert(
			out,
			ui.el("div", {
				key = "d" .. i,
				class = "tsn-bar",
				title = day_label(tostring(d.d)) .. " · " .. money(c),
				attrs = { ["data-h"] = bucket, ["data-o"] = if i == #days then "today" else "ok" },
			})
		)
	end
	return {
		ui.el("div", { key = "bars", class = "tsn-bars" }, out),
		U.text({ ui.span(string.format("%d days · %s · avg %s/day", #days, money(total), money(if #days > 0 then total / #days else 0)), "muted") }, "bars-sum"),
	}
end

-- A titled list of `{c = cost}` rows, as one keyed column.
local function money_list(key: string, head: string, rows: { any }, label: (any) -> string): Node
	local ui = tern.ui
	local items: { Node } = {}
	for i, r in rows do
		table.insert(
			items,
			ui.node("item", {
				key = tostring(i),
				label = { ui.span(label(r)) },
				value = { ui.span(money(r.c)) },
			})
		)
	end
	return U.with(ui.col({ U.text({ ui.span(head, "dim") }, "head"), ui.node("list", { key = "rows" }, items) }), { key = key })
end

function P.view(state: State): (Node, Node, Node?)
	local ui = tern.ui
	local now = os.time()
	local limit = settings.get().daily_budget
	local status = if state.spend_loading then "updating…" else ""
	local children: { Node } = { S.header(state, status) }
	local s: any = state.spend
	if state.spend_err ~= nil and s == nil then
		table.insert(children, cards.error("No spend to show", state.spend_err :: string, { retry = "refresh" }))
	elseif type(s) ~= "table" then
		table.insert(children, cards.loading("Adding up spend…"))
	else
		local line = string.format("Today %s · This week %s · This month %s", money(s.today), money(s.week), money(s.month))
		if limit > 0 then
			line ..= " · Budget " .. money(limit) .. "/day"
		end
		table.insert(children, U.text({ ui.span(line, "strong") }, "totals"))
		if limit > 0 then
			local today = num(s.today) or 0
			table.insert(
				children,
				U.with(ui.meter(math.min(1, today / limit), { ui.span(string.format("%d%% of today's budget", math.floor(100 * today / limit + 0.5)), "muted") }), {
					key = "meter",
					thresholds = { warn = 0.8, bad = 1 },
				})
			)
		end
		local note = "API-equivalent estimates from omp stats."
		if state.spend_note then
			note ..= " " .. (state.spend_note :: string)
		end
		table.insert(children, U.text({ ui.span(note, "muted") }, "note"))

		local days: { any } = if type(s.days) == "table" then s.days else {}
		for _, n in bars(days) do
			table.insert(children, n)
		end

		local folders: { any } = if type(s.folders) == "table" then s.folders else {}
		local models: { any } = if type(s.models) == "table" then s.models else {}
		local cols: { Node } = {}
		if #folders > 0 then
			table.insert(cols, money_list("folders", "BY PROJECT (30 days)", folders, function(r)
				return if str(r.cwd) then U.tilde(r.cwd) else tostring(r.f)
			end))
		end
		if #models > 0 then
			table.insert(cols, money_list("models", "BY MODEL (30 days)", models, function(r)
				return str(r.m) or "unknown"
			end))
		end
		if #cols == 2 and U.tier(state.cx.cols) >= 3 then
			table.insert(children, ui.el("div", { key = "split", class = "tsn-split" }, cols))
		else
			for _, c in cols do
				table.insert(children, c)
			end
		end
		local list = top(state)
		if #list > 0 then
			table.insert(children, U.text({ ui.span("TOP SESSIONS (30 days)", "dim") }, "h-top"))
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
						label = { ui.span(D.clip(str(r.title) or "Untitled session", 80), "strong") },
						detail = { ui.span(table.concat(parts, " · "), "muted") },
						value = { ui.span(U.cost_text(r.cost)) },
						icon = "history",
					})
				)
			end
			local sel = list[state.spend_sel]
			table.insert(children, ui.node("list", { key = "top", selected = if sel then U.item_id("top", sel.id) else nil }, items))
		end
	end

	local dock: { Node } = {}
	if state.notice then
		table.insert(dock, U.text({ ui.span(state.notice :: string, "muted") }, "notice"))
	end
	table.insert(
		dock,
		U.with(ui.row({
			U.badge(if limit > 0 then "Budget " .. money(limit) .. " b" else "Set budget b", "neutral", "budget", "b-budget"),
			U.badge("Refresh ⇧R", "neutral", "refresh", "b-refresh"),
		}), { key = "acts" })
	)
	table.insert(dock, U.hints({ { "⏎", "details" }, { "b", "budget" }, { "⇧R", "refresh" }, { "⇥", "search" } }))

	local layer: Node? = nil
	local f = state.budget_edit
	if f ~= nil then
		local body: { Node } = {
			ui.node("input", {
				key = "amount",
				text = f.text,
				cursor = textfield.utf16(f),
				placeholder = "Dollars per day, 0 to turn off",
				prompt = { ui.span("$ ", "muted") },
			}),
		}
		if state.budget_err then
			table.insert(body, U.text({ ui.span(state.budget_err :: string, "error") }, "err"))
		end
		table.insert(body, U.text({ ui.span("Over it, you get one notification a day.", "muted") }, "about"))
		table.insert(body, U.hints({ { "⏎", "save" }, { "esc", "cancel" } }, "keys"))
		layer = ui.col({ ui.node("overlay", { key = "budget", head = "Daily budget", size = "sm", modal = true }, body) })
	end
	return ui.col(children), ui.col(dock), layer
end

function P.edit_budget(state: State)
	local limit = settings.get().daily_budget
	state.budget_edit = textfield.new(if limit > 0 then tostring(limit) else "")
	state.budget_err = nil
	U.focus(state.cx, "layer.budget.amount")
end

local function budget_key(state: State, k: Key): boolean
	local f = state.budget_edit :: textfield.Field
	if k.name == "escape" then
		state.budget_edit = nil
		state.budget_err = nil
		U.focus(state.cx, nil)
		return true
	elseif k.name == "enter" then
		local n = tonumber((f.text:gsub("[$,%s]", "")))
		if f.text:match("^%s*$") then
			n = 0
		end
		if n == nil or n < 0 or n ~= n or n == math.huge then
			state.budget_err = "Enter an amount like 25, or 0 to turn it off."
			return true
		end
		settings.set({ daily_budget = n })
		state.budget_edit = nil
		state.budget_err = nil
		U.focus(state.cx, nil)
		budget.check()
		return true
	end
	if textfield.key(f, k, false) then
		state.budget_err = nil
		return true
	end
	return false
end

function P.move(state: State, delta: number): boolean
	local list = top(state)
	if #list == 0 then
		return false
	end
	local i = math.clamp(state.spend_sel + delta, 1, #list)
	if i == state.spend_sel then
		return false
	end
	state.spend_sel = i
	return true
end

function P.act(state: State, act: string): boolean
	if act == "budget" then
		P.edit_budget(state)
	elseif act == "refresh" then
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
		return P.move(state, -1)
	elseif name == "down" then
		return P.move(state, 1)
	elseif name == "enter" then
		return P.act(state, "open")
	elseif name == "b" then
		return P.act(state, "budget")
	elseif name == "R" or (name == "r" and k.shift) then
		return P.act(state, "refresh")
	end
	return false
end

return P
