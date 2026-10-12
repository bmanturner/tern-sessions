--!strict
-- lib/settings.luau : the plugin's settings, kept in kv key `settings`. Invalid fields fall back to
-- their defaults.

export type Settings = { daily_budget: number, omp_dir: string }

local settings = {}

local function stored(): { [string]: any }
	local ok, v = pcall(function()
		return tern.kv.get("settings")
	end)
	return if ok and type(v) == "table" then v else {}
end

function settings.get(): Settings
	local s = stored()
	local budget = s.daily_budget
	local dir = s.omp_dir
	return {
		daily_budget = if type(budget) == "number" and budget >= 0 then budget else 0,
		-- "" means $HOME/.omp
		omp_dir = if type(dir) == "string" then dir else "",
	}
end

function settings.set(patch: { [string]: any })
	local s = stored()
	for k, v in patch do
		s[k] = v
	end
	pcall(function()
		tern.kv.set("settings", s)
	end)
end

return settings
