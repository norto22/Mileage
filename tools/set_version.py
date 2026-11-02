#!/usr/bin/env python3
"""Sets Mileage's version everywhere it is written, from the release branch's name.

    python3 tools/set_version.py           use the current git branch, e.g. v0.4.1
    python3 tools/set_version.py v0.4.1    use this version

Writes the version into versions/client.json, versions/server.json and the fallback
versions in mileage.lua (HARD_CLIENT_VERSION, HARD_SERVER_VERSION), which is what
tools/release_check.py checks against the pull request's title and branch. A release
branch is named for its version, so on branch v0.4.1 this makes the server report 0.4.1.
Run tools/build.py afterwards only if the client sources changed; the version is not
inside the client archive.
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_check  # noqa: E402

ROOT = release_check.ROOT


def current_branch():
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=ROOT, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def write_version_file(rel, version):
    path = os.path.join(ROOT, rel)
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    data["major"], data["minor"], data["revision"] = version
    data["lineage"] = release_check.LINEAGE
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(data, indent=4) + "\n")


def write_plugin(version):
    path = os.path.join(ROOT, release_check.SERVER_PLUGIN)
    with open(path, encoding="utf-8", newline="") as f:
        source = f.read()
    major, minor, revision = version
    for name in release_check.HARD_VERSIONS:
        source, count = release_check.hard_version_pattern(name).subn(
            lambda m, n=name: f"local {n} = {{major = {major}, minor = {minor}, revision = {revision},",
            source,
        )
        if count != 1:
            raise ValueError(f"{release_check.SERVER_PLUGIN} must define {name} exactly once, found {count}")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(source)


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else current_branch()
    version, error = release_check.title_version(name)
    if error:
        print(f"set version failed: {error.replace('title', 'branch or argument')}", file=sys.stderr)
        return 1
    try:
        for rel in release_check.VERSION_FILES:
            write_version_file(rel, version)
        write_plugin(version)
    except (OSError, ValueError, KeyError) as e:
        print(f"set version failed: {e}", file=sys.stderr)
        return 1
    print(f"version set to {release_check.describe(version)} from {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
