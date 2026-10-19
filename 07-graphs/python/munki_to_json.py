#!/usr/bin/env python3
"""Export a Munki repo's dependency graph to the deps.json format depgraph.py reads.

Usage: python3 munki_to_json.py /path/to/munki_repo/pkgsinfo > my_deps.json
       python3 depgraph.py my_deps.json

Reads every pkginfo plist under the folder and collects name -> requires.
Several versions of one item are merged (union of their requires). Munki
lets a requirement pin a version ("Foo-1.2" or "Foo--1.2"); those are mapped
back to the plain item name when it exists in the repo. `update_for` is left
out: "X update_for Y" means X installs after Y, the same direction as
"X requires Y", so add those as extra requires edges if you want them.
"""
import json
import plistlib
import sys
from pathlib import Path


def strip_version(requirement, names):
    if requirement in names:
        return requirement
    for sep in ("--", "-"):
        if sep in requirement:
            base = requirement.rsplit(sep, 1)[0]
            if base in names:
                return base
    return requirement  # unknown; depgraph.py will report it


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = Path(sys.argv[1])
    raw = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name.startswith("."):
            continue
        try:
            info = plistlib.loads(path.read_bytes())
        except Exception:
            continue  # not a plist
        if not isinstance(info, dict) or "name" not in info:
            continue
        raw.setdefault(info["name"], set()).update(info.get("requires", []))
    names = set(raw)
    graph = {name: sorted({strip_version(r, names) for r in reqs}) for name, reqs in sorted(raw.items())}
    json.dump(graph, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
