"""Smoke test for a DataGrout Reactor app — the D&D 5e SRD rules engine.

Hits the Reactor HTTP API (`POST /apps/<server>/<rule>`) that `reactor.expose`
publishes for an LC rule, and asserts the engine returns correct 5e math. This
is the "external client calls the rule's API" surface — no MCP, just JSON/HTTP,
which is exactly what a Tether/game frontend would do.

Run against a locally-running DataGrout (mix phx.server on :4000):

    python examples/dnd_reactor_smoke.py \
        --base http://localhost:4000 \
        --server "$(cat /tmp/dnd_server_uuid)"

Uses only the Python standard library so it runs without installing the SDK;
swap urllib for httpx/requests (or the conduit Client for the MCP path) freely.
"""

import argparse
import json
import sys
import urllib.request


def invoke(base, server, rule, payload):
    """POST a Reactor rule invocation and return the parsed JSON body."""
    url = f"{base}/apps/{server}/{rule}"
    body = json.dumps({"namespace": "dnd", **payload}).encode()
    req = urllib.request.Request(
        url, data=body, headers={"content-type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def scalar(result, key):
    """Reactor returns each output var as a list of bindings; take the first."""
    v = result.get("result", {}).get(key)
    return v[0] if isinstance(v, list) and v else v


# (rule, payload, output_key, expected) — the canonical sample chars from the seed.
CASES = [
    ("skill_bonus", {"character": "shadow", "skill": "stealth"}, "bonus", 5),
    ("skill_bonus", {"character": "shadow", "skill": "perception"}, "bonus", 3),
    ("skill_bonus", {"character": "shadow", "skill": "persuasion"}, "bonus", -1),
    ("save_bonus", {"character": "shadow", "ability": "dex"}, "bonus", 5),
    ("save_bonus", {"character": "shadow", "ability": "str"}, "bonus", 0),
    ("spell_save_dc", {"character": "mira"}, "dc", 14),
    ("spell_attack_bonus", {"character": "mira"}, "bonus", 6),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:4000")
    ap.add_argument("--server", required=True, help="server_uuid or app slug")
    args = ap.parse_args()

    failures = 0
    for rule, payload, key, expected in CASES:
        try:
            body = invoke(args.base, args.server, rule, payload)
            got = scalar(body, key)
            ok = body.get("ok") and got == expected
            mark = "PASS" if ok else "FAIL"
            if not ok:
                failures += 1
            print(f"[{mark}] {rule}({payload}) -> {key}={got} (expected {expected})")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"[FAIL] {rule}({payload}) -> error: {e}")

    # The combinatorial rule (findall_limit-backed): full skill sheet.
    try:
        sheet = invoke(args.base, args.server, "skill_sheet", {"character": "shadow"})
        rows = scalar(sheet, "sheet") or []
        print(f"[INFO] skill_sheet(shadow) -> {len(rows)} skills (expected 18)")
        if len(rows) != 18:
            failures += 1
    except Exception as e:  # noqa: BLE001
        failures += 1
        print(f"[FAIL] skill_sheet -> error: {e}")

    print(f"\n{'ALL PASS' if failures == 0 else f'{failures} FAILURE(S)'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
