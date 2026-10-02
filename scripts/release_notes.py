#!/usr/bin/env python3
"""The release notes for a version, assembled the same way for every repository.

Written to stdout as Markdown; `release.sh` is the only caller, at the point where every asset's
digest is known (the install one-liner embeds them). It can also be run by hand against an
already-published version, which is the cheapest way to iterate on the format:

    RELEASE_NAME=fume RELEASE_TITLE=fume RELEASE_REPO_NAME=propensive/fume \
      RELEASE_LAUNCHER=fume.launcher RELEASE_LIBRARIES=fume-client \
      ./scripts/release_notes.py 0.4.0

The prose comes from the pull requests themselves. `pull_request_template.md` asks every PR for
"a single summary paragraph … the changelog blurb for the release" and then, below a blank line,
"release notes in Markdown addressed to users"; squash-merge subjects carry `(#N)`, so the pull
requests in a release are recoverable from the commit range since the previous release tag.

Sections, each omitted when it would be empty:

  1. a lead paragraph naming the release and what it carries;
  2. `doc/notes/<version>.md`, verbatim, if the repository has committed one — optional
     everywhere, with no configuration and no gate;
  3. Installing — the one-liner and the bootstrap, for a repository that publishes executables;
  4. Changes — one entry per merged pull request since the previous release;
  5. Migration — where the repository keeps migration notes;
  6. Assets — what is attached and how to depend on it.

Environment: RELEASE_NAME, RELEASE_TITLE, RELEASE_REPO_NAME, RELEASE_LIBRARIES (space-separated),
RELEASE_LAUNCHER (non-empty when executables are published), RELEASE_MIGRATION (the notes
directory, or empty); RELEASE_TAG_PREFIXES, for a repository whose tags are not bare versions
(`xek- xeq-`: the first prefixes this release's tag, and a tag under any of them is an earlier
release; a first entry of `-` means the tag is the bare version, the rest earlier prefixes); RELEASE_ASSETS, the directory of an assembled release's files, which the lead and the
Assets section then describe in place of jars; GITHUB_TOKEN lifts the API rate limit.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import textwrap
import urllib.error
import urllib.request
from pathlib import Path

# Squash merges put the number in the subject; a merge commit names it at the front.
SQUASHED = re.compile(r"\(#(\d+)\)\s*$")
MERGED = re.compile(r"^Merge pull request #(\d+)\b")
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
# A pull request body is written for users, but it collects things that are not: the trailers an
# agent appends, and the headings a developer-facing template asks for. Both are removed below.
TRAILER = re.compile(r"^(\U0001F916 Generated with|Co-Authored-By:|Generated with \[Claude)",
                     re.MULTILINE)
DEVELOPER = re.compile(r"^#+\s*(test plan|testing|checklist|how to test)\b.*",
                       re.IGNORECASE | re.MULTILINE)
HEADING = re.compile(r"^(#{1,4})(\s)", re.MULTILINE)

# Above this, the per-pull-request prose is dropped in favour of one line each: a release body is
# capped at 125,000 characters, and a release spanning a hundred pull requests would exceed it.
PROSE_BUDGET = 60000

NAME = os.environ.get("RELEASE_NAME", "")
TITLE = os.environ.get("RELEASE_TITLE", NAME)
REPO = os.environ.get("RELEASE_REPO_NAME", f"propensive/{NAME}")
LIBRARIES = os.environ.get("RELEASE_LIBRARIES", "").split()
LAUNCHER = os.environ.get("RELEASE_LAUNCHER", "")
MIGRATION = os.environ.get("RELEASE_MIGRATION", "")
PREFIXES = os.environ.get("RELEASE_TAG_PREFIXES", "").split()
ASSETS = sorted(path.name for path in Path(os.environ["RELEASE_ASSETS"]).iterdir()
                if path.is_file()) if os.environ.get("RELEASE_ASSETS") else []


def git(*arguments: str) -> str:
    result = subprocess.run(["git", *arguments], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def api(path: str):
    request = urllib.request.Request(f"https://api.github.com/{path}",
                                     headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read())
    except (urllib.error.HTTPError, urllib.error.URLError):
        return None


def wrap(text: str) -> str:
    """Reflow the generated prose to a readable width.

    The boilerplate below is written with the repository's line length, but substituting a name
    into it leaves the wrapping ragged. Only whole paragraphs are reflowed: a line that is part
    of a fenced block, a list or a heading is left exactly as it is.
    """
    out: list[str] = []
    paragraph: list[str] = []
    fenced = False

    def flush() -> None:
        if paragraph:
            out.append(textwrap.fill(" ".join(paragraph), width=96,
                                     break_on_hyphens=False, break_long_words=False))
            paragraph.clear()

    for line in text.split("\n"):
        if line.startswith("```"):
            flush()
            fenced = not fenced
            out.append(line)
        elif fenced or not line.strip() or line.lstrip()[:1] in "-*#>|" or line.startswith("    "):
            flush()
            out.append(line)
        else:
            paragraph.append(line.strip())
    flush()
    return "\n".join(out)


def plural(count: int, singular: str, suffix: str = "s") -> str:
    return singular if count == 1 else singular + suffix


def listed(items: list[str]) -> str:
    """`a`, `b` and `c` — the ecosystem's house style for a list in prose."""
    quoted = [f"`{item}`" for item in items]
    if len(quoted) <= 1:
        return "".join(quoted)
    return ", ".join(quoted[:-1]) + " and " + quoted[-1]


def prefix(entry: str) -> str:
    return "" if entry == "-" else entry


def tag(version: str) -> str:
    return (prefix(PREFIXES[0]) if PREFIXES else "") + version


def previous_tag(version: str) -> str:
    patterns = [f"{prefix(entry)}[0-9]*" for entry in PREFIXES] or ["[0-9]*.[0-9]*.[0-9]*"]
    matches = [argument for pattern in patterns for argument in ("--match", pattern)]
    return git("describe", "--tags", "--abbrev=0", *matches, f"{tag(version)}^")


def pull_requests(version: str) -> list[dict]:
    """Every merged pull request between the previous release and this one, newest first.

    A commit whose subject names no pull request — a direct push to main — contributes the
    subject alone, so that nothing in the range goes unreported.
    """
    previous = previous_tag(version)
    span = f"{previous}..{tag(version)}" if previous else tag(version)
    subjects = git("log", "--format=%s", span).splitlines()

    entries: list[dict] = []
    seen: set[int] = set()
    for subject in subjects:
        match = SQUASHED.search(subject) or MERGED.match(subject)
        if not match:
            if subject.strip():
                entries.append({"number": None, "title": subject.strip()})
            continue
        number = int(match.group(1))
        if number in seen:
            continue
        seen.add(number)
        pull = api(f"repos/{REPO}/pulls/{number}")
        if pull is None:
            entries.append({"number": number, "title": SQUASHED.sub("", subject).strip()})
            continue
        entries.append({"number": number, "title": pull.get("title", "").strip(),
                        "body": pull.get("body") or ""})
    return entries


def split_body(body: str) -> tuple[str, str]:
    """The summary paragraph and the user-facing notes, per the pull request template.

    Everything that is not addressed to users is dropped first: the template's own comments, an
    agent's trailer, and a developer-facing section (a test plan, a checklist) together with
    whatever follows it. What survives keeps its Markdown, but its headings are demoted below the
    `###` each pull request is given here, so that a body written with `##` headings does not
    break out of the Changes section.
    """
    text = COMMENT.sub("", body)
    text = TRAILER.split(text)[0]
    cut = DEVELOPER.search(text)
    if cut:
        text = text[:cut.start()]
    text = HEADING.sub(lambda match: "#" * min(len(match.group(1)) + 2, 6) + match.group(2), text)

    blocks = [block.strip() for block in text.split("\n\n")]
    blocks = [block for block in blocks if block]
    # A body that opens with its own "Summary" heading buries the blurb one block further down.
    if blocks and re.fullmatch(r"#+\s*summary\s*:?", blocks[0], re.IGNORECASE):
        blocks = blocks[1:]
    if not blocks:
        return "", ""
    return blocks[0], "\n\n".join(blocks[1:])


def changes(version: str) -> str:
    entries = pull_requests(version)
    if not entries:
        return ""

    def full(entry: dict) -> str:
        if entry["number"] is None:
            return f"### {entry['title']}\n"
        heading = (f"### {entry['title']} "
                   f"([#{entry['number']}](https://github.com/{REPO}/pull/{entry['number']}))\n")
        summary, notes = split_body(entry.get("body", ""))
        return "\n".join(part for part in (heading, summary, notes) if part) + "\n"

    def brief(entry: dict) -> str:
        if entry["number"] is None:
            return f"- {entry['title']}"
        return (f"- {entry['title']} "
                f"([#{entry['number']}](https://github.com/{REPO}/pull/{entry['number']}))")

    body = "\n".join(full(entry) for entry in entries)
    if len(body) > PROSE_BUDGET:
        body = ("\n".join(brief(entry) for entry in entries) + "\n\nThere are too many changes "
                "in this release to describe each in full here; follow a pull request for its "
                "own notes.\n")
    return "## Changes\n\n" + body


def installing(version: str) -> str:
    release = api(f"repos/{REPO}/releases/tags/{version}")
    if release is None:
        return ""
    digest = next((asset.get("digest", "") for asset in release.get("assets", [])
                   if asset.get("name") == NAME), "")
    if not digest.startswith("sha256:"):
        return ""
    url = f"https://github.com/{REPO}/releases/download/{version}/{NAME}"
    return f"""## Installing

```sh
curl -fsSL https://propensive.dev/{NAME} | sh
```

Or, without trusting the redirect, from this release alone — a 106-byte POSIX-shell bootstrap
which downloads the `{NAME}` script below, checks it against the digest given here, and runs it:

```sh
openssl base64 -d <<EOF | sh -s -- {url} {digest[7:]}
Zj1gbWt0ZW1wYDtjdXJsIC1zTG8gJGYgJDF8fHdnZXQgLXFPICRmICQxO2Nhc2UgYG9wZW5zc2wg
ZGdzdCAtc2hhMjU2ICRmYCBpbiAqJDIpY2htb2QgK3ggJGY7ZXhlYyAkZjtlc2Fj
EOF
```
"""


def migration(version: str) -> str:
    if not MIGRATION:
        return ""
    file = Path(MIGRATION) / f"{version}.md"
    if not file.exists():
        return ""
    url = f"https://github.com/{REPO}/blob/{version}/{MIGRATION}/{version}.md"
    previous = previous_tag(version)
    span = f"from {previous} to {version}" if previous else f"to {version}"
    return f"""## Migration

[`{MIGRATION}/{version}.md`]({url}) records every rename, move, signature change, removal and
changed behaviour a consumer could observe {span}. It is written for an LLM agent rather than
for a person: to upgrade a project from version `A` to version `B`, instruct an agent to read
every `{MIGRATION}/<v>.md` with `A < v <= B`, in ascending version order, and to apply the
changes each one describes.
"""


def modules() -> tuple[list[str], int]:
    """The library modules, and how many of the assets are platform cross-builds of them.

    Soundness attaches a jar per component per platform, so the number of assets and the number
    of modules differ by a factor of two or more; the lead paragraph and the Assets section must
    not disagree about which they are counting.
    """
    plain = [library for library in LIBRARIES
             if "_sjs1_" not in library and "_native0." not in library]
    return plain, len(LIBRARIES) - len(plain)


def assembled() -> str:
    sums = [name for name in ASSETS if name.endswith("SHA256SUMS")]
    text = f"## Assets\n\nAttached: {listed(ASSETS)}."
    if sums:
        text += f" `{sums[0]}` lists the SHA-256 of every other asset."
    return text + "\n"


def assets(version: str) -> str:
    if ASSETS and not LIBRARIES:
        return assembled()
    plain, crossed = modules()
    if len(plain) == 1:
        attached = f"`{plain[0]}`, attached as `{plain[0]}-{version}.jar`"
    else:
        named = listed(plain) if len(plain) <= 8 else f"{len(plain)} library modules"
        attached = f"{named}, each attached as `<artifactId>-{version}.jar`"
    cross = ""
    if crossed:
        cross = (", alongside the Scala.js (`_sjs1_3`) and Scala Native (`_native0.5_3`) "
                 "cross-builds of the platform-capable components")

    text = f"""## Assets

{attached}{cross}, with its POM and `ivy.xml`
embedded under `META-INF/maven/` — the jar alone is enough for a consumer to resolve it. Depend
on this release by pinning it in `etc/refs`:

```
propensive/{NAME}\t{version}
```

`make sync-deps` installs the set into a local ivy repository, transitively; see
[propensive/.github](https://github.com/propensive/.github) for the scheme.
"""
    if LAUNCHER:
        text += f"""
Also attached: one `{NAME}` executable per platform (`{NAME}-linux-x64`, `{NAME}-linux-arm64`,
`{NAME}-macos-x64`, `{NAME}-macos-arm64` and `{NAME}-windows-x64.exe`); `{NAME}`, the polyglot
bootstrap — a small any-shell script, to be renamed `{NAME}.bat` or `{NAME}.ps1` on Windows,
which downloads the right executable, verifies its checksum, replaces itself and re-invokes; and
`install.sh`, which <https://propensive.dev/{NAME}> redirects to. Each executable externalizes
the {'library' if len(plain) == 1 else 'libraries'} above, resolving
further dependencies from the Soundness and proscala releases and from Maven Central on first
run.
"""
    return text


def lead(version: str) -> str:
    if ASSETS and not LIBRARIES:
        return f"{TITLE} {version}."
    plain, crossed = modules()
    if 0 < len(plain) <= 4:
        carried = f"{listed(plain)}"
    else:
        carried = f"the jars of {len(plain)} library modules"
        if crossed:
            carried += (f", with their Scala.js and Scala Native cross-builds — "
                        f"{len(LIBRARIES)} assets in all")

    if LAUNCHER:
        return (f"{TITLE} {version} — the `{NAME}` command for Linux, macOS and Windows, its "
                f"installer, and {carried}, the {'library' if len(plain) == 1 else 'libraries'} "
                f"it is built from.")
    return f"{TITLE} {version} — {carried}, each embedding its own POM and `ivy.xml`."


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        print("usage: release_notes.py X.Y.Z", file=sys.stderr)
        return 2
    version = arguments[0]
    if not NAME:
        print("release_notes: RELEASE_NAME is unset", file=sys.stderr)
        return 2

    overview = Path("doc/notes") / f"{version}.md"
    sections = [
        wrap(lead(version)),
        overview.read_text(encoding="utf-8").strip() if overview.exists() else "",
        wrap(installing(version)) if LAUNCHER else "",
        changes(version),
        wrap(migration(version)),
        wrap(assets(version)),
    ]
    print("\n\n".join(section.strip() for section in sections if section.strip()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
