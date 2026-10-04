#!/usr/bin/env python3
"""Propose a new release to the repositories that consume it, as one draft pull request each.

Run by `release.sh` once a release is published, from the released commit; and by xek's
`runners-release.sh` once a runner release is uploaded. It reads the repositories to propose to
from `etc/downstream` in the calling repository — one `owner/repo` (or bare `repo`) per line,
`#` for comments — so the chain is declared where it starts, and a repository whose release
nobody should hear about simply has no such file.

For each consumer it edits, on a new branch `pins/<name>-<version>` from the default branch:

  etc/refs     the released repository's pin, set to this release; and every other pin the
               consumer shares with the release's own `etc/refs`, set to the version the release
               was built against — so a Pyrocosm release carries its Soundness to Pyrocosm's
               consumers in the same pull request
  etc/xek.tsv  the builder pin, set to the release's own (or, for an xek runner release, to the
               release itself)

A pin only ever moves forwards: a consumer that already pins something newer — a later release,
or a snapshot of a later version — keeps it; a snapshot of the released version gives way to
the release. A consumer with nothing to change is left alone, as is one whose branch already
exists, so a re-run opens nothing twice.

The pull request is a draft: a new version may break the consumer's build, and the fixes belong
on the same branch — the pull request that fixes the breakage carries the bump. Its first
paragraph is written for users, since merged pull request bodies become release notes; what is
addressed to the maintainer is an HTML comment, which the notes drop.

Usage: etc/shared propagate.py [--dry-run] [--repo owner/name] [--title T] [--xek SHA256] VERSION

  --repo       the released repository; defaults to $RELEASE_REPO_NAME, which release.sh exports
  --title      its display name; defaults to $RELEASE_TITLE, else the repository's name
  --xek        an xek runner release, with the SHA-256 of its builder script: consumers' etc/xek.tsv
               is what moves, not their etc/refs. Implied when $RELEASE_ASSETS, the directory of
               an assembled release's files (which release.sh exports), holds the script `xek`
  --dry-run    print what each pull request would change, and write nothing

Credentials: `gh`, with contents and pull-requests write access to every consumer. A release job's
own GITHUB_TOKEN reaches no other repository, so under GitHub Actions the script uses
$PROPAGATE_TOKEN and, if that is unset, says so and does nothing. Run by hand, it uses whatever
`gh` is authenticated as.
"""

from __future__ import annotations

import base64
import difflib
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

VERSION = re.compile(r"^(\d+(?:\.\d+)*)(?:-([0-9a-f]{12}))?$")


def log(message: str) -> None:
    print(f"propagate: {message}", file=sys.stderr)


def order(version: str) -> tuple[tuple[int, ...], int] | None:
    """A sort key: the numeric version, then a release above a snapshot of the same version."""
    match = VERSION.match(version)
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split(".")), 0 if match.group(2) else 1


def newer(candidate: str, current: str) -> bool:
    a, b = order(candidate), order(current)
    return a is not None and b is not None and a > b


def repository(name: str) -> str:
    return name if "/" in name else f"propensive/{name}"


def pins(text: str) -> dict[str, str]:
    """`etc/refs` as repository → version, ignoring comments and any commit column."""
    result: dict[str, str] = {}
    for line in text.splitlines():
        columns = [column for column in line.strip().split("\t") if column.strip()]
        if not columns or columns[0].startswith("#") or len(columns) < 2:
            continue
        result[repository(columns[0].strip())] = columns[1].strip()
    return result


BUILDER_PIN = "etc/xek.tsv"


def builder_pin(text: str) -> tuple[str, str] | None:
    fields = dict(
        line.split("\t", 1) for line in text.splitlines() if "\t" in line and not line.startswith("#")
    )
    version = fields.get("version", "").strip()
    sha = fields.get("xek", "").strip()
    return (version, sha) if version and sha else None


# ---------------------------- GITHUB ----------------------------

def gh(*arguments: str, payload: dict | None = None, missing_ok: bool = False) -> str | None:
    environment = dict(os.environ)
    token = os.environ.get("PROPAGATE_TOKEN")
    if token:
        environment["GH_TOKEN"] = token
    result = subprocess.run(
        ["gh", *arguments],
        input=json.dumps(payload) if payload is not None else None,
        capture_output=True, text=True, env=environment,
    )
    if result.returncode != 0:
        if missing_ok and ("404" in result.stderr or "Not Found" in result.stderr):
            return None
        raise RuntimeError(f"gh {' '.join(arguments[:3])}: {result.stderr.strip()}")
    return result.stdout


def api(path: str, missing_ok: bool = False, **payload) -> dict | None:
    if payload:
        method = payload.pop("method", "POST")
        out = gh("api", "-X", method, path, "--input", "-", payload=payload)
    else:
        out = gh("api", path, missing_ok=missing_ok)
    return None if out is None else json.loads(out)


def graphql(query: str, **variables) -> dict:
    out = gh("api", "graphql", "--input", "-", payload={"query": query, "variables": variables})
    result = json.loads(out or "{}")
    if result.get("errors"):
        raise RuntimeError(f"gh api graphql: {result['errors']}")
    return result["data"]


# One commit of whole files onto an existing branch, through `createCommitOnBranch`, which GitHub
# signs, so the commit is verified and satisfies a consumer's "require signed commits" rule. A
# commit made through the Git Data REST API (a tree, a commit, a ref) is left unsigned.
COMMIT_ON_BRANCH = """
mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid } }
}
"""


def commit_files(repo: str, branch: str, head: str, message: str, files: dict[str, str]) -> str:
    headline, _, body = message.partition("\n\n")
    additions = [
        {"path": path, "contents": base64.b64encode(text.encode("utf-8")).decode("ascii")}
        for path, text in files.items()
    ]
    data = graphql(COMMIT_ON_BRANCH, input={
        "branch": {"repositoryNameWithOwner": repo, "branchName": branch},
        "expectedHeadOid": head,
        "message": {"headline": headline, "body": body},
        "fileChanges": {"additions": additions},
    })
    return data["createCommitOnBranch"]["commit"]["oid"]


def read(repo: str, path: str, ref: str) -> str | None:
    content = api(f"repos/{repo}/contents/{path}?ref={ref}", missing_ok=True)
    return None if content is None else base64.b64decode(content["content"]).decode("utf-8")


# ---------------------------- EDITS ----------------------------

def edit_refs(text: str, targets: dict[str, str], changes: list[str]) -> str:
    """Moves each pin in `targets` forwards, keeping every other line exactly as it was."""
    lines = []
    for line in text.splitlines():
        columns = [column for column in line.split("\t") if column.strip()]
        if len(columns) >= 2 and not columns[0].lstrip().startswith("#"):
            name, current = columns[0].strip(), columns[1].strip()
            target = targets.get(repository(name))
            if target is not None and newer(target, current):
                line = f"{name}\t{target}"
                changes.append(f"`{repository(name)}` {current} → {target}")
        lines.append(line)
    return "\n".join(lines) + "\n"


def edit_builder(text: str, target: tuple[str, str], changes: list[str]) -> str:
    current = builder_pin(text)
    if current is None or not newer(target[0], current[0]):
        return text
    changes.append(f"the `xek` builder {current[0]} → {target[0]}")
    lines = []
    for line in text.splitlines():
        if line.startswith("version\t"):
            line = f"version\t{target[0]}"
        elif line.startswith("xek\t"):
            line = f"xek\t{target[1]}"
        lines.append(line)
    return "\n".join(lines) + "\n"


def diff(path: str, before: str, after: str) -> str:
    return "".join(difflib.unified_diff(
        before.splitlines(True), after.splitlines(True), f"a/{path}", f"b/{path}"))


# ---------------------------- ONE CONSUMER ----------------------------

def propose(consumer: str, name: str, title: str, version: str,
            refs_targets: dict[str, str], builder_target: tuple[str, str] | None,
            released: str, xek: bool, dry_run: bool) -> None:
    info = api(f"repos/{consumer}")
    base = info["default_branch"]
    head = api(f"repos/{consumer}/git/ref/heads/{base}")["object"]["sha"]
    branch = f"pins/{name}-{version}"

    if api(f"repos/{consumer}/git/ref/heads/{branch}", missing_ok=True) is not None:
        log(f"{consumer}: branch {branch} already exists; nothing to do")
        return

    changes: list[str] = []
    files: dict[str, tuple[str, str]] = {}

    refs = read(consumer, "etc/refs", head)
    if refs is not None and refs_targets:
        if not xek and released not in pins(refs):
            log(f"{consumer}: its etc/refs does not pin {released}; is etc/downstream right?")
        before = len(changes)
        edited = edit_refs(refs, refs_targets, changes)
        if len(changes) > before:
            files["etc/refs"] = (refs, edited)

    if builder_target is not None:
        builder = read(consumer, BUILDER_PIN, head)
        if builder is None:
            if xek:
                log(f"{consumer}: has no {BUILDER_PIN} to move to {title} {version}")
        else:
            before = len(changes)
            edited = edit_builder(builder, builder_target, changes)
            if len(changes) > before:
                files[BUILDER_PIN] = (builder, edited)

    if not files:
        log(f"{consumer}: already current; nothing to propose")
        return

    subject = (f"Package with {title} {version}" if xek else f"Build against {title} {version}")
    others = [change for change in changes if not change.startswith(f"`{released}`")]
    summary = (
        f"Moves to {title} {version}"
        + (f", and to what it was built against: {', '.join(others)}" if others and not xek else "")
        + "."
    )
    maintainer = (
        f"<!-- Opened as a draft by the release of {title} {version}. If the new version breaks "
        "the build, push the fixes to this branch — the pull request that fixes the breakage "
        "carries the bump — and rewrite the paragraph above to say what changed for users. In a "
        "repository that attests its CI locally, run `make attest && make push` here before "
        "marking it ready. -->"
    )
    body = f"{summary}\n\n{maintainer}\n"
    message = f"{subject}\n\n" + "\n".join(f"- {change}" for change in changes) + "\n"

    if dry_run:
        log(f"{consumer}: would open a draft pull request “{subject}” from {branch}")
        for path, (before, after) in files.items():
            sys.stderr.write(diff(path, before, after))
        return

    # The branch first, at the consumer's head, and then the commit onto it. Should the commit fail,
    # the branch goes too, since a branch that exists is taken above to mean "already proposed".
    api(f"repos/{consumer}/git/refs", ref=f"refs/heads/{branch}", sha=head)
    try:
        commit_files(consumer, branch, head, message, {path: after for path, (_, after) in files.items()})
    except Exception:
        gh("api", "-X", "DELETE", f"repos/{consumer}/git/refs/heads/{branch}", missing_ok=True)
        raise
    url = gh("pr", "create", "--repo", consumer, "--draft", "--base", base, "--head", branch,
             "--title", subject, "--body", body)
    log(f"{consumer}: opened {url.strip() if url else branch}")


# ---------------------------- MAIN ----------------------------

def main(arguments: list[str]) -> int:
    dry_run = False
    repo = os.environ.get("RELEASE_REPO_NAME", "")
    title = os.environ.get("RELEASE_TITLE", "")
    xek_sha = ""
    positional: list[str] = []
    it = iter(arguments)
    for argument in it:
        if argument == "--dry-run":
            dry_run = True
        elif argument == "--repo":
            repo = next(it, "")
        elif argument == "--title":
            title = next(it, "")
        elif argument == "--xek":
            xek_sha = next(it, "")
        else:
            positional.append(argument)

    if len(positional) != 1 or not repo:
        log("usage: propagate.py [--dry-run] [--repo owner/name] [--title T] [--xek SHA256] VERSION")
        return 2
    version = positional[0]
    released = repository(repo)
    builder = Path(os.environ.get("RELEASE_ASSETS", "")) / "xek"
    if not xek_sha and os.environ.get("RELEASE_ASSETS") and builder.is_file():
        xek_sha = hashlib.sha256(builder.read_bytes()).hexdigest()
    name = released.split("/", 1)[1]
    title = title or name
    xek = bool(xek_sha)
    if xek and not re.match(r"^[0-9a-f]{64}$", xek_sha):
        log(f"--xek needs the builder script's SHA-256, not '{xek_sha}'")
        return 2

    downstream_file = Path("etc/downstream")
    if not downstream_file.exists():
        log("no etc/downstream; nothing to propose")
        return 0
    consumers = [
        repository(line.strip()) for line in downstream_file.read_text().splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    if not consumers:
        return 0

    if os.environ.get("GITHUB_ACTIONS") == "true" and not os.environ.get("PROPAGATE_TOKEN") and not dry_run:
        log("PROPAGATE_TOKEN is not set, and a release job's own token reaches no other "
            f"repository; not proposing {title} {version} to {', '.join(consumers)}")
        return 0

    # What the consumers move to: this release, what it was built against, and its builder.
    refs_file = Path("etc/refs")
    builder_file = Path(BUILDER_PIN)
    if xek:
        refs_targets: dict[str, str] = {}
        builder_target: tuple[str, str] | None = (version, xek_sha)
    else:
        refs_targets = {
            pin: pinned for pin, pinned in (pins(refs_file.read_text()) if refs_file.exists() else {}).items()
            if order(pinned) is not None and order(pinned)[1] == 1  # releases only, never a snapshot
        }
        refs_targets[released] = version
        builder_target = builder_pin(builder_file.read_text()) if builder_file.exists() else None

    failures = 0
    for consumer in consumers:
        try:
            propose(consumer, name, title, version, refs_targets, builder_target, released, xek, dry_run)
        except Exception as error:  # one consumer's failure must not stop the others
            failures += 1
            log(f"{consumer}: {error}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
