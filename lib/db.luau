--!strict
-- lib/db.luau : runs lib/query.luau SQL with the system sqlite3 against omp's history.db, with
-- stats.db attached as `s` when it exists. Read-only; nothing is cached. Every query ends in one
-- JSON row, which is decoded for the caller.
local query = require("./query")
local settings = require("./settings")

local db = {}

local SQLITE = { "/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3", "/usr/local/bin/sqlite3" }

local function exists(path: string): boolean
	local ok, yes = pcall(function()
		return tern.fs.exists(path)
	end)
	return ok and yes == true
end

function db.paths(): { history: string, stats: string }
	local dir = settings.get().omp_dir
	if dir == "" then
		dir = (tern.getenv("HOME") or "") .. "/.omp"
	end
	return { history = dir .. "/agent/history.db", stats = dir .. "/stats.db" }
end

function db.sqlite(): string?
	for _, p in SQLITE do
		if exists(p) then
			return p
		end
	end
	return nil
end

function db.has_stats(): boolean
	return exists(db.paths().stats)
end

-- cb(value) with the decoded last line, cb(nil) when the query printed no row, cb(nil, message) on failure.
function db.run(sql: string, cb: (any?, string?) -> ())
	local sqlite = db.sqlite()
	if sqlite == nil then
		return cb(nil, "sqlite3 isn't installed. Install it (e.g. sudo apt install sqlite3) and reopen.")
	end
	local paths = db.paths()
	if not exists(paths.history) then
		return cb(nil, "No omp history yet: " .. paths.history .. " doesn't exist.")
	end
	-- Never -bail: with it sqlite3 prints nothing at all.
	local argv = { sqlite, "-readonly", "-noheader", "-list" }
	if exists(paths.stats) then
		table.insert(argv, "-cmd")
		table.insert(argv, "attach " .. query.lit(paths.stats) .. " as s")
	end
	table.insert(argv, paths.history)
	table.insert(argv, sql)
	local function done(r: ProcessResult)
		if r.timed_out then
			return cb(nil, "The query took too long.")
		elseif r.status ~= 0 then
			local line = tostring(r.stderr):match("[^\r\n]+") or ("sqlite3 failed (status " .. tostring(r.status) .. ")")
			return cb(nil, line:sub(1, 200))
		end
		local last: string? = nil
		for line in tostring(r.stdout):gmatch("[^\r\n]+") do
			if line:match("%S") then
				last = line
			end
		end
		if last == nil then
			return cb(nil, nil)
		end
		local okd, value = pcall(function()
			return tern.json.decode(last :: string)
		end)
		if not okd then
			return cb(nil, "Unexpected output from sqlite3.")
		end
		cb(value, nil)
	end
	local ok = pcall(function()
		tern.process.run(argv, { timeout_ms = 15000 }, done)
	end)
	if not ok then
		cb(nil, "sqlite3 couldn't start.")
	end
end

return db
