#!/usr/bin/env python3
"""A playlist curator: a local model plus the iTunes Remote daemon.

The model never reads the library — 93,000 tracks would not fit in any
prompt. It reasons about it in three steps, and the daemon does the
searching:

  1. plan      the request -> a small JSON plan, including which of the
               library's artists fit (it sees the full artist list)
  2. retrieve  the daemon pulls those artists' tracks -> a few hundred
               candidates, by id
  3. curate    the model picks from the candidates BY ID, with reasons,
               so it can only choose songs that exist

Then it is a conversation: say what to change and it edits; `save Name`
makes it a real iTunes playlist through the daemon.

Usage:  python3 curator.py "make a playlist for date night"
        (then type feedback, `save <name>`, or `quit`)
"""
import json, os, re, subprocess, sys, time, urllib.request, urllib.parse, urllib.error

OLLAMA = os.environ.get("OLLAMA", "http://127.0.0.1:11434")
MODEL = os.environ.get("CURATOR_MODEL", "gemma4:12b")
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
os.makedirs(CACHE, exist_ok=True)


# --- daemon ---------------------------------------------------------------

def _default(key):
    return subprocess.run(["defaults", "read", "local.stevenbleifer.itunesremote", key],
                          capture_output=True, text=True).stdout.strip()

DAEMON = os.environ.get("DAEMON") or "http://%s:%s" % (
    _default("serverLANHost") or "Stevens-MacBook-Pro.local", _default("serverPort") or "8765")
TOKEN = os.environ.get("TOKEN") or _default("serverToken")


def api(method, path, query=None, body=None, timeout=120):
    url = DAEMON + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def artists():
    """All artists with their track counts, cached for the session."""
    p = os.path.join(CACHE, "artists.json")
    if os.path.exists(p) and time.time() - os.path.getmtime(p) < 3600:
        return json.load(open(p))
    a = api("GET", "/api/artists")["artists"]
    json.dump(a, open(p, "w"))
    return a


def tracks_by(artist, limit=80):
    return api("GET", "/api/tracks", {"artist": artist, "limit": limit})["tracks"]


# --- model ----------------------------------------------------------------

def chat(messages, json_mode=True, temperature=0.4, max_tokens=2500):
    # No thinking, and a hard cap on output: left alone, the model wrote
    # 4,500 tokens of preamble at 9 tok/s and never reached the answer.
    body = {"model": MODEL, "stream": False, "messages": messages, "think": False,
            "options": {"temperature": temperature, "num_ctx": 32768, "num_predict": max_tokens}}
    if json_mode:
        body["format"] = "json"
    req = urllib.request.Request(OLLAMA + "/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    content = d["message"]["content"]
    sys.stderr.write("  [%s: %.1fs, %d tokens]\n" % (MODEL, time.time() - t0, d.get("eval_count", 0)))
    return content


def parse_json(text):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.S)
        return json.loads(m.group(0)) if m else {}


# --- step 1: plan -----------------------------------------------------------

# The artist list comes FIRST and the request LAST, on purpose: Ollama keeps
# the KV cache for an identical prompt prefix, so the 22k-token list is
# processed once per model load (about four minutes at ~100 tok/s) and later
# requests reuse it and cost seconds.
PLAN_PROMPT = """You curate playlists from ONE person's music library. You cannot see the songs, only the list of artists in the library below, with how many tracks each has.

Library artists (name: track count):
{artists}

You will be given a request. Produce a JSON object:
{{
  "vibe": one sentence on the mood, tempo and setting you are going for,
  "decades": list of decades that fit, like ["1970s", "2000s"], or [] for any,
  "avoid": list of things to steer clear of (genres, moods, artists), as short strings,
  "artists": 25 to 40 artist names, copied EXACTLY as written in the library list, that best fit the request. Prefer artists with more tracks when in doubt. Do not invent artists that are not in the list,
  "length": number of songs the playlist should have (default 25)
}}

Request: {request}
"""


def plan(request, arts):
    listing = "\n".join("%s: %d" % (a["name"], a["count"]) for a in arts)
    out = parse_json(chat([{"role": "user", "content": PLAN_PROMPT.format(request=request, artists=listing)}],
                          max_tokens=1200))
    known = {a["name"].lower(): a["name"] for a in arts}
    picked, unknown = [], []
    for name in out.get("artists", []):
        real = known.get(str(name).lower())
        (picked if real else unknown).append(real or name)
    out["artists"] = list(dict.fromkeys(picked))
    if unknown:
        sys.stderr.write("  (dropped %d names not in the library: %s)\n" % (len(unknown), ", ".join(unknown[:5])))
    out.setdefault("length", 25)
    return out


# --- step 2: retrieve --------------------------------------------------------

def candidates(the_plan, cap=200):
    """A few hundred real tracks from the planned artists, spread evenly
    across them, one version per song, better-known versions first."""
    per_artist = {}
    for name in the_plan["artists"]:
        try:
            ts = tracks_by(name)
        except Exception as e:
            sys.stderr.write("  (could not fetch %s: %s)\n" % (name, e))
            continue
        seen, keep = set(), []
        # Prefer rated and played tracks, then studio-looking albums.
        ts.sort(key=lambda t: (-(t.get("rating") or 0), -(t.get("playCount") or 0),
                               1 if re.search(r"live|demo|bootleg|session", (t.get("album") or ""), re.I) else 0))
        for t in ts:
            k = (t["name"].lower().strip(), (t.get("artist") or "").lower())
            if k in seen or not t.get("name"):
                continue
            seen.add(k)
            keep.append(t)
        per_artist[name] = keep
    # Round-robin so no artist swamps the list.
    out, i = [], 0
    while len(out) < cap and any(per_artist.values()):
        for name, ts in per_artist.items():
            if i < len(ts) and len(out) < cap:
                out.append(ts[i])
        i += 1
        if i > 200:
            break
    return out


def line(t):
    y = " %s" % t["year"] if t.get("year") else ""
    return "%s | %s – %s (%s%s) [%s]%s" % (
        t["persistentId"], t.get("artist"), t["name"], t.get("album") or "?", y,
        t.get("genre") or "", " ★%d" % (t["rating"] // 20) if t.get("rating") else "")


# --- step 3: curate ----------------------------------------------------------

CURATE_PROMPT = """You curate playlists from ONE person's music library.

Request: {request}
Your plan: {vibe} Decades: {decades}. Avoid: {avoid}.
{feedback}
Below are candidate songs from the library, one per line, as:
  ID | artist – title (album year) [genre] ★rating

Choose {length} songs for the playlist. Rules:
- Use ONLY the IDs listed. Never invent a song.
- Sequence them like a real playlist: an opener, a flow, an ender.
- Vary artists; at most 2 songs by the same artist unless the request asks for one artist.
- Prefer songs that clearly fit the request over merely famous ones.

Return JSON: {{"playlist": [{{"id": "...", "why": "a few words"}}, ...], "note": "one or two sentences to the listener about the choices"}}

Candidates:
{candidates}
"""


def curate(request, the_plan, cands, feedback=None, current=None):
    fb = ""
    if feedback:
        fb = "The listener's feedback on the previous version: %s\nThe previous version was:\n%s\nKeep what they liked, change what they asked for.\n" % (
            feedback, "\n".join("  " + line(t) for t in current))
    prompt = CURATE_PROMPT.format(
        request=request, vibe=the_plan.get("vibe", ""), decades=", ".join(the_plan.get("decades") or []) or "any",
        avoid=", ".join(the_plan.get("avoid") or []) or "nothing in particular",
        feedback=fb, length=the_plan.get("length", 25), candidates="\n".join(line(t) for t in cands))
    out = parse_json(chat([{"role": "user", "content": prompt}], temperature=0.5))
    by_id = {t["persistentId"]: t for t in cands}
    chosen, bad, per_artist = [], 0, {}
    holiday = re.compile(r"christmas|xmas|santa|jingle|silent night|noel|hanukkah", re.I)
    wants_holiday = bool(holiday.search(request))
    for item in out.get("playlist", []):
        t = by_id.get(str(item.get("id", "")).upper())
        if not t or any(c["persistentId"] == t["persistentId"] for c in chosen):
            bad += 1
            continue
        # The model is told these rules and ignores them often enough that
        # they are enforced here: at most two per artist, no holiday songs
        # unless asked, and the planned length.
        a = (t.get("artist") or "").lower()
        if per_artist.get(a, 0) >= 2 and "artist" not in request.lower():
            continue
        if not wants_holiday and (holiday.search(t["name"]) or holiday.search(t.get("album") or "")):
            continue
        per_artist[a] = per_artist.get(a, 0) + 1
        chosen.append(dict(t, why=item.get("why", "")))
        if len(chosen) >= int(the_plan.get("length", 25)):
            break
    if bad:
        sys.stderr.write("  (model named %d ids that were not candidates; dropped)\n" % bad)
    return chosen, out.get("note", "")


def show(chosen, note):
    total = sum(t.get("totalTime") or 0 for t in chosen) // 1000
    print()
    for i, t in enumerate(chosen, 1):
        y = " (%s)" % t["year"] if t.get("year") else ""
        print("%2d. %s – %s%s   [%s]" % (i, t.get("artist"), t["name"], y, t.get("why", "")))
    print("\n%d songs, %d:%02d.  %s\n" % (len(chosen), total // 60, total % 60, note))


# --- save --------------------------------------------------------------------

def save(name, chosen):
    pl = api("POST", "/api/playlists", body={"name": name})
    pid = pl.get("persistentId") or pl.get("playlist", {}).get("persistentId")
    res = api("POST", "/api/playlists/%s/tracks" % pid, body={"ids": [t["persistentId"] for t in chosen]})
    print("Saved as “%s” in iTunes (%s)." % (name, json.dumps(res)[:120]))


# --- main --------------------------------------------------------------------

def main():
    request = " ".join(sys.argv[1:]).strip() or input("What kind of playlist? ").strip()
    arts = artists()
    print("Thinking about %d artists…" % len(arts))
    the_plan = plan(request, arts)
    print("Plan: %s\n  decades: %s\n  avoid: %s\n  artists (%d): %s" % (
        the_plan.get("vibe"), the_plan.get("decades"), the_plan.get("avoid"),
        len(the_plan["artists"]), ", ".join(the_plan["artists"])))
    cands = candidates(the_plan)
    print("Pulled %d candidate songs from the library." % len(cands))
    chosen, note = curate(request, the_plan, cands)
    show(chosen, note)
    while True:
        try:
            fb = input("feedback / save <name> / quit > ").strip()
        except EOFError:
            break
        if not fb or fb == "quit":
            break
        if fb.startswith("save "):
            save(fb[5:].strip(), chosen)
            continue
        chosen, note = curate(request, the_plan, cands, feedback=fb, current=chosen)
        show(chosen, note)


if __name__ == "__main__":
    main()
