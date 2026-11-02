#!/usr/bin/env python3
"""Checks that a release pull request is consistent before it is merged.

    TITLE=v0.2.0 BRANCH=v0.2.0 python3 tools/release_check.py --base <server.json from main>
    TITLE=v0.2.0 python3 tools/release_check.py

The title and branch are read from the TITLE and BRANCH environment variables, never
from the command line, so they are only ever data. Rules:
  - the title is vMAJOR.MINOR.REVISION;
  - when BRANCH is set, the branch is named the same as the title;
  - versions/client.json and versions/server.json both carry that version and the
    norto22/Mileage lineage;
  - the fallback versions in mileage.lua (HARD_CLIENT_VERSION, HARD_SERVER_VERSION)
    carry that version too, so a server never reports an older one;
  - with --base, the version is strictly higher than the base server.json, because
    installed servers refuse to downgrade.
Exits non-zero naming every rule that failed.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINEAGE = "norto22/Mileage"
VERSION_FILES = [
    "Resources/Server/Mileage/versions/client.json",
    "Resources/Server/Mileage/versions/server.json",
]
SERVER_PLUGIN = "Resources/Server/Mileage/mileage.lua"
HARD_VERSIONS = ("HARD_CLIENT_VERSION", "HARD_SERVER_VERSION")
TITLE_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def hard_version_pattern(name):
    """Matches `local NAME = {major = 0, minor = 4, revision = 1, ...` in mileage.lua."""
    return re.compile(
        r"^local " + name + r" = \{major = ([0-9]+), minor = ([0-9]+), revision = ([0-9]+),",
        re.MULTILINE,
    )


def read_version(path):
    """Returns ((major, minor, revision), lineage). Each part must be a non-negative JSON
    integer: the server's updater compares them as numbers, and the package is named
    from them."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    parts = []
    for key in ("major", "minor", "revision"):
        value = data[key]
        if type(value) is not int or value < 0:
            raise ValueError(f"{key} must be a non-negative whole number, got {value!r}")
        parts.append(value)
    return tuple(parts), data.get("lineage")


def describe(version):
    return ".".join(str(part) for part in version)


def title_version(title):
    """Returns (version, error) for the pull request title."""
    if title is None:
        return None, "TITLE is not set"
    match = TITLE_PATTERN.fullmatch(title)
    if not match:
        return None, f"title must be vX.X.X, for example v0.2.0 (got {title!r})"
    return tuple(int(part) for part in match.groups()), None


def version_file_errors(version):
    errors = []
    for rel in VERSION_FILES:
        try:
            found, lineage = read_version(os.path.join(ROOT, rel))
        except (OSError, ValueError, KeyError, TypeError) as e:
            errors.append(f"{rel} cannot be read ({e})")
            continue
        if found != version:
            errors.append(f"{rel} is {describe(found)}, the title says {describe(version)}; the version files must match the title")
        if lineage != LINEAGE:
            errors.append(f"{rel} lineage is {lineage!r}, expected {LINEAGE!r}")
    return errors


def plugin_errors(version):
    errors = []
    try:
        with open(os.path.join(ROOT, SERVER_PLUGIN), encoding="utf-8") as f:
            source = f.read()
    except OSError as e:
        return [f"{SERVER_PLUGIN} cannot be read ({e})"]
    for name in HARD_VERSIONS:
        matches = hard_version_pattern(name).findall(source)
        if len(matches) != 1:
            errors.append(f"{SERVER_PLUGIN} must define {name} exactly once, found {len(matches)}")
            continue
        found = tuple(int(part) for part in matches[0])
        if found != version:
            errors.append(f"{SERVER_PLUGIN} {name} is {describe(found)}, the title says {describe(version)}; it must match the title")
    return errors


def branch_errors(title, branch):
    if branch is None:
        return []
    if branch != title:
        return [f"branch is {branch!r}, the title is {title!r}; a release branch is named for its version"]
    return []


def base_errors(version, base_path):
    try:
        base, _ = read_version(base_path)
    except (OSError, ValueError, KeyError, TypeError) as e:
        return [f"base version {base_path} cannot be read ({e})"]
    if version <= base:
        return [f"{describe(version)} must be higher than {describe(base)} on the base branch; servers refuse to downgrade"]
    return []


def main():
    parser = argparse.ArgumentParser(description="Check a release pull request.")
    parser.add_argument("--base", help="server.json from the branch being merged into")
    args = parser.parse_args()

    title = os.environ.get("TITLE")
    version, error = title_version(title)
    if error:
        print(f"release check failed: {error}", file=sys.stderr)
        return 1

    errors = branch_errors(title, os.environ.get("BRANCH"))
    errors += version_file_errors(version)
    errors += plugin_errors(version)
    if args.base:
        errors += base_errors(version, args.base)

    if errors:
        for error in errors:
            print(f"release check failed: {error}", file=sys.stderr)
        return 1
    print(f"release check passed for {title}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
