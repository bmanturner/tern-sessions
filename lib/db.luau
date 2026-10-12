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

function db.has_history(): boolean
	return exists(db.paths().history)
end

export type DbError = {
	kind: "no_sqlite" | "no_history" | "busy" | "timeout" | "failed",
	message: string,
	detail: string?,
}

local MESSAGES = {
	no_sqlite = "SQLite isn't installed, so omp's history can't be read.",
	no_history = "Run omp once and your sessions will appear here.",
	busy = "omp is busy writing its database. Try again in a moment.",
	timeout = "omp's database took too long to answer.",
	failed = "Couldn't read omp's database.",
}

local function fail(kind: "no_sqlite" | "no_history" | "busy" | "timeout" | "failed", detail: string?): DbError
	return { kind = kind, message = MESSAGES[kind], detail = detail }
end

type Entry = { sql: string, cb: (any?, DbError?) -> (), tag: string? }

-- One sqlite3 process at a time: omp itself writes these files, so concurrent readers only invite
-- lock errors. The next entry starts from the previous entry's callback.
local queue: { Entry } = {}
local running = false

local pump: () -> ()

-- Runs one entry (attempt 1 or its single retry) and calls `done` exactly once.
local function execute(entry: Entry, attempt: number, done: (any?, DbError?) -> ())
	local sqlite = db.sqlite()
	if sqlite == nil then
		return done(nil, fail("no_sqlite"))
	end
	local paths = db.paths()
	if not exists(paths.history) then
		return done(nil, fail("no_history", paths.history))
	end
	-- Never -bail: with it sqlite3 prints nothing at all.
	local argv = { sqlite, "-readonly", "-noheader", "-list", "-cmd", ".timeout 4000" }
	if exists(paths.stats) then
		table.insert(argv, "-cmd")
		table.insert(argv, "attach " .. query.lit(paths.stats) .. " as s")
	end
	table.insert(argv, paths.history)
	table.insert(argv, entry.sql)
	local function finished(r: ProcessResult)
		if r.timed_out then
			return done(nil, fail("timeout"))
		end
		if r.status ~= 0 then
			local stderr = tostring(r.stderr)
			local lower = stderr:lower()
			local locked = lower:find("locked", 1, true) ~= nil or lower:find("busy", 1, true) ~= nil
			if locked and attempt == 1 then
				tern.log.warn("tern-sessions: sqlite3 busy, retrying", stderr)
				local okt = pcall(function()
					tern.timer(400, function()
						execute(entry, 2, done)
					end)
				end)
				if okt then
					return
				end
			end
			tern.log.warn("tern-sessions: sqlite3 failed", stderr)
			if locked then
				return done(nil, fail("busy"))
			end
			local line = stderr:match("[^\r\n]+")
			if line == nil then
				line = "sqlite3 exited with status " .. tostring(r.status)
			else
				line = (line :: string):gsub("^Error in %d+%a* command line argument: ", "")
			end
			return done(nil, fail("failed", (line :: string):sub(1, 200)))
		end
		local last: string? = nil
		for line in tostring(r.stdout):gmatch("[^\r\n]+") do
			if line:match("%S") then
				last = line
			end
		end
		if last == nil then
			return done(nil, nil)
		end
		local okd, value = pcall(function()
			return tern.json.decode(last :: string)
		end)
		if not okd then
			return done(nil, fail("failed", "unexpected output"))
		end
		done(value, nil)
	end
	local ok = pcall(function()
		tern.process.run(argv, { timeout_ms = 15000 }, finished)
	end)
	if not ok then
		done(nil, fail("failed", "sqlite3 couldn't start"))
	end
end

function pump()
	if running then
		return
	end
	local entry = table.remove(queue, 1)
	if entry == nil then
		return
	end
	running = true
	execute(entry, 1, function(value, err)
		running = false
		local ok, e = pcall(function()
			entry.cb(value, err)
		end)
		if not ok then
			tern.log.error("tern-sessions: db callback failed", e)
		end
		pump()
	end)
end

-- cb(value) with the decoded last line, cb(nil) when the query printed no row, cb(nil, err) on failure.
-- A queued call with the same non-nil `tag` is replaced; its callback never runs.
function db.run(sql: string, cb: (any?, DbError?) -> (), tag: string?)
	if tag ~= nil then
		for i = #queue, 1, -1 do
			if queue[i].tag == tag then
				table.remove(queue, i)
			end
		end
	end
	table.insert(queue, { sql = sql, cb = cb, tag = tag })
	pump()
end

return db
