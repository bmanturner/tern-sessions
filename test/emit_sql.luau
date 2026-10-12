-- Prints every statement test/sql.ts runs against the fixture DBs, as blocks:
-- @@<name>|<has_stats> / sql / @@end, or @@skip|<name> when the builder returned nil.
local query = require("./query")

local A = "aaaaaaaa-0000-4000-8000-00000000000a"

local function emit(name: string, has_stats: boolean, sql: string?)
	if sql == nil then
		print("@@skip|" .. name)
		return
	end
	print("@@" .. name .. "|" .. (has_stats and "1" or "0"))
	print(sql)
	print("@@end")
end

local function search(name: string, text: string, has_stats: boolean?)
	local stats = has_stats ~= false
	emit(name, stats, query.search_sql(query.parse(text), stats))
end

search("empty", "")
search("deploy", "deploy")
search("repo", "repo:beta")
search("model", "model:opus")
search("cost", "cost>5")
-- Fixture A started 2 days ago, B 5, C 10, D 40.
local cut = os.date("%Y-%m-%d", os.time() - 3 * 86400)
search("after", "after:" .. cut)
search("before", "before:" .. cut)
search("syntax", '" OR *')
search("nostats", "", false)
search("nostats_deploy", "deploy", false)
emit("detail", true, query.detail_sql(A, true))
emit("detail_nostats", false, query.detail_sql(A, false))
emit("detail_bad", true, query.detail_sql("zz", true))
emit("spend", true, query.spend_sql())
emit("today", true, query.today_sql())
