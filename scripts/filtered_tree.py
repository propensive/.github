#!/usr/bin/env python3
"""The filtered tree of a commit: the key a snapshot is published under.

A snapshot of a library (see snapshot.sh) is named not by its commit but by the SHA of a git
*tree object* holding the commit's tree with every `.dockerignore`-excluded path removed. Two
commits with the same sources, build script and resources — however they were rebased, squashed
or amended, and whatever their documentation says — share a filtered tree, and so share a
snapshot. This is the object Soundness's CI attestation keys on too (etc/ci/_lib.py there, of
which this is the dependency-free extract).

`.dockerignore` is read from the commit, never the working tree, so the tree is a pure function
of the commit; a repository without one is taken whole.

Usage: filtered_tree.py [commit]      prints the tree SHA (40 hex digits)
       filtered_tree.py --list [commit]   prints the surviving paths, for tuning .dockerignore

All git plumbing, against a throwaway index, so the caller's index is never touched. The tree
object is written to the object database; that is intentional, since it is what the snapshot
is named after.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable


def _parse_dockerignore(text: str) -> list[tuple[bool, str]]:
    out: list[tuple[bool, str]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        negate = line.startswith("!")
        if negate:
            line = line[1:].lstrip()
        if line.startswith("./"):
            line = line[2:]
        elif line.startswith("/"):
            line = line[1:]
        if line.endswith("/"):
            line = line[:-1]
        if not line:
            continue
        out.append((negate, line))
    return out


def _pattern_to_regex(pat: str) -> re.Pattern[str]:
    """A docker-style ignore pattern as a regex over the full path: `*` and `?` stop at `/`,
    `**/` is zero or more leading components, `/**` zero or more trailing ones, and `**`
    elsewhere anything at all."""
    chars: list[str] = ["^"]
    i = 0
    n = len(pat)
    while i < n:
        if pat[i:i + 3] == "**/":
            chars.append("(?:.*/)?")
            i += 3
            continue
        if pat[i:i + 3] == "/**" and (i + 3 == n or pat[i + 3] == "/"):
            chars.append("(?:/.*)?")
            i += 3
            continue
        if pat[i:i + 2] == "**":
            chars.append(".*")
            i += 2
            continue
        c = pat[i]
        if c == "*":
            chars.append("[^/]*")
        elif c == "?":
            chars.append("[^/]")
        else:
            chars.append(re.escape(c))
        i += 1
    chars.append("$")
    return re.compile("".join(chars))


def _matches(path: str, regex: re.Pattern[str]) -> bool:
    """The path itself, or any ancestor directory of it: excluding a directory excludes
    everything beneath."""
    if regex.match(path):
        return True
    parts = path.split("/")
    return any(regex.match("/".join(parts[:i])) for i in range(1, len(parts)))


def is_excluded(path: str, patterns: list[tuple[bool, str]]) -> bool:
    excluded = False
    for negate, pat in patterns:
        if _matches(path, _pattern_to_regex(pat)):
            excluded = not negate
    return excluded


def _load_dockerignore(commit: str) -> list[tuple[bool, str]]:
    try:
        data = subprocess.check_output(["git", "show", f"{commit}:.dockerignore"],
                                       stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return []
    return _parse_dockerignore(data.decode("utf-8"))


def _ls_tree(commit: str) -> Iterable[str]:
    raw = subprocess.check_output(["git", "ls-tree", "-r", "-z", commit])
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        header, path = entry.split(b"\t", 1)
        if header.split(b" ")[1] == b"blob":
            yield path.decode("utf-8")


def excluded_paths(commit: str) -> list[str]:
    patterns = _load_dockerignore(commit)
    return [path for path in _ls_tree(commit) if is_excluded(path, patterns)]


def filtered_tree(commit: str = "HEAD") -> str:
    excluded = excluded_paths(commit)
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(tmp, "index"))
        subprocess.check_call(["git", "read-tree", commit], env=env)
        if excluded:
            subprocess.run(["git", "update-index", "--force-remove", "-z", "--stdin"],
                           input=b"".join(p.encode("utf-8") + b"\0" for p in excluded),
                           env=env, check=True)
        return subprocess.check_output(["git", "write-tree"], env=env).decode().strip()


def main(arguments: list[str]) -> int:
    listing = arguments[:1] == ["--list"]
    if listing:
        arguments = arguments[1:]
    commit = arguments[0] if arguments else "HEAD"
    if listing:
        gone = set(excluded_paths(commit))
        for path in _ls_tree(commit):
            if path not in gone:
                print(path)
    else:
        print(filtered_tree(commit))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
