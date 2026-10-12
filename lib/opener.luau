--!strict
-- lib/opener.luau : resumes or forks an omp session in a new Tern tab, in the session's own folder.
local bins = require("./bins")

local opener = {}

export type Target = { id: string, file: string?, cwd: string?, title: string? }

local function exists(path: string?): boolean
	if type(path) ~= "string" or path == "" then
		return false
	end
	local ok, yes = pcall(function()
		return tern.fs.exists(path)
	end)
	return ok and yes == true
end

local function home(): string
	return tern.getenv("HOME") or "/"
end

local function tilde(path: string): string
	local h = home()
	if h ~= "" and h ~= "/" and path:sub(1, #h) == h and (#path == #h or path:sub(#h + 1, #h + 1) == "/") then
		return "~" .. path:sub(#h + 1)
	end
	return path
end

local function run(argv: { string }, timeout: number, cb: (ProcessResult?) -> ())
	local ok = pcall(function()
		tern.process.run(argv, { timeout_ms = timeout }, function(r)
			cb(r)
		end)
	end)
	if not ok then
		cb(nil)
	end
end

-- cb(cwd, note): the recorded folder, else the one in the session file's header, else $HOME.
local function pick_cwd(sess: Target, cb: (string, string?) -> ())
	if exists(sess.cwd) then
		return cb(sess.cwd :: string, nil)
	end
	local gone = function()
		local name = if type(sess.cwd) == "string" and sess.cwd ~= "" then tilde(sess.cwd) else "Its folder"
		cb(home(), name .. " no longer exists, so it opened in your home folder.")
	end
	if not exists(sess.file) then
		return gone()
	end
	-- tern.fs.read wants the whole file under its cap; head reads just the header.
	run({ "/usr/bin/head", "-c", "4096", sess.file :: string }, 3000, function(r)
		if r ~= nil and r.status == 0 then
			local line = tostring(r.stdout):match("^[^\n]*\n([^\n]*)")
			if line ~= nil then
				local ok, header = pcall(function()
					return tern.json.decode(line)
				end)
				if ok and type(header) == "table" and exists(header.cwd) then
					return cb(header.cwd, nil)
				end
			end
		end
		gone()
	end)
end

-- cb(true, note) once the tab is open, cb(false, message) when it couldn't be.
function opener.open(sess: Target, how: "resume" | "fork", cb: (boolean, string?) -> ())
	bins.resolve(function(b, err)
		if b == nil then
			return cb(false, if err == "tern_missing" then "Couldn't find tern." else "Couldn't find omp.")
		end
		local target = if exists(sess.file) then sess.file :: string else sess.id
		pick_cwd(sess, function(cwd, note)
			local omp_args = { b.omp, if how == "fork" then "--fork" else "--resume", target }
			local function launch(argv: { string }, retried: boolean)
				for _, a in omp_args do
					table.insert(argv, a)
				end
				run(argv, 10000, function(r)
					if r ~= nil and r.status == 0 then
						local block = tostring(r.stdout):match('"block"%s*:%s*(%d+)')
						if block ~= nil then
							run({ b.tern, "focus", block }, 5000, function() end)
						end
						return cb(true, note)
					end
					local text = if r ~= nil then tostring(r.stderr) else "tern couldn't start."
					if not retried and text:find("there is no session", 1, true) then
						return launch({ b.tern, "new", "session", "Agent sessions", "--json", "--cwd", cwd, "--" }, true)
					end
					if r == nil then
						bins.invalidate()
					end
					cb(false, "Couldn't open it: " .. text:sub(1, 160))
				end)
			end
			launch({ b.tern, "new", "tab", "--json", "--cwd", cwd, "--" }, false)
		end)
	end)
end

return opener
