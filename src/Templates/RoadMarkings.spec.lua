local TestTypes = require("../TestTypes")

local StraightRoadGenerator = require("./StraightRoadGenerator")

--[[
	A tapered end is built to the lane layout of the neighbour it was matched
	to, so the markings it paints at that face have to be the ones the
	neighbour paints. They did not used to be: one marking set was chosen for
	the whole segment from the widest lane count, which left an odd-lane road
	drawing a shared centre lane where its even-lane neighbour drew a divided
	centreline, so the two met with a line down the middle of the other's
	centre lane. Stepping a road's width a lane at a time flips that parity
	every step, so every other joint was wrong.
]]

local LANE_WIDTH = 24
local SIDEWALK = 8
local LENGTH = 400
local TAPER = 150

local function generate(attributes: { [string]: any }, size: Vector3): Folder
	local merged: { [string]: any } = {}
	for name, value in StraightRoadGenerator.Attributes :: any do
		merged[name] = value
	end
	for name, value in attributes do
		merged[name] = value
	end
	local container = Instance.new("Folder")
	;(StraightRoadGenerator :: any).OnGenerate({
		Attributes = merged,
		Size = size,
		Pause = function() end,
	}, container)
	return container
end

-- The lateral offsets of the markings in the slice nearest the blue face,
-- rounded to the stud and rendered as a string so two roads compare directly
local function faceMarkings(container: Folder): string
	local slices: { [number]: { number } } = {}
	local best, bestDistance = nil, math.huge
	for _, part in container:GetChildren() do
		if part.Name ~= "RoadMarking" then
			continue
		end
		local position = (part :: BasePart).CFrame.Position
		local key = math.round(position.Z * 4)
		local slice = slices[key]
		if not slice then
			slice = {}
			slices[key] = slice
		end
		table.insert(slice, position.X)
		local distance = math.abs(position.Z + LENGTH / 2)
		if distance < bestDistance then
			bestDistance, best = distance, key
		end
	end
	local lats = if best then slices[best] else {}
	table.sort(lats)
	local rendered = {}
	for _, lat in lats do
		table.insert(rendered, string.format("%.0f", lat))
	end
	return table.concat(rendered, " ")
end

local function plainRoad(lanes: number): Folder
	return generate(
		{ LaneCount = lanes, LaneWidth = LANE_WIDTH, SidewalkWidth = SIDEWALK },
		Vector3.new(lanes * LANE_WIDTH + 2 * SIDEWALK, 0, LENGTH)
	)
end

local function taperedRoad(base: number, target: number): Folder
	return generate({
		LaneCount = base,
		LaneWidth = LANE_WIDTH,
		SidewalkWidth = SIDEWALK,
		TaperBlue = true,
		TaperBlueLaneCount = target,
		TaperBlueLaneWidth = LANE_WIDTH,
		TaperBlueSidewalkWidth = SIDEWALK,
		TaperBlueLength = TAPER,
	}, Vector3.new(math.max(base, target) * LANE_WIDTH + 2 * SIDEWALK, 0, LENGTH))
end

return function(t: TestTypes.TestContext)
	-- Both parities, in both directions, and a step of one lane either way
	-- (the step that used to flip the centreline treatment every time)
	for _, pair in { { 5, 2 }, { 2, 5 }, { 4, 5 }, { 5, 4 }, { 6, 5 }, { 2, 3 }, { 3, 2 } } do
		local base, target = pair[1], pair[2]
		t.test(`markings: a {base} lane road tapered to {target} paints {target} lanes at that face`, function()
			local tapered = taperedRoad(base, target)
			local plain = plainRoad(target)
			local atFace = faceMarkings(tapered)
			local neighbour = faceMarkings(plain)
			tapered:Destroy()
			plain:Destroy()
			if atFace ~= neighbour then
				t.fail(`taper face painted [{atFace}], the neighbour paints [{neighbour}]`)
			end
		end)
	end

	t.test("markings: an untapered road is unaffected by the per-end layouts", function()
		-- Four lanes: edge lines, one divider each side, and the double-yellow
		-- centre pair. Width 4*24 + 16 = 112, so the edge line sits at
		-- 56 - 8 - 2.6 = 45.4 and the dividers at one lane width.
		local road = plainRoad(4)
		local markings = faceMarkings(road)
		road:Destroy()
		t.expect(markings).toBe("-45 -24 -1 1 24 45")
	end)

	t.test("markings: a single lane carries no centreline", function()
		local road = plainRoad(1)
		local markings = faceMarkings(road)
		road:Destroy()
		-- Width 24 + 16 = 40, edge lines at 20 - 8 - 2.6 = 9.4
		t.expect(markings).toBe("-9 9")
	end)
end
