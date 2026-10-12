--!strict
-- lib/sync.luau : brings stats.db up to date by running `omp stats --summary` (an incremental sync),
-- at most once a minute unless forced. Concurrent callers share one run. Skipped when the omp_dir
-- setting points somewhere else: omp only syncs its own ~/.omp.
local settings = require("./settings")
local bins = require("./bins")

local sync = {}

local FRESH_MS = 60000

local last_ok = -math.huge
local waiting: { (string?) -> () } = {}
local running = false

local function finish(note: string?)
	running = false
	local list = waiting
	waiting = {}
	for _, cb in list do
		cb(note)
	end
end

-- cb(nil) when stats.db is current, cb(note) when it may be stale.
function sync.run(force: boolean, cb: (string?) -> ())
	if settings.get().omp_dir ~= "" or (not force and tern.now() - last_ok < FRESH_MS) then
		return cb(nil)
	end
	table.insert(waiting, cb)
	if running then
		return
	end
	running = true
	bins.resolve(function(b)
		if b == nil then
			return finish("omp wasn't found, so spend may be out of date.")
		end
		local function done(r: ProcessResult)
			if r.status == 0 and not r.timed_out then
				last_ok = tern.now()
				return finish(nil)
			end
			finish("omp stats failed, so spend may be out of date.")
		end
		local ok = pcall(function()
			tern.process.run({ b.omp, "stats", "--summary" }, { timeout_ms = 30000 }, done)
		end)
		if not ok then
			bins.invalidate()
			finish("omp stats failed, so spend may be out of date.")
		end
	end)
end

return sync
