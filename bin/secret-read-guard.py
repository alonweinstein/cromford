#!/usr/bin/env python3
# bin/secret-read-guard.py — PreToolUse tripwire: agents don't print env/secret
# files (BH-3689).
#
# On 2026-09-29 a review subagent ran a filtered grep over env/global.env and
# printed HARNESS_SECRET into its transcript. A prompt rule can't stop that; a
# hook on the tool call can stop the obvious shape of it.
#
# WIRING. rules/settings.json registers this on matcher "Read|Grep|Bash" as
# /root/harness/bin/secret-read-guard.py; update-runners.sh and fleet-propagate
# copy that file to every box. fly/builder-runner.sh and a Mac run
# bin/secret-read-guard-install.sh, which points the entry at this checkout.
#
# WHAT IS A SECRET PATH (after ~, $HOME, $HARNESS expansion, relative paths
# resolved against the payload cwd):
#   basename *.env, .git-credentials, .netrc, *.private-key.pem, github-app*.pem;
#   a path ending /.orgo/credentials;
#   anything that IS or is inside <H>/env, /etc/harness/env, ~/.aikido, ~/.orgo
#   (also compared after realpath, so the /root/harness/env symlink counts).
#   <H> is $HARNESS, else this script's ../ . Globs are judged on their text.
#
# WHAT IS DENIED
#   Read  — file_path is a secret path.
#   Grep  — path is a secret path, or glob matches *.env/.netrc/.git-credentials/*.pem.
#   Bash  — the command is split into simple commands on ; && || | & ( ) and
#           newlines. Leading VAR=val and the wrappers sudo/command/env/nohup/
#           time/nice/timeout/rtk/rtk proxy are stripped. A command whose verb
#           is in READERS with a secret-path argument is denied, and so is any
#           `<` redirect from a secret path whatever the verb. For grep-family,
#           sed and awk the first positional is the pattern/script: it counts
#           only when it exists on disk (or globs to something), so
#           `grep -rn global.env bin/` stays allowed.
#   `.` and `source` are never readers: `set -a; . env/x.env; set +a` is how
#   scripts load env, and it prints nothing.
#   HEREDOCS. A `<<WORD` / `<<-WORD` body (through its terminator line) is
#   stdin to the verb, not a command, so it is removed before lexing: writing a
#   file whose text says `cat env/x.env` prints nothing. The line carrying the
#   `<<` is still judged. A `<<WORD` with no terminator line is left as written.
#   A command shlex cannot tokenize (an unbalanced quote) is judged on a loose
#   split instead (separators, then whitespace, quotes stripped); that is a
#   normal path, not a CRASH, and logs nothing.
#
# WHAT IT DOES NOT STOP — it is a tripwire, not a sandbox:
#   python/node/perl one-liners (`python3 -c 'open(...)'`), `bash -c "<string>"`,
#   eval, backticks, copy-then-print (`cp env/x.env /tmp/y; cat /tmp/y`), a
#   verb not in READERS, a recursive grep over a PARENT of a secret dir
#   (`grep -r X /root/harness`), and any tool other than Read/Grep/Bash.
#
# HOOK CONTRACT (same as bin/iron-law-guard.sh):
#   exit 0  allow, silent.
#   exit 2  deny; stderr is the reason the model sees.
#   LOUD    empty/non-JSON payload or no tool_name: exit 0 + one logged line.
#   CRASH   an exception while judging: exit 2 only when the raw payload text
#           looks like it names a secret path, else exit 0; one logged line
#           either way (the exception class, never the payload).
#
# LOGGING. Every denial is logged with tool, verb and path only — never the
# command, the grep pattern, or file bytes (a pattern can itself be a secret).
# With <H>/bin/alert-line.sh executable and <H>/logs present (a box, Fly) it is
# spawned detached as `alert-line.sh --severity warn <text>`; the verdict never
# waits on it. Otherwise (a Mac) the line is appended to
# ~/.claude/logs/secret-read-guard.log. A logging failure never changes a verdict.
import fnmatch
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time

READERS = {
    "cat", "tac", "nl", "less", "more", "head", "tail", "grep", "egrep", "fgrep",
    "zgrep", "rg", "sed", "awk", "cut", "sort", "uniq", "strings", "xxd", "od",
    "base64", "diff",
}
# Verbs whose first positional is a pattern or script, not a file.
PATTERN_FIRST = {"grep", "egrep", "fgrep", "zgrep", "rg", "sed", "awk"}
WRAPPERS = {"sudo", "command", "env", "nohup", "time", "nice", "timeout"}
SEPARATORS = {";", ";;", "&", "&&", "|", "||", "|&", "(", ")", "\n"}
SECRET_BASENAMES = ("*.env", ".git-credentials", ".netrc", "*.private-key.pem", "github-app*.pem")
SECRET_GLOBS = ("*.env", ".netrc", ".git-credentials", "*.pem")
RAW_SECRET = re.compile(r"\.env\b|\.netrc|\.git-credentials|\.aikido|\.orgo/credentials|\.pem\b|/harness/env\b")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# `<<WORD`, `<<-WORD`, `<<'WORD'`, `<< "WORD"`; not the `<<<` here-string.
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*(['\"]?)([A-Za-z0-9_][A-Za-z0-9_.-]*)\2")

HOME = os.environ.get("HOME") or os.path.expanduser("~")
H = os.environ.get("HARNESS") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET_DIRS = [os.path.join(H, "env"), "/etc/harness/env",
               os.path.join(HOME, ".aikido"), os.path.join(HOME, ".orgo")]


def normalize(tok, cwd):
    p = tok.strip().strip("'\"")
    for var, val in (("HOME", HOME), ("HARNESS", H)):
        p = p.replace("${%s}" % var, val)
        p = re.sub(r"\$%s(?![A-Za-z0-9_])" % var, lambda _m: val, p)
    if p == "~" or p.startswith("~/"):
        p = HOME + p[1:]
    if not os.path.isabs(p):
        p = os.path.join(cwd or os.getcwd(), p)
    return os.path.normpath(p)


def _inside(p, d):
    return p == d or p.startswith(d.rstrip("/") + "/")


def is_secret(tok, cwd):
    if not tok:
        return None
    p = normalize(tok, cwd)
    base = os.path.basename(p)
    if any(fnmatch.fnmatchcase(base, pat) for pat in SECRET_BASENAMES):
        return p
    if p.endswith("/.orgo/credentials"):
        return p
    real = os.path.realpath(p)
    for d in SECRET_DIRS:
        if _inside(p, d) or _inside(real, os.path.realpath(d)):
            return p
    return None


def _exists_or_globs(tok, cwd):
    import glob
    p = normalize(tok, cwd)
    return os.path.exists(p) or bool(glob.glob(p))


def strip_heredocs(cmd):
    """Drops every heredoc body and its terminator line; keeps the `<<` line."""
    lines = cmd.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            dash, word = m.group(1), m.group(3)
            j = i
            while j < len(lines) and (lines[j].lstrip("\t") if dash else lines[j]) != word:
                j += 1
            if j == len(lines):
                break  # no terminator: not provably a heredoc, judge the rest as written
            i = j + 1
    return "\n".join(out)


def _split_loose(cmd):
    out = []
    for part in re.split(r"[;&|()\n]+", cmd):
        words = [w.strip("'\"") for w in re.sub(r"(<+|>+)", r" \1 ", part).split()]
        if words:
            out.append(words)
    return out


def split_commands(cmd):
    cmd = strip_heredocs(cmd)
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|<>()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    try:
        toks = list(lex)
    except ValueError:  # unbalanced quote: tokenizing failed, judging did not
        return _split_loose(cmd)
    cur, out = [], []
    for tok in toks:
        if tok in SEPARATORS:
            if cur:
                out.append(cur)
            cur = []
        else:
            cur.append(tok)
    if cur:
        out.append(cur)
    return out


def strip_wrappers(words):
    changed = True
    while words and changed:
        changed = False
        while words and ASSIGN.match(words[0]):
            words, changed = words[1:], True
        if not words:
            break
        verb = os.path.basename(words[0])
        if verb == "rtk":
            words = words[2:] if len(words) > 1 and words[1] == "proxy" else words[1:]
            changed = True
        elif verb in WRAPPERS:
            words = words[1:]
            while words and (words[0].startswith("-") or ASSIGN.match(words[0])):
                opt = words[0]
                words = words[1:]
                if verb == "nice" and opt == "-n" and words:
                    words = words[1:]
            if verb == "timeout" and words:
                words = words[1:]  # the duration
            changed = True
    return words


def judge_bash(cmd, cwd):
    for words in split_commands(cmd):
        # Pull redirections out first: `<` targets are reads, `>` targets are not.
        args, i = [], 0
        while i < len(words):
            w = words[i]
            if w and set(w) <= set("<>&|") and ("<" in w or ">" in w):
                tgt = words[i + 1] if i + 1 < len(words) else ""
                if w == "<":
                    hit = is_secret(tgt, cwd)
                    if hit:
                        return ("<", hit)
                i += 2
                continue
            args.append(w)
            i += 1
        args = strip_wrappers(args)
        if not args:
            continue
        verb = os.path.basename(args[0])
        if verb not in READERS:
            continue
        positional_seen = False
        skip_next = False
        for a in args[1:]:
            if skip_next:
                skip_next = False
                continue
            if a in ("-e", "--regexp"):
                skip_next = True
                continue
            if a.startswith("-"):
                if a.startswith("--") and "=" in a:
                    hit = is_secret(a.split("=", 1)[1], cwd)
                    if hit:
                        return (verb, hit)
                continue
            first = not positional_seen
            positional_seen = True
            hit = is_secret(a, cwd)
            if not hit:
                continue
            if first and verb in PATTERN_FIRST and not _exists_or_globs(a, cwd):
                continue
            return (verb, hit)
    return None


def judge(payload):
    """Returns (tool, verb, path) for a denial, or None to allow."""
    tool = payload["tool_name"]
    ti = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    if tool == "Read":
        hit = is_secret(ti.get("file_path", ""), cwd)
        return (tool, "", hit) if hit else None
    if tool == "Grep":
        hit = is_secret(ti.get("path", ""), cwd)
        if hit:
            return (tool, "", hit)
        g = ti.get("glob") or ""
        if g and any(fnmatch.fnmatchcase(os.path.basename(g), pat) for pat in SECRET_GLOBS):
            return (tool, "", "glob " + g)
        return None
    if tool == "Bash":
        r = judge_bash(ti.get("command", ""), cwd)
        return (tool, r[0], r[1]) if r else None
    return None


def log_line(text):
    """Fire-and-forget. Never raises, never waits."""
    try:
        text = "[%s] %s" % (socket.gethostname(), text)
        alert = os.path.join(H, "bin", "alert-line.sh")
        if os.access(alert, os.X_OK) and os.path.isdir(os.path.join(H, "logs")):
            subprocess.Popen([alert, "--severity", "warn", text],
                             env=dict(os.environ, HARNESS=H), start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, close_fds=True)
            return
        d = os.path.join(HOME, ".claude", "logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "secret-read-guard.log"), "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime()), text))
    except Exception:
        pass


def main():
    lane = os.environ.get("HARNESS_LANE") or "none"
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else None
    except ValueError:
        payload = None
    if not isinstance(payload, dict) or not payload.get("tool_name"):
        log_line("secret-read-guard INERT: hook payload empty, not JSON, or without tool_name; "
                 "this call was not judged (lane=%s)" % lane)
        return 0
    try:
        verdict = judge(payload)
    except Exception as e:  # CRASH: fail closed only where a leak is possible
        deny = bool(RAW_SECRET.search(raw))
        if deny:
            sys.stderr.write("secret-read-guard: could not judge this call and it mentions a "
                             "secret-looking path, so it is blocked. Env and secret files are "
                             "never read by an agent.\n")
            sys.stderr.flush()
        log_line("secret-read-guard CRASH %s on %s; %s (lane=%s)" % (
            type(e).__name__, payload.get("tool_name"), "denied" if deny else "allowed", lane))
        return 2 if deny else 0
    if not verdict:
        return 0
    tool, verb, path = verdict
    sys.stderr.write("secret-read-guard: %s on %s is blocked — env and secret files are never "
                     "read by an agent. Source it in a script (set -a; . <file>; set +a) or ask "
                     "for the one value you need.\n" % (tool, path))
    sys.stderr.flush()
    log_line("secret-read-guard denied %s %s(lane=%s)" % (
        tool, "%s %s " % (verb, path) if verb else "%s " % path, lane))
    return 2


if __name__ == "__main__":
    sys.exit(main())
