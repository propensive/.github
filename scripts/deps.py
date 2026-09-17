#!/usr/bin/env python3
"""The dependency pins of a repository, etc/refs, and their transitive closure.

A repository pins each propensive library it builds against in `etc/refs`, one per line,
tab-separated, `#` for comments:

    # repository            version               commit (snapshots only)
    propensive/soundness    0.66.0
    propensive/pyrocosm     0.2.0-3f9a1c2b7d4e    8c1e0d5a…(40 hex)

A version `X.Y.Z` is a RELEASE: the jars under the GitHub Release tagged `X.Y.Z`. A version
`X.Y.Z-<12 hex>` is a SNAPSHOT: an unreleased build published by snapshot.sh under the
pre-release tagged `snapshot-<12 hex>`, where the hex is the start of the filtered tree hash
(filtered_tree.py) of the commit it was built from, and `X.Y.Z` the version that repository
declared at the time. The commit is a breadcrumb for humans and for sync-deps.sh, which builds
the snapshot from a sibling checkout when it is not on GitHub.

The build reads the file (a `deps` object in build.mill), so this is the single place a pin
lives; CI keys its cache on the files' hashes.

A TOOL is different from a dependency. A dependency is what a repository's jars are compiled
against, and what their POMs will name: Soundness for Pyrocosm, Pyrocosm for fume. A tool is
what a repository RUNS — fume to run its tests, flair to check its sources, the flair compiler
plugin Soundness loads with `-Xplugin` — and never appears in a POM. Tools are pinned in
`etc/tools`, in the same shape, with two differences: a tool is always a RELEASE (a snapshot
there is rejected), and a tool is not part of the closure `walk` computes or `check` gates,
since a release of it exists by definition. That is what keeps the release graph acyclic:
Soundness runs flair, flair depends on Pyrocosm, Pyrocosm depends on Soundness, and none of
those releases waits on the others. `sync-deps.sh` installs a tool's jars (a plugin is a jar);
`tools.sh` installs a tool's command.

Pins are TRANSITIVE: a snapshot of Pyrocosm was built against some exact Soundness, named in
Pyrocosm's own etc/refs at that commit, and its POMs refer to that version, so a consumer
of the snapshot must install it too. `walk` fetches each pinned repository's etc/refs at
the pinned tag (from raw.githubusercontent.com; a release predating the file has no pins) and
follows it, depth first. Reaching one repository at two versions is fine when the direct pin
supersedes a release reached transitively — a tool may need a Soundness newer than the one
Pyrocosm was built against, and coursier evicts to the direct pin's version, which is installed
alongside — and an error when two different snapshots meet, or when a snapshot is reached only
transitively while something else is pinned here: two builds would disagree about what an
unreleased library IS.

Usage: deps.py walk [file]     the closure, as `repo TAB version TAB tag TAB kind [TAB commit]`
                               lines, dependencies before dependents
       deps.py check [file]    exit 1 unless every pin in the closure is a release that exists
                               on GitHub (the gate every release script runs first); also
                               validates etc/tools next to the file
       deps.py tools [file]    the tools, as `repo TAB version` lines (etc/tools by default)
       deps.py kind <version>  prints `release` or `snapshot`, exit 1 for neither

Environment: GITHUB_TOKEN lifts the API rate limit for `check`.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

RELEASE = re.compile(r"^\d+\.\d+\.\d+$")
SNAPSHOT = re.compile(r"^\d+\.\d+\.\d+-([0-9a-f]{12})$")
DEFAULT_FILE = Path("etc/refs")
TOOLS_FILE = Path("etc/tools")


@dataclass(frozen=True)
class Pin:
    repo: str
    version: str
    commit: str

    @property
    def kind(self) -> str:
        return kind_of(self.version)

    @property
    def tag(self) -> str:
        match = SNAPSHOT.match(self.version)
        return f"snapshot-{match.group(1)}" if match else self.version


def fail(message: str) -> None:
    print(f"deps: {message}", file=sys.stderr)
    sys.exit(1)


def log(message: str) -> None:
    print(f"deps: {message}", file=sys.stderr)


def kind_of(version: str) -> str:
    if RELEASE.match(version):
        return "release"
    if SNAPSHOT.match(version):
        return "snapshot"
    fail(f"'{version}' is neither a release (X.Y.Z) nor a snapshot (X.Y.Z-<12 hex>)")
    return ""  # unreachable


def parse(text: str, origin: str, releases_only: bool = False) -> list[Pin]:
    pins: list[Pin] = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        columns = [column.strip() for column in line.split("\t") if column.strip()]
        if len(columns) < 2:
            fail(f"{origin}:{number}: expected `repository TAB version [TAB commit]`")
        repo, version = columns[0], columns[1]
        commit = columns[2] if len(columns) > 2 else ""
        if "/" not in repo:
            repo = f"propensive/{repo}"
        if releases_only and kind_of(version) != "release":
            fail(f"{origin}:{number}: a tool is always a release; '{version}' is not X.Y.Z")
        if kind_of(version) == "snapshot" and commit and not re.match(r"^[0-9a-f]{40}$", commit):
            fail(f"{origin}:{number}: the commit must be a full 40-hex SHA")
        pins.append(Pin(repo, version, commit))
    return pins


def http(url: str, accept: str) -> bytes | None:
    request = urllib.request.Request(url, headers={"Accept": accept})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def upstream_pins(pin: Pin) -> list[Pin]:
    url = f"https://raw.githubusercontent.com/{pin.repo}/{pin.tag}/etc/refs"
    data = http(url, "text/plain")
    return parse(data.decode("utf-8"), url) if data is not None else []


def walk(pins: list[Pin]) -> list[Pin]:
    """The transitive closure, dependencies first, with the conflict rule above."""
    ordered: list[Pin] = []
    chosen: dict[str, Pin] = {}
    done: set[tuple[str, str]] = set()
    visiting: set[tuple[str, str]] = set()

    def visit(pin: Pin, via: str) -> None:
        seen = chosen.get(pin.repo)
        if seen is not None and seen.version != pin.version:
            if seen.kind == "snapshot" and pin.kind == "snapshot":
                fail(f"{pin.repo} is pinned at {seen.version} and, via {via}, at {pin.version}; "
                     "two different snapshots of one library cannot both be what it IS")
            if via != "etc/refs" and pin.kind == "snapshot":
                fail(f"{pin.repo} is reached at the snapshot {pin.version} via {via}, but pinned "
                     f"at {seen.version} here; pin the snapshot directly, or drop it upstream")
            log(f"{pin.repo}: {seen.version} (pinned here) supersedes {pin.version} (via {via})")
        key = (pin.repo, pin.version)
        if key in done:
            return
        if key in visiting:
            fail(f"{pin.repo} {pin.version} depends on itself")
        visiting.add(key)
        for upstream in upstream_pins(pin):
            visit(upstream, f"{pin.repo} {pin.version}")
        visiting.discard(key)
        done.add(key)
        chosen.setdefault(pin.repo, pin)
        ordered.append(pin)

    for pin in pins:
        visit(pin, "etc/refs")
    return ordered


def release_exists(pin: Pin) -> bool:
    url = f"https://api.github.com/repos/{pin.repo}/releases/tags/{pin.tag}"
    data = http(url, "application/vnd.github+json")
    return data is not None and not json.loads(data).get("draft", False)


def main(arguments: list[str]) -> int:
    if not arguments:
        print("usage: deps.py {walk|check} [file] | kind <version>", file=sys.stderr)
        return 2
    command = arguments[0]

    if command == "kind":
        if len(arguments) != 2:
            fail("`kind` takes one version")
        print(kind_of(arguments[1]))
        return 0

    if command == "tools":
        file = Path(arguments[1]) if len(arguments) > 1 else TOOLS_FILE
        if file.exists():
            for pin in parse(file.read_text(encoding="utf-8"), str(file), releases_only=True):
                print(f"{pin.repo}\t{pin.version}")
        return 0

    file = Path(arguments[1]) if len(arguments) > 1 else DEFAULT_FILE
    if not file.exists():
        fail(f"{file} does not exist")
    closure = walk(parse(file.read_text(encoding="utf-8"), str(file)))
    tools_file = file.parent / "tools"
    tools = (parse(tools_file.read_text(encoding="utf-8"), str(tools_file), releases_only=True)
             if tools_file.exists() else [])

    if command == "walk":
        for pin in closure:
            print("\t".join([pin.repo, pin.version, pin.tag, pin.kind] + ([pin.commit] if pin.commit else [])))
        return 0

    if command == "check":
        problems = [f"{pin.repo} is pinned at the snapshot {pin.version}; release it first"
                    for pin in closure if pin.kind == "snapshot"]
        problems += [f"{pin.repo} has no published release {pin.version}"
                     for pin in closure if pin.kind == "release" and not release_exists(pin)]
        problems += [f"tool {pin.repo} has no published release {pin.version}"
                     for pin in tools if not release_exists(pin)]
        for problem in problems:
            print(f"deps: {problem}", file=sys.stderr)
        if problems:
            return 1
        print(f"deps: every pin is a published release ({len(closure)} in the closure, "
              f"{len(tools)} tools)")
        return 0

    fail(f"unknown command {command}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
