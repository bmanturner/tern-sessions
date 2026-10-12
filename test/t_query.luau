-- query.parse and query.fts on the search syntax, plus SQL quoting.
local query = require("./query")

local function list(t: { string }): string
	local out = {}
	for _, s in t do
		table.insert(out, "[" .. s .. "]")
	end
	return table.concat(out, " ")
end

local function ranges(p: query.Parsed): string
	local out = {}
	for _, t in p.tokens do
		table.insert(out, "[" .. t.from .. "-" .. t.to .. " " .. t.kind .. "]")
	end
	return table.concat(out, " ")
end

local function show(text: string)
	local p = query.parse(text)
	print("> " .. text)
	print("  words: " .. list(p.words))
	print("  repo: " .. list(p.repo) .. "  model: " .. list(p.model))
	print("  after: " .. tostring(p.after) .. "  before: " .. tostring(p.before) .. "  cost: " .. tostring(p.cost_min) .. ".." .. tostring(p.cost_max))
	print("  errors: " .. list(p.errors))
	print("  tokens: " .. ranges(p))
	print("  fts: " .. tostring(query.fts(p.words)))
end

show("deploy auth")
show('"exact phrase" repo:web model:opus')
show("after:2026-10-01 before:bad cost>$5.5 cost<x")
show("it's 100%_done")
show('" OR *')
show("REPO:Api Model:GPT cost<12")

local sql = query.search_sql(query.parse("it's 100%_done"), true)
print("quote doubled: " .. tostring(sql:find("it''s", 1, true) ~= nil))
print("percent escaped: " .. tostring(sql:find("100\\%", 1, true) ~= nil))
print("underscore escaped: " .. tostring(sql:find("\\_done", 1, true) ~= nil))
print("no -bail: " .. tostring(sql:find("-bail", 1, true) == nil))
print("detail bad id: " .. tostring(query.detail_sql("zz", true)))
print("detail injection: " .. tostring(query.detail_sql("aaaaaaaa-0000-4000-8000-00000000000'", true)))

-- ui.luau pulls in lib/cards.luau, which reads tern.ui at load; U.mark itself needs nothing from Tern.
tern = { ui = {} }
local U = require("./ui")
print("mark: " .. U.mark("Deploy docs; next deploy.", { "deploy" }))
print("mark none: " .. U.mark("nothing here", { "deploy" }))
print("mark overlap: " .. U.mark("abcabc", { "abc", "bca" }))
