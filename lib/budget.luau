--!strict
-- lib/budget.luau : the host timer. Every 5 minutes it prunes closed managers and, with a daily
-- budget set, checks today's spend: once a day over budget it sends a desktop notification and a
-- toast in every open manager.
local app = require("./app")
local db = require("./db")
local platform = require("./platform")
local query = require("./query")
local settings = require("./settings")
local sync = require("./sync")

local budget = {}

local FIRST_MS = 10000
local EVERY_MS = 300000

local function alert(today: number, limit: number)
	local argv = platform.notify_argv(
		"Agent Sessions",
		string.format("Today's omp spend is $%.2f, over your $%.2f daily budget.", today, limit)
	)
	if argv ~= nil then
		pcall(function()
			tern.process.run(argv, { timeout_ms = 5000 }, function() end)
		end)
	end
	app.each(function(s)
		s.cx:toast("error", "Over today's budget", string.format("$%.2f of $%.2f", today, limit))
	end)
end

local function check()
	local limit = settings.get().daily_budget
	if limit <= 0 then
		return
	end
	sync.run(false, function()
		if not db.has_stats() then
			return
		end
		db.run(query.today_sql(), function(r)
			if type(r) ~= "table" or type(r.today) ~= "number" then
				return
			end
			local today: number = r.today
			local _, alerted = pcall(function()
				return tern.kv.get("alerted_day")
			end)
			if today >= limit and alerted ~= r.day then
				pcall(function()
					tern.kv.set("alerted_day", r.day)
				end)
				alert(today, limit)
			end
			app.each(function(s)
				s.today = today
				s.cx:render()
			end)
		end)
	end)
end

local function tick()
	budget.check()
	app.prune()
	tern.timer(EVERY_MS, tick)
end

-- Runs a check now (after the budget changes).
function budget.check()
	local ok, err = pcall(function()
		check()
	end)
	if not ok then
		tern.log.warn("tern-sessions: budget check failed", err)
	end
end

function budget.start()
	tern.timer(FIRST_MS, tick)
end

return budget
