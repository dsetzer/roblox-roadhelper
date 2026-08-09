--[[
	TaperHandles: the two edits a taper needs, on the selected road endpoint.

	- Width handles sit on each side of the end face. Dragging one sideways
	  widens or narrows the SEGMENT (snapped to whole lanes); the session
	  tapers whichever of its ends are joined to neighbours back to those
	  neighbours, so changing a road's width doesn't drag the rest of the road
	  along with it.
	- A length handle sits on the centreline where the end's taper finishes.
	  Dragging it back and forth along the road sets how long that transition
	  runs. It only appears on an end which actually tapers.
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

local WIDTH_COLOR = Color3.fromRGB(120, 220, 160)
local LENGTH_COLOR = Color3.fromRGB(255, 200, 40)

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
	local frame = endpoint.WorldCFrame
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
			-- A flat outward-pointing wedge: it reads as "drag me sideways"
			children[handleId] = Roact.createElement("ConeHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.lookAlong(handle.Position - handle.Axis * (size * 0.6), handle.Axis),
				Height = size * 1.4,
				Radius = size * 0.5,
				Color3 = handle.Color,
				Transparency = if hovered then 0 else 0.3,
				AlwaysOnTop = false,
				Shading = Enum.AdornShading.XRay,
				ZIndex = 0,
			})
		else
			-- A bar laid across the road marking where the taper finishes
			children[handleId] = Roact.createElement("BoxHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.lookAlong(handle.Position, handle.Axis),
				Size = Vector3.new(size * 3.5, size * 0.4, size * 0.9),
				Color3 = handle.Color,
				Transparency = if hovered then 0 else 0.3,
				AlwaysOnTop = false,
				Shading = Enum.AdornShading.XRay,
				ZIndex = 0,
			})
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
