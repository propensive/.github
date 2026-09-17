# `<tool>.propensive.dev`

Each application released from a propensive repository is installed with one line,

```sh
curl -fsSL https://<tool>.propensive.dev/ | sh
```

and that URL is a Firebase Hosting site that does nothing but redirect (302) *every* path to
`https://github.com/propensive/<tool>/releases/latest/download/install.sh`, the installer
`release-launcher.sh` attaches to each release (`generate-install.sh` writes it). Nothing is
hosted; GitHub always serves the latest release.

This directory is the versioned configuration of those sites, deployed with the Firebase CLI:

```sh
cd hosting
firebase login                 # once
firebase deploy --only hosting # every site in firebase.json, or --only hosting:flair for one
```

## How it fits together

| piece | where | what |
|---|---|---|
| Firebase project | `propensive-infrastructure` (assumed from the site fume resolves to today; correct `.firebaserc` if the project id differs) | holds every site below |
| Hosting site | `<tool>-propensive` | one per tool, so each can redirect to its own repository — a site's redirects cannot depend on the host name, which is why one site cannot serve every tool |
| deploy target | `firebase.json` / `.firebaserc` | `hosting[].target` ↔ `targets.<project>.hosting.<tool>` ↔ site id |
| custom domain | Firebase console → Hosting → the site → *Add custom domain* | `<tool>.propensive.dev`, verified by a TXT record, served by the site's certificate |
| DNS | Cloud DNS, zone `propensive.dev` (the `ns-cloud-d*.googledomains.com` name servers) | `<tool>.propensive.dev CNAME <tool>-propensive.web.app.` plus the TXT record the console asks for |

The redirect target itself never changes, so a deploy is needed only when a tool is added.

## Adding a tool (`tel`, `lira`, …)

1. Add its entry to `firebase.json` and `.firebaserc` (the pattern is identical per tool).
2. Create the site: `firebase hosting:sites:create <tool>-propensive` (or in the console).
3. `firebase deploy --only hosting:<tool>`.
4. In the console, add the custom domain `<tool>.propensive.dev` to the site; add the TXT
   record it shows and the CNAME to `<tool>-propensive.web.app.` in Cloud DNS.
5. Once the certificate is issued, `curl -sI https://<tool>.propensive.dev/` answers 302 to the
   release's `install.sh`.

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

# a site
curl -sS -X POST "${auth[@]}" -d '{}' "$API/projects/$P/sites?siteId=<tool>-propensive"
# its redirect, as a finalized, released version
V=$(curl -sS -X POST "${auth[@]}" -d '{"config":{"redirects":[{"glob":"**","statusCode":302,
  "location":"https://github.com/propensive/<tool>/releases/latest/download/install.sh"}]}}' \
  "$API/sites/<tool>-propensive/versions" | jq -r .name)
curl -sS -X PATCH "${auth[@]}" -d '{"status":"FINALIZED"}' "$API/$V?updateMask=status"
curl -sS -X POST "${auth[@]}" -d '{}' "$API/sites/<tool>-propensive/releases?versionName=$V"
# the custom domain, whose `requiredDnsUpdates` say what to put in Cloud DNS
curl -sS -X POST "${auth[@]}" -d '{}' \
  "$API/projects/$P/sites/<tool>-propensive/customDomains?customDomainId=<tool>.propensive.dev"
curl -sS "${auth[@]}" "$API/projects/$P/sites/<tool>-propensive/customDomains/<tool>.propensive.dev"
# the DNS record it asks for
gcloud dns record-sets create <tool>.propensive.dev. --zone propensive-dev --project $P \
  --type CNAME --ttl 300 --rrdatas <tool>-propensive.web.app.
```

Ownership and the certificate follow within minutes of the CNAME resolving; the domain's
`hostState`, `ownershipState` and `certState` all read `*_ACTIVE` once it is serving.
