--!strict
-- Agent Sessions window half: the palette commands that open the manager. Everything else runs in
-- the host half.

-- iOS has no tern.process, and omp is desktop-only.
if tern.runtime.os == "ios" then
	return
end

require("./lib/commands").register()
