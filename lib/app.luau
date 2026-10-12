--!strict
-- lib/app.luau : the live manager blocks of this host. Their pane ids are published in kv key
-- `managers` so the window half can focus one instead of opening another.

local app = {}

local states: { any } = {}

function app.publish()
	local ids: { string } = {}
	for _, s in states do
		table.insert(ids, s.pane_id)
	end
	pcall(function()
		tern.kv.set("managers", tern.json.array(ids))
	end)
end

function app.add(state: any)
	table.insert(states, state)
	app.publish()
end

-- Drops states whose pane is gone.
function app.prune()
	local ok, panes = pcall(tern.pane.list)
	if not ok then
		return
	end
	local live: { [number]: boolean } = {}
	for _, info in panes do
		live[info.pane] = true
	end
	for i = #states, 1, -1 do
		if not live[states[i].cx.pane] then
			table.remove(states, i)
		end
	end
	app.publish()
end

function app.each(fn: (any) -> ())
	for _, s in table.clone(states) do
		pcall(fn, s)
	end
end

return app
