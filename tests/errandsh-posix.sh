#!/usr/bin/env bash
# errandsh's test, and it is a test rather than a claim.
#
# ⛔ IT DRIVES errandsh OVER PIPES, NOT A PTY, because a cage with no
# /dev/ptmx gives the remote side a pipe and not a terminal. That is the
# condition errandsh exists for, and a test that opened a pty would test a
# machine that is not the one this is for. It also means the stty path is
# never taken here, so the no-terminal degradation is exercised for free.
#
# It runs the SAME file under every shell the host has, because the whole
# claim is POSIX: a script that only works under bash is a bash script with
# a shebang. dash is the one that matters, and it is the one that found every
# bug this file has ever had.
#
#   ./tests/errandsh-posix.sh
#
# Exit: 0 every shell passed, 1 one failed, 2 could not run.
set -uo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
ERRSH="$ROOT/shell/errandsh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/errandsh-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ⛔ EXIT 2 AND NOT 1, because "could not run" is a different claim from
# "failed". A host with one shell still gets a real answer.
command -v python3 >/dev/null 2>&1 || { echo "errandsh-posix: no python3 to drive the pipes with" >&2; exit 2; }
[ -r "$ERRSH" ] || { echo "errandsh-posix: no $ERRSH" >&2; exit 2; }

SHELLS=""
for s in dash "busybox" bash ksh mksh posh; do
    command -v "$s" >/dev/null 2>&1 || continue
    case "$s" in
        busybox) busybox sh -c ':' 2>/dev/null && SHELLS="$SHELLS busybox:sh";;
        *)       SHELLS="$SHELLS $s";;
    esac
done
[ -n "$SHELLS" ] || { echo "errandsh-posix: no shell found" >&2; exit 2; }

echo "errandsh-posix: shells: $SHELLS"
echo "errandsh-posix: binary: $ERRSH"

DRIVER="$WORK/drive.py"
cat >"$DRIVER" <<'PYEOF'
"""Drive errandsh over pipes and report what it did.

No pty anywhere: the host has no /dev/ptmx, which is the point. Everything
is therefore a pipe, and errandsh's stty path cannot be taken, so the
no-terminal degradation is what runs.
"""
import os, select, subprocess, sys, time

SHELL, BIN, HOME = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(HOME, exist_ok=True)
env = dict(os.environ)
env.update({"ERRANDSH_SHELL": "/bin/sh",
            "ERRANDSH_HISTORY": HOME + "/hist",
            "NO_COLOR": "1", "HOME": HOME, "TMPDIR": HOME})
for k in ("ERRANDSH_NAME", "ERRANDSH_MAXHIST"):
    env.pop(k, None)

p = subprocess.Popen(SHELL.split() + [BIN], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)

def read(t=1.5):
    out = b""; end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([p.stdout], [], [], 0.1)
        if r:
            try: c = os.read(p.stdout.fileno(), 65536)
            except OSError: break
            if not c: break
            out += c; end = time.time() + 0.35
    return out.decode("latin1", "replace")

def send(b, w=1.5):
    try:
        p.stdin.write(b); p.stdin.flush()
    except BrokenPipeError:
        pass
    time.sleep(0.25)
    return read(w)

fails = []
def ck(cond, name, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (("  <- " + detail) if (detail and not cond) else ""))
    if not cond: fails.append(name)

init = read(2.0)
ck("[" in init, "prompt renders", repr(init[-40:].strip()))
ck("Illegal number" not in init and "invalid" not in init,
   "no arithmetic or range error at startup", repr(init[-80:]))

r = send(b"echo PODSSH-OK\n")
ck("PODSSH-OK" in r, "command output is relayed", repr(r[-60:].strip()))

send(b"false\n")
r = send(b"true\n")
ck("[1]" in r, "a failed command shows its exit code in the prompt", repr(r[-40:].strip()))

r = send(b"echo SUB-$(echo done)\n")
ck("SUB-done" in r, "the child shell performs substitution", repr(r[-60:].strip()))

send(b"cd /tmp\n")
r = send(b"echo PWD-IS-$(basename $(pwd))\n")
ck("PWD-IS-tmp" in r, "the cwd persists between commands", repr(r[-60:].strip()))
send(b"cd -\n")

# Up and Down walk the history, and the RECALLED TEXT is what proves it: a
# cursor movement on a short line looks identical to no movement at all, so an
# arrow that only moves the cursor cannot be told from one that did nothing.
send(b"echo HISTONE\n")
send(b"echo HISTTWO\n")
send(b"echo HISTTHREE\n")
r = send(b"\x1b[A")
ck("HISTTHREE" in r, "Up recalls the newest command", repr(r[-40:].strip()))
r = send(b"\x1b[A")
ck("HISTTWO" in r, "Up walks further back", repr(r[-40:].strip()))
r = send(b"\x1b[A")
ck("HISTONE" in r, "Up reaches the oldest", repr(r[-40:].strip()))
r = send(b"\x1b[B")
ck("HISTTWO" in r, "Down walks forward again", repr(r[-40:].strip()))

# Cursor movement is asserted on the WALK-BACK ESCAPE, not on the text: a
# cursor move does not change the line, so checking the text cannot tell a
# working Left from a dead one. redraw ends with ESC [ n D where n is how
# many characters are AFTER the cursor, so n is the position.
def cursor_back(s):
    import re
    m = re.findall(r"\x1b\[(\d+)D", s)
    return int(m[-1]) if m else 0

send(b"echo ABCDEFGHIJKLMNOPQRSTUVWXYZ\n")
send(b"echo ABCDEFGHIJKLMNOPQRSTUVWXYZ")
WIDTH = len("echo ABCDEFGHIJKLMNOPQRSTUVWXYZ")
ck(cursor_back(send(b"")) == 0, "a cursor at the end walks back 0", str(cursor_back(send(b""))))
ck(cursor_back(send(b"\x1b[D")) == 1, "Left walks back 1")
ck(cursor_back(send(b"\x1b[D")) == 2, "Left again walks back 2")
ck(cursor_back(send(b"\x1b[C")) == 1, "Right walks forward 1")
ck(cursor_back(send(b"\x1b[H")) == WIDTH, "Home walks back to the start")
ck(cursor_back(send(b"\x1b[F")) == 0, "End walks forward to the end")
send(b"\n")

# Ctrl-R finds a match and puts it on the line WITHOUT running it.
r = send(b"\x12HISTTWO")
ck("rsearch" in r, "Ctrl-R shows its own prompt", repr(r[-40:].strip()))
r = send(b"\r")
ck("HISTTWO" in r, "Ctrl-R puts the match on the line")

# An escape this file does not know is SWALLOWED, not inserted: a terminal's
# private sequence on the command line is a bug an operator cannot see.
r = send(b"\x1b[Z")
ck("Z" not in r.replace("\r", "").split()[-1:], "an unknown escape is swallowed", repr(r[-40:].strip()))

send(b"junk")
send(b"\x01")
send(b"\x15")
r = send(b"echo EDITED\n")
ck("EDITED" in r, "Ctrl-U clears the line without corrupting it", repr(r[-60:].strip()))

send(b"alpha beta")
send(b"\x17")
send(b"\n")
r = send(b"echo AFTER-W\n")
ck("AFTER-W" in r, "Ctrl-W does not corrupt the line", repr(r[-60:].strip()))

send(b"echo XY")
send(b"\x7f")
send(b"\n")
r = send(b"echo AFTER-BS\n")
ck("AFTER-BS" in r, "Backspace does not corrupt the line", repr(r[-60:].strip()))

hist = ""
if os.path.exists(env["ERRANDSH_HISTORY"]):
    hist = open(env["ERRANDSH_HISTORY"]).read()
ck("false" in hist, "history is persisted to disk", hist.strip().replace("\n", "|")[:70])
ck("PODSSH-OK" in hist, "every command reached the history", hist.strip().replace("\n", "|")[:70])
ck(hist.count("false") <= 1, "a repeated command is stored once",
   "false appears %d times" % hist.count("false"))

r = send(b"ech\t")
r = send(b"hi\n")
ck("hi" in r, "Tab completes a command name", repr(r[-60:].strip()))

r = send(b'echo "quoted"\n')
ck("quoted" in r, "quotes reach the child intact", repr(r[-60:].strip()))

send(b"\x04", 0.4)
time.sleep(1.0)
rc = p.poll()
ck(rc is not None, "Ctrl-D leaves the session", "still running")
ck(rc == 0, "a clean leave exits 0", "status %r" % (rc,))
if rc is None:
    p.kill()

print(("FAILED: " + ", ".join(fails)) if fails else "all clauses held")
sys.exit(1 if fails else 0)
PYEOF

pass=0; fail=0
for entry in $SHELLS; do
    name=${entry%%:*}
    shcmd=$entry
    case "$entry" in
        *:*) shcmd=$(echo "$entry" | cut -d: -f2-);;
    esac
    home="$WORK/$(echo "$name" | tr -c 'a-zA-Z0-9' '_')"
    rm -rf "$home"
    echo
    echo "== $name ($shcmd)"
    # shellcheck disable=SC2086
    if python3 "$DRIVER" "$shcmd" "$ERRSH" "$home" 2>&1 | sed 's/^/   /'; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
done

echo
echo "errandsh-posix: $pass shell(s) passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
