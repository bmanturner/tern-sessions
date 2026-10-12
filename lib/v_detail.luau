--!strict
-- lib/v_detail.luau : one session: its facts, recaps and first prompts, with resume / fork / copy id.
-- Also owns opening a session (used by the search and spend views too).
local U = require("./ui")
local db = require("./db")
local opener = require("./opener")
local query = require("./query")
local cards = require("./cards")

type State = U.State

local D = {}

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

local function clip(s: string, n: number): string
	local one = (s:gsub("%s+", " "))
	if utf8.len(one) ~= nil and (utf8.len(one) :: number) > n then
		local cut = utf8.offset(one, n) or (n + 1)
		return one:sub(1, cut - 1) .. "…"
	end
	return one
end

D.clip = clip

function D.launch(state: State, sess: any, how: "resume" | "fork")
	if state.launching or type(sess) ~= "table" or str(sess.id) == nil then
		return
	end
	local title = str(sess.title) or "the session"
	state.launching = true
	state.notice = (if how == "fork" then "Forking " else "Resuming ") .. clip(title, 60) .. "…"
	opener.open({ id = sess.id, file = str(sess.file), cwd = str(sess.cwd), title = title }, how, function(ok, note)
		state.launching = false
		state.notice = nil
		if ok then
			U.toast(state, "success", (if how == "fork" then "Forked " else "Resumed ") .. clip(title, 60), note)
		else
			U.toast(state, "error", "Couldn't open the session", note)
		end
		U.render(state)
	end)
end

function D.open(state: State, id: string, back: "search" | "spend")
	state.mode = "detail"
	state.back = back
	state.detail_id = id
	state.detail = nil
	state.detail_err = nil
	state.notice = nil
	state.prompt_sel = 1
	U.focus_later(state.cx, U.KEYS_ID)
	local sql = query.detail_sql(id, db.has_stats())
	if sql == nil then
		state.detail = false
		return
	end
	db.run(sql, function(v, err)
		if state.detail_id ~= id then
			return
		end
		if err ~= nil then
			state.detail_err = err
		elseif type(v) == "table" then
			state.detail = v
		else
			state.detail = false
		end
		U.refocus(state)
		U.render(state)
	end)
end

function D.back(state: State)
	state.mode = state.back
	state.notice = nil
	U.focus_later(state.cx, if state.mode == "search" then "main.query" else U.KEYS_ID)
end

function D.title(state: State): string?
	local d = state.detail
	return if type(d) == "table" then str(d.title) else nil
end

local function kv(label: string, value: string): { Spans }
	return { { tern.ui.span(label, "muted") }, { tern.ui.span(value) } }
end

-- First model plus "+N" for the rest.
local function models_text(models: string): string
	local list: { string } = {}
	for m in models:gmatch("[^,]+") do
		table.insert(list, m)
	end
	if #list == 0 then
		return models
	end
	return if #list > 1 then string.format("%s +%d", list[1], #list - 1) else list[1]
end

local function summary(d: any): string
	local parts: { string } = {}
	if num(d.cost) then
		table.insert(parts, U.cost_text(d.cost))
	end
	if num(d.requests) then
		table.insert(parts, string.format("%d request%s", d.requests, if d.requests == 1 then "" else "s"))
	end
	if num(d.started) and num(d.ended) then
		table.insert(parts, U.duration_text(d.ended - d.started))
	end
	if str(d.models) then
		table.insert(parts, models_text(d.models))
	end
	return table.concat(parts, " · ")
end

local function prompt_count(state: State): number
	local d: any = state.detail
	return if type(d) == "table" and type(d.prompts) == "table" then #d.prompts else 0
end

function D.view(state: State): (Node, Node)
	local ui = tern.ui
	local d: any = state.detail
	local now = os.time()
	local children: { Node } = {}
	local title = D.title(state) or "Session"
	table.insert(
		children,
		ui.node("row", { key = "crumb", gap = "xs" }, {
			U.with(ui.text({ ui.span("Agent Sessions", "muted") }), { key = "crumb-home", actions = { click = "back" }, title = "Back" }),
			U.text({ ui.span("›", "muted") }, "crumb-sep"),
			U.text({ ui.span(clip(title, 90), "strong") }, "crumb-title"),
		})
	)
	if state.detail_err ~= nil then
		table.insert(children, U.error_card(state.detail_err :: any, nil))
	elseif d == false then
		table.insert(children, cards.error("Session not found", "It may have been deleted."))
	elseif type(d) ~= "table" then
		table.insert(children, cards.loading("Loading the session…"))
	else
		local line = summary(d)
		if line ~= "" then
			table.insert(children, U.text({ ui.span(line, "strong") }, "summary"))
		end
		local started, ended = num(d.started), num(d.ended)
		local rows: { { Spans } } = {
			kv("Folder", if str(d.cwd) then U.tilde(d.cwd) else "unknown"),
		}
		if started then
			table.insert(rows, kv("Started", U.abs(started)))
		end
		if ended then
			table.insert(rows, kv("Ended", U.abs(ended)))
		end
		local n = num(d.subagents) or 0
		if num(d.cost) and n > 0 then
			table.insert(
				rows,
				kv("Cost", string.format("%s (incl. %s in %d subagent%s)", U.cost_text(d.cost), U.cost_text(num(d.cost_sub) or 0), n, if n == 1 then "" else "s"))
			)
		end
		if num(d.tool_calls) then
			table.insert(rows, kv("Tool calls", tostring(d.tool_calls)))
		end
		table.insert(rows, kv("Session", tostring(d.id)))
		table.insert(rows, kv("File", if str(d.file) then U.tilde(d.file) else "Missing (resume looks it up by id)"))
		table.insert(children, U.with(ui.kv(rows), { key = "facts" }))

		local recaps: { any } = if type(d.recaps) == "table" then d.recaps else {}
		if #recaps > 0 then
			table.insert(children, U.with(ui.rule({ ui.span(if #recaps == 1 then "RECAP" else "RECAPS", "dim") }), { key = "h-recaps" }))
			for i, r in recaps do
				local t = num(r.t)
				table.insert(
					children,
					U.text({
						ui.span(clip(tostring(r.text or ""), 400)),
						ui.span(if t then "  " .. U.when_text(t, now) else "", "muted"),
					}, "recap" .. i)
				)
			end
		end
		local prompts: { any } = if type(d.prompts) == "table" then d.prompts else {}
		if #prompts > 0 then
			local count = num(d.prompt_count) or #prompts
			local head = if count > #prompts then string.format("PROMPTS (first %d of %d)", #prompts, count) else string.format("PROMPTS (%d)", count)
			table.insert(children, U.with(ui.rule({ ui.span(head, "dim") }), { key = "h-prompts" }))
			local items: { Node } = {}
			for i, p in prompts do
				local t = num(p.t)
				table.insert(
					items,
					ui.node("item", {
						key = tostring(i),
						label = { ui.span(clip(tostring(p.text or ""), 300)) },
						value = { ui.span(if t then U.when_text(t, now) else "", "muted") },
						actions = { click = "copy" },
					})
				)
			end
			table.insert(
				children,
				ui.node("list", {
					key = "prompts",
					selected = "main.prompts." .. math.clamp(state.prompt_sel, 1, #prompts),
					max = 0.45,
				}, items)
			)
		end
	end

	local dock = U.dock(state, {
		notice = state.notice,
		actions = {
			{ label = "Resume", key = "enter", act = "resume", primary = true },
			{ label = "Fork", key = "f", act = "fork" },
			{ label = "Copy id", key = "y", act = "copy" },
			{ label = "Back", key = "escape", act = "back" },
		},
	})
	return ui.col(children), dock
end

function D.act(state: State, act: string): boolean
	local d: any = state.detail
	if act == "back" then
		D.back(state)
		return true
	end
	if type(d) ~= "table" or state.launching then
		return false
	end
	if act == "resume" or act == "fork" then
		D.launch(state, d, act :: any)
	elseif act == "copy" then
		local id = state.detail_id
		if id == nil then
			return false
		end
		pcall(function()
			state.cx:copy(id)
		end)
		U.toast(state, "success", "Copied session id")
	else
		return false
	end
	return true
end

local PAGE = 8

function D.key(state: State, k: Key): boolean
	if k.ctrl or k.meta or k.alt then
		return false
	end
	local name = k.name
	if name == "enter" or name == "r" then
		return D.act(state, "resume")
	elseif name == "f" then
		return D.act(state, "fork")
	elseif name == "y" then
		return D.act(state, "copy")
	elseif name == "escape" or name == "backspace" then
		return D.act(state, "back")
	end
	local n = prompt_count(state)
	local to: number? = nil
	if name == "up" then
		to = state.prompt_sel - 1
	elseif name == "down" then
		to = state.prompt_sel + 1
	elseif name == "page_up" then
		to = state.prompt_sel - PAGE
	elseif name == "page_down" then
		to = state.prompt_sel + PAGE
	elseif name == "home" then
		to = 1
	elseif name == "end" then
		to = n
	end
	if to == nil or n == 0 then
		return false
	end
	to = math.clamp(to, 1, n)
	if to == state.prompt_sel then
		return false
	end
	state.prompt_sel = to
	return true
end

return D
