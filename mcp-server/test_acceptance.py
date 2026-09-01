#!/usr/bin/env python3
"""DESIGN.md §14 phase 4's own acceptance test, frozen into a script
(per AGENTS.md's own discipline: "freeze what you learn... exploration
is disposable, scenarios accumulate") instead of staying one-off
exploration:

  "Claude Code with the MCP server configured can, in one session and
  with no Bash calls, open a fixture notebook, run a cell, wait for
  idle, and report the resolved face of the output border."

`profiles/smoke/` stands in for the fictional notebook example the rest
of DESIGN.md uses (as it already does for every other acceptance test in
this repo -- see README's "What's been validated"): `hello.txt` is the
fixture, `C-c C-s` (which faces SMOKE-MARKER via a real key binding,
without touching undo or the modified flag) is the "cell", and
`smoke-marker-face` is the "output border"'s resolved face.

This drives eh_mcp_server.py exactly as an MCP client would: spawned
over stdio, called by name, nothing about the harness's internals
touched directly -- no Bash-side `eh` or Emacs Lisp calls of any kind.

Usage:
  EH_HOST=http://localhost:8080 \\
  EH_CF_ACCESS_CLIENT_ID=... EH_CF_ACCESS_CLIENT_SECRET=... \\
  python3 mcp-server/test_acceptance.py [--session NAME]

Exits 0 and prints "ACCEPTANCE TEST: PASS" on success; exits 1 with a
description of what failed otherwise -- suitable for a CI step.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SERVER_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eh_mcp_server.py")


async def run(session_name: str) -> None:
    if not os.environ.get("EH_HOST"):
        sys.exit("EH_HOST must be set to the running harness's http(s) base URL")

    params = StdioServerParameters(command=sys.executable, args=[SERVER_SCRIPT], env=dict(os.environ))

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as mcp_session:
            await mcp_session.initialize()

            tool_names = {t.name for t in (await mcp_session.list_tools()).tools}
            expected = {"emacs_session", "emacs_eval", "emacs_snapshot", "emacs_keys",
                        "emacs_click", "emacs_wait", "emacs_run_scenario", "emacs_screenshot"}
            missing = expected - tool_names
            if missing:
                sys.exit(f"MCP server is missing tools: {sorted(missing)}")

            def text_of(result):
                blocks = [c.text for c in result.content if c.type == "text"]
                if not blocks:
                    sys.exit(f"expected a text content block, got: {result.content}")
                return blocks[0]

            def check_ok(label, result):
                envelope = json.loads(text_of(result))
                if not envelope.get("ok"):
                    sys.exit(f"{label} failed: {envelope}")
                return envelope

            check_ok("session reset", await mcp_session.call_tool(
                "emacs_session", {"action": "reset", "name": session_name}))

            check_ok("open fixture", await mcp_session.call_tool("emacs_eval", {
                "session": session_name,
                "form": '(find-file (expand-file-name "hello.txt" eh-profile-fixtures-dir))',
            }))

            check_ok("run the \"cell\" (C-c C-s)", await mcp_session.call_tool(
                "emacs_keys", {"session": session_name, "keys": ["C-c C-s"]}))

            check_ok("wait for idle", await mcp_session.call_tool(
                "emacs_wait", {"session": session_name, "what": "smoke-ready", "timeout": 15}))

            snap_env = check_ok("snapshot", await mcp_session.call_tool(
                "emacs_snapshot", {"session": session_name, "props": ["smoke-marker"]}))
            faces = [r["face"] for r in snap_env["snapshot"]["runs"] if r.get("face")]
            if faces != ["smoke-marker-face"]:
                sys.exit(f"expected exactly one run faced smoke-marker-face, got: {faces}")
            print("resolved face of the output border:", faces[0])

            shot_result = await mcp_session.call_tool("emacs_screenshot", {"session": session_name})
            images = [c for c in shot_result.content if c.type == "image"]
            if not images or not images[0].data:
                sys.exit("emacs_screenshot returned no image content")
            print(f"screenshot: {len(images[0].data)} base64 bytes, mime={images[0].mime_type}")

    print("\nACCEPTANCE TEST: PASS")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--session", default="acceptance-test")
    args = p.parse_args()
    asyncio.run(run(args.session))


if __name__ == "__main__":
    main()
