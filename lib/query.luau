--!strict
-- lib/query.luau : the search syntax and every SQL statement, as plain strings. No tern.* here, so
-- the tests run it under luau-web. The SQL runs against omp's history.db with stats.db attached as
-- `s` (see lib/db.luau); without stats.db only the history half of the prelude runs.

export type Parsed = {
	words: { string },
	repo: { string },
	model: { string },
	after: string?,
	before: string?,
	cost_min: number?,
	cost_max: number?,
	errors: { string },
}

local query = {}

local LIMIT = 100
local ESC = " escape '\\'"

-- An SQL string literal.
function query.lit(s: string): string
	return "'" .. s:gsub("'", "''") .. "'"
end

-- A LIKE pattern matching `word` anywhere, with the LIKE wildcards escaped. Append ESC after it.
function query.like(word: string): string
	local esc = word:gsub("\\", "\\\\"):gsub("%%", "\\%%"):gsub("_", "\\_")
	return query.lit("%" .. esc .. "%")
end

-- An FTS5 match expression: every word a quoted prefix term, all required. Nil when no word has a
-- letter or digit (FTS5 would find nothing, or fail to parse).
function query.fts(words: { string }): string?
	local terms: { string } = {}
	for _, w in words do
		if w:find("[%w\128-\255]") then
			table.insert(terms, '"' .. w:gsub('"', '""') .. '"*')
		end
	end
	if #terms == 0 then
		return nil
	end
	return table.concat(terms, " AND ")
end

local function tokens(text: string): { { text: string, quoted: boolean } }
	local out: { { text: string, quoted: boolean } } = {}
	local cur: { string } = {}
	local quoted = false
	local inside = false
	local function flush()
		local t = table.concat(cur)
		if quoted then
			t = t:match("^%s*(.-)%s*$") or ""
		end
		if t ~= "" then
			table.insert(out, { text = t, quoted = quoted })
		end
		cur = {}
		quoted = false
	end
	for i = 1, #text do
		local ch = text:sub(i, i)
		if ch == '"' then
			inside = not inside
			quoted = true
		elseif not inside and ch:match("%s") then
			flush()
		else
			table.insert(cur, ch)
		end
	end
	flush()
	return out
end

function query.parse(text: string): Parsed
	local p: Parsed = { words = {}, repo = {}, model = {}, errors = {} }
	for _, tok in tokens(text) do
		local t = tok.text
		local lower = t:lower()
		if tok.quoted then
			table.insert(p.words, t)
		elseif lower:sub(1, 5) == "repo:" and #t > 5 then
			table.insert(p.repo, t:sub(6))
		elseif lower:sub(1, 6) == "model:" and #t > 6 then
			table.insert(p.model, t:sub(7))
		elseif lower:sub(1, 6) == "after:" or lower:sub(1, 7) == "before:" then
			local key, value = lower:match("^(%a+):(.*)$")
			if value ~= nil and value:match("^%d%d%d%d%-%d%d%-%d%d$") then
				if key == "after" then
					p.after = value
				else
					p.before = value
				end
			else
				table.insert(p.errors, tostring(key) .. ": needs a date like 2026-10-01")
			end
		elseif lower:match("^cost[<>]") then
			local op, n = lower:match("^cost([<>])%$?(%d+%.?%d*)$")
			local value = n and tonumber(n)
			if value == nil then
				table.insert(p.errors, "cost: needs a number like cost>5")
			elseif op == ">" then
				p.cost_min = value
			else
				p.cost_max = value
			end
		else
			table.insert(p.words, t)
		end
	end
	return p
end

-- Every session as a row of temp table `meta`: stats.db's top-level rollups (with their subagents'
-- cost), then sessions history.db knows that stats.db doesn't. Times are unix seconds.
local function prelude(has_stats: boolean): string
	local out = {
		"create temp table sess(id, file, started, ended, requests, models, cost, cost_sub, subagents, tool_calls);",
	}
	if has_stats then
		local base = "substr(r.session_file,1,length(r.session_file)-6)"
		local kids = "s.session_rollup c where c.session_file > " .. base .. "||'/' and c.session_file < " .. base .. "||'0'"
		table.insert(
			out,
			"insert into sess select substr(r.session_file, length(r.session_file)-41, 36), r.session_file, r.started_at/1000, r.ended_at/1000, r.requests, r.models, r.cost_total, "
				.. "coalesce((select sum(c.cost_total) from " .. kids .. "),0), "
				.. "(select count(*) from " .. kids .. "), "
				.. "r.tool_calls from s.session_rollup r "
				.. "where r.session_file glob '*/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*_*.jsonl' "
				.. "and r.session_file not glob '*/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*_*/*';"
		)
	end
	table.insert(
		out,
		"insert into sess select session_id, null, min(created_at), max(created_at), null, null, null, null, null, null "
			.. "from main.history where session_id is not null and session_id not in (select id from sess) group by session_id;"
	)
	table.insert(
		out,
		"create temp table meta as select x.*, "
			.. "case when x.cost is null then null else coalesce(x.cost,0)+coalesce(x.cost_sub,0) end total, "
			.. "coalesce((select title from main.session_titles t where t.session_id = x.id), "
			.. "(select substr(prompt,1,80) from main.history h where h.session_id = x.id order by created_at limit 1)) title, "
			.. "coalesce((select cwd from main.history h where h.session_id = x.id and cwd is not null order by created_at limit 1), "
			.. "(select cwd from main.session_recaps r where r.session_id = x.id order by created_at limit 1)) cwd "
			.. "from sess x;"
	)
	return table.concat(out, "\n")
end

local function num(n: number): string
	return string.format("%.4f", n)
end

local function all_like(column: string, words: { string }): string
	local parts: { string } = {}
	for _, w in words do
		table.insert(parts, column .. " like " .. query.like(w) .. ESC)
	end
	return table.concat(parts, " and ")
end

function query.search_sql(p: Parsed, has_stats: boolean): string
	local out = { prelude(has_stats) }
	local fts = query.fts(p.words)
	if fts ~= nil then
		table.insert(
			out,
			"create temp table hit0 as select hh.session_id sid, snippet(history_fts,0,'«','»','…',12) snip, bm25(history_fts) score "
				.. "from main.history_fts join main.history hh on hh.id = history_fts.rowid where history_fts match "
				.. query.lit(fts)
				.. ";"
		)
		table.insert(out, "create temp table hit as select sid, snip, min(score) score from hit0 group by sid;")
	else
		table.insert(out, "create temp table hit(sid, snip, score);")
	end

	local has_words = #p.words > 0
	local tm, rm, recap_conds = "0", "0", ""
	if has_words then
		tm = "coalesce((" .. all_like("m.title", p.words) .. "),0)"
		recap_conds = all_like("r.recap", p.words)
		rm = "exists(select 1 from main.session_recaps r where r.session_id = m.id and " .. recap_conds .. ")"
	end

	local where: { string } = {}
	if has_words then
		table.insert(where, "(tm or rm or hsid is not null)")
	end
	for _, r in p.repo do
		table.insert(where, "cwd like " .. query.like(r) .. ESC)
	end
	for _, m in p.model do
		table.insert(where, "models like " .. query.like(m) .. ESC)
	end
	if p.after then
		table.insert(where, "started >= cast(strftime('%s', " .. query.lit(p.after) .. ", 'utc') as integer)")
	end
	if p.before then
		table.insert(where, "started < cast(strftime('%s', " .. query.lit(p.before) .. ", 'utc') as integer)")
	end
	if p.cost_min then
		table.insert(where, "total > " .. num(p.cost_min))
	end
	if p.cost_max then
		table.insert(where, "total < " .. num(p.cost_max))
	end

	local snip = "null"
	if has_words then
		snip = "case when tm then null when rm then (select substr(r.recap,1,160) from main.session_recaps r where r.session_id = q.id and "
			.. recap_conds
			.. " order by r.created_at desc limit 1) else hsnip end"
	end
	local order = has_words and "tm*2 + rm desc, coalesce(hscore,0) asc, started desc" or "started desc"

	table.insert(
		out,
		"select json_group_array(json_object('id',id,'file',file,'title',title,'cwd',cwd,'started',started,'ended',ended,'cost',total,'models',models,'requests',requests,'hit',hit,'snip',snip)) from ("
			.. "select id, file, title, cwd, started, ended, total, models, requests, "
			.. "case when tm then 'title' when rm then 'recap' when hsid is not null then 'prompt' end hit, "
			.. snip .. " snip from ("
			.. "select m.*, " .. tm .. " tm, " .. rm .. " rm, h.sid hsid, h.snip hsnip, h.score hscore from meta m left join hit h on h.sid = m.id"
			.. ") q"
			.. (#where > 0 and (" where " .. table.concat(where, " and ")) or "")
			.. " order by " .. order .. " limit " .. LIMIT
			.. ");"
	)
	return table.concat(out, "\n")
end

-- One session with its recaps and first prompts; nil for an id that isn't a session uuid.
function query.detail_sql(id: string, has_stats: boolean): string?
	if #id ~= 36 or not id:match("^[%x%-]+$") then
		return nil
	end
	local lid = query.lit(id)
	return prelude(has_stats)
		.. "\nselect json_object('id',id,'file',file,'title',title,'cwd',cwd,'started',started,'ended',ended,'requests',requests,"
		.. "'models',models,'cost',total,'cost_sub',cost_sub,'subagents',subagents,'tool_calls',tool_calls,"
		.. "'recaps',json((select json_group_array(json_object('t',created_at,'text',recap)) from (select created_at, recap from main.session_recaps where session_id = "
		.. lid
		.. " order by created_at desc))),"
		.. "'prompts',json((select json_group_array(json_object('t',created_at,'text',substr(prompt,1,300))) from (select created_at, prompt from main.history where session_id = "
		.. lid
		.. " order by created_at asc limit 30))),"
		.. "'prompt_count',(select count(*) from main.history where session_id = "
		.. lid
		.. ")) from meta where id = "
		.. lid
		.. ";"
end

local TODAY0 = "cast(strftime('%s','now','localtime','start of day','utc') as integer)*1000"

-- The ledger: needs stats.db. Buckets are hourly, in ms.
function query.spend_sql(): string
	local sum_since = function(col: string): string
		return "(select coalesce(sum(cost_total),0) from s.message_rollup where bucket >= (select " .. col .. " from k))"
	end
	return prelude(true)
		.. "\ncreate temp table k as select "
		.. TODAY0 .. " day0, "
		.. "cast(strftime('%s','now','localtime','-6 days','weekday 1','start of day','utc') as integer)*1000 week0, "
		.. "cast(strftime('%s','now','localtime','start of month','utc') as integer)*1000 month0, "
		.. "cast(strftime('%s','now','localtime','start of day','-29 days','utc') as integer)*1000 d30;"
		.. "\nselect json_object("
		.. "'today'," .. sum_since("day0") .. ","
		.. "'week'," .. sum_since("week0") .. ","
		.. "'month'," .. sum_since("month0") .. ","
		.. "'total30'," .. sum_since("d30") .. ","
		.. "'days',json((with recursive n(i) as (select 13 union all select i-1 from n where i>0) "
		.. "select json_group_array(json_object('d',d,'c',coalesce(c,0))) from (select n.d, x.c from (select date('now','localtime','-'||i||' days') d from n) n "
		.. "left join (select date(bucket/1000,'unixepoch','localtime') d, sum(cost_total) c from s.message_rollup where bucket >= (select d30 from k) group by 1) x on x.d = n.d order by n.d))),"
		.. "'folders',json((select json_group_array(json_object('f',folder,'c',c,'cwd',(select cwd from meta where instr(file,'/'||folder||'/') > 0 and cwd is not null limit 1))) "
		.. "from (select folder, sum(cost_total) c from s.message_rollup where bucket >= (select d30 from k) group by folder order by c desc limit 8))),"
		.. "'models',json((select json_group_array(json_object('m',model,'c',c)) "
		.. "from (select model, sum(cost_total) c from s.message_rollup where bucket >= (select d30 from k) group by model order by c desc limit 8))),"
		.. "'top',json((select json_group_array(json_object('id',id,'title',title,'cwd',cwd,'started',started,'cost',total)) "
		.. "from (select * from meta where started >= (select d30 from k)/1000 and file is not null order by total desc limit 10)))"
		.. ");"
end

function query.today_sql(): string
	return "select json_object('today', (select coalesce(sum(cost_total),0) from s.message_rollup where bucket >= "
		.. TODAY0
		.. "), 'day', date('now','localtime'));"
end

return query
