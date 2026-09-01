#!/usr/bin/env python3
"""ehd -- the in-container dispatcher (DESIGN.md §5, §6).

Listens on a Unix socket (default /run/eh/eh.sock), speaks newline-delimited
JSON: one request line in, one response line out, per connection.  Owns
session lifecycle (Xvfb + openbox + one Emacs process per session) and
translates `eh` subcommands into the file-based Emacs eval protocol
(eh-driver.el, DESIGN §6.2), or into direct subprocess calls (xdotool,
ImageMagick, ffmpeg) for the parts that live outside Emacs.

ehd does the work; `bin/eh` and `ehd-cli` are dumb pipes to it.
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import dataclasses
import hashlib
import hmac
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Optional

EH_ROOT = Path(os.environ.get("EH_ROOT", "/opt/eh"))
ELISP_DIR = Path(os.environ.get("EH_ELISP_DIR", str(EH_ROOT / "elisp")))
PROFILES_ROOT = Path(os.environ.get("EH_PROFILES_ROOT", "/srv/profiles"))
RUN_ROOT = Path(os.environ.get("EH_VAR_RUN", "/run/eh"))
RUNS_ARTIFACT_ROOT = Path(os.environ.get("EH_RUNS_ROOT", "/var/lib/eh/runs"))
SCRATCH_ROOT = Path(os.environ.get("EH_SCRATCH_ROOT", "/tmp"))
SOCKET_PATH = Path(os.environ.get("EH_SOCK", str(RUN_ROOT / "eh.sock")))
EMACS_BIN = os.environ.get("EH_EMACS_BIN", "emacs")
DISPLAY_BASE = int(os.environ.get("EH_DISPLAY_BASE", "99"))

# DESIGN §6.1/§14 phase 4: the HTTP transport, off by default. The real
# access boundary is the Cloudflare Tunnel + Access application in front
# of it (§10.2); CF-Access-Client-Id/Secret matching here is defense in
# depth for whatever reaches this process directly, not the only gate.
HTTP_ENABLE = os.environ.get("EH_HTTP_ENABLE", "0") not in ("", "0", "false", "False")
HTTP_HOST = os.environ.get("EH_HTTP_HOST", "0.0.0.0")
HTTP_PORT = int(os.environ.get("EH_HTTP_PORT", "8080"))
HTTP_CLIENT_ID = os.environ.get("EH_HTTP_CLIENT_ID", "")
HTTP_CLIENT_SECRET = os.environ.get("EH_HTTP_CLIENT_SECRET", "")
HTTP_MAX_BODY = 8 * 1024 * 1024
HTTP_INLINE_SHOT_CAP = 8 * 1024 * 1024

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_TIMEOUT = 3
EXIT_EMACS_ERROR = 4
EXIT_SESSION_DEAD = 5


class EhError(Exception):
    def __init__(self, message: str, exit_code: int = EXIT_USAGE, **extra: Any):
        super().__init__(message)
        self.message = message
        self.exit_code = exit_code
        self.extra = extra


@dataclasses.dataclass
class Session:
    name: str
    display: int
    geometry: str
    theme: Optional[str]
    profile: str
    emacs_bin: str
    scratch_home: Path
    run_dir: Path
    socket_path: Path
    xvfb: subprocess.Popen
    openbox: subprocess.Popen
    emacs: subprocess.Popen
    created_at: float = dataclasses.field(default_factory=time.time)
    dead: bool = False
    video: Optional[subprocess.Popen] = None
    video_out: Optional[Path] = None

    def env(self) -> dict:
        e = dict(os.environ)
        e.update(
            DISPLAY=f":{self.display}",
            HOME=str(self.scratch_home),
            TZ="UTC",
            LANG="C.UTF-8",
            LC_ALL="C.UTF-8",
            NO_AT_BRIDGE="1",
        )
        e.pop("COLORTERM", None)
        return e


class SessionManager:
    def __init__(self):
        self.sessions: dict[str, Session] = {}
        self._displays_in_use: set[int] = set()
        self._lock = asyncio.Lock()

    def default_name(self) -> Optional[str]:
        if len(self.sessions) == 1:
            return next(iter(self.sessions))
        return None

    def get(self, name: Optional[str]) -> Session:
        name = name or os.environ.get("EH_SESSION") or self.default_name()
        if not name or name not in self.sessions:
            raise EhError(f"no such session: {name}", EXIT_SESSION_DEAD)
        sess = self.sessions[name]
        if sess.dead:
            raise EhError(f"session {name} is dead", EXIT_SESSION_DEAD)
        return sess

    def _alloc_display(self) -> int:
        n = DISPLAY_BASE
        while n in self._displays_in_use or Path(f"/tmp/.X{n}-lock").exists():
            n += 1
        self._displays_in_use.add(n)
        return n

    async def new(self, name: str, profile: str = "smoke", geometry: str = "1280x800",
                   theme: Optional[str] = None, emacs_bin: Optional[str] = None,
                   font: str = "DejaVu Sans Mono-11") -> Session:
        async with self._lock:
            if name in self.sessions and not self.sessions[name].dead:
                raise EhError(f"session {name} already exists", EXIT_USAGE)
            display = self._alloc_display()
        profile_dir = PROFILES_ROOT / profile
        if not profile_dir.is_dir():
            raise EhError(f"no such profile: {profile}", EXIT_USAGE)

        run_dir = RUN_ROOT / name
        scratch_home = SCRATCH_ROOT / f"eh-scratch-{name}"
        for p in (run_dir / "in", run_dir / "out", scratch_home / "emacs.d"):
            p.mkdir(parents=True, exist_ok=True)
        # `run_dir` doubles as Emacs's `server-socket-dir` (§6.2); server.el's
        # server-ensure-safe-dir refuses to bind the socket there unless it is
        # 0700, and a plain mkdir() leaves it group/other-readable per umask.
        os.chmod(run_dir, 0o700)

        env = dict(os.environ, DISPLAY=f":{display}")
        width, height = (geometry.split("x") + ["800"])[:2]

        xvfb = subprocess.Popen(
            ["Xvfb", f":{display}", "-screen", "0", "1920x1080x24", "-dpi", "96", "-nolisten", "tcp"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if not await _wait_for(lambda: _xvfb_ready(display), timeout=10):
            xvfb.kill()
            raise EhError(f"Xvfb did not come up on display :{display}", EXIT_SESSION_DEAD)

        openbox_rc = run_dir / "openbox-rc.xml"
        openbox_rc.write_text(_OPENBOX_RC)
        openbox = subprocess.Popen(
            ["openbox", "--config-file", str(openbox_rc)],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

        socket_name = "server"
        socket_path = run_dir / socket_name
        init_file = run_dir / "session-init.el"
        init_file.write_text(_session_init_el(
            session_name=name, run_dir=run_dir, profile_dir=profile_dir,
            width=width, height=height, font=font, theme=theme,
            strict_prompts=True,
        ))

        emacs_bin = emacs_bin or EMACS_BIN
        emacs_args = [
            emacs_bin, "-Q", "--no-site-file",
            "-l", str(init_file),
        ]
        sess_env = dict(env, HOME=str(scratch_home), TZ="UTC", LANG="C.UTF-8",
                         LC_ALL="C.UTF-8", NO_AT_BRIDGE="1",
                         EH_SOCKET_NAME=socket_name)
        sess_env.pop("COLORTERM", None)
        emacs_log = open(run_dir / "emacs.log", "wb")
        try:
            emacs = subprocess.Popen(emacs_args, env=sess_env, stdout=emacs_log, stderr=emacs_log)
        except OSError as e:
            # Most commonly a bad --emacs binary (matrix runs pass one per
            # version -- DESIGN §14 phase 3).  Must surface as EhError, not
            # escape as a raw OSError: `_run_one_version` only catches
            # EhError to convert a bad version into that version's own
            # failed result rather than aborting the whole matrix.
            xvfb.kill()
            openbox.kill()
            raise EhError(f"failed to launch {emacs_bin}: {e}", EXIT_SESSION_DEAD)

        sess = Session(name=name, display=display, geometry=geometry, theme=theme,
                        profile=profile, emacs_bin=emacs_bin, scratch_home=scratch_home,
                        run_dir=run_dir, socket_path=socket_path,
                        xvfb=xvfb, openbox=openbox, emacs=emacs)

        if not await _wait_for(lambda: socket_path.exists(), timeout=30):
            sess.dead = True
            self.sessions[name] = sess
            raise EhError("emacs server socket never appeared (see emacs.log)", EXIT_SESSION_DEAD)
        ok = await _emacsclient_ping(sess)
        if not ok:
            sess.dead = True
            raise EhError("emacs server did not respond to ping", EXIT_SESSION_DEAD)

        self.sessions[name] = sess
        return sess

    async def reset(self, name: str) -> Session:
        sess = self.get(name)
        _terminate(sess.emacs)
        shutil.rmtree(sess.scratch_home, ignore_errors=True)
        (sess.scratch_home / "emacs.d").mkdir(parents=True, exist_ok=True)
        init_file = sess.run_dir / "session-init.el"
        env = dict(os.environ, DISPLAY=f":{sess.display}", HOME=str(sess.scratch_home),
                    TZ="UTC", LANG="C.UTF-8", LC_ALL="C.UTF-8", NO_AT_BRIDGE="1",
                    EH_SOCKET_NAME="server")
        env.pop("COLORTERM", None)
        emacs_log = open(sess.run_dir / "emacs.log", "ab")
        sess.emacs = subprocess.Popen([sess.emacs_bin, "-Q", "--no-site-file", "-l", str(init_file)],
                                       env=env, stdout=emacs_log, stderr=emacs_log)
        sess.dead = False
        if not await _wait_for(lambda: sess.socket_path.exists(), timeout=30):
            sess.dead = True
            raise EhError("emacs server never came back after reset", EXIT_SESSION_DEAD)
        return sess

    async def rm(self, name: str):
        sess = self.sessions.pop(name, None)
        if not sess:
            raise EhError(f"no such session: {name}", EXIT_USAGE)
        _terminate(sess.emacs)
        _terminate(sess.openbox)
        _terminate(sess.xvfb)
        self._displays_in_use.discard(sess.display)

    def list(self) -> list[dict]:
        return [
            dict(name=s.name, display=s.display, profile=s.profile, geometry=s.geometry,
                 theme=s.theme, dead=s.dead, created_at=s.created_at)
            for s in self.sessions.values()
        ]


def _terminate(proc: Optional[subprocess.Popen]):
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _xvfb_ready(display: int) -> bool:
    return Path(f"/tmp/.X11-unix/X{display}").exists()


async def _wait_for(predicate, timeout: float, poll: float = 0.1) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        await asyncio.sleep(poll)
    return predicate()


async def _emacsclient_ping(sess: Session) -> bool:
    try:
        proc = await asyncio.create_subprocess_exec(
            "emacsclient", "--socket-name", str(sess.socket_path), "--eval", "1",
            env=sess.env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        await asyncio.wait_for(proc.communicate(), timeout=10)
        return proc.returncode == 0
    except Exception:
        return False


_OPENBOX_RC = """<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <keyboard></keyboard>
  <mouse></mouse>
  <theme><name>Clearlooks</name><titleLayout></titleLayout></theme>
  <applications>
    <application class="*"><decor>no</decor></application>
  </applications>
</openbox_config>
"""


def _session_init_el(*, session_name: str, run_dir: Path, profile_dir: Path,
                      width: str, height: str, font: str, theme: Optional[str],
                      strict_prompts: bool) -> str:
    theme_form = f'(load-theme (quote {theme}) t)' if theme else ""
    theme_lisp = f'"{theme}"' if theme else "nil"
    return f"""\
;; generated by ehd -- do not edit
(setq eh-session-name "{session_name}")
(setq eh-run-dir "{run_dir}")
(setq eh-strict-prompts {"t" if strict_prompts else "nil"})
(setq eh-frame-width {width})
(setq eh-frame-height {height})
(setq eh-frame-font "{font}")
(setq eh-profile-dir "{profile_dir}")
(setq eh-profile-fixtures-dir "{profile_dir / 'fixtures'}")
(setq eh-profile-scratch-dir (expand-file-name "workdir" eh-run-dir))
(setq eh-session-theme {theme_lisp})
(setq eh-session-geometry "{width}x{height}")
(make-directory eh-profile-scratch-dir t)
(load "{ELISP_DIR / 'eh-init-core.el'}")
{theme_form}
(load "{profile_dir / 'init.el'}")
(eh-driver-start-server)
"""


# ---------------------------------------------------------------------
# emacs eval bridge (DESIGN §6.2)

async def emacs_eval(sess: Session, form_text: str, timeout: float = 30.0) -> dict:
    req_id = uuid.uuid4().hex
    in_path = sess.run_dir / "in" / f"{req_id}.el"
    out_path = sess.run_dir / "out" / f"{req_id}.json"
    in_path.write_text(form_text)
    cmd = ["emacsclient", "--socket-name", str(sess.socket_path),
           "--eval", f'(eh-driver-run "{req_id}")']
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, env=sess.env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        _out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        await _hang_recovery(sess)
        raise EhError(f"eval timed out after {timeout}s; hang recovery engaged", EXIT_TIMEOUT)
    if proc.returncode != 0:
        sess.dead = True
        raise EhError(f"emacsclient failed: {err.decode(errors='replace')}", EXIT_SESSION_DEAD)
    if not out_path.exists():
        raise EhError("emacs produced no output file", EXIT_EMACS_ERROR)
    envelope = json.loads(out_path.read_text())
    if envelope.get("ok") is False:
        raise EhEvalError(envelope)
    return envelope


class EhEvalError(Exception):
    def __init__(self, envelope: dict):
        self.envelope = envelope
        super().__init__(envelope.get("error", {}).get("message", "emacs error"))


async def _hang_recovery(sess: Session):
    win = await _find_emacs_window(sess)
    for _ in range(3):
        if win:
            subprocess.run(["xdotool", "key", "--window", win, "ctrl+g"], env=sess.env())
        await asyncio.sleep(0.2)
    try:
        sess.emacs.send_signal(signal.SIGUSR2)
    except Exception:
        pass
    shot_path = sess.run_dir / f"hang-{int(time.time())}.png"
    try:
        subprocess.run(["import", "-window", "root", str(shot_path)], env=sess.env(), timeout=5)
    except Exception:
        pass
    try:
        ps = subprocess.run(["ps", "-ef"], capture_output=True, text=True, timeout=5)
        (sess.run_dir / "proc-tree-at-hang.txt").write_text(ps.stdout)
    except Exception:
        pass
    sess.dead = True


async def _find_emacs_window(sess: Session) -> Optional[str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            "xdotool", "search", "--class", "Emacs",
            env=sess.env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        ids = out.decode().split()
        return ids[0] if ids else None
    except Exception:
        return None


def _elisp_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


_MODIFIER_KEYS = {"ctrl": "ctrl", "control": "ctrl", "alt": "alt", "meta": "alt",
                   "shift": "shift", "super": "super", "hyper": "hyper"}


def _translate_chord(desc: str) -> str:
    """Best-effort single Emacs key chord -> xdotool key syntax, per DESIGN §6.3.
    Must be tested against the real translator; this covers the common cases."""
    mods = {"C": "ctrl", "M": "alt", "S": "shift", "s": "super", "H": "hyper"}
    names = {"RET": "Return", "TAB": "Tab", "SPC": "space", "DEL": "BackSpace",
              "ESC": "Escape", "return": "Return"}
    desc = desc.strip()
    if desc.startswith("<") and desc.endswith(">"):
        desc = desc[1:-1]
    parts = desc.split("-")
    out_mods = []
    while len(parts) > 1 and parts[0] in mods:
        out_mods.append(mods[parts[0]])
        parts = parts[1:]
    key = "-".join(parts)
    key = names.get(key, key)
    return "+".join(out_mods + [key])


def _translate_key(desc: str) -> list[str]:
    """DESC may be a single chord ("C-c") or a whitespace-separated sequence
    of chords ("C-c C-e", per the `eh keys "C-c C-e"` example in DESIGN §6.3);
    each chord becomes one xdotool key token, pressed in order."""
    return [_translate_chord(chord) for chord in desc.split()]


# ---------------------------------------------------------------------
# doctor (DESIGN §12)

def _which_ok(name: str) -> tuple[bool, str]:
    path = shutil.which(name)
    return (bool(path), path or "not found")


def host_doctor_checks() -> list[dict]:
    checks = []
    for tool in ("Xvfb", "openbox", "emacsclient", "xdotool", "convert", "compare",
                 "identify", "ffmpeg"):
        ok, detail = _which_ok(tool)
        checks.append(dict(check=f"tool:{tool}", ok=ok, detail=detail))
    ok = RUNS_ARTIFACT_ROOT.exists() or _try_mkdir(RUNS_ARTIFACT_ROOT)
    writable = ok and os.access(RUNS_ARTIFACT_ROOT, os.W_OK)
    checks.append(dict(check="writable-run-dir", ok=writable, detail=str(RUNS_ARTIFACT_ROOT)))
    checks.append(dict(check="clock-is-utc", ok=(time.tzname[0] in ("UTC", "GMT")),
                        detail=str(time.tzname)))
    return checks


def _try_mkdir(p: Path) -> bool:
    try:
        p.mkdir(parents=True, exist_ok=True)
        return True
    except Exception:
        return False


async def run_doctor(mgr: SessionManager, session_name: Optional[str]) -> dict:
    checks = host_doctor_checks()
    ephemeral = None
    try:
        sess = mgr.get(session_name)
    except EhError:
        ephemeral = f"doctor-{uuid.uuid4().hex[:8]}"
        sess = await mgr.new(ephemeral, profile="smoke")
    try:
        envelope = await emacs_eval(sess, "(eh-doctor-json)", timeout=30)
        checks.extend(envelope["value"])
    finally:
        if ephemeral:
            await mgr.rm(ephemeral)
    all_ok = all(c["ok"] for c in checks)
    return dict(ok=all_ok, checks=checks)


# ---------------------------------------------------------------------
# command handlers

def _region_arg(args) -> Optional[list]:
    r = args.get("region")
    return list(r) if r else None


async def handle(mgr: SessionManager, req: dict) -> dict:
    cmd = req.get("cmd")
    args = req.get("args") or {}
    timeout = req.get("timeout") or 30
    session_name = req.get("session")

    if cmd == "doctor":
        result = await run_doctor(mgr, session_name)
        return dict(ok=result["ok"], checks=result["checks"],
                    exit_code=EXIT_OK if result["ok"] else EXIT_FAIL)

    if cmd == "session-new":
        sess = await mgr.new(
            name=args["name"], profile=args.get("profile", "smoke"),
            geometry=args.get("geometry", "1280x800"), theme=args.get("theme"),
            emacs_bin=args.get("emacs"), font=args.get("font", "DejaVu Sans Mono-11"),
        )
        return dict(ok=True, session=sess.name, display=sess.display, exit_code=EXIT_OK)

    if cmd == "session-list":
        return dict(ok=True, sessions=mgr.list(), exit_code=EXIT_OK)

    if cmd == "session-reset":
        sess = await mgr.reset(args.get("name") or session_name)
        return dict(ok=True, session=sess.name, exit_code=EXIT_OK)

    if cmd == "session-rm":
        await mgr.rm(args.get("name") or session_name)
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "run":
        return await handle_run(mgr, session_name, args, timeout)

    sess = mgr.get(session_name)

    if cmd == "eval":
        envelope = await emacs_eval(sess, args["form"], timeout)
        return dict(ok=True, **{k: v for k, v in envelope.items() if k != "ok"}, exit_code=EXIT_OK)

    if cmd == "snapshot":
        kwargs = []
        if args.get("buffer"): kwargs.append(f':buffer {_elisp_str(args["buffer"])}')
        if args.get("window"): kwargs.append(":window t")
        region = _region_arg(args)
        if region: kwargs.append(f":region (list {region[0]} {region[1]})")
        if args.get("visible_only"): kwargs.append(":visible-only t")
        if args.get("no_text"): kwargs.append(":no-text t")
        if args.get("images"): kwargs.append(":images t")
        if args.get("props"):
            props = " ".join(f"'{p}" for p in args["props"])
            kwargs.append(f":props (list {props})")
        if args.get("format") == "sexp":
            form = f"(eh-snapshot {' '.join(kwargs)})"
            envelope = await emacs_eval(sess, form, timeout)
            return dict(ok=True, snapshot=envelope["value"], exit_code=EXIT_OK)
        form = f"(eh-snapshot-json {' '.join(kwargs)})"
        envelope = await emacs_eval(sess, form, timeout)
        return dict(ok=True, snapshot=envelope["value"], exit_code=EXIT_OK)

    if cmd == "describe":
        envelope = await emacs_eval(sess, "(eh-describe-json)", timeout)
        return dict(ok=True, describe=envelope["value"], exit_code=EXIT_OK)

    if cmd == "keys":
        keys = args["keys"]
        if args.get("x"):
            win = await _find_emacs_window(sess)
            if not win:
                raise EhError("no Emacs window found for --x", EXIT_SESSION_DEAD)
            for k in keys:
                subprocess.run(["xdotool", "key", "--window", win, "--clearmodifiers",
                                 *_translate_key(k)], env=sess.env(), timeout=timeout)
            return dict(ok=True, exit_code=EXIT_OK)
        form = "(eh-send-keys " + " ".join(_elisp_str(k) for k in keys) + ")"
        await emacs_eval(sess, form, timeout)
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "type":
        await emacs_eval(sess, f'(eh-type-text {_elisp_str(args["text"])})', timeout)
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "answer":
        val = args["value"]
        lisp = "'yes" if val == "yes" else ("'no" if val == "no" else _elisp_str(val))
        await emacs_eval(sess, f"(eh-push-answer {lisp})", timeout)
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "click":
        xy = await _resolve_click_xy(sess, args, timeout)
        win = await _find_emacs_window(sess)
        button = str(args.get("button", 1))
        mod_keys = [_MODIFIER_KEYS[m] for m in (args.get("modifiers") or [])]
        cmdline = ["xdotool", "mousemove", "--window", win, str(xy[0]), str(xy[1])]
        subprocess.run(cmdline, env=sess.env(), timeout=timeout)
        click_cmd = ["xdotool", "click"]
        if args.get("double"):
            click_cmd += ["--repeat", "2"]
        click_cmd.append(button)
        try:
            if mod_keys:
                subprocess.run(["xdotool", "keydown", *mod_keys], env=sess.env(), timeout=timeout)
            subprocess.run(click_cmd, env=sess.env(), timeout=timeout)
        finally:
            if mod_keys:
                subprocess.run(["xdotool", "keyup", *mod_keys], env=sess.env(), timeout=timeout)
        return dict(ok=True, x=xy[0], y=xy[1], exit_code=EXIT_OK)

    if cmd == "drag":
        from_xy = await _resolve_click_xy(sess, {"at": args["from"]}, timeout)
        to_xy = await _resolve_click_xy(sess, {"at": args["to"]}, timeout)
        win = await _find_emacs_window(sess)
        subprocess.run(["xdotool", "mousemove", "--window", win, str(from_xy[0]), str(from_xy[1]),
                         "mousedown", "1", "mousemove", "--window", win, str(to_xy[0]), str(to_xy[1]),
                         "mouseup", "1"], env=sess.env(), timeout=timeout)
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "scroll":
        if args.get("lines"):
            await emacs_eval(sess, f'(scroll-up {int(args["lines"])})', timeout)
        elif args.get("pixels"):
            await emacs_eval(sess, f'(eh-scroll-pixels {int(args["pixels"])})', timeout)
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "wait":
        name_or_form = args["what"]
        wtimeout = args.get("timeout", 30)
        poll = args.get("poll_ms", 50) / 1000.0
        if args.get("is_name"):
            form = f'(eh-wait-name {_elisp_str(name_or_form)} {wtimeout} {poll})'
        else:
            form = f'(eh-wait-form {_elisp_str(name_or_form)} {wtimeout} {poll})'
        try:
            await emacs_eval(sess, form, timeout=wtimeout + 5)
        except EhEvalError as e:
            symbol = e.envelope.get("error", {}).get("symbol", "")
            if "eh-timeout" in symbol:
                return dict(ok=False, error=e.envelope["error"], exit_code=EXIT_TIMEOUT)
            raise
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "settle":
        kwargs = []
        if args.get("frames_stable"): kwargs.append(f":frames-stable {args['frames_stable']}")
        if args.get("timeout"): kwargs.append(f":timeout {args['timeout']}")
        await emacs_eval(sess, f"(eh-settle {' '.join(kwargs)})", args.get("timeout", 15) + 5)
        return dict(ok=True, exit_code=EXIT_OK)

    if cmd == "shot":
        out = args.get("out") or str(sess.run_dir / f"shot-{uuid.uuid4().hex[:8]}.png")
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        if args.get("display"):
            subprocess.run(["import", "-window", "root", out], env=sess.env(), timeout=timeout)
            digest = hashlib.sha256(Path(out).read_bytes()).hexdigest()
            return dict(ok=True, path=out, sha256=digest, exit_code=EXIT_OK)
        envelope = await emacs_eval(sess, f'(eh-shot-to-file-json {_elisp_str(out)})', timeout)
        return dict(ok=True, **envelope["value"], exit_code=EXIT_OK)

    if cmd == "video-start":
        out = args.get("out") or str(sess.run_dir / "video.mp4")
        geom = sess.geometry
        proc = subprocess.Popen(
            ["ffmpeg", "-y", "-f", "x11grab", "-framerate", "10", "-video_size", geom,
             "-i", f":{sess.display}", out],
            env=sess.env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        sess.video, sess.video_out = proc, Path(out)
        return dict(ok=True, path=out, exit_code=EXIT_OK)

    if cmd == "video-stop":
        if sess.video:
            sess.video.send_signal(signal.SIGINT)
            try:
                sess.video.wait(timeout=10)
            except Exception:
                sess.video.kill()
            out = sess.video_out
            sess.video = None
            if args.get("gif"):
                gif_path = out.with_suffix(".gif")
                _mp4_to_gif(out, gif_path, env=sess.env(), timeout=timeout)
                return dict(ok=True, path=str(out), gif=str(gif_path), exit_code=EXIT_OK)
            return dict(ok=True, path=str(out), exit_code=EXIT_OK)
        return dict(ok=False, error={"message": "no video in progress"}, exit_code=EXIT_USAGE)

    if cmd == "diff-shot":
        return await handle_diff_shot(sess, args, timeout)

    if cmd == "baseline-accept":
        return await handle_baseline_accept(sess, args)

    if cmd == "logs":
        service = args.get("service", "emacs")
        tail = args.get("tail", 100)
        path = sess.run_dir / f"{service}.log"
        if not path.exists():
            return dict(ok=False, error={"message": f"no such log: {service}"}, exit_code=EXIT_USAGE)
        lines = path.read_text(errors="replace").splitlines()[-tail:]
        return dict(ok=True, lines=lines, exit_code=EXIT_OK)

    raise EhError(f"unknown command: {cmd}", EXIT_USAGE)


async def _resolve_click_xy(sess: Session, args: dict, timeout: float) -> tuple[int, int]:
    if args.get("xy"):
        x, y = args["xy"]
        return int(x), int(y)
    if args.get("at_point"):
        # Not a bare `(point)`: `current-buffer` at RPC time is server.el's
        # own connection buffer, not whatever an earlier, separate `eh`
        # call left on screen (see `eh-selected-buffer` in eh-driver.el).
        form = "(eh-display-xy-json (eh-selected-point))"
    elif args.get("at"):
        form = f'(eh-display-xy-json {args["at"]})'
    elif args.get("at_text"):
        form = (f'(eh-display-xy-json (save-excursion (goto-char (point-min)) '
                f'(search-forward {_elisp_str(args["at_text"])}) (match-beginning 0)))')
    else:
        raise EhError("click needs --at-point, --at, --at-text or --xy", EXIT_USAGE)
    envelope = await emacs_eval(sess, form, timeout)
    v = envelope["value"]
    if v is False or v is None:
        raise EhError("target position is not visible on screen", EXIT_FAIL)
    return int(v["x"]), int(v["y"])


def _mp4_to_gif(src: Path, dst: Path, env: dict, timeout: float) -> None:
    """Two-pass ffmpeg palette conversion (DESIGN §6.4 `eh video --gif`):
    a plain single-pass gif encode looks washed out next to the source
    video, and the palette step is cheap for the short clips this is for."""
    palette = dst.with_suffix(".palette.png")
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(src), "-vf",
             "fps=10,scale=iw:-1:flags=lanczos,palettegen", str(palette)],
            env=env, capture_output=True, timeout=max(timeout, 30),
        )
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(src), "-i", str(palette), "-filter_complex",
             "fps=10,scale=iw:-1:flags=lanczos[x];[x][1:v]paletteuse", str(dst)],
            env=env, capture_output=True, timeout=max(timeout, 30),
        )
    finally:
        palette.unlink(missing_ok=True)


async def handle_diff_shot(sess: Session, args: dict, timeout: float) -> dict:
    """Delegates the whole comparison to Emacs (`eh-diff-shot-json` in
    eh-driver.el), which is also what `eh-expect-no-visual-drift' calls from
    inside a scenario -- one implementation of the compare, not two (§8.1)."""
    name = args["name"]
    tolerance = args.get("tolerance", 0.002)
    form = f'(eh-diff-shot-json {_elisp_str(name)} {tolerance})'
    envelope = await emacs_eval(sess, form, timeout)
    v = envelope["value"]
    ok = bool(v.get("ok"))
    return dict(ok=ok, **{k: val for k, val in v.items() if k != "ok"},
                exit_code=EXIT_OK if ok else EXIT_FAIL)


async def handle_baseline_accept(sess: Session, args: dict) -> dict:
    name = args.get("name")
    all_flag = bool(args.get("all"))
    name_lisp = _elisp_str(name) if name else "nil"
    form = f'(eh-baseline-accept-json {name_lisp} {"t" if all_flag else "nil"})'
    envelope = await emacs_eval(sess, form, timeout=30)
    v = envelope["value"]
    return dict(ok=True, accepted=v.get("accepted", []), exit_code=EXIT_OK)


async def handle_run(mgr: SessionManager, session_name: Optional[str], args: dict,
                      timeout: float) -> dict:
    """`--emacs V,...` runs the same scenarios against each named Emacs
    binary/version in turn, each in its own fresh session, and reports
    per-version results (DESIGN §14 phase 3, §13.3 open question 1)."""
    versions = args.get("emacs") or [None]
    if len(versions) == 1:
        return await _run_one_version(mgr, session_name, args, timeout, versions[0])

    results = {}
    for v in versions:
        results[v] = await _run_one_version(mgr, None, args, timeout, v)
    ok = all(r.get("ok") for r in results.values())
    return dict(ok=ok, matrix=results, exit_code=EXIT_OK if ok else EXIT_FAIL)


async def _run_one_version(mgr: SessionManager, session_name: Optional[str], args: dict,
                            timeout: float, emacs_bin: Optional[str]) -> dict:
    """A scenario run always gets a fresh session unless --reuse-session is
    passed (DESIGN §5.2): state leaking between scenarios is the single most
    common source of "passes alone, fails in the suite"."""
    profile = args.get("profile", "smoke")
    reuse = args.get("reuse_session") and session_name
    ephemeral_name = None
    try:
        if reuse and session_name in mgr.sessions and not mgr.sessions[session_name].dead:
            sess = mgr.get(session_name)
        else:
            suffix = f"-{_safe_name_component(emacs_bin)}" if emacs_bin else ""
            ephemeral_name = session_name or f"run-{profile}{suffix}-{uuid.uuid4().hex[:8]}"
            sess = await mgr.new(ephemeral_name, profile=profile,
                                  geometry=args.get("geometry", "1280x800"),
                                  theme=args.get("theme"), emacs_bin=emacs_bin)
    except EhError as e:
        # session creation itself failed (e.g. this version's Emacs binary
        # doesn't exist) -- report it as this version's result rather than
        # aborting the rest of the matrix.
        return dict(ok=False, error={"message": e.message, **e.extra}, exit_code=e.exit_code)

    try:
        return await _run_scenarios_in_session(sess, args, timeout)
    except EhError as e:
        return dict(ok=False, error={"message": e.message, **e.extra}, exit_code=e.exit_code)
    finally:
        if ephemeral_name and not args.get("keep_session"):
            try:
                await mgr.rm(ephemeral_name)
            except EhError:
                pass


def _safe_name_component(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)


async def _run_scenarios_in_session(sess: Session, args: dict, timeout: float) -> dict:
    profile_dir = PROFILES_ROOT / sess.profile
    scenarios_dir = profile_dir / "scenarios"
    wanted = args.get("scenario") or []
    all_files = sorted(scenarios_dir.glob("*.el")) if scenarios_dir.is_dir() else []
    if wanted:
        files = [f for f in all_files if f.stem in wanted or f.name in wanted]
    else:
        files = all_files
    if not files:
        return dict(ok=False, error={"message": "no scenario files matched"}, exit_code=EXIT_USAGE)

    run_id = f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{sess.profile}-{uuid.uuid4().hex[:6]}"
    run_dir = RUNS_ARTIFACT_ROOT / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    tag = args.get("tag")
    selector = f'(tag {tag})' if tag else None

    files_form = " ".join(_elisp_str(str(f)) for f in files)
    form = (f'(eh-run-scenarios-json (list {files_form}) '
            f'{_elisp_str(selector) if selector else "nil"} {_elisp_str(str(run_dir))})')
    envelope = await emacs_eval(sess, form, timeout=max(timeout, 120))
    summary = envelope["value"]

    (run_dir / "report.json").write_text(json.dumps(summary, indent=2))
    (run_dir / "junit.xml").write_text(_junit_xml(sess.profile, summary))
    lines = [f"{t['status'].upper():8s} {t['name']}" for t in summary["tests"]]
    verdict = "PASS" if summary["failed"] == 0 else "FAIL"
    lines.append(f"-- {summary['passed']}/{summary['total']} passed, "
                 f"{summary['skipped']} skipped: {verdict}")
    (run_dir / "summary.txt").write_text("\n".join(lines) + "\n")

    ok = summary["failed"] == 0
    return dict(ok=ok, run_dir=str(run_dir), summary=summary,
                exit_code=EXIT_OK if ok else EXIT_FAIL)


def _junit_xml(profile: str, summary: dict) -> str:
    import xml.sax.saxutils as sx
    cases = []
    for t in summary["tests"]:
        attrs = f'classname="{sx.quoteattr(profile)[1:-1]}" name="{sx.quoteattr(t["name"])[1:-1]}" time="{t["duration_ms"]/1000.0:.3f}"'
        if t["status"] == "failed":
            cases.append(f'<testcase {attrs}><failure message={sx.quoteattr(t.get("message", ""))}/></testcase>')
        elif t["status"] == "skipped":
            cases.append(f'<testcase {attrs}><skipped message={sx.quoteattr(t.get("message", ""))}/></testcase>')
        else:
            cases.append(f'<testcase {attrs}/>')
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<testsuite name="{profile}" tests="{summary["total"]}" '
            f'failures="{summary["failed"]}" skipped="{summary["skipped"]}">\n'
            + "\n".join(cases) + "\n</testsuite>\n")


# ---------------------------------------------------------------------
# HTTP transport (DESIGN §6.1, §14 phase 4)
#
# A shim over the same `handle()` dispatcher the Unix socket uses --
# not a second implementation. `POST /v1/<cmd>` takes the same
# {session, args, timeout} body `ehd-cli` takes on stdin, cmd moves into
# the URL path instead of the JSON body. `GET /health` is unauthenticated,
# for the tunnel/orchestrator's own liveness checks.

def _http_status_line(code: int) -> str:
    reasons = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
               405: "Method Not Allowed", 413: "Payload Too Large",
               500: "Internal Server Error"}
    return f"HTTP/1.1 {code} {reasons.get(code, 'Error')}"


async def _http_write_json(writer: asyncio.StreamWriter, code: int, obj: dict) -> None:
    body = json.dumps(obj).encode()
    header = (f"{_http_status_line(code)}\r\n"
              f"Content-Type: application/json\r\n"
              f"Content-Length: {len(body)}\r\n"
              f"Connection: close\r\n\r\n").encode()
    writer.write(header + body)
    await writer.drain()


async def _http_read_request(reader: asyncio.StreamReader):
    """Minimal HTTP/1.1 request parser: request line + headers + a
    Content-Length body. No chunked transfer-encoding, no keep-alive --
    this serves single JSON request/response round trips from `bin/eh`
    and the MCP shim (DESIGN §6.1's http transport is a machine path,
    same as ssh/docker), not a browser."""
    request_line = await reader.readline()
    if not request_line:
        return None
    try:
        method, path, _version = request_line.decode(errors="replace").strip().split(" ", 2)
    except ValueError:
        return None
    headers: dict[str, str] = {}
    while True:
        line = await reader.readline()
        if not line or line in (b"\r\n", b"\n"):
            break
        if b":" not in line:
            continue
        k, v = line.decode(errors="replace").split(":", 1)
        headers[k.strip().lower()] = v.strip()
    length = int(headers.get("content-length", "0") or "0")
    if length > HTTP_MAX_BODY:
        return method, path, headers, None
    body = await reader.readexactly(length) if length else b""
    return method, path, headers, body


def _http_check_auth(headers: dict) -> bool:
    if not HTTP_CLIENT_ID and not HTTP_CLIENT_SECRET:
        return True
    got_id = headers.get("cf-access-client-id", "")
    got_secret = headers.get("cf-access-client-secret", "")
    return (hmac.compare_digest(got_id, HTTP_CLIENT_ID)
            and hmac.compare_digest(got_secret, HTTP_CLIENT_SECRET))


async def _inline_shot_bytes(resp: dict) -> None:
    """The HTTP caller -- the MCP shim, most notably -- has no shared
    filesystem with the container, unlike the CLI's local/docker/ssh
    transports, which can `Read` `resp["path"]` themselves. Inline the
    PNG so one HTTP round trip is enough for `emacs_screenshot` to hand
    back real pixels (DESIGN §14's "no Bash calls" acceptance test)."""
    try:
        data = Path(resp["path"]).read_bytes()
    except OSError:
        return
    if len(data) <= HTTP_INLINE_SHOT_CAP:
        resp["data_base64"] = base64.b64encode(data).decode("ascii")


async def handle_http_connection(mgr: SessionManager, reader: asyncio.StreamReader,
                                  writer: asyncio.StreamWriter) -> None:
    try:
        try:
            parsed = await asyncio.wait_for(_http_read_request(reader), timeout=30)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError):
            return
        if parsed is None:
            return
        method, path, headers, body = parsed
        if body is None:
            await _http_write_json(writer, 413,
                                    {"ok": False, "error": {"message": "request body too large"},
                                     "exit_code": EXIT_USAGE})
            return

        if method == "GET" and path.split("?", 1)[0] in ("/health", "/healthz"):
            await _http_write_json(writer, 200, {"ok": True, "status": "healthy"})
            return

        route = path.split("?", 1)[0]
        if not route.startswith("/v1/"):
            await _http_write_json(writer, 404, {"ok": False, "error": {"message": "not found"},
                                                  "exit_code": EXIT_USAGE})
            return
        if method != "POST":
            await _http_write_json(writer, 405,
                                    {"ok": False, "error": {"message": "method not allowed"},
                                     "exit_code": EXIT_USAGE})
            return
        if not _http_check_auth(headers):
            await _http_write_json(writer, 401, {"ok": False, "error": {"message": "unauthorized"},
                                                  "exit_code": EXIT_USAGE})
            return

        cmd = route[len("/v1/"):].strip("/")
        try:
            payload = json.loads(body.decode()) if body else {}
        except Exception:
            await _http_write_json(writer, 400,
                                    {"ok": False, "error": {"message": "invalid JSON body"},
                                     "exit_code": EXIT_USAGE})
            return
        req = dict(cmd=cmd, session=payload.get("session"), args=payload.get("args") or {},
                   timeout=payload.get("timeout") or 30)
        try:
            resp = await handle(mgr, req)
        except EhError as e:
            resp = dict(ok=False, error={"message": e.message, **e.extra}, exit_code=e.exit_code)
        except EhEvalError as e:
            resp = dict(ok=False, error=e.envelope.get("error"), exit_code=EXIT_EMACS_ERROR)
        except Exception as e:  # noqa: BLE001
            resp = dict(ok=False, error={"message": f"internal ehd error: {e}"}, exit_code=EXIT_USAGE)

        if cmd == "shot" and resp.get("ok") and resp.get("path"):
            await _inline_shot_bytes(resp)

        await _http_write_json(writer, 200, resp)
    finally:
        writer.close()


# ---------------------------------------------------------------------
# server

async def handle_connection(mgr: SessionManager, reader: asyncio.StreamReader,
                             writer: asyncio.StreamWriter):
    try:
        line = await reader.readline()
        if not line:
            return
        req = json.loads(line.decode())
        try:
            resp = await handle(mgr, req)
        except EhError as e:
            resp = dict(ok=False, error={"message": e.message, **e.extra}, exit_code=e.exit_code)
        except EhEvalError as e:
            resp = dict(ok=False, error=e.envelope.get("error"), exit_code=EXIT_EMACS_ERROR)
        except Exception as e:  # noqa: BLE001
            resp = dict(ok=False, error={"message": f"internal ehd error: {e}"}, exit_code=EXIT_USAGE)
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
    finally:
        writer.close()


async def amain():
    SOCKET_PATH.parent.mkdir(parents=True, exist_ok=True)
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()
    mgr = SessionManager()
    unix_server = await asyncio.start_unix_server(
        lambda r, w: handle_connection(mgr, r, w), path=str(SOCKET_PATH)
    )
    os.chmod(SOCKET_PATH, 0o666)

    async with contextlib.AsyncExitStack() as stack:
        servers = [await stack.enter_async_context(unix_server)]
        if HTTP_ENABLE:
            if not (HTTP_CLIENT_ID and HTTP_CLIENT_SECRET):
                sys.stderr.write(
                    "ehd: WARNING -- EH_HTTP_ENABLE=1 with no EH_HTTP_CLIENT_ID/"
                    "EH_HTTP_CLIENT_SECRET set; the HTTP API is unauthenticated "
                    "at the origin (relying on Cloudflare Access in front of it)\n")
            http_server = await asyncio.start_server(
                lambda r, w: handle_http_connection(mgr, r, w), host=HTTP_HOST, port=HTTP_PORT)
            servers.append(await stack.enter_async_context(http_server))
            sys.stderr.write(f"ehd: HTTP API listening on {HTTP_HOST}:{HTTP_PORT}\n")
        await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    try:
        asyncio.run(amain())
    except KeyboardInterrupt:
        sys.exit(0)
