# JpSnap core. Same file runs on the server (ssh forced command) and on the PC ("run_on": "pc").
#   translate: stdin = line 1 optional OpenAI API key (empty = Codex login), then base64 PNG -> JSON breakdown with pitch accent
#   tts:       stdin = base64 JSON {"texts": [...], "rate"} -> JSON {"items": [{"audio": base64 mp3, "marks": [{"t" ms, "d" ms, "text"}]}]}
# Output is ASCII JSON so no console code page can mangle it. Needs schema.json, prompt.txt, accents.txt beside it.
import base64, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SMALL = set("ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ")
RATES = {"slow": "-35%", "normal": "-5%"}
# The screenshot is untrusted (prompt injection), so codex gets no tools: no shell, code mode, web, browser, apps,
# plugins, MCP or user config. With code_mode_host off every tool call fails closed; it can only answer.
NO_TOOLS = ["--ignore-user-config", "--ignore-rules", "-c", 'web_search="disabled"'] + [x for f in (
    "shell_tool", "unified_exec", "code_mode", "code_mode_host", "browser_use", "browser_use_external", "computer_use",
    "in_app_browser", "apps", "plugins", "remote_plugin", "multi_agent", "image_generation", "view_image", "hooks",
    "tool_suggest", "skill_search", "goals", "sleep_tool") for x in ("--disable", f)]

def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)

def morae(reading):
    out = []
    for ch in reading:
        if ch in SMALL and out:
            out[-1] += ch
        elif not ch.isspace():
            out.append(ch)
    return out

def pattern(accent, m):  # Tokyo pitch accent number -> H/L per mora
    if accent == 0:
        return "L" + "H" * (m - 1) if m > 1 else "L"
    if accent == 1:
        return "H" + "L" * (m - 1)
    return "L" + "H" * (min(accent, m) - 1) + "L" * (m - min(accent, m))

def load_accents():  # Kanjium accents.txt: word \t reading (empty for kana words) \t accent number(s)
    acc = {}
    with open(os.path.join(HERE, "accents.txt"), encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3 and (n := re.search(r"\d+", parts[2])):
                acc.setdefault((parts[0], parts[1]), int(n.group()))
    return acc

def kata_to_hira(s):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)

def enrich(data, acc):
    """Per token: morae, pitch ("LHH"), pitch_src ("dict" | "ai" | ""), accent (int or None)."""
    prev = None
    for t in data.get("tokens", []):
        mor = morae(t.get("reading", "")) if t.get("pos") != "punctuation" else []
        t["morae"], t["accent"], src, pitch = mor, None, "", ""
        n = acc.get((t["surface"], t.get("reading", "")))
        if n is None and kata_to_hira(t["surface"]) == t.get("reading"):
            n = acc.get((t["surface"], ""))
        if mor and n is not None and t.get("pos") not in ("particle", "auxiliary"):
            t["accent"], pitch, src = n, pattern(n, len(mor)), "dict"
        elif mor and t.get("pos") == "particle" and prev and prev["pitch_src"] == "dict":
            # a particle stays high after a flat (accent 0) word and is low after any drop
            pitch, src = ("H" if prev["accent"] == 0 else "L") * len(mor), "dict"
        elif mor and len(ai := "".join(re.findall(r"[HL]", t.get("pitch", "")))) == len(mor):
            pitch, src = ai, "ai"  # the model sometimes writes "き=L の=H": keep only the H/L marks
        t["pitch"], t["pitch_src"] = pitch, src
        prev = t
    toks = data.get("tokens", [])
    for name, min_len in (("words", 2), ("parts", 1)):  # token ranges from the model: keep only valid ones
        ok = []
        for g in data.get(name, []):
            f, l = g.get("first"), g.get("last")
            if isinstance(f, int) and isinstance(l, int) and 0 <= f and f + min_len - 1 <= l < len(toks):
                g["text"] = "".join(t["surface"] for t in toks[f:l + 1])
                ok.append(g)
        data[name] = ok
    return data

def translate():
    key, _, b64 = sys.stdin.buffer.read(40_000_000).partition(b"\n")
    key = key.decode("ascii", "replace").strip()
    if not re.fullmatch(r"(sk-[A-Za-z0-9_-]+)?", key):
        fail("Bad API key format (expected sk-...).")
    try:
        png = base64.b64decode(b64)
    except ValueError:
        fail("Bad image data.")
    if png[1:4] != b"PNG":
        fail("Not a PNG image.")
    env = dict(os.environ)
    if key:
        env["CODEX_API_KEY"] = key  # per run only; codex does not store it
    with tempfile.TemporaryDirectory(prefix="jp-translate.") as d:
        with open(os.path.join(d, "shot.png"), "wb") as f:
            f.write(png)
        with open(os.path.join(HERE, "prompt.txt"), "rb") as prompt:
            r = subprocess.run(
                [os.environ.get("JPSNAP_CODEX", "codex"), "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                 "-m", "gpt-6-luna", "-c", "model_reasoning_effort=low", *NO_TOOLS, "--output-schema", os.path.join(HERE, "schema.json"),
                 "-o", os.path.join(d, "out.json"), "-i", os.path.join(d, "shot.png")],
                stdin=prompt, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, cwd=d, env=env,
                creationflags=0x08000000 if os.name == "nt" else 0)  # CREATE_NO_WINDOW
        if r.returncode:
            fail("codex failed: " + "\n".join(r.stderr.decode("utf-8", "replace").strip().splitlines()[-5:]))
        with open(os.path.join(d, "out.json"), encoding="utf-8") as f:
            data = json.load(f)
    print(json.dumps(enrich(data, load_accents())))

def tts():
    import asyncio
    import edge_tts
    req = json.loads(base64.b64decode(sys.stdin.read(1_000_000)))
    texts = req.get("texts", [])
    texts = [str(x)[:2000] for x in ([texts] if isinstance(texts, str) else texts)][:80]  # PowerShell may unwrap a 1-item list
    rate = RATES.get(req.get("rate"), "-5%")

    async def one(text, sem):
        async with sem:
            com = edge_tts.Communicate(text, "ja-JP-NanamiNeural", rate=rate, boundary="WordBoundary")
            audio, marks = bytearray(), []
            async for c in com.stream():
                if c["type"] == "audio":
                    audio += c["data"]
                elif c["type"] == "WordBoundary":
                    marks.append({"t": c["offset"] / 10000, "d": c["duration"] / 10000, "text": c["text"]})
            return {"audio": base64.b64encode(bytes(audio)).decode(), "marks": marks}

    async def run():
        sem = asyncio.Semaphore(4)  # a few at a time: the read-aloud service throttles bursts
        return await asyncio.gather(*(one(t, sem) for t in texts))

    print(json.dumps({"items": asyncio.run(run())}))

def selftest():
    acc = load_accents()
    d = enrich({"tokens": [
        {"surface": "昨日", "reading": "きのう", "pos": "noun", "pitch": ""},
        {"surface": "友達", "reading": "ともだち", "pos": "noun", "pitch": ""},
        {"surface": "と", "reading": "と", "pos": "particle", "pitch": "L"},
        {"surface": "ラーメン", "reading": "らーめん", "pos": "noun", "pitch": ""},
        {"surface": "食べました", "reading": "たべました", "pos": "verb", "pitch": "LHHHL"},
        {"surface": "きょう", "reading": "きょう", "pos": "noun", "pitch": "HX"},
        {"surface": "食べた", "reading": "たべた", "pos": "verb", "pitch": "た=L べ=H た=L"},
        {"surface": "ぴよぽ", "reading": "ぴよぽ", "pos": "noun", "pitch": "ぴ=L よ=H"},
    ]}, acc)
    g = enrich({"tokens": [{"surface": s, "reading": "", "pos": "noun", "pitch": ""} for s in ("8", "杯", "を")],
                "words": [{"first": 0, "last": 1, "text": "x"}, {"first": 2, "last": 2}, {"first": 1, "last": 5}, {"first": "0", "last": 1}],
                "parts": [{"first": 0, "last": 2}, {"first": -1, "last": 0}]}, acc)
    assert [w["text"] for w in g["words"]] == ["8杯"] and [p["text"] for p in g["parts"]] == ["8杯を"], g
    got = [(t["pitch"], t["pitch_src"]) for t in d["tokens"]]
    want = [("LHL", "dict"), ("LHHH", "dict"), ("H", "dict"), ("HLLL", "dict"), ("LHHHL", "ai"), ("", ""), ("LHL", "ai"), ("", "")]
    assert got == want, got
    assert morae("きょうしゃ") == ["きょ", "う", "しゃ"]
    assert {"shell_tool", "code_mode_host", "browser_use", "--ignore-user-config"} <= set(NO_TOOLS)
    print("selftest ok")

if __name__ == "__main__":
    {"translate": translate, "tts": tts, "selftest": selftest}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: fail("usage: translate|tts|selftest"))()
