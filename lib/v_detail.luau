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

-- Resumes or forks `sess` in a new tab; toasts the outcome.
function D.launch(state: State, sess: any, how: "resume" | "fork")
	if type(sess) ~= "table" or str(sess.id) == nil then
		return
	end
	local title = str(sess.title) or "the session"
	state.notice = (if how == "fork" then "Forking " else "Resuming ") .. clip(title, 60) .. "…"
	opener.open({ id = sess.id, file = str(sess.file), cwd = str(sess.cwd), title = title }, how, function(ok, note)
		if ok then
			state.notice = nil
			U.toast(state, "success", (if how == "fork" then "Forked " else "Opened ") .. clip(title, 60), note)
		else
			state.notice = note
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
	local sql = query.detail_sql(id, db.has_stats())
	if sql == nil then
		state.detail_err = "Session not found."
		return
	end
	db.run(sql, function(v, err)
		if state.detail_id ~= id then
			return
		end
		if type(v) == "table" then
			state.detail = v
		else
			state.detail_err = err or "Session not found."
		end
		U.render(state)
	end)
end

function D.back(state: State)
	state.mode = state.back
	state.notice = nil
	if state.mode == "search" then
		U.focus(state.cx, "main.query")
	end
end

function D.title(state: State): string?
	local d = state.detail
	return if type(d) == "table" then str(d.title) else nil
end

local function kv(label: string, value: string): { Spans }
	return { { tern.ui.span(label, "muted") }, { tern.ui.span(value) } }
end

local function cost_row(d: any): string
	local total = num(d.cost)
	if total == nil then
		return "no spend data"
	end
	local out = U.cost_text(total)
	local n = num(d.subagents) or 0
	if n > 0 then
		out ..= string.format(" (incl. %s in %d subagent%s)", U.cost_text(num(d.cost_sub) or 0), n, if n == 1 then "" else "s")
	end
	return out .. " · API-equivalent estimate"
end

function D.view(state: State): (Node, Node)
	local ui = tern.ui
	local d: any = state.detail
	local now = os.time()
	local children: { Node } = {}
	local title = D.title(state) or "Session"
	table.insert(
		children,
		U.text({ ui.span("Agent Sessions", "muted"), ui.span(" › ", "muted"), ui.span(clip(title, 90), "strong") }, "crumb")
	)
	if state.detail_err ~= nil then
		table.insert(children, cards.error("Couldn't load this session", state.detail_err :: string))
	elseif type(d) ~= "table" then
		table.insert(children, cards.loading("Loading the session…"))
	else
		table.insert(children, U.text({ ui.span(tostring(d.id), "muted") }, "id"))
		local started, ended = num(d.started), num(d.ended)
		local rows: { { Spans } } = {
			kv("Folder", str(d.cwd) and U.tilde(d.cwd) or "unknown"),
		}
		if started then
			table.insert(rows, kv("Started", U.abs(started)))
		end
		if ended then
			table.insert(rows, kv("Ended", U.abs(ended)))
		end
		if started and ended then
			table.insert(rows, kv("Duration", U.duration_text(ended - started)))
		end
		if num(d.requests) then
			table.insert(rows, kv("Requests", tostring(d.requests)))
		end
		if num(d.tool_calls) then
			table.insert(rows, kv("Tool calls", tostring(d.tool_calls)))
		end
		if str(d.models) then
			table.insert(rows, kv("Models", ((d.models :: string):gsub(",", ", "))))
		end
		table.insert(rows, kv("Cost", cost_row(d)))
		table.insert(rows, kv("File", if str(d.file) then U.tilde(d.file) else "not found; resume uses the id"))
		table.insert(children, U.with(ui.kv(rows), { key = "facts" }))

		local recaps: { any } = if type(d.recaps) == "table" then d.recaps else {}
		if #recaps > 0 then
			table.insert(children, U.text({ ui.span("RECAPS", "dim") }, "h-recaps"))
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
			table.insert(children, U.text({ ui.span(head, "dim") }, "h-prompts"))
			local items: { Node } = {}
			for i, p in prompts do
				local t = num(p.t)
				table.insert(
					items,
					ui.node("item", {
						key = tostring(i),
						label = { ui.span(clip(tostring(p.text or ""), 200)) },
						value = { ui.span(if t then U.when_text(t, now) else "", "muted") },
					})
				)
			end
			table.insert(children, ui.node("list", { key = "prompts" }, items))
		end
	end

	local dock: { Node } = {}
	if state.notice then
		table.insert(dock, U.text({ ui.span(state.notice :: string, "muted") }, "notice"))
	end
	table.insert(
		dock,
		U.with(ui.row({
			U.badge("Resume r", "accent", "resume", "b-resume"),
			U.badge("Fork f", "neutral", "fork", "b-fork"),
			U.badge("Copy id y", "neutral", "copy", "b-copy"),
			U.badge("Back esc", "neutral", "back", "b-back"),
		}), { key = "acts" })
	)
	return ui.col(children), ui.col(dock)
end

function D.copy(state: State)
	local id = state.detail_id
	if id == nil then
		return
	end
	pcall(function()
		state.cx:copy(id)
	end)
	state.notice = "Copied the session id."
end

function D.act(state: State, act: string): boolean
	local d: any = state.detail
	if act == "resume" or act == "fork" then
		if type(d) == "table" then
			D.launch(state, d, act :: any)
		end
	elseif act == "copy" then
		D.copy(state)
	elseif act == "back" then
		D.back(state)
	else
		return false
	end
	return true
end

function D.key(state: State, k: Key): boolean
	if k.ctrl or k.meta or k.alt then
		return false
	end
	local name = k.name
	if name == "r" then
		return D.act(state, "resume")
	elseif name == "f" then
		return D.act(state, "fork")
	elseif name == "y" then
		return D.act(state, "copy")
	elseif name == "escape" or name == "backspace" then
		return D.act(state, "back")
	end
	return false
end

return D
