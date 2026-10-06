# `propensive.dev/<tool>`

Each application released from a propensive repository is installed with one line, in a POSIX
shell or in PowerShell:

```sh
curl -fsSL https://propensive.dev/<tool> | sh
```

```powershell
irm https://propensive.dev/<tool> | iex
```

Both lines name the same URL. It is a single Firebase Hosting site whose every path is rewritten
to one Cloud Function, `installer` (`functions/index.js`), which fetches the tool's installer
from `https://github.com/propensive/<tool>/releases/latest/download/` and serves it: `install.ps1`
when the client is PowerShell (a `User-Agent` of `PowerShell/…` or `WindowsPowerShell/…`, which is
what `irm`, `iwr` and Windows PowerShell's `curl` alias send), `install.sh` otherwise (curl, wget,
a browser). A path ending `.sh` or `.ps1` names the script outright, for a client whose
`User-Agent` is not telling: `https://propensive.dev/<tool>.ps1`. The function holds each
script for five minutes per instance, so a new release is served within that long of being
published; nothing is deployed here per release, and GitHub always holds the latest. The script
is served as the response itself — a 200, not a redirect — so `-L` is not needed, and a request
GitHub cannot answer is a one-line 502, which `curl -f` fails on, rather than a page piped into
`sh`. Everything else, `/` and any path that is not a tool, redirects to `https://propensive.com/`.

This directory is the versioned configuration of that site, deployed with the Firebase CLI:

```sh
cd hosting
firebase login                          # once
firebase deploy --only functions,hosting
```

The function needs the project on the Blaze plan; its volume is well inside the free tier.

## How it fits together

| piece | where | what |
|---|---|---|
| Firebase project | `propensive-infrastructure` | holds the site and the function below |
| Hosting site | `propensive-dev` | one site for every tool, which is what putting the tool in the path buys: the rewrite can depend on the path, never on the host name |
| Cloud Function | `installer`, `us-central1`, from `functions/` | serves each path; the only place that knows which tools exist (`TOOLS` in `functions/index.js`) |
| deploy target | `firebase.json` / `.firebaserc` | `hosting[].target` ↔ `targets.<project>.hosting.propensive` ↔ site id |
| custom domain | Firebase console → Hosting → the site → *Add custom domain* | `propensive.dev`, verified by a TXT record, served by the site's certificate |
| DNS | Cloud DNS, zone `propensive.dev` (the `ns-cloud-d*.googledomains.com` name servers) | the A records the custom domain's `requiredDnsUpdates` asks for — an apex cannot be a CNAME — plus that TXT record |

Hosting applies `redirects` before `rewrites`, which is how `/` reaches propensive.com while the
`**` rewrite takes every other path to the function.

Until September 2026 this was one site per tool (`<tool>-propensive`, serving
`<tool>.propensive.dev`), because a site's redirects cannot depend on the host name; and until
October 2026 it was a list of redirects, one pair per tool, to the release's `install.sh`, which
could serve only the one script and needed curl's `-L`.

## Adding a tool (`tel`, `lira`, …)

1. Add the name to `TOOLS` in `functions/index.js`.
2. `firebase deploy --only functions`.
3. `curl -sI https://propensive.dev/<tool>` answers 200 with `text/x-shellscript`.

No site, domain or DNS work is involved — that is the point of the path-based scheme.

The repository must publish `install.sh` and `install.ps1` with each release. `release.sh` does
that for any repository with a `launcher`, with `xek installer` (xek 1.2 and later); a repository
whose release is assembled by its own command (xek's) runs `xek installer` into its assets there,
and `release.sh` uploads them and checks their digests like any other asset.

## Testing locally

```sh
cd hosting/functions && npm install && cd ..
firebase emulators:start --only functions,hosting
curl -sS http://localhost:5000/xek | head -3                             # install.sh
curl -sS -A 'Mozilla/5.0 (Windows NT 10.0) PowerShell/7.4' http://localhost:5000/xek | head -3  # install.ps1
```

## Without the Firebase CLI

The site, the domain and DNS can also be made with `gcloud`'s credentials and the Hosting REST
API, which is how the sites were first made consistent (the CLI needs its own login; gcloud's
suffices for the API, with the project named as the quota project). The function itself is
deployed by the CLI.

```sh
T=$(gcloud auth print-access-token)
API=https://firebasehosting.googleapis.com/v1beta1
P=propensive-infrastructure
auth=(-H "Authorization: Bearer $T" -H "x-goog-user-project: $P" -H "Content-Type: application/json")

# the site
curl -sS -X POST "${auth[@]}" -d '{}' "$API/projects/$P/sites?siteId=propensive-dev"
# the custom domain, whose `requiredDnsUpdates` say what to put in Cloud DNS
curl -sS -X POST "${auth[@]}" -d '{}' \
  "$API/projects/$P/sites/propensive-dev/customDomains?customDomainId=propensive.dev"
curl -sS "${auth[@]}" "$API/projects/$P/sites/propensive-dev/customDomains/propensive.dev"
# the records it asks for, e.g.
gcloud dns record-sets create propensive.dev. --zone propensive-dev --project $P \
  --type A --ttl 300 --rrdatas <the addresses from requiredDnsUpdates>
```

Ownership and the certificate follow within minutes of the records resolving; the domain's
`hostState`, `ownershipState` and `certState` all read `*_ACTIVE` once it is serving.
