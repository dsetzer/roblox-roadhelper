--!strict
--[[
	RoadMath: Pure math for working with procedural road segments.

	A road segment is a ProceduralModel with a StraightRoadGenerator or
	CurveRoadGenerator ModuleScript child. Each segment has two endpoints:
	"Blue" (the start/entry end, matching the AdjustBlue* attributes) and
	"Red" (the end/exit end, matching AdjustRed*).

	Endpoint frames are the segments' *nominal* snap frames: positioned at the
	end edge centre (which is invariant under all the Adjust angle attributes),
	with LookVector pointing outward along the un-adjusted travel direction and
	UpVector equal to the model's up.

	Conventions used throughout (matching the generators):
	- width = LaneCount*LaneWidth + 2*SidewalkWidth
	- A road is built to its own lane layout (the plain LaneCount / LaneWidth /
	  SidewalkWidth attributes), and EACH end may taper to a layout of its own
	  over the last TaperBlueLength / TaperRedLength studs. So a segment has a
	  BaseWidth plus a BlueWidth and a RedWidth; Width (the one the bounding
	  box has to fit) is the widest of the three.
	- Straight: blue at local (-fs*sway, -Y/2, -Z/2) facing -Z, red at
	  (fs*sway, +Y/2, +Z/2) facing +Z, fs = Flip and -1 or 1,
	  sway = max((X - width)/2, 0). The road always climbs blue -> red.
	  End positions don't depend on which end is the wide one.
	- Curve: blue at (-X/2 + wBlue, blueY, -Z/2) facing -Z, red at
	  (X/2, redY, Z/2 - wRed) facing +X, w = that end's width/2. Flip swaps
	  which end is at the top of the box vertically (blue is the top when
	  Flip).
	- AdjustDir attributes are clockwise-positive in plan view, which matches
	  right-handed rotation about +Y with Roblox's CFrame.Angles.
]]

local RoadMath = {}

export type SegmentKind = "Straight" | "Curve" | "Intersection"
-- Roads have a Blue and a Red end; intersections have one id per stub
export type EndpointId = "Blue" | "Red" | "ZPlus" | "ZMinus" | "XPlus" | "XMinus"

export type SegmentInfo = {
	Model: Model, -- Actually a ProceduralModel
	Kind: SegmentKind,
	-- The width the bounding box has to fit: the wider of the two ends
	Width: number,
	Size: Vector3,
	Pivot: CFrame,
	Flip: boolean,
	-- Road-only fields: the segment's own width, and the width at each end
	-- (which differs from it where that end tapers)
	BaseWidth: number?,
	BlueWidth: number?,
	RedWidth: number?,
	-- Intersection-only fields: the X road's width, its angle from the Z
	-- road (radians), and whether the -X stub exists
	WidthX: number?,
	Angle: number?,
	ThroughRoad: boolean?,
}

-- The lane layout one end of a segment is built from
export type LaneLayout = {
	LaneCount: number,
	LaneWidth: number,
	SidewalkWidth: number,
}

export type Endpoint = {
	Segment: SegmentInfo,
	Id: EndpointId,
	WorldCFrame: CFrame,
}

export type MoveSolution = {
	Size: Vector3,
	Pivot: CFrame,
	Flip: boolean,
	-- True when the segment was rotated 180 degrees so its blue/red ends
	-- swap geographic places. The caller must also swap the segment's
	-- AdjustBlue*/AdjustRed* attributes (negating grades and banks) and
	-- re-color any endpoint references it holds.
	SwapEnds: boolean,
}

-- Shortest allowed segment (along the travel direction for straights)
RoadMath.MIN_LENGTH = 8

-- How close two endpoint centres must be to be considered joined
RoadMath.JOINT_TOLERANCE = 1

local GENERATOR_KINDS: { [string]: SegmentKind } = {
	StraightRoadGenerator = "Straight",
	CurveRoadGenerator = "Curve",
	RoadIntersectionGenerator = "Intersection",
}

--------------------------------------------------------------------------------
-- Segment discovery
--------------------------------------------------------------------------------

local function getNumberAttribute(model: Instance, name: string, default: number): number
	local value = model:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	return default
end

function RoadMath.getSegmentInfo(instance: Instance): SegmentInfo?
	if instance.ClassName ~= "ProceduralModel" then
		return nil
	end
	local kind: SegmentKind? = nil
	for _, child in instance:GetChildren() do
		local foundKind = GENERATOR_KINDS[child.Name]
		if foundKind and child:IsA("ModuleScript") then
			kind = foundKind
			break
		end
	end
	if not kind then
		return nil
	end
	local model = instance :: Model
	local sidewalkWidth = getNumberAttribute(model, "SidewalkWidth", 8)
	if kind == "Intersection" then
		return {
			Model = model,
			Kind = kind,
			Width = getNumberAttribute(model, "LaneCountZ", 2) * getNumberAttribute(model, "LaneWidthZ", 24)
				+ 2 * sidewalkWidth,
			WidthX = getNumberAttribute(model, "LaneCountX", 2) * getNumberAttribute(model, "LaneWidthX", 24)
				+ 2 * sidewalkWidth,
			Angle = math.rad(math.clamp(getNumberAttribute(model, "IntersectionAngle", 90), 25, 155)),
			ThroughRoad = model:GetAttribute("ThroughRoad") ~= false,
			Size = (model :: any).Size :: Vector3,
			Pivot = model:GetPivot(),
			Flip = false,
		}
	end
	local laneWidth = getNumberAttribute(model, "LaneWidth", 24)
	local laneCount = getNumberAttribute(model, "LaneCount", 2)
	local baseWidth = laneCount * laneWidth + 2 * sidewalkWidth
	-- Each end may taper to a layout of its own; the plain attributes stay the
	-- segment's own width, which is what the middle of the road is built to.
	local function endWidthOf(prefix: string): number
		if model:GetAttribute(prefix) ~= true then
			return baseWidth
		end
		local endLaneCount = getNumberAttribute(model, prefix .. "LaneCount", 0)
		local endLaneWidth = getNumberAttribute(model, prefix .. "LaneWidth", 0)
		local endSidewalk = getNumberAttribute(model, prefix .. "SidewalkWidth", -1)
		return (if endLaneCount > 0 then endLaneCount else laneCount)
				* (if endLaneWidth > 0 then endLaneWidth else laneWidth)
			+ 2 * (if endSidewalk >= 0 then endSidewalk else sidewalkWidth)
	end
	local blueWidth = endWidthOf("TaperBlue")
	local redWidth = endWidthOf("TaperRed")
	return {
		Model = model,
		Kind = kind,
		Width = math.max(baseWidth, blueWidth, redWidth),
		BaseWidth = baseWidth,
		BlueWidth = blueWidth,
		RedWidth = redWidth,
		Size = (model :: any).Size :: Vector3,
		Pivot = model:GetPivot(),
		Flip = model:GetAttribute("Flip") == true,
	}
end

-- Walk up from (typically) a generated road part to the segment it belongs to
function RoadMath.segmentFromDescendant(instance: Instance?): SegmentInfo?
	local current = instance
	while current and current ~= workspace and current ~= game do
		local info = RoadMath.getSegmentInfo(current)
		if info then
			return info
		end
		current = current.Parent
	end
	return nil
end

function RoadMath.findSegments(root: Instance): { SegmentInfo }
	local segments = {}
	-- Recurse manually so we can prune: segments never contain other segments
	-- (their contents are just the generator and generated geometry), and
	-- BaseParts never contain them either. This keeps rescans cheap even in
	-- places with a lot of generated road geometry.
	local function visit(container: Instance)
		for _, child in container:GetChildren() do
			local info = RoadMath.getSegmentInfo(child)
			if info then
				table.insert(segments, info)
			elseif not child:IsA("BasePart") then
				visit(child)
			end
		end
	end
	visit(root)
	return segments
end

--------------------------------------------------------------------------------
-- Lane layouts and tapering
--------------------------------------------------------------------------------

--[[
	A road is built to one lane layout — its own, in the plain LaneCount /
	LaneWidth / SidewalkWidth attributes — and EACH end may additionally taper
	to a layout of its own over the last TaperBlueLength / TaperRedLength studs
	of the road. The naming follows the AdjustBlue*/AdjustRed* attributes.

	The plain attributes are never touched to express a taper, so a taper can
	never read as a resize of the whole segment, and a generator that doesn't
	implement tapering still draws the road at its own width.
]]

RoadMath.TAPER_ATTRIBUTE_PREFIXES = { Blue = "TaperBlue", Red = "TaperRed" }

-- How long a taper should be when RoadHelper picks the length. Real
-- transitions run several times their width change so the edge deflects
-- gently; the floor keeps small changes from being abrupt, and callers clamp
-- to the road that has to fit it.
RoadMath.TAPER_RATIO = 6
RoadMath.MIN_TAPER_LENGTH = 16

function RoadMath.layoutWidth(layout: LaneLayout): number
	return layout.LaneCount * layout.LaneWidth + 2 * layout.SidewalkWidth
end

function RoadMath.layoutsMatch(a: LaneLayout, b: LaneLayout): boolean
	return a.LaneCount == b.LaneCount
		and a.LaneWidth == b.LaneWidth
		and a.SidewalkWidth == b.SidewalkWidth
end

local function taperPrefix(id: EndpointId): string?
	return RoadMath.TAPER_ATTRIBUTE_PREFIXES[id]
end

-- The segment's own lane layout: what it is built from away from any taper,
-- and the per-axis layout for an intersection's exits.
function RoadMath.baseLayout(segment: SegmentInfo, id: EndpointId): LaneLayout
	local model = segment.Model
	local axis = ""
	if segment.Kind == "Intersection" then
		axis = if id == "XPlus" or id == "XMinus" then "X" else "Z"
	end
	return {
		LaneCount = getNumberAttribute(model, "LaneCount" .. axis, 2),
		LaneWidth = getNumberAttribute(model, "LaneWidth" .. axis, 24),
		SidewalkWidth = getNumberAttribute(model, "SidewalkWidth", 8),
	}
end

-- Whether an end tapers away from the segment's own layout
function RoadMath.isEndTapered(segment: SegmentInfo, id: EndpointId): boolean
	local prefix = taperPrefix(id)
	if not prefix or segment.Kind == "Intersection" then
		return false
	end
	return segment.Model:GetAttribute(prefix) == true
end

-- The lane layout one end of a segment is built from: its taper layout when
-- that end tapers, the segment's own layout otherwise.
function RoadMath.endLayout(segment: SegmentInfo, id: EndpointId): LaneLayout
	local base = RoadMath.baseLayout(segment, id)
	local prefix = taperPrefix(id)
	if not prefix or not RoadMath.isEndTapered(segment, id) then
		return base
	end
	-- Zero lane values (and a negative sidewalk width) mean "same as the road",
	-- matching the generators: an end can taper in one respect without having
	-- to restate the rest of its layout.
	local model = segment.Model
	local laneCount = getNumberAttribute(model, prefix .. "LaneCount", 0)
	local laneWidth = getNumberAttribute(model, prefix .. "LaneWidth", 0)
	local sidewalkWidth = getNumberAttribute(model, prefix .. "SidewalkWidth", -1)
	return {
		LaneCount = if laneCount > 0 then laneCount else base.LaneCount,
		LaneWidth = if laneWidth > 0 then laneWidth else base.LaneWidth,
		SidewalkWidth = if sidewalkWidth >= 0 then sidewalkWidth else base.SidewalkWidth,
	}
end

-- The length of a segment along its travel direction, which taper lengths are
-- measured against. Approximate for curves (entry run plus exit run rather
-- than the true arc length), which is all a taper length needs.
function RoadMath.segmentLength(segment: SegmentInfo): number
	if segment.Kind == "Curve" then
		return math.max(segment.Size.X - RoadMath.endWidth(segment, "Blue") / 2, 0)
			+ math.max(segment.Size.Z - RoadMath.endWidth(segment, "Red") / 2, 0)
	end
	return segment.Size.Z
end

function RoadMath.defaultTaperLength(widthChange: number, available: number): number
	local wanted = math.max(math.abs(widthChange) * RoadMath.TAPER_RATIO, RoadMath.MIN_TAPER_LENGTH)
	return math.min(wanted, available)
end

--[[
	How far back from an end its taper runs. Zero or unset means half the
	segment. The two ends share the road, so their windows are scaled down to
	fit rather than allowed to overlap and fight over the middle.
]]
function RoadMath.taperLengths(segment: SegmentInfo): (number, number)
	local length = RoadMath.segmentLength(segment)
	local function wanted(id: EndpointId): number
		if not RoadMath.isEndTapered(segment, id) then
			return 0
		end
		local prefix = taperPrefix(id) :: string
		local value = getNumberAttribute(segment.Model, prefix .. "Length", 0)
		return math.clamp(if value > 0 then value else length / 2, 0, length)
	end
	local blue, red = wanted("Blue"), wanted("Red")
	local total = blue + red
	if total > length and total > 0 then
		local scale = length / total
		blue *= scale
		red *= scale
	end
	return blue, red
end

-- The attributes for a road built to one layout throughout, with no tapers
function RoadMath.uniformLayoutAttributes(layout: LaneLayout): { [string]: any }
	return {
		LaneCount = layout.LaneCount,
		LaneWidth = layout.LaneWidth,
		SidewalkWidth = layout.SidewalkWidth,
		TaperBlue = false,
		TaperRed = false,
	}
end

--[[
	The attributes making ONE end of a road taper to `layout` while the rest of
	the segment — and its other end — keep what they have. Only that end's
	Taper* attributes are written.
]]
function RoadMath.layoutAttributesForEnd(
	segment: SegmentInfo,
	id: EndpointId,
	layout: LaneLayout
): { [string]: any }
	local prefix = taperPrefix(id)
	if not prefix then
		return {}
	end
	local base = RoadMath.baseLayout(segment, id)
	if RoadMath.layoutsMatch(base, layout) then
		-- Nothing to transition to: drop the taper rather than leaving one
		-- that tapers to the width it already is
		return { [prefix] = false }
	end
	local attributes: { [string]: any } = {
		[prefix] = true,
		[prefix .. "LaneCount"] = layout.LaneCount,
		[prefix .. "LaneWidth"] = layout.LaneWidth,
		[prefix .. "SidewalkWidth"] = layout.SidewalkWidth,
	}
	-- A newly tapered end gets a length to suit its width change; an end that
	-- already tapers keeps the length it has, so a hand-set one survives.
	if not RoadMath.isEndTapered(segment, id)
		or getNumberAttribute(segment.Model, prefix .. "Length", 0) <= 0
	then
		attributes[prefix .. "Length"] = RoadMath.defaultTaperLength(
			RoadMath.layoutWidth(layout) - RoadMath.layoutWidth(base),
			RoadMath.segmentLength(segment) / 2
		)
	end
	return attributes
end

function RoadMath.taperLengthAttributes(id: EndpointId, length: number): { [string]: any }
	local prefix = taperPrefix(id)
	if not prefix then
		return {}
	end
	return { [prefix .. "Length"] = math.max(length, 0) }
end

-- Whether the segment changes width along its length at all. Derived from the
-- widths rather than the attributes, so it answers the question the callers
-- actually mean: does this road transition?
function RoadMath.isTapered(segment: SegmentInfo): boolean
	local base = segment.BaseWidth or segment.Width
	return RoadMath.endWidth(segment, "Blue") ~= base or RoadMath.endWidth(segment, "Red") ~= base
end

-- The road width at one end of a segment: a tapered end is built to its own
-- layout, and an intersection's X road can differ from its Z road.
function RoadMath.endWidth(segment: SegmentInfo, id: EndpointId): number
	if id == "Blue" then
		return segment.BlueWidth or segment.Width
	elseif id == "Red" then
		return segment.RedWidth or segment.Width
	elseif id == "XPlus" or id == "XMinus" then
		return segment.WidthX or segment.Width
	end
	return segment.Width
end

--------------------------------------------------------------------------------
-- Endpoint frames
--------------------------------------------------------------------------------

--[[
	Endpoint frame in the segment's local (pivot) space.

	`width` is the segment's box width (the wider end of a taper); `endWidth`
	is the width at this particular end, defaulting to the box width. Only the
	curve's end offsets depend on it — a straight's ends sit on the box faces
	whichever end is the wide one.
]]
function RoadMath.localEndpointFrame(
	kind: SegmentKind,
	size: Vector3,
	width: number,
	flip: boolean,
	id: EndpointId,
	endWidth: number?
): CFrame
	local halfY = size.Y / 2
	local halfZ = size.Z / 2
	if kind == "Straight" then
		local sway = math.max((size.X - width) / 2, 0)
		local fs = if flip then -1 else 1
		if id == "Blue" then
			return CFrame.lookAlong(Vector3.new(-fs * sway, -halfY, -halfZ), -Vector3.zAxis)
		else
			return CFrame.lookAlong(Vector3.new(fs * sway, halfY, halfZ), Vector3.zAxis)
		end
	else
		local w = (endWidth or width) / 2
		local halfX = size.X / 2
		if id == "Blue" then
			local y = if flip then halfY else -halfY
			return CFrame.lookAlong(Vector3.new(-halfX + w, y, -halfZ), -Vector3.zAxis)
		else
			local y = if flip then -halfY else halfY
			return CFrame.lookAlong(Vector3.new(halfX, y, halfZ - w), Vector3.xAxis)
		end
	end
end

-- An intersection's ends sit at the box bottom: the Z road's ends centred on
-- the ±Z faces, and the (possibly angled) X road's squared ends at halfX
-- along its own direction
local function intersectionEndpointFrame(segment: SegmentInfo, id: EndpointId): CFrame
	local size = segment.Size
	local halfY = size.Y / 2
	if id == "ZPlus" then
		return CFrame.lookAlong(Vector3.new(0, -halfY, size.Z / 2), Vector3.zAxis)
	elseif id == "ZMinus" then
		return CFrame.lookAlong(Vector3.new(0, -halfY, -size.Z / 2), -Vector3.zAxis)
	end
	local angle = segment.Angle or math.pi / 2
	local uX = Vector3.new(math.sin(angle), 0, math.cos(angle))
	local s = if id == "XPlus" then 1 else -1
	local p = uX * (s * size.X / 2)
	return CFrame.lookAlong(Vector3.new(p.X, -halfY, p.Z), uX * s)
end

function RoadMath.getEndpoint(segment: SegmentInfo, id: EndpointId): Endpoint
	local localFrame
	if segment.Kind == "Intersection" then
		localFrame = intersectionEndpointFrame(segment, id)
	else
		localFrame = RoadMath.localEndpointFrame(
			segment.Kind,
			segment.Size,
			segment.Width,
			segment.Flip,
			id,
			RoadMath.endWidth(segment, id)
		)
	end
	return {
		Segment = segment,
		Id = id,
		WorldCFrame = segment.Pivot * localFrame,
	}
end

function RoadMath.getEndpoints(segment: SegmentInfo): (Endpoint, Endpoint)
	return RoadMath.getEndpoint(segment, "Blue"), RoadMath.getEndpoint(segment, "Red")
end

-- The endpoint ids a segment has
function RoadMath.endpointIds(segment: SegmentInfo): { EndpointId }
	if segment.Kind == "Intersection" then
		local ids: { EndpointId } = { "ZPlus", "ZMinus", "XPlus" }
		if segment.ThroughRoad then
			table.insert(ids, "XMinus")
		end
		return ids
	end
	return { "Blue", "Red" }
end

function RoadMath.allEndpoints(segment: SegmentInfo): { Endpoint }
	local endpoints = {}
	for _, id in RoadMath.endpointIds(segment) do
		table.insert(endpoints, RoadMath.getEndpoint(segment, id))
	end
	return endpoints
end

-- The road width at an endpoint
function RoadMath.endpointWidth(endpoint: Endpoint): number
	return RoadMath.endWidth(endpoint.Segment, endpoint.Id)
end

-- The endpoint frame rotated to the end's *actual* face: the effective Dir
-- yaw applied about the frame's up axis, position unchanged. Used to align
-- handles and hover UX with the face rather than the bounding box.
function RoadMath.actualEndpointFrame(endpoint: Endpoint): CFrame
	local dirName = if endpoint.Id == "Blue" then "AdjustBlueDir" else "AdjustRedDir"
	local dirAngle = math.rad(getNumberAttribute(endpoint.Segment.Model, dirName, 0))
	dirAngle *= RoadMath.flipFactor(endpoint.Segment, "Dir")
	local frame = endpoint.WorldCFrame
	if dirAngle == 0 then
		return frame
	end
	return CFrame.fromAxisAngle(frame.UpVector, dirAngle) * (frame - frame.Position) + frame.Position
end

-- The outward direction of the end's *actual* (Adjust-angle rotated) face, in
-- world space, horizontal component only. Used for placing new segments off an
-- open end so they align with the face rather than the nominal frame.
function RoadMath.actualOutwardDirection(endpoint: Endpoint): Vector3
	local dirName = if endpoint.Id == "Blue" then "AdjustBlueDir" else "AdjustRedDir"
	local dirAngle = math.rad(getNumberAttribute(endpoint.Segment.Model, dirName, 0))
	dirAngle *= RoadMath.flipFactor(endpoint.Segment, "Dir")
	local nominalOutward = endpoint.WorldCFrame.LookVector
	local up = endpoint.WorldCFrame.UpVector
	return CFrame.fromAxisAngle(up, dirAngle):VectorToWorldSpace(nominalOutward)
end

--------------------------------------------------------------------------------
-- Joints
--------------------------------------------------------------------------------

-- Find the endpoint of another segment which is joined to this one (a "closed"
-- endpoint), or nil if the endpoint is open.
function RoadMath.findJoint(endpoint: Endpoint, segments: { SegmentInfo }): Endpoint?
	local position = endpoint.WorldCFrame.Position
	local outward = endpoint.WorldCFrame.LookVector
	local bestEndpoint: Endpoint? = nil
	local bestDistance = RoadMath.JOINT_TOLERANCE
	for _, segment in segments do
		if segment.Model == endpoint.Segment.Model then
			continue
		end
		for _, id in RoadMath.endpointIds(segment) do
			local other = RoadMath.getEndpoint(segment, id)
			local distance = (other.WorldCFrame.Position - position).Magnitude
			-- Faces must roughly oppose to count as a joint
			if distance <= bestDistance and other.WorldCFrame.LookVector:Dot(outward) < -0.5 then
				bestDistance = distance
				bestEndpoint = other
			end
		end
	end
	return bestEndpoint
end

--------------------------------------------------------------------------------
-- Moving endpoints
--------------------------------------------------------------------------------

-- Solve the new Size / Pivot / Flip for a segment when one of its endpoints is
-- moved to a new world position while its other endpoint stays fixed. The
-- segment's rotation is unchanged. Clamps keep the segment valid, so the moved
-- endpoint may not exactly reach the requested position.
function RoadMath.solveMove(segment: SegmentInfo, movedId: EndpointId, newWorldPosition: Vector3): MoveSolution
	local fixedId: EndpointId = if movedId == "Blue" then "Red" else "Blue"
	local fixedWorld = RoadMath.getEndpoint(segment, fixedId).WorldCFrame.Position
	local rotation = segment.Pivot.Rotation

	-- Delta from the blue endpoint to the red endpoint, in local space
	local delta = rotation:VectorToObjectSpace(newWorldPosition - fixedWorld)
	if movedId == "Blue" then
		delta = -delta
	end

	local swapEnds = false
	if segment.Kind == "Straight" and delta.Y < 0 then
		-- Straight roads always climb blue -> red. To pull this end below the
		-- other one, rotate the segment 180 degrees about vertical so the ends
		-- swap roles: the S-bend has 180-degree rotational symmetry, so the
		-- worldly shape (and the sway and Flip values) are preserved, and the
		-- dragged geographic end becomes the (bottom) blue end.
		swapEnds = true
		rotation = rotation * CFrame.Angles(0, math.pi, 0)
		movedId, fixedId = fixedId, movedId
		-- blue->red delta in the rotated frame: X and Z negate twice (once
		-- from reversing the ends, once from the 180 rotation), Y negates once
		delta = Vector3.new(delta.X, -delta.Y, delta.Z)
	elseif segment.Kind == "Curve" then
		-- A curve is a quarter turn of fixed handedness: travelling blue ->
		-- red always bends the same way, so the corner only reaches the side
		-- of the fixed end that the moved end started on. The opposite turn
		-- is the SAME corner driven the other way round, so when the moved
		-- end crosses the line the fixed end looks along, trade the ends'
		-- roles and yaw the box a quarter turn to suit. Which quarter: the
		-- fixed end keeps its exact position and outward direction, and blue
		-- looks -Z where red looks +X, so the two directions of the trade are
		-- opposite quarter turns.
		-- The component to test is the one across the fixed end's own travel
		-- direction; the other going negative puts the moved end BEHIND the
		-- fixed one, which no quarter turn reaches either way.
		local crossedOver = if fixedId == "Blue" then delta.X < 0 else delta.Z < 0
		if crossedOver then
			swapEnds = true
			rotation = rotation * CFrame.Angles(0, if fixedId == "Blue" then math.pi / 2 else -math.pi / 2, 0)
			movedId, fixedId = fixedId, movedId
			-- The fixed end hasn't moved, only changed colour, so the delta
			-- re-derives from the same world points in the new frame
			delta = rotation:VectorToObjectSpace(newWorldPosition - fixedWorld)
			if movedId == "Blue" then
				delta = -delta
			end
		end
	end

	-- Each end's width follows its geographic end through a swap (the taper
	-- attributes are traded to match, see swappedTaperValues), so read them
	-- against the colours the ends are about to have
	local blueWidth = RoadMath.endWidth(segment, "Blue")
	local redWidth = RoadMath.endWidth(segment, "Red")
	if swapEnds then
		blueWidth, redWidth = redWidth, blueWidth
	end

	local width = segment.Width
	local newSize: Vector3
	local newFlip: boolean
	if segment.Kind == "Straight" then
		-- Lateral offset becomes sway (and its side selects Flip)
		newFlip = delta.X < 0
		newSize = Vector3.new(
			width + math.abs(delta.X),
			delta.Y,
			math.max(delta.Z, RoadMath.MIN_LENGTH)
		)
	else
		-- The corner's entry/exit are on perpendicular faces; each in-plane
		-- delta axis maps to one size axis, offset by the width at the end
		-- that face carries. Flip selects which end is the top.
		newFlip = delta.Y < 0
		newSize = Vector3.new(
			math.max(delta.X + blueWidth / 2, width),
			math.abs(delta.Y),
			math.max(delta.Z + redWidth / 2, width)
		)
	end

	-- Position the pivot so that the fixed endpoint stays where it was
	local newLocalFixed = RoadMath.localEndpointFrame(
		segment.Kind,
		newSize,
		width,
		newFlip,
		fixedId,
		if fixedId == "Blue" then blueWidth else redWidth
	)
	local pivotPosition = fixedWorld - rotation:VectorToWorldSpace(newLocalFixed.Position)
	return {
		Size = newSize,
		Pivot = rotation + pivotPosition,
		Flip = newFlip,
		SwapEnds = swapEnds,
	}
end

-- The attribute updates accompanying a SwapEnds solution: the blue and red
-- adjust values trade places, following their geographic ends. Dir carries
-- over unchanged (yaw angles are frame independent for upright models);
-- grade and bank negate because the travel direction through each geographic
-- end reverses, preserving each face's actual world geometry.
function RoadMath.swappedAdjustValues(get: (name: string) -> number): { [string]: number }
	return {
		AdjustBlueDir = get("AdjustRedDir"),
		AdjustBlueGrade = -get("AdjustRedGrade"),
		AdjustBlueBank = -get("AdjustRedBank"),
		AdjustRedDir = get("AdjustBlueDir"),
		AdjustRedGrade = -get("AdjustBlueGrade"),
		AdjustRedBank = -get("AdjustBlueBank"),
	}
end

-- The taper updates accompanying a SwapEnds solution: each taper is pinned to
-- a geographic end, so the two ends' taper attributes trade places along with
-- their colours.
function RoadMath.swappedTaperValues(segment: SegmentInfo): { [string]: any }?
	if not RoadMath.isTapered(segment) then
		return nil
	end
	local model = segment.Model
	local swapped: { [string]: any } = {}
	for _, pair in { { "TaperBlue", "TaperRed" }, { "TaperRed", "TaperBlue" } } do
		local from, to = pair[1], pair[2]
		swapped[to] = model:GetAttribute(from) == true
		for _, suffix in { "LaneCount", "LaneWidth", "SidewalkWidth", "Length" } do
			swapped[to .. suffix] = model:GetAttribute(from .. suffix)
		end
	end
	return swapped
end

--------------------------------------------------------------------------------
-- Adjust angle mapping
--------------------------------------------------------------------------------

export type AdjustAxis = "Dir" | "Grade" | "Bank"

function RoadMath.adjustAttributeName(id: EndpointId, axis: AdjustAxis): string
	return "Adjust" .. (if id == "Blue" then "Blue" else "Red") .. axis
end

function RoadMath.getAdjustValue(endpoint: Endpoint, axis: AdjustAxis): number
	return getNumberAttribute(endpoint.Segment.Model, RoadMath.adjustAttributeName(endpoint.Id, axis), 0)
end

--[[
	Sign mapping for rotating a joint. The rotation gesture is measured at the
	*selected* endpoint's frame:
	- Dir: right-handed angle about the up axis
	- Grade: right-handed angle about the lateral (right) axis, so positive
	  tips the selected end's outward direction upward
	- Bank: right-handed angle about the selected end's outward axis

	For each end attached to the joint, the attribute delta is sign * angle:
	- Dir: +1 for every end (attribute yaw convention matches CFrame yaw for
	  upright models, and all mated faces rotate together about up)
	- Grade/Bank: colorSign * facingSign, where colorSign is +1 for Red and
	  -1 for Blue (Red's travel direction is outward, Blue's is inward), and
	  facingSign is +1 when the end faces the same way as the selected end
	  (i.e. it IS the selected end) and -1 for the mated partner.
]]
--[[
	How a segment's Flip attribute changes the *world* meaning of each Adjust
	attribute (mirroring the corresponding generator math):
	- Curve grades are multiplied by the climb sign, which Flip negates.
	- Straight Flip mirrors the path horizontally, negating the effective yaw
	  of the Dir attributes.
	- Banks (and the remaining combinations) are unaffected.
]]
function RoadMath.flipFactor(segment: SegmentInfo, axis: AdjustAxis): number
	if not segment.Flip then
		return 1
	end
	if axis == "Grade" and segment.Kind == "Curve" then
		return -1
	end
	if axis == "Dir" and segment.Kind == "Straight" then
		return -1
	end
	return 1
end

function RoadMath.adjustDeltaSign(selected: Endpoint, target: Endpoint, axis: AdjustAxis): number
	local flipFactor = RoadMath.flipFactor(target.Segment, axis)
	if axis == "Dir" then
		return flipFactor
	end
	local colorSign = if target.Id == "Red" then 1 else -1
	local facing = target.WorldCFrame.LookVector:Dot(selected.WorldCFrame.LookVector)
	local facingSign = if facing >= 0 then 1 else -1
	return colorSign * facingSign * flipFactor
end

-- The frame new segments are placed against. Normally the endpoint's
-- nominal frame, but an intersection's angled X exits square their outward
-- direction to the intersection's own box axis: the new segment stays
-- box-aligned with the intersection, and its joining end's Dir adjust takes
-- up the skew instead (see matchingAdjust).
function RoadMath.placementFrame(endpoint: Endpoint): CFrame
	if endpoint.Segment.Kind == "Intersection" and (endpoint.Id == "XPlus" or endpoint.Id == "XMinus") then
		local s = if endpoint.Id == "XPlus" then 1 else -1
		local outward = endpoint.Segment.Pivot:VectorToWorldSpace(Vector3.new(s, 0, 0))
		return CFrame.lookAlong(endpoint.WorldCFrame.Position, outward)
	end
	return endpoint.WorldCFrame
end

-- The Adjust values a newly added segment's joining end must have to mate
-- flush with the given open end. The new model is placed aligned with the
-- open end's nominal frame (not its Dir-rotated face), so the joining end
-- needs the same effective world Dir yaw as the open end: rotating both
-- faces of a joint by the same world yaw keeps them flush. The world yaw of
-- any end is flipFactor("Dir") * attribute about +Y regardless of end color,
-- and the new segment is unflipped, so its attribute is the effective yaw
-- directly.
function RoadMath.matchingAdjust(openEnd: Endpoint, newEndId: EndpointId): { Dir: number, Grade: number, Bank: number }
	if openEnd.Segment.Kind == "Intersection" then
		-- Flat exits: no grade/bank. Dir takes up the yaw between the
		-- box-aligned placement frame and the actual exit direction (zero
		-- for the Z exits, the skew for angled X exits).
		local n = RoadMath.placementFrame(openEnd).LookVector
		local d = openEnd.WorldCFrame.LookVector
		local yaw = math.deg(math.atan2(n:Cross(d).Y, n:Dot(d)))
		return { Dir = math.round(yaw * 100) / 100, Grade = 0, Bank = 0 }
	end
	local openColorSign = if openEnd.Id == "Red" then 1 else -1
	local newColorSign = if newEndId == "Red" then 1 else -1
	local k = -openColorSign * newColorSign
	-- The new segment is created unflipped, but the open end's attribute
	-- values must be converted through its own flip factors to get their
	-- actual world meaning.
	return {
		Dir = RoadMath.flipFactor(openEnd.Segment, "Dir") * RoadMath.getAdjustValue(openEnd, "Dir"),
		Grade = k * RoadMath.flipFactor(openEnd.Segment, "Grade") * RoadMath.getAdjustValue(openEnd, "Grade"),
		Bank = k * RoadMath.getAdjustValue(openEnd, "Bank"),
	}
end

--------------------------------------------------------------------------------
-- New segment placement
--------------------------------------------------------------------------------

export type TurnDirection = "Left" | "Straight" | "Right" | "Intersection"

-- Plan-view angle of a direction vector, matching the clockwise-positive
-- convention: angle(v) increases when v is rotated by CFrame.Angles(0, a, 0)
-- with positive a.
local function yawAngleOf(direction: Vector3): number
	return math.atan2(direction.X, direction.Z)
end

--[[
	Compute the placement for a new segment extending the given open end.
	Returns the segment kind, which end of the new segment joins the open end,
	the new segment's pivot CFrame, and its size.

	- Straight extends with a StraightRoad joined at its Blue end.
	- Right turns join a CurveRoad at its Blue (entry) end: entering the curve
	  and exiting +X is a right turn.
	- Left turns join a CurveRoad at its Red (exit) end, traversed backwards.
]]
function RoadMath.placeNewSegment(
	openEnd: Endpoint,
	turn: TurnDirection,
	width: number,
	sizeOverride: Vector3?
): (SegmentKind, EndpointId, CFrame, Vector3)
	local kind: SegmentKind = if turn == "Straight" then "Straight" else "Curve"
	local joinId: EndpointId = if turn == "Left" then "Red" else "Blue"

	local size = sizeOverride
	if not size then
		if kind == "Straight" then
			size = Vector3.new(width, 0, math.max(2 * width, RoadMath.MIN_LENGTH))
		else
			size = Vector3.new(2 * width, 0, 2 * width)
		end
	end
	assert(size)

	-- Yaw the new model so its joining end's nominal outward direction opposes
	-- the open end's PLACEMENT frame: the new model stays aligned the same way
	-- as the segment it extends (box-aligned for an intersection's angled
	-- exits), and any rotation of the actual face is matched by a Dir on the
	-- joining end instead (see matchingAdjust), keeping the joint flush.
	local placement = RoadMath.placementFrame(openEnd)
	local outward = placement.LookVector
	local joinLocal = RoadMath.localEndpointFrame(kind, size, width, false, joinId)
	local targetYaw = yawAngleOf(-outward)
	local nominalYaw = yawAngleOf(joinLocal.LookVector)
	local rotation = CFrame.Angles(0, targetYaw - nominalYaw, 0)

	local pivotPosition = placement.Position - rotation:VectorToWorldSpace(joinLocal.Position)
	return kind, joinId, rotation + pivotPosition, size
end

--------------------------------------------------------------------------------
-- Lane layout changes
--------------------------------------------------------------------------------

--[[
	Compensate the bounds (and pivot) for a road width change so that BOTH
	endpoint positions stay exactly where they are (keeping any joints sealed).
	The two ends may take different widths, which is what tapers the road.

	Straight: endpoints sit at (±sway, ·, ±Z/2) with sway = (X - width)/2 and
	width the WIDER end, so growing X by the delta of that maximum keeps sway
	(and both endpoints) unchanged. Which end is the wide one doesn't matter.

	Curve: blue sits at (-X/2 + wBlue, ·, -Z/2) and red at (X/2, ·, Z/2 - wRed)
	in pivot space, w being that end's half width. Solving both fixed under
	half-width deltas dBlue and dRed gives X' = X + dBlue, Z' = Z + dRed, with
	the pivot (box centre) shifted by (-dBlue/2, 0, dRed/2).
]]
function RoadMath.solveWidthChange(
	segment: SegmentInfo,
	newBlueWidth: number,
	newRedWidth: number?,
	newBaseWidth: number?
): { Size: Vector3, Pivot: CFrame }
	local newRed = newRedWidth or newBlueWidth
	-- The box has to fit the widest cross-section: either end, or the
	-- segment's own width where that is wider than both
	local newMax = math.max(newBlueWidth, newRed, newBaseWidth or 0)
	local size = segment.Size
	if segment.Kind == "Straight" then
		local delta = newMax - segment.Width
		return {
			Size = Vector3.new(math.max(size.X + delta, newMax), size.Y, size.Z),
			Pivot = segment.Pivot,
		}
	else
		local dBlue = (newBlueWidth - RoadMath.endWidth(segment, "Blue")) / 2
		local dRed = (newRed - RoadMath.endWidth(segment, "Red")) / 2
		return {
			Size = Vector3.new(size.X + dBlue, size.Y, size.Z + dRed),
			Pivot = segment.Pivot * CFrame.new(-dBlue / 2, 0, dRed / 2),
		}
	end
end

return RoadMath
