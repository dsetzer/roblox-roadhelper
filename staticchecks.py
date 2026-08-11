#!/usr/bin/env python3
"""
Static checks over the src tree, for mistakes Luau can't catch at compile time
and the spec suite can't reach.

Luau resolves table fields and globals at runtime, so a call to a function that
no longer exists, or a read of a local from above its declaration (which
silently becomes a nil global), compiles perfectly and only fails when a user
clicks the thing. Each check here exists because that happened:

  * RoadMath members   -- a scripted edit deleted segmentFromDescendant and
                          findSegments; seven call sites kept compiling.
  * session members    -- main.lua calls into the session by name only.
  * use before declare -- outdatedGenerators was declared 200 lines below the
                          function that read it, so the panel got nil.

Runs standalone (python staticchecks.py) and from runtests.py before the build.
No third-party dependencies and no Studio needed.
"""

import os
import re
import shutil
import subprocess
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "src")

# Names that are legitimately global in a Roblox script
ROBLOX_GLOBALS = {
    "workspace", "game", "script", "plugin", "shared", "settings", "typeof",
    "Instance", "Enum", "CFrame", "Vector2", "Vector3", "Color3", "UDim",
    "UDim2", "Rect", "Ray", "Region3", "BrickColor", "TweenInfo", "Random",
    "NumberRange", "NumberSequence", "ColorSequence", "PhysicalProperties",
    "Font", "OverlapParams", "RaycastParams", "DateTime", "Path2DControlPoint",
    "task", "os", "debug", "utf8", "buffer", "table", "string", "math",
    "coroutine", "select", "require", "warn", "print", "error", "assert",
    "pcall", "xpcall", "tostring", "tonumber", "type", "next", "ipairs",
    "pairs", "unpack", "setmetatable", "getmetatable", "rawget", "rawset",
    "rawequal", "rawlen", "tick", "time", "wait", "delay", "spawn", "newproxy",
}


def lua_files():
    for root, _dirs, names in os.walk(SRC):
        for name in sorted(names):
            if name.endswith(".lua"):
                yield os.path.join(root, name)


def strip_comments(line: str) -> str:
    """Good enough for identifier scanning: drop trailing line comments."""
    index = line.find("--")
    return line if index < 0 else line[:index]


def check_module_members(module_name: str, module_path: str, failures: list[str]):
    """Every `Module.member` referenced anywhere in src must exist on it."""
    source = open(module_path, encoding="utf-8").read()
    defined = set(re.findall(rf"^function {module_name}\.(\w+)", source, re.M))
    defined |= set(re.findall(rf"^{module_name}\.(\w+)\s*=", source, re.M))
    defined |= set(re.findall(r"^export type (\w+)", source, re.M))

    for path in lua_files():
        body = open(path, encoding="utf-8").read()
        for name in sorted(set(re.findall(rf"\b{module_name}\.(\w+)", body))):
            if name not in defined:
                rel = os.path.relpath(path)
                failures.append(f"{rel}: {module_name}.{name} is not defined")


def check_session_members(failures: list[str]):
    """main.lua drives the session purely by member name."""
    session = open(os.path.join(SRC, "createRoadSession.lua"), encoding="utf-8").read()
    defined = set(re.findall(r"^\tfunction session\.(\w+)", session, re.M))
    defined |= set(re.findall(r"^\tsession\.(\w+)\s*=", session, re.M))

    main = open(os.path.join(SRC, "main.lua"), encoding="utf-8").read()
    for name in sorted(set(re.findall(r"\bsession\.(\w+)", main))):
        if name not in defined:
            failures.append(f"src/main.lua: session.{name} is not defined")


def check_use_before_declaration(failures: list[str]):
    """
    A local read above its own `local` line silently becomes a nil global
    rather than an error, so it compiles and only fails at runtime.

    This needs real scope analysis, which luau-analyze already does: it reports
    such a read as an unknown global. Everything Roblox provides is unknown to
    it as well (it has no Roblox type definitions here), so those are filtered
    out and what remains is project names that don't resolve. Skipped with a
    note when luau-analyze isn't installed, since it isn't worth making it a
    hard dependency of the suite.
    """
    if shutil.which("luau-analyze") is None:
        print("  (luau-analyze not on PATH; skipping the unresolved-name check)")
        return

    unknown = re.compile(r"Unknown global '(\w+)'")
    for path in lua_files():
        result = subprocess.run(
            ["luau-analyze", path], capture_output=True, text=True
        )
        for line in (result.stdout + result.stderr).splitlines():
            match = unknown.search(line)
            if match and match.group(1) not in ROBLOX_GLOBALS:
                failures.append(line.strip())


def run() -> int:
    failures: list[str] = []
    check_module_members("RoadMath", os.path.join(SRC, "RoadMath.lua"), failures)
    check_session_members(failures)
    check_use_before_declaration(failures)

    if failures:
        print("Static checks failed:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print("Static checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
