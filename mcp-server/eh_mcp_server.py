#!/usr/bin/env python3
"""eh_mcp_server -- MCP shim over ehd's HTTP API (DESIGN.md §6.1, §14 phase 4).

Runs wherever Claude Code runs (a laptop, a cloud sandbox) -- NOT inside
the harness container. Speaks MCP over stdio to its client and, for every
tool call, makes exactly one `POST {EH_HOST}/v1/<cmd>` to `ehd`'s HTTP API
(see ehd/ehd.py's `handle_http_connection`) -- the same wire protocol
`bin/eh`'s http transport uses. It does no work of its own: every tool
here is a thin translation from an MCP call to that one HTTP round trip
and back, exactly as DESIGN §14 phase 4 specifies ("a thin shim over the
same `ehd` dispatcher, reached over the HTTP transport").

Configuration (environment variables, read once at import time):

  EH_HOST                     required: the harness's http(s) base URL,
                               e.g. https://emacs-harness.example.com
  EH_CF_ACCESS_CLIENT_ID      optional: Cloudflare Access service-token id
  EH_CF_ACCESS_CLIENT_SECRET  optional: Cloudflare Access service-token secret
  EH_TIMEOUT                  optional: default per-call timeout in seconds
                               (default 30)

Every tool takes an optional `session` argument; when omitted, `ehd`
falls back to its own `$EH_SESSION` or the sole running session (DESIGN
§5.2) -- but that fallback is evaluated in `ehd`'s process environment
*inside the container*, not this process's, since the http transport
(unlike the ssh/docker transports) does not share an environment with
`ehd`. Pass `session` explicitly unless the harness has exactly one
session running.

Install: pip install -r requirements.txt
Run directly for a smoke test: EH_HOST=... python3 eh_mcp_server.py
Wire into Claude Code as an MCP server (stdio) pointed at this script.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from mcp.server.mcpserver import MCPServer
import mcp.types as types

EH_HOST = os.environ.get("EH_HOST", "")
CF_ACCESS_CLIENT_ID = os.environ.get("EH_CF_ACCESS_CLIENT_ID", "")
CF_ACCESS_CLIENT_SECRET = os.environ.get("EH_CF_ACCESS_CLIENT_SECRET", "")
DEFAULT_TIMEOUT = float(os.environ.get("EH_TIMEOUT", "30"))

mcp = MCPServer(
    "emacs-harness",
    instructions=(
        "Drive a real, graphical Emacs running headlessly in the emacs-harness "
        "container. Prefer emacs_snapshot over emacs_screenshot for almost every "
        "question -- it answers text, faces, overlays, properties, geometry and "
        "the mode line exactly and cheaply; use emacs_screenshot only to confirm "
        "something actually rasterised, or to show a human. Drive input with "
        "emacs_keys, not emacs_eval on the underlying function, so the real "
        "keymap and command loop are exercised. Every action that touches a "
        "subprocess or redisplay is asynchronous: call emacs_wait afterward "
        "rather than assuming it already happened."
    ),
)


def _post(cmd: str, session: str | None = None, args: dict | None = None,
          timeout: float = DEFAULT_TIMEOUT) -> dict:
    """One HTTP round trip to `ehd`, same wire format as bin/eh's http
    transport: POST {session, args, timeout} as JSON to /v1/<cmd>. Never
    raises -- a transport-level failure comes back as the same {"ok":
    false, "error": {...}} envelope a real `ehd` error would, so callers
    (here, the MCP tool functions) don't need two error-handling paths."""
    if not EH_HOST:
        return {"ok": False,
                "error": {"message": "EH_HOST is not set -- point it at the harness's "
                                      "https:// base URL (DESIGN §6.1)"},
                "exit_code": 2}
    body = json.dumps({"session": session, "args": args or {}, "timeout": timeout}).encode()
    url = f"{EH_HOST.rstrip('/')}/v1/{cmd}"
    headers = {"Content-Type": "application/json"}
    if CF_ACCESS_CLIENT_ID:
        headers["CF-Access-Client-Id"] = CF_ACCESS_CLIENT_ID
    if CF_ACCESS_CLIENT_SECRET:
        headers["CF-Access-Client-Secret"] = CF_ACCESS_CLIENT_SECRET
    http_req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(http_req, timeout=timeout + 10) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"ok": False, "error": {"message": f"http {e.code}: {e.reason}"},
                    "exit_code": 5}
    except urllib.error.URLError as e:
        return {"ok": False, "error": {"message": f"cannot reach ehd (http, {url}): {e.reason}"},
                "exit_code": 5}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": {"message": f"http transport error: {e}"}, "exit_code": 5}


@mcp.tool()
def emacs_session(action: str, name: str | None = None, profile: str = "smoke",
                   geometry: str = "1280x800", theme: str | None = None,
                   emacs: str | None = None) -> str:
    """Manage harness sessions. `action` is one of "new", "list", "reset",
    "rm". `name` names the session (required for new/reset/rm; omit for
    list). `profile`/`geometry`/`theme`/`emacs` apply to "new" only. A
    scenario run gets a fresh session by default (DESIGN §5.2) -- prefer
    "reset" over reusing a dirty one when state may have leaked."""
    if action not in ("new", "list", "reset", "rm"):
        return json.dumps({"ok": False,
                            "error": {"message": f'unknown action "{action}": '
                                                  'expected new, list, reset or rm'}})
    args: dict = {"name": name}
    if action == "new":
        args = dict(name=name, profile=profile, geometry=geometry, theme=theme, emacs=emacs)
    resp = _post(f"session-{action}", session=name, args=args, timeout=60)
    return json.dumps(resp)


@mcp.tool()
def emacs_eval(form: str, session: str | None = None, timeout: float = 30) -> str:
    """Evaluate an Elisp FORM in the session (DESIGN tier 1) and return the
    JSON result envelope: {ok, value, value_type, messages, stdout,
    elapsed_ms} on success, {ok: false, error: {symbol, data, message,
    backtrace}} if FORM signalled. Prefer emacs_keys for anything a real
    key sequence would trigger -- eval bypasses the keymap and command
    loop entirely."""
    resp = _post("eval", session=session, args=dict(form=form), timeout=timeout)
    return json.dumps(resp)


@mcp.tool()
def emacs_snapshot(session: str | None = None, buffer: str | None = None,
                    window: bool = False, region: list[int] | None = None,
                    props: list[str] | None = None, visible_only: bool = False,
                    no_text: bool = False, images: bool = False,
                    timeout: float = 30) -> str:
    """The workhorse (DESIGN §6.2): a structured, diffable description of a
    buffer or window -- text, resolved faces, overlays, text properties,
    read-only/invisible state and decoded image descriptors, as a list of
    maximal runs. Omit `buffer` to snapshot whatever the session's frame
    currently shows. Pass `region` as [BEG, END] to snapshot only that
    span, and `props` (e.g. ["smoke-marker"]) to limit which overlay/text
    properties are reported. This is almost always the right tool before
    reaching for emacs_screenshot."""
    args = dict(buffer=buffer, window=window, region=region, props=props,
                visible_only=visible_only, no_text=no_text, images=images, format="json")
    resp = _post("snapshot", session=session, args=args, timeout=timeout)
    return json.dumps(resp)


@mcp.tool()
def emacs_keys(keys: list[str], session: str | None = None, x: bool = False,
                timeout: float = 30) -> str:
    """Send a sequence of Emacs key descriptions (e.g. ["C-c C-e"] or
    ["C-c C-i", "x = 2", "RET"]) through the real keymap and command loop
    (DESIGN tier 2a: `execute-kbd-macro`, the default and almost-always-
    right choice) or, with x=true, through the real X server via xdotool
    (tier 2b -- slower and asynchronous, follow with emacs_wait; the only
    way to prove a key like <C-return> actually arrives)."""
    resp = _post("keys", session=session, args=dict(keys=keys, x=x), timeout=timeout)
    return json.dumps(resp)


@mcp.tool()
def emacs_click(session: str | None = None, at_point: bool = False, at: str | None = None,
                 at_text: str | None = None, xy: list[int] | None = None, button: int = 1,
                 double: bool = False, modifiers: list[str] | None = None,
                 timeout: float = 30) -> str:
    """Click through the real X server (DESIGN tier 2b), targeted by
    exactly one of: at_point (wherever point already is), at (an Elisp
    form evaluating to a buffer position, e.g. "(eh-cell-output-start
    2)"), at_text (first match of that string in the visible window), or
    xy ([X, Y] raw display coordinates). `modifiers` is a list drawn from
    ctrl/shift/alt/super/hyper."""
    args = dict(at_point=at_point, at=at, at_text=at_text, xy=xy, button=button,
                double=double, modifiers=modifiers)
    resp = _post("click", session=session, args=args, timeout=timeout)
    return json.dumps(resp)


@mcp.tool()
def emacs_wait(what: str, session: str | None = None, timeout: float = 30,
               poll_ms: float = 50) -> str:
    """Block until a condition holds (DESIGN tier 0 -- use this after
    *every* action that touches a subprocess or redisplay; a fixed sleep
    that merely happens to be long enough is a test that will fail in
    CI). `what` is either a profile-registered waiter name (e.g.
    "subprocess-idle") or a literal Elisp predicate form (e.g. "(not
    (my-pkg-busy-p))") -- forms are auto-detected by a leading "(". On
    timeout the error envelope carries a full window snapshot of what the
    session looked like when it gave up."""
    is_name = not what.strip().startswith("(")
    args = dict(what=what, is_name=is_name, timeout=timeout, poll_ms=poll_ms)
    resp = _post("wait", session=session, args=args, timeout=timeout + 5)
    return json.dumps(resp)


@mcp.tool()
def emacs_run_scenario(profile: str, session: str | None = None,
                        scenario: list[str] | None = None, tag: str | None = None,
                        emacs: list[str] | None = None, batch: bool = False,
                        reuse_session: bool = False, timeout: float = 300) -> str:
    """Run a profile's ERT scenarios (or, with batch=true, its existing
    batch suite unchanged) and return the JSON summary: counts plus one
    entry per test with status/duration/message, and the artifact run
    directory. Omit `scenario` to run every scenario the profile has.
    `emacs` runs the same selection against each named Emacs binary in
    turn and reports a per-version matrix (DESIGN §14 phase 3)."""
    args = dict(profile=profile, scenario=scenario or [], tag=tag, emacs=emacs,
                batch=batch, reuse_session=reuse_session)
    resp = _post("run", session=session, args=args, timeout=timeout)
    return json.dumps(resp)


@mcp.tool()
def emacs_screenshot(session: str | None = None, display: bool = False,
                      timeout: float = 30) -> list[types.ContentBlock]:
    """Screenshot the session's frame (DESIGN tier 3 -- the backstop for
    "did this actually rasterise/lay out", not a substitute for
    emacs_snapshot). Returns the metadata envelope (path inside the
    container, sha256, byte count) as text, followed by the actual PNG
    pixels as image content -- `ehd`'s HTTP layer inlines them, since this
    process has no shared filesystem with the container. display=true
    captures the whole X display instead of just the frame's own cairo
    export (tooltips, menus, other frames)."""
    resp = _post("shot", session=session, args=dict(display=display), timeout=timeout)
    data_b64 = resp.pop("data_base64", None)
    blocks: list[types.ContentBlock] = [types.TextContent(type="text", text=json.dumps(resp))]
    if data_b64:
        blocks.append(types.ImageContent(type="image", data=data_b64, mimeType="image/png"))
    return blocks


if __name__ == "__main__":
    mcp.run()
