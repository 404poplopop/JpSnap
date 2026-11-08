# JpSnap core. The same file runs on the server (ssh forced command) and on the PC ("run_on": "pc").
#   translate: stdin = line 1 JSON {"key": optional OpenAI API key, "fast": bool, "model": one of MODELS,
#              "priority": bool (Codex fast service tier)}, then a base64 PNG
#              -> JSON breakdown: tokens with pitch accent, words, parts, grammar (fast: tokens and translation only)
#   tts:       stdin = base64 JSON {"texts": [...], "rate": "normal" | "slow", "voice": "nanami" | "keita"}
#              -> JSON {"items": [{"audio": base64 mp3, "marks": [{"t" ms, "d" ms, "text"}]}]}
#   selftest:  pitch logic and request checks, no network
# Output is ASCII JSON so no console code page can mangle it.
# Needs schema.json, prompt.txt, prompt_fast.txt and accents.txt beside it.
import asyncio, base64, binascii, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# Codex models that take images; the PC picks one in settings, anything else is refused. Luna is the quick, cheap one.
MODELS = ("gpt-6-luna", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol")
RATES = {"slow": "-35%", "normal": "-5%"}
VOICES = {"nanami": "ja-JP-NanamiNeural", "keita": "ja-JP-KeitaNeural"}
FAST_TOKEN_FIELDS = ("surface", "reading", "romaji", "pos", "meaning", "pitch")
API_KEY = re.compile(r"(sk-[A-Za-z0-9_-]{8,200})?")
SMALL_KANA = set("ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ")
# The screenshot is untrusted (prompt injection), so codex gets no tools: no shell, code mode, web, browser, apps,
# plugins, MCP or user config. With code_mode_host off every tool call fails closed; it can only answer.
NO_TOOLS = ["--ignore-user-config", "--ignore-rules", "-c", 'web_search="disabled"'] + [x for f in (
    "shell_tool", "unified_exec", "code_mode", "code_mode_host", "browser_use", "browser_use_external", "computer_use",
    "in_app_browser", "apps", "plugins", "remote_plugin", "multi_agent", "image_generation", "view_image", "hooks",
    "tool_suggest", "skill_search", "goals", "sleep_tool") for x in ("--disable", f)]


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


# ---------- requests (trust boundary: everything on stdin comes from the PC) ----------

def parse_translate_request(raw):
    """b'{"key": "", "fast": false, "model": "gpt-6-luna", "priority": false}\\n<base64 png>'
    -> (key, fast, model, priority, png bytes); older clients send only key and fast"""
    head, _, b64 = raw.partition(b"\n")
    try:
        opts = json.loads(head.decode("ascii")) if len(head) <= 4096 else None
    except (UnicodeDecodeError, ValueError):
        opts = None
    if not isinstance(opts, dict):
        fail("Bad request header.")
    key, fast = opts.get("key", ""), opts.get("fast", False)
    model, priority = opts.get("model", MODELS[0]), opts.get("priority", False)
    if not isinstance(key, str) or not API_KEY.fullmatch(key):
        fail("Bad API key format (expected sk-...).")
    if not isinstance(fast, bool) or not isinstance(priority, bool):
        fail("Bad request header.")
    if model not in MODELS:
        fail("Unknown model.")
    try:
        png = base64.b64decode(b64)
    except (binascii.Error, ValueError):
        fail("Bad image data.")
    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
        fail("Not a PNG image.")
    return key, fast, model, priority, png


def parse_tts_request(raw):
    """base64 JSON -> (texts, edge-tts rate, edge-tts voice)"""
    try:
        req = json.loads(base64.b64decode(raw))
    except (binascii.Error, ValueError):
        req = None
    if not isinstance(req, dict):
        fail("Bad tts request.")
    texts = req.get("texts", [])
    texts = [texts] if isinstance(texts, str) else texts  # PowerShell unwraps a 1-item list
    if not isinstance(texts, list):
        fail("Bad tts request.")
    texts = [str(t)[:2000] for t in texts][:80]
    return texts, RATES.get(req.get("rate"), RATES["normal"]), VOICES.get(req.get("voice"), VOICES["nanami"])


# ---------- pitch accent ----------

def morae(reading):
    out = []
    for ch in reading:
        if ch in SMALL_KANA and out:
            out[-1] += ch
        elif not ch.isspace():
            out.append(ch)
    return out


def pattern(accent, m):
    """Tokyo pitch accent number -> H/L per mora."""
    if accent == 0:
        return "L" + "H" * (m - 1) if m > 1 else "L"
    if accent == 1:
        return "H" + "L" * (m - 1)
    drop = min(accent, m)
    return "L" + "H" * (drop - 1) + "L" * (m - drop)


def load_accents():
    """Kanjium accents.txt: word \\t reading (empty for kana words) \\t accent number(s)."""
    acc = {}
    with open(os.path.join(HERE, "accents.txt"), encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3 and (n := re.search(r"\d+", parts[2])):
                acc.setdefault((parts[0], parts[1]), int(n.group()))
    return acc


def kata_to_hira(s):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)


def add_pitch(tokens, acc):
    """Per token: morae, pitch ("LHH"), pitch_src ("dict" | "ai" | ""), accent (int or None)."""
    prev = None
    for t in tokens:
        reading, pos = t.get("reading", ""), t.get("pos")
        mor = morae(reading) if pos != "punctuation" else []
        n = acc.get((t["surface"], reading))
        if n is None and kata_to_hira(t["surface"]) == reading:
            n = acc.get((t["surface"], ""))
        ai = "".join(re.findall(r"[HL]", t.get("pitch", "")))  # the model sometimes writes "き=L の=H"
        t["morae"], t["accent"], t["pitch"], t["pitch_src"] = mor, None, "", ""
        if mor and n is not None and pos not in ("particle", "auxiliary"):
            t["accent"], t["pitch"], t["pitch_src"] = n, pattern(n, len(mor)), "dict"
        elif mor and pos == "particle" and prev and prev["pitch_src"] == "dict":
            # a particle stays high after a flat (accent 0) word and is low after any drop
            t["pitch"], t["pitch_src"] = ("H" if prev["accent"] == 0 else "L") * len(mor), "dict"
        elif mor and len(ai) == len(mor):
            t["pitch"], t["pitch_src"] = ai, "ai"
        prev = t


def keep_valid_ranges(data):
    """words / parts are token ranges from the model: keep only ranges that fit, and rebuild their text."""
    toks = data["tokens"]
    for name, min_len in (("words", 2), ("parts", 1)):
        ok = []
        for g in data.get(name, []):
            f, l = g.get("first"), g.get("last")
            if type(f) is int and type(l) is int and 0 <= f and f + min_len - 1 <= l < len(toks):
                g["text"] = "".join(t["surface"] for t in toks[f:l + 1])
                ok.append(g)
        data[name] = ok


def enrich(data, acc):
    data.setdefault("tokens", [])
    data.setdefault("grammar", [])
    for t in data["tokens"]:
        for field in ("role", "explanation"):  # absent in fast answers
            t.setdefault(field, "")
    add_pitch(data["tokens"], acc)
    keep_valid_ranges(data)
    return data


# ---------- translate ----------

def schema(fast):
    with open(os.path.join(HERE, "schema.json"), encoding="utf-8") as f:
        s = json.load(f)
    if fast:  # same schema, cut down to what the quick pass fills in
        tok = s["properties"]["tokens"]["items"]
        tok["properties"] = {k: tok["properties"][k] for k in FAST_TOKEN_FIELDS}
        tok["required"] = list(FAST_TOKEN_FIELDS)
        s["required"] = ["sentence", "translation", "tokens"]
        s["properties"] = {k: s["properties"][k] for k in s["required"]}
    return s


def run_codex(png, key, fast, model=MODELS[0], priority=False):
    env = dict(os.environ)
    if key:
        env["CODEX_API_KEY"] = key  # this run only; codex does not store it
    with tempfile.TemporaryDirectory(prefix="jp-translate.") as d:
        shot, out, schema_file = (os.path.join(d, n) for n in ("shot.png", "out.json", "schema.json"))
        with open(shot, "wb") as f:
            f.write(png)
        with open(schema_file, "w", encoding="utf-8") as f:
            json.dump(schema(fast), f, ensure_ascii=False)
        with open(os.path.join(HERE, "prompt_fast.txt" if fast else "prompt.txt"), "rb") as prompt:
            r = subprocess.run(
                [os.environ.get("JPSNAP_CODEX", "codex"), "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                 "-m", model, "-c", "model_reasoning_effort=low", *NO_TOOLS,
                 *(["-c", 'service_tier="priority"'] if priority else []),  # Codex "Fast": ~1.5x speed, more usage
                 "--output-schema", schema_file, "-o", out, "-i", shot],
                stdin=prompt, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, cwd=d, env=env,
                creationflags=0x08000000 if os.name == "nt" else 0)  # CREATE_NO_WINDOW
        if r.returncode:
            fail("codex failed: " + "\n".join(r.stderr.decode("utf-8", "replace").strip().splitlines()[-5:]))
        with open(out, encoding="utf-8") as f:
            return json.load(f)


def translate():
    key, fast, model, priority, png = parse_translate_request(sys.stdin.buffer.read(40_000_000))
    print(json.dumps(enrich(run_codex(png, key, fast, model, priority), load_accents())))


# ---------- tts ----------

def tts():
    import edge_tts
    texts, rate, voice = parse_tts_request(sys.stdin.read(1_000_000))

    async def one(text, sem):
        async with sem:
            audio, marks = bytearray(), []
            async for c in edge_tts.Communicate(text, voice, rate=rate, boundary="WordBoundary").stream():
                if c["type"] == "audio":
                    audio += c["data"]
                elif c["type"] == "WordBoundary":
                    marks.append({"t": c["offset"] / 10000, "d": c["duration"] / 10000, "text": c["text"]})
            return {"audio": base64.b64encode(bytes(audio)).decode(), "marks": marks}

    async def run():
        sem = asyncio.Semaphore(4)  # a few at a time: the read-aloud service throttles bursts
        return await asyncio.gather(*(one(t, sem) for t in texts))

    print(json.dumps({"items": asyncio.run(run())}))


# ---------- selftest ----------

def rejects(parse, raw):
    import contextlib, io
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            parse(raw)
    except SystemExit:
        return True
    return False


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
    got = [(t["pitch"], t["pitch_src"]) for t in d["tokens"]]
    want = [("LHL", "dict"), ("LHHH", "dict"), ("H", "dict"), ("HLLL", "dict"), ("LHHHL", "ai"), ("", ""), ("LHL", "ai"), ("", "")]
    assert got == want, got
    assert d["tokens"][0]["explanation"] == "" and d["words"] == [] and d["grammar"] == []
    assert morae("きょうしゃ") == ["きょ", "う", "しゃ"]

    g = enrich({"tokens": [{"surface": s, "reading": "", "pos": "noun", "pitch": ""} for s in ("8", "杯", "を")],
                "words": [{"first": 0, "last": 1, "text": "x"}, {"first": 2, "last": 2}, {"first": 1, "last": 5},
                          {"first": "0", "last": 1}, {"first": True, "last": 1}],
                "parts": [{"first": 0, "last": 2}, {"first": -1, "last": 0}]}, acc)
    assert [w["text"] for w in g["words"]] == ["8杯"] and [p["text"] for p in g["parts"]] == ["8杯を"], g

    png = b"\x89PNG\r\n\x1a\n...."
    ok = b'{"key": "sk-abcdefgh12", "fast": true}\n' + base64.b64encode(png)
    assert parse_translate_request(ok) == ("sk-abcdefgh12", True, "gpt-6-luna", False, png)
    assert parse_translate_request(b'{}\n' + base64.b64encode(png)) == ("", False, "gpt-6-luna", False, png)
    picked = b'{"model": "gpt-6-sol", "priority": true}\n' + base64.b64encode(png)
    assert parse_translate_request(picked) == ("", False, "gpt-6-sol", True, png)
    for bad in (b'sk-abc\n' + base64.b64encode(png), b'{"key": "sk-x y"}\n' + base64.b64encode(png),
                b'{"key": "abc"}\n' + base64.b64encode(png), b'{"fast": "yes"}\n' + base64.b64encode(png),
                b'[]\n' + base64.b64encode(png), b'{"model": "gpt-6-luna --x"}\n' + base64.b64encode(png),
                b'{"model": ["gpt-6-luna"]}\n' + base64.b64encode(png), b'{"priority": 1}\n' + base64.b64encode(png), b'{}\n' + base64.b64encode(b"GIF89a"), b"x" * 5000 + b"\n"):
        assert rejects(parse_translate_request, bad), bad[:40]

    tts_req = base64.b64encode(json.dumps({"texts": "きのう", "rate": "slow", "voice": "keita"}).encode())
    assert parse_tts_request(tts_req) == (["きのう"], "-35%", "ja-JP-KeitaNeural")
    odd = base64.b64encode(json.dumps({"texts": ["a"], "rate": "fast!", "voice": "../x"}).encode())
    assert parse_tts_request(odd) == (["a"], "-5%", "ja-JP-NanamiNeural")
    assert rejects(parse_tts_request, base64.b64encode(b"[1]")) and rejects(parse_tts_request, "!!")

    fs = schema(True)
    assert fs["required"] == ["sentence", "translation", "tokens"]
    assert fs["properties"]["tokens"]["items"]["required"] == list(FAST_TOKEN_FIELDS)
    assert {"shell_tool", "code_mode_host", "browser_use", "--ignore-user-config"} <= set(NO_TOOLS)
    print("selftest ok")


if __name__ == "__main__":
    modes = {"translate": translate, "tts": tts, "selftest": selftest}
    modes.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: fail("usage: translate | tts | selftest"))()
