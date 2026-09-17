# `propensive.dev/<tool>`

Each application released from a propensive repository is installed with one line,

```sh
curl -fsSL https://propensive.dev/<tool> | sh
```

and that URL is a single Firebase Hosting site that does nothing but redirect (302) each tool's
path to `https://github.com/propensive/<tool>/releases/latest/download/install.sh`, the installer
`release-launcher.sh` attaches to each release (`generate-install.sh` writes it). Nothing is
hosted; GitHub always serves the latest release. Everything else, including `/`, redirects to
`https://propensive.com/`.

This directory is the versioned configuration of that site, deployed with the Firebase CLI:

```sh
cd hosting
firebase login                 # once
firebase deploy --only hosting
```

## How it fits together

| piece | where | what |
|---|---|---|
| Firebase project | `propensive-infrastructure` | holds the site below |
| Hosting site | `propensive-dev` | one site for every tool, which is what putting the tool in the path buys: the redirect can depend on the path, never on the host name |
| deploy target | `firebase.json` / `.firebaserc` | `hosting[].target` ↔ `targets.<project>.hosting.propensive` ↔ site id |
| custom domain | Firebase console → Hosting → the site → *Add custom domain* | `propensive.dev`, verified by a TXT record, served by the site's certificate |
| DNS | Cloud DNS, zone `propensive.dev` (the `ns-cloud-d*.googledomains.com` name servers) | the A records the custom domain's `requiredDnsUpdates` asks for — an apex cannot be a CNAME — plus that TXT record |

Redirects are matched in order and the first match wins, so the catch-all `**` to
`https://propensive.com/` must stay last in `firebase.json`. Each tool needs *two* globs: a bare
`/fume` does not match `/fume/**`, and both forms should work.

Until September 2026 this was one site per tool (`<tool>-propensive`, serving
`<tool>.propensive.dev`), because a site's redirects cannot depend on the host name. Those sites
are superseded by this one, and are deleted — domain first, then site, then the Cloud DNS
records — once `propensive.dev` itself is serving.

## Adding a tool (`tel`, `lira`, …)

1. Add the `/<tool>` and `/<tool>/**` redirect entries to `firebase.json`, *above* the catch-all.
2. `firebase deploy --only hosting`.
3. `curl -sI https://propensive.dev/<tool>` answers 302 to the release's `install.sh`.

No site, domain or DNS work is involved — that is the point of the path-based scheme.

The repository must publish `install.sh` with each release, which `release-launcher.sh` does
for any repository using it.

## Without the Firebase CLI

Everything above can also be done with `gcloud`'s credentials and the Hosting REST API, which
is how the sites were first made consistent (the CLI needs its own login; gcloud's suffices for
the API, with the project named as the quota project):

```sh
T=$(gcloud auth print-access-token)
API=https://firebasehosting.googleapis.com/v1beta1
P=propensive-infrastructure
auth=(-H "Authorization: Bearer $T" -H "x-goog-user-project: $P" -H "Content-Type: application/json")

# the site
curl -sS -X POST "${auth[@]}" -d '{}' "$API/projects/$P/sites?siteId=propensive-dev"
# its redirects, as a finalized, released version (the same list as firebase.json, in order)
V=$(curl -sS -X POST "${auth[@]}" -d @- "$API/sites/propensive-dev/versions" <<'JSON' | jq -r .name
{"config":{"redirects":[
  {"glob":"/fume","statusCode":302,
   "location":"https://github.com/propensive/fume/releases/latest/download/install.sh"},
  {"glob":"/fume/**","statusCode":302,
   "location":"https://github.com/propensive/fume/releases/latest/download/install.sh"},
  {"glob":"**","statusCode":302,"location":"https://propensive.com/"}]}}
JSON
)
curl -sS -X PATCH "${auth[@]}" -d '{"status":"FINALIZED"}' "$API/$V?updateMask=status"
curl -sS -X POST "${auth[@]}" -d '{}' "$API/sites/propensive-dev/releases?versionName=$V"
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
