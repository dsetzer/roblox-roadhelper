# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RoadHelper is a Roblox Studio plugin (based on the Redupe plugin's architecture) for working
with procedural road segments — `ProceduralModel` instances containing a
`StraightRoadGenerator` or `CurveRoadGenerator` ModuleScript, as found in the ProceduralCarts
place. The core mechanic is selecting and manipulating road segment *endpoints*:

- An endpoint is one end of a segment: **blue** (start/entry) or **red** (end/exit),
  matching the road generators' `AdjustBlue*`/`AdjustRed*` attribute naming.
- An endpoint is **open** (no adjacent road) or **closed** (two segment ends joined).
- Selected endpoints get **move handles** (repositions the endpoint by editing the segment's
  Size/pivot/Flip — both segments for a closed joint) and **rotate handles** (edits the
  `AdjustBlue/RedDir/Grade/Bank` attributes — both sides of a closed joint stay continuous).
- Open endpoints additionally get three **add handles** (left turn / straight / right turn):
  click to append a new segment, click-drag to place its far endpoint following the cursor.
- Dragging an end onto a neighbour of a different width **auto tapers** it: that end takes the
  neighbour's lane layout and transitions back to the segment's own width over the taper
  length, instead of stepping at the joint.
- Selected endpoints also get **width handles** (widen/narrow the segment in whole lanes; ends
  joined to neighbours auto taper back to them, so the neighbours don't move) and a **taper
  length handle** on a tapering end (drag along the road to set how far the transition runs).
- The UI panel shows the selected endpoint's angles for numeric editing, a Taper section, plus
  an Add section with Straight/Curve buttons that add a segment in front of the camera.

## Build Commands

```bash
# Build the plugin (default build task)
rojo build -p "RoadHelper V1.0.rbxmx"

# Run tests (*.spec.lua files in the src folder); requires the runtests.rbxl place open
python runtests.py

# Install dependencies (must fix the Luau types after installing)
wally install
rojo sourcemap default.project.json --output sourcemap.json
wally-package-types --sourcemap sourcemap.json Packages
```

## Architecture

**Entry point:** `loader.server.lua` creates the toolbar button and dock widget, then
lazy-loads `src/main.lua` on first activation.

- `src/main.lua` — Orchestrator: plugin activation lifecycle, React UI root, session management.
- `src/RoadMath.lua` — Pure math: segment descriptors from a ProceduralModel's Size/attributes/
  pivot, blue/red endpoint world frames, endpoint-move solving (Size + pivot + Flip), joint
  detection, and Adjust-attribute sign mapping for rotations at either end color.
- `src/createRoadSession.lua` — Active tool session: mounts a DraggerFramework
  DraggerToolComponent with a custom handle list, tracks the selected endpoint, applies edits
  with ChangeHistoryService recordings. Workspace walks are kept off the main thread's back:
  the generator scan yields every few hundred instances, and template lookup reuses the models
  that walk found rather than re-walking (it runs inside mouseDown, so it can't yield).
- `src/Handles/` — Handle implementations following the DraggerFramework handles protocol
  (`update`/`hitTest`/`render`/`mouseDown`/`mouseDrag`/`mouseUp`):
  - `EndpointPickHandles.lua` — clickable markers on every road endpoint.
  - `EndpointMoveHandles.lua` — arrow handles moving the selected endpoint (adapted from Redupe).
  - `EndpointRotateHandles.lua` — arc handles editing Adjust angles (adapted from Redupe).
  - `AddHandles.lua` — left/straight/right segment-append handles on open endpoints.
- `src/Dragger/` — handle view components (arrows/arcs) carried over from Redupe.
- `src/Templates/` — the road generators. New segments clone an existing segment where there
  is one (which inherits its already-loaded generator, keeping fresh module loads off the add
  path) and are built from these only when the place has none of that kind. Appearance
  attributes are copied on before the new model is parented, so it generates once, already
  correct. A clone carries its neighbour's generator, which may predate tapering; generators
  RoadHelper installs are stamped, and the Taper panel's "Update generator" swaps a segment
  onto the packaged one.
- `src/RoadHelperGui.lua` + `src/PluginGui/` — React settings panel and reusable components.

## Key Facts About Road Segments

- `ProceduralModel` is a Model subclass with a `Size` Vector3 property; the generated geometry
  regenerates automatically when Size or attributes change. Move it with `PivotTo()`; the pivot
  is the center of the nominal bounding box that the generator works in.
- Road width is derived: `width = LaneCount*LaneWidth + 2*SidewalkWidth`.
- Either END may taper: `TaperBlue`/`TaperRed` turn on a lane layout of that end's own
  (`TaperBlueLaneCount`/`LaneWidth`/`SidewalkWidth`, zero meaning "same as the road"), reached
  over the last `TaperBlueLength` studs. The plain `LaneCount`/`LaneWidth`/`SidewalkWidth`
  attributes stay the segment's OWN width and are never rewritten to express a taper, so a
  taper can't read as a resize of the whole road. `Width` in RoadMath is the widest
  cross-section anywhere, which is what the box must fit; `BaseWidth`/`BlueWidth`/`RedWidth`
  are the road's own and each end's.
- StraightRoad endpoints (local): blue `(∓sway, -Y/2, -Z/2)` outward -Z, red `(±sway, +Y/2, +Z/2)`
  outward +Z, where `sway = max((X - width)/2, 0)` and the sign pair mirrors with `Flip`.
- CurveRoad endpoints (local): blue `(-X/2 + blueWidth/2, ·, -Z/2)` outward -Z, red
  `(X/2, ·, Z/2 - redWidth/2)` outward +X; `Flip` mirrors the climb only (blue at top when Flip).
- The Adjust dir/grade/bank rotations all pivot about the endpoint centre point, so endpoint
  *positions* are invariant under angle edits — only move edits Size/pivot.

## Key Conventions

Same as Redupe: `--!strict`, React via `React.createElement` (aliased `e`), Signal library for
events, modules returning a single function, undo via ChangeHistoryService recordings.
