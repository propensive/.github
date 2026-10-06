// The one function behind https://propensive.dev/<tool>: it serves the installer of the tool's
// latest GitHub release, `install.sh` to curl and wget, `install.ps1` to PowerShell's `irm`,
// decided by the User-Agent unless the path says which (`/<tool>.sh`, `/<tool>.ps1`). Hosting
// rewrites every path but `/` here (firebase.json); a path which is not a tool is sent to
// propensive.com, as the old catch-all redirect did.
//
// Nothing is published here per release. Each script is fetched from
// github.com/propensive/<tool>/releases/latest/download/<script> — GitHub's "latest" redirect
// — and held for a few minutes per instance, so a release is served within that long of being
// published, and GitHub is asked once per instance per script in the meantime.

const { onRequest } = require("firebase-functions/v2/https");

// The tools served, which are the repositories whose releases carry the installers. The list
// is explicit so that this is not a proxy to any propensive repository, or to any name a
// visitor types.
const TOOLS = new Set(["flame", "fume", "flair", "tel", "lira", "xek", "fury", "fever"]);

const HOME = "https://propensive.com/";
const TTL = 5 * 60 * 1000;

// How long a fetched script is served before GitHub is asked again, and what each is served as:
// `text/x-shellscript` is what a shell script is, and PowerShell's `irm` prints text/plain as
// a string, which is what `iex` runs.
const SCRIPTS = {
  sh:  { asset: "install.sh",  type: "text/x-shellscript; charset=utf-8" },
  ps1: { asset: "install.ps1", type: "text/plain; charset=utf-8" },
};

// The path's tool and, if it names one, the script: `/fume`, `/fume.ps1`, `/fume/anything`.
function parse(path) {
  const match = /^\/([a-z][a-z0-9-]*?)(?:\.(sh|ps1))?(?:\/.*)?$/.exec(path);
  if (!match || !TOOLS.has(match[1])) return null;
  return { tool: match[1], script: match[2] };
}

// Which installer the client can run, from its User-Agent. Windows PowerShell 5.1 sends
// `WindowsPowerShell/5.1.…`, PowerShell 7 sends `PowerShell/7.…`, for `irm` and `iwr` and 5.1's
// `curl` alias alike; everything else — curl, wget, a browser — gets the shell script.
function choose(userAgent) {
  return /powershell\//i.test(userAgent || "") ? "ps1" : "sh";
}

// Fetched scripts, by `<tool>/<script>`, each with the time it was fetched; a failed refresh
// serves the stale copy rather than nothing.
const cache = new Map();

async function script(tool, kind) {
  const key = `${tool}/${kind}`;
  const held = cache.get(key);
  if (held && Date.now() - held.at < TTL) return held.body;

  const url = `https://github.com/propensive/${tool}/releases/latest/download/${SCRIPTS[kind].asset}`;
  try {
    const response = await fetch(url, { redirect: "follow" });
    if (!response.ok) throw new Error(`${url}: ${response.status}`);
    const body = await response.text();
    cache.set(key, { body, at: Date.now() });
    return body;
  } catch (error) {
    if (held) return held.body;
    throw error;
  }
}

exports.installer = onRequest({ region: "us-central1", maxInstances: 3 }, async (req, res) => {
  const parsed = parse(req.path);

  if (!parsed) {
    res.redirect(302, HOME);
    return;
  }

  const kind = parsed.script || choose(req.get("user-agent"));
  // Every response depends on the User-Agent, so no cache between here and the client can
  // key it usefully; the cache above is what keeps GitHub out of the common path.
  res.set("Cache-Control", "no-store");
  res.set("Vary", "User-Agent");

  let body;
  try {
    body = await script(parsed.tool, kind);
  } catch (error) {
    console.error(error);
    // One line, so that `curl -f` fails and `sh` runs nothing, rather than an error page.
    res.status(502).type("text/plain").send(`propensive.dev: ${parsed.tool}'s ${SCRIPTS[kind].asset} could not be fetched from GitHub\n`);
    return;
  }

  res.status(200).type(SCRIPTS[kind].type);
  if (req.method === "HEAD") res.end();
  else res.send(body);
});
