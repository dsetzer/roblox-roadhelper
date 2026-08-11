--[[
	TaperHandles: the two edits a taper needs, on the selected road endpoint.

	- Width handles are the balls on each side of the end face (round, so they
	  don't read as more of the cone-shaped add handles). Dragging one sideways
	  widens or narrows the SEGMENT (snapped to whole lanes); the session
	  tapers whichever of its ends are joined to neighbours back to those
	  neighbours, so changing a road's width doesn't drag the rest of the road
	  along with it.
	- The length handle is the double-headed arrow on the centreline where the
	  end's taper finishes. Dragging it back and forth along the road sets how
	  long that transition runs. It only appears on an end which actually
	  tapers, and is coloured apart from the width handles.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)
local Math = require(DraggerFramework.Utility.Math)
local computeDraggedDistance = require(DraggerFramework.Utility.computeDraggedDistance)

local RoadMath = require(script.Parent.Parent.RoadMath)

local WIDTH_HANDLE_ID_LEFT = "WidthLeft"
local WIDTH_HANDLE_ID_RIGHT = "WidthRight"
local LENGTH_HANDLE_ID = "TaperLength"

local HIT_RADIUS = 1.5
local WIDTH_OUTSET = 1.6
local MARKER_SIZE = 1.4

-- Colours nothing else in the tool uses: the add handles are white/yellow/blue
-- and the move and rotate handles take the axis colours, so these two read as
-- their own pair rather than as more of either
local WIDTH_COLOR = Color3.fromRGB(90, 215, 205)
local LENGTH_COLOR = Color3.fromRGB(205, 130, 255)

local TaperHandles = {}
TaperHandles.__index = TaperHandles

export type Props = {
	-- The selected endpoint when it belongs to a road (never an intersection)
	GetEndpoint: () -> RoadMath.Endpoint?,
	StartWidth: () -> (),
	-- Requested full width of the segment, in studs
	ApplyWidth: (width: number) -> (),
	EndWidth: () -> (),
	StartLength: () -> (),
	ApplyLength: (length: number) -> (),
	EndLength: () -> (),
}

function TaperHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._handles = {}
	return setmetatable(self, TaperHandles)
end

function TaperHandles:update(draggerToolModel, selectionInfo)
	if self._draggingHandleId then
		return
	end
	local endpoint = self._props.GetEndpoint()
	if not endpoint then
		self._handles = {}
		return
	end
	local segment = endpoint.Segment
	-- The end's ACTUAL face, not its nominal box frame: endpoint positions are
	-- invariant under the Adjust angles, so the nominal frame doesn't turn when
	-- the end is rotated and these handles would keep the road's original
	-- heading. The move and rotate handles align the same way.
	local frame = RoadMath.actualEndpointFrame(endpoint)
	local scale = self._draggerContext:getHandleScale(frame.Position)
	-- Lateral axis of the end face, and the direction back into the segment
	local lateral = frame.LookVector:Cross(frame.UpVector)
	if lateral.Magnitude < 1e-4 then
		self._handles = {}
		return
	end
	lateral = lateral.Unit
	local inward = -frame.LookVector

	local handles = {}
	local halfWidth = RoadMath.endWidth(segment, endpoint.Id) / 2
	for _, side in { { WIDTH_HANDLE_ID_LEFT, -1 }, { WIDTH_HANDLE_ID_RIGHT, 1 } } do
		local handleId, sign = side[1], side[2] :: number
		handles[handleId] = {
			Kind = "Width",
			Position = frame.Position + lateral * (sign * (halfWidth + WIDTH_OUTSET * scale)),
			Axis = lateral * sign,
			Color = WIDTH_COLOR,
			Scale = scale,
		}
	end

	-- The length handle marks where the transition finishes, so it only makes
	-- sense on an end that is actually tapering
	if RoadMath.isEndTapered(segment, endpoint.Id) then
		local blueLength, redLength = RoadMath.taperLengths(segment)
		local length = if endpoint.Id == "Blue" then blueLength else redLength
		handles[LENGTH_HANDLE_ID] = {
			Kind = "Length",
			Position = frame.Position + inward * length,
			Axis = inward,
			Color = LENGTH_COLOR,
			Scale = scale,
			Length = length,
		}
	end
	self._handles = handles
end

function TaperHandles:shouldBiasTowardsObjects()
	return false
end

function TaperHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestHandleId, closestDistance = nil, math.huge
	for handleId, handle in self._handles do
		local hit, distance = Math.intersectRaySphere(
			mouseRay.Origin, mouseRay.Direction.Unit,
			handle.Position, HIT_RADIUS * handle.Scale)
		if hit and distance and distance < closestDistance then
			closestDistance = distance
			closestHandleId = handleId
		end
	end
	return closestHandleId, closestDistance, true
end

function TaperHandles:render(hoveredHandleId)
	local children = {}
	for handleId, handle in self._handles do
		local hovered = handleId == hoveredHandleId or handleId == self._draggingHandleId
		local size = MARKER_SIZE * handle.Scale * (if hovered then 1.25 else 1)
		if handle.Kind == "Width" then
			-- A ball rather than a cone: the add handles are cones, and these
			-- do something quite different, so they shouldn't look alike
			children[handleId] = Roact.createElement("SphereHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.new(handle.Position),
				Radius = size * 0.55,
				Color3 = handle.Color,
				Transparency = if hovered then 0 else 0.3,
				AlwaysOnTop = false,
				Shading = Enum.AdornShading.XRay,
				ZIndex = 0,
			})
		else
			-- A double-headed arrow lying along the road: it slides both ways,
			-- which a plain bar didn't say. Two cones nose to nose rather than
			-- the add handles' single outward one.
			for index, direction in { handle.Axis, -handle.Axis } do
				children[handleId .. index] = Roact.createElement("ConeHandleAdornment", {
					Adornee = workspace.Terrain,
					CFrame = CFrame.lookAlong(handle.Position, direction),
					Height = size * 1.3,
					Radius = size * 0.45,
					Color3 = handle.Color,
					Transparency = if hovered then 0 else 0.3,
					AlwaysOnTop = false,
					Shading = Enum.AdornShading.XRay,
					ZIndex = 0,
				})
			end
		end
	end
	return Roact.createElement("Folder", {}, children)
end

function TaperHandles:mouseDown(mouseRay, handleId)
	local handle = self._handles[handleId]
	if not handle then
		return
	end
	local endpoint = self._props.GetEndpoint()
	if not endpoint then
		return
	end
	self._draggingHandleId = handleId
	self._axis = handle.Axis
	self._startPosition = handle.Position
	local hasDistance, distance = computeDraggedDistance(self._startPosition, self._axis, mouseRay)
	self._startDistance = if hasDistance then distance else 0
	if handle.Kind == "Width" then
		self._startValue = RoadMath.endWidth(endpoint.Segment, endpoint.Id)
		self._props.StartWidth()
	else
		self._startValue = handle.Length
		self._props.StartLength()
	end
end

function TaperHandles:mouseDrag(mouseRay)
	local handleId = self._draggingHandleId
	if not handleId then
		return
	end
	local hasDistance, distance = computeDraggedDistance(self._startPosition, self._axis, mouseRay)
	if not hasDistance then
		return
	end
	local delta = distance - self._startDistance
	if self._handles[handleId].Kind == "Width" then
		-- Both sides move together: the road widens about its centreline, so
		-- dragging one side out by d adds 2d of width
		self._props.ApplyWidth(math.max(self._startValue + 2 * delta, 0))
	else
		self._props.ApplyLength(math.max(self._startValue + delta, 0))
	end
end

function TaperHandles:mouseUp(mouseRay)
	local handleId = self._draggingHandleId
	if not handleId then
		return
	end
	local kind = self._handles[handleId].Kind
	self._draggingHandleId = nil
	if kind == "Width" then
		self._props.EndWidth()
	else
		self._props.EndLength()
	end
end

return TaperHandles
