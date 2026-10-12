--!strict
-- lib/ui.luau : the manager's state type and small view helpers shared by lib/v_*.luau. Calls tern.*
-- only inside functions.
local textfield = require("./textfield")
local cards = require("./cards")
local db = require("./db")

local U = {}

export type State = {
	cx: BlockCx,
	pane_id: string,
	mode: "search" | "spend" | "detail",
	back: "search" | "spend",
	q: textfield.Field,
	parsed: any?,
	results: { any }?,
	sel_idx: number,
	searching: boolean,
	seq: number,
	debounce: number,
	err: db.DbError?,
	detail_id: string?,
	detail: any?,
	detail_err: any?,
	spend: any?,
	spend_at: number,
	spend_err: any?,
	spend_note: string?,
	spend_sel: number,
	spend_loading: boolean,
	budget_edit: textfield.Field?,
	budget_err: string?,
	notice: string?,
	cwd_hint: string?,
	today: number?,
	pending: boolean,
	after: ("open" | "resume")?,
	launching: boolean,
	sel_id: string?,
	spend_sel_id: string?,
	prompt_sel: number,
}

function U.trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

-- `node` with `props` merged into its props.
function U.with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

function U.badge(label: string, tone: string, act: string, key: string, value: string?): Node
	local click = if value ~= nil then act .. "=" .. value else act
	return U.with(tern.ui.badge(label, tone), { key = key, actions = { click = click } })
end

function U.text(spans: Spans, key: string): Node
	return U.with(tern.ui.text(spans), { key = key })
end

function U.home(): string
	return tern.getenv("HOME") or ""
end

-- `path` with a leading $HOME shown as ~.
function U.tilde(path: string?): string
	if type(path) ~= "string" then
		return ""
	end
	local h = U.home()
	if h ~= "" and h ~= "/" and path:sub(1, #h) == h and (#path == #h or path:sub(#h + 1, #h + 1) == "/") then
		return "~" .. path:sub(#h + 1)
	end
	return path
end

-- Posts a toast; the pane may be gone.
function U.toast(state: State, level: "success" | "info" | "error", text: string, sub: string?)
	pcall(function()
		state.cx:toast(level, text, sub)
	end)
end

-- Sends a raw `focus` frame op.
function U.focus(cx: BlockCx, target: string)
	pcall(function()
		cx:frame({ { "focus", target } })
	end)
end

-- Focuses `id` after the current render, for nodes drawn by that same render.
function U.focus_later(cx: BlockCx, id: string)
	tern.timer(0, function()
		U.focus(cx, id)
	end)
end

-- Sends the current focus owner: the budget field, the search query, or the hidden dock input.
function U.refocus(state: State)
	if state.budget_edit ~= nil then
		U.focus_later(state.cx, "layer.budget.amount")
	elseif state.mode == "search" then
		U.focus_later(state.cx, "main.query")
	else
		U.focus_later(state.cx, U.KEYS_ID)
	end
end

-- Seconds as "14h", "12m", "2h 20m" (minutes dropped over 3 h), "3d".
function U.span_text(secs: number): string
	local s = math.max(0, secs)
	if s < 60 then
		return "<1m"
	elseif s < 3600 then
		return string.format("%dm", s // 60)
	elseif s < 10800 then
		local m = (s % 3600) // 60
		return if m == 0 then string.format("%dh", s // 3600) else string.format("%dh %dm", s // 3600, m)
	elseif s < 86400 then
		return string.format("%dh", s // 3600)
	end
	return string.format("%dd", s // 86400)
end

function U.abs(t: number): string
	return (string.gsub(os.date("%a %d %b %H:%M", t), "^(%a+) 0", "%1 "))
end

local function day_key(t: number): string
	return os.date("%Y-%m-%d", t)
end

-- Time today, "yesterday 09:00", "Mon 09:00" within 6 days, else "12 Oct 09:00" (with the year
-- when it isn't this year).
function U.when_text(t: number, now: number): string
	local hm = os.date("%H:%M", t)
	if day_key(t) == day_key(now) then
		return hm
	elseif day_key(t) == day_key(now - 86400) then
		return "yesterday " .. hm
	elseif math.abs(t - now) < 6 * 86400 then
		return os.date("%a ", t) .. hm
	elseif os.date("%Y", t) ~= os.date("%Y", now) then
		return (string.gsub(os.date("%d %b %Y", t), "^0", ""))
	end
	return (string.gsub(os.date("%d %b ", t), "^0", "")) .. hm
end

function U.cost_text(cost: any): string
	if type(cost) ~= "number" then
		return "—"
	elseif cost < 0.005 then
		return "<$0.01"
	end
	return string.format("$%.2f", cost)
end

function U.duration_text(secs: number): string
	local s = math.max(0, math.floor(secs))
	if s < 60 then
		return string.format("%ds", s)
	elseif s < 3600 then
		return string.format("%dm %02ds", s // 60, s % 60)
	end
	return string.format("%dh %02dm", s // 3600, (s % 3600) // 60)
end

-- Width tiers of the main region: 4 everything, 3 drops request counts, 2 drops folders, 1 title only.
function U.tier(cols: number): number
	if cols >= 100 then
		return 4
	elseif cols >= 80 then
		return 3
	elseif cols >= 60 then
		return 2
	end
	return 1
end

function U.arr<T>(t: T): T
	return tern.json.array(t)
end

-- Key hints: `{{key, what}, …}` as keycap spans (key ids like "enter", "ctrl+r").
function U.hints(pairs: { { string } }, key: string?): Node
	local ui = tern.ui
	local spans: { Span | string } = {}
	for i, pair in pairs do
		if i > 1 then
			table.insert(spans, ui.span("  ", "muted"))
		end
		table.insert(spans, ui.span(pair[1], "key"))
		table.insert(spans, ui.span(" " .. pair[2], "muted"))
	end
	return U.text(spans, key or "hints")
end

-- The tab strip: Search (with `opts.count` muted after it) and Spend over a hairline, plus a
-- dots spinner labelled `opts.busy` at the end. Clicks arrive as a `select` event whose `item` is
-- "search" or "spend".
function U.header(state: State, opts: { count: string?, busy: string? }): Node
	local ui = tern.ui
	local search_label: { Span | string } = { ui.span("Search") }
	if opts.count ~= nil and opts.count ~= "" then
		table.insert(search_label, ui.span("  " .. (opts.count :: string), "muted"))
	end
	local tabs = ui.node("tabs", {
		key = "tabs",
		active = if state.mode == "spend" then "spend" else "search",
		items = {
			{ id = "search", label = search_label },
			{ id = "spend", label = { ui.span("Spend") } },
		},
	})
	local children: { Node } = { tabs }
	if opts.busy ~= nil then
		table.insert(children, ui.node("spinner", { key = "busy", style = "dots", label = opts.busy }))
	end
	return U.with(ui.row(children), { key = "header", gap = "md" })
end

-- Focus id of the hidden input that owns the keyboard in spend and detail modes.
U.KEYS_ID = "dock.keys"

export type DockAction = { label: string, key: string, act: string, primary: boolean?, hidden: boolean? }

-- The dock: `notice` (muted) or `context` above one status strip of clickable actions, each a
-- verb followed by its keycap. Outside search mode it also holds the hidden input that takes focus.
function U.dock(state: State, opts: { context: Node?, notice: string?, actions: { DockAction } }): Node
	local ui = tern.ui
	local children: { Node } = {}
	if opts.notice ~= nil then
		table.insert(children, U.text({ ui.span(opts.notice :: string, "muted") }, "notice"))
	elseif opts.context ~= nil then
		table.insert(children, opts.context :: Node)
	end
	local segs: { Node } = {}
	for _, a in opts.actions do
		if a.hidden ~= true then
			table.insert(
				segs,
				ui.node("seg", {
					key = "a-" .. a.act,
					spans = { ui.span(a.label .. " "), ui.span(a.key, "key") },
					tone = if a.primary then "accent" else nil,
					actions = { click = a.act },
				})
			)
		end
	end
	table.insert(children, ui.node("status", { key = "bar", transparent = true, aria = "Actions" }, segs))
	if state.mode ~= "search" then
		table.insert(children, ui.node("input", { key = "keys", text = "", readonly = true, aria = "Agent Sessions keys" }))
	end
	return ui.col(children)
end

-- UTF-16 units of `s` before byte index `byte` (the input node counts cursor and decor in UTF-16).
function U.utf16_at(s: string, byte: number): number
	local head = s:sub(1, math.max(0, byte - 1))
	local ok, n = pcall(function()
		local units = 0
		for _, cp in utf8.codes(head) do
			units += if cp >= 0x10000 then 2 else 1
		end
		return units
	end)
	return if ok then n :: number else #head
end

-- The error card for a db failure; Retry sends `retry_act`.
function U.error_card(err: db.DbError, retry_act: string?): Node
	if err.kind == "no_history" then
		return cards.with(cards.empty("No omp sessions yet", err.message), { key = "err" })
	elseif err.kind == "no_sqlite" then
		local fixes: { string }? = if tern.runtime.os == "linux" then { "sudo apt install sqlite3" } else nil
		return cards.with(cards.error("SQLite is missing", err.message, { fixes = fixes }), { key = "err" })
	end
	local title = if err.kind == "busy" then "omp's database is busy" elseif err.kind == "timeout" then "The search timed out" else "Couldn't read omp's database"
	return cards.with(cards.error(title, err.message, { detail = err.detail, retry = retry_act }), { key = "err" })
end

-- `text` with every case-insensitive occurrence of `words` wrapped in «», as FTS snippets are.
function U.mark(text: string, words: { string }): string
	local lower = text:lower()
	local hits: { { number } } = {}
	for _, w in words do
		local lw = w:lower()
		if lw ~= "" then
			local from = 1
			while true do
				local a, b = lower:find(lw, from, true)
				if a == nil then
					break
				end
				table.insert(hits, { a, b :: number })
				from = (b :: number) + 1
			end
		end
	end
	if #hits == 0 then
		return text
	end
	table.sort(hits, function(x, y)
		return x[1] < y[1]
	end)
	local out: { string } = {}
	local pos = 1
	for _, h in hits do
		if h[1] >= pos then
			table.insert(out, text:sub(pos, h[1] - 1))
			table.insert(out, "«" .. text:sub(h[1], h[2]) .. "»")
			pos = h[2] + 1
		end
	end
	table.insert(out, text:sub(pos))
	return table.concat(out)
end

-- FTS snippet text with «matches» as marked spans. `base` styles unmarked text (default "muted").
function U.snippet_spans(text: string, base: string?): { Span | string }
	local plain = base or "muted"
	local mark = if plain == "muted" then "mark" else plain .. " mark"
	local ui = tern.ui
	local s = U.trim((text:gsub("%s+", " ")))
	local out: { Span | string } = {}
	local i = 1
	while i <= #s do
		local a, b = s:find("«", i, true)
		if a == nil then
			table.insert(out, ui.span(s:sub(i), plain))
			break
		end
		if a > i then
			table.insert(out, ui.span(s:sub(i, a - 1), plain))
		end
		local c, d = s:find("»", (b :: number) + 1, true)
		if c == nil then
			table.insert(out, ui.span(s:sub((b :: number) + 1), mark))
			break
		end
		table.insert(out, ui.span(s:sub((b :: number) + 1, c - 1), mark))
		i = (d :: number) + 1
	end
	return out
end

-- The item id of row `key` in list `list`, and the reverse.
function U.item_id(list: string, key: string): string
	return "main." .. list .. "." .. key
end

function U.parse_item(item: any): (string?, string?)
	if type(item) ~= "string" then
		return nil, nil
	end
	local list, key = string.match(item, "^main%.([%w_]+)%.([%w%-]+)$")
	return list, key
end

-- Re-renders after an async callback; the pane may be gone by then.
function U.render(state: State)
	pcall(function()
		state.cx:render()
	end)
end

return U
