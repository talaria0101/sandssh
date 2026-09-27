#!/bin/sh
# tests/unit.sh - the pure helpers, the ones whose correctness does not need a
# machine. A helper exercised only through a full bootstrap is a helper whose bug
# arrives disguised as a bootstrap failure.
#
# Exit 2 when the library cannot be loaded.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space fetch env toolchain; do
    [ -r "$ROOT/lib/$m.sh" ] || { echo "unit: no lib/$m.sh" >&2; exit 2; }
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT
SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin unit

t_is "$(sh_split_on ',' 'a,b,c')" 'a b c' 'split_on replaces commas'
t_is "$(sh_split_on '/@' '@scope/pkg')" ' scope pkg' 'split_on takes several separators'
t_is "$(sh_split_on ',' '')" '' 'split_on of an empty string is empty'

t_ok "$(sh_in_list b 'a,b,c'; echo $?)" 'split list membership: b' 
sh_in_list b 'a,b,c' && t_ok 0 'in_list finds a comma-separated member' || t_ok 1 'in_list finds a comma-separated member'
sh_in_list z 'a b c' && t_ok 1 'in_list rejects an absent member' || t_ok 0 'in_list rejects an absent member'
sh_in_list b 'a|b|c' && t_ok 0 'in_list finds a pipe-separated member' || t_ok 1 'in_list finds a pipe-separated member'

t_is "$(sh_trim '   padded   ')" 'padded' 'trim removes surrounding blanks'

t_is "$(sh_json_escape 'a"b')" 'a\"b' 'json_escape escapes a quote'
t_is "$(sh_json_escape 'a\b')" 'a\\b' 'json_escape escapes a backslash'

t_is "$(sh_first_line printf 'one\ntwo\n')" 'one' 'first_line takes the first line'
t_is "$(sh_first_word printf 'one two three\n')" 'one' 'first_word takes the first word'
# ⛔ NO TRAILING NEWLINE. `read` fails at EOF there and the answer was dropped.
t_is "$(sh_first_line printf 'one')" 'one' 'first_line answers without a trailing newline'
t_is "$(sh_first_word printf 'go1.27.1')" 'go1.27.1' 'first_word answers without a trailing newline'

# The arch spellings, because a wrong one is a 404 that reads as a network error.
SH_ARCH=x86_64;  t_is "$(sh_arch_go)"   amd64 'arch_go x86_64 -> amd64'
SH_ARCH=aarch64; t_is "$(sh_arch_node)" arm64 'arch_node aarch64 -> arm64'
SH_ARCH=x86_64; SH_KERNEL=Linux; SH_LIBC=glibc
t_is "$(sh_arch_rust)" 'x86_64-unknown-linux-gnu' 'arch_rust x86_64 glibc'
SH_LIBC=musl
t_is "$(sh_arch_rust)" 'x86_64-unknown-linux-musl' 'arch_rust x86_64 musl'

sh_detect_all
t_ok "$([ -n "$SH_KERNEL" ] && [ -n "$SH_ARCH" ] && [ -n "$SH_LIBC" ]; echo $?)" 'detect_all fills the basics'
t_ok "$(case "$SH_PRIVILEGE" in root|sudo|none) echo 0 ;; *) echo 1 ;; esac)" 'privilege is three-valued'

# free_mb answers a number for a directory that exists and nothing for one that
# does not; a wrong answer here makes the space plan choose a full root.
free=$(sh_free_mb /tmp)
case "$free" in
    ''|*[!0-9]*) t_ok 1 "free_mb /tmp is numeric (got '$free')" ;;
    *)           t_ok 0 "free_mb /tmp is numeric" ;;
esac
t_is "$(sh_free_mb /nonexistent-sandhome-path)" '' 'free_mb of a missing path is empty'

# is_exec_file: a shared object must NOT be copied onto the exec root. This is
# the measurement the whole split rests on, so it is asserted directly.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-unit.XXXXXX")
: > "$tmp/data.txt"
printf '#!/bin/sh\nexit 0\n' > "$tmp/run.sh"; chmod 0755 "$tmp/run.sh"
: > "$tmp/libfoo.so"; chmod 0755 "$tmp/libfoo.so"
sh_is_exec_file "$tmp/run.sh" && t_ok 0 'is_exec_file accepts an executable' || t_ok 1 'is_exec_file accepts an executable'
sh_is_exec_file "$tmp/data.txt" && t_ok 1 'is_exec_file rejects a data file' || t_ok 0 'is_exec_file rejects a data file'
sh_is_exec_file "$tmp/libfoo.so" && t_ok 1 'is_exec_file rejects a shared object' || t_ok 0 'is_exec_file rejects a shared object'

# sh_sq_quote: every path written into env.sh passes through this. A home with
# an apostrophe or a space in it must survive being written and read back.
t_is "$(sh_sq_quote /a/b)" "'/a/b'" 'sq_quote wraps a plain path'
t_is "$(sh_sq_quote "/a b/c")" "'/a b/c'" 'sq_quote keeps a space inside the quotes'
t_is "$(sh_sq_quote "/a'b/c")" "'/a'\\''b/c'" 'sq_quote escapes an apostrophe'
q=$(sh_sq_quote "/a'b c")
t_is "$(sh -c "printf '%s' $q")" "/a'b c" 'the quoted form reads back byte for byte'

# sh_lex_normalize: the mirrored-symlink rule rests on it, so a wrong answer here
# is a symlink pointing at the wrong file in every exec view.
t_is "$(sh_lex_normalize /a/b/../c)" '/a/c' 'lex_normalize resolves a parent'
t_is "$(sh_lex_normalize /a/./b/)" '/a/b' 'lex_normalize drops dots and a trailing slash'
t_is "$(sh_lex_normalize /a/b/../../..)" '/' 'lex_normalize clamps above the root'
t_is "$(sh_lex_normalize a/b/../c)" 'a/c' 'lex_normalize keeps a relative path relative'
t_is "$(sh_lex_normalize ../x/y)" '../x/y' 'lex_normalize keeps a leading parent in a relative path'
t_is "$(sh_lex_normalize /src/lib/tool/../tool/main.js)" '/src/lib/tool/main.js' 'the npm target normalizes inside its tree'

# The env file itself: source it in a child that starts with the variables
# unset, and read the paths back out. This is the defect a home with a space
# would have caused, so it is asserted through the generated bytes.
SH_HOME="/tmp/sandhome env's home"; SH_EXEC='/tmp/sandhome exec'
out=$(sh_env_body)
t_is "$(sh -c "$out
printf '%s' \"\$SANDHOME_HOME\"")" "$SH_HOME" 'env.sh round-trips a home with a space and an apostrophe'
t_is "$(sh -c "$out
printf '%s' \"\$SANDHOME_EXEC\"")" "$SH_EXEC" 'env.sh round-trips the exec root'
mkdir -p "$SH_HOME"
printf 'SH_PROFILE_OK=yes\n' > "$SH_HOME/profile.sh"
t_is "$(sh -c "$(sh_profile_source_line)
printf '%s' \"\$SH_PROFILE_OK\"")" 'yes' 'the profile source line reads a profile from a path with an apostrophe'

# The version parsers, run against local files so they are tested offline. Both
# were wrong once in the same direction: the first line was taken where the
# format does not put the answer on the first line.
. "$ROOT/tools/go.sh"
. "$ROOT/tools/node.sh"
SH_HOME_TMP=$tmp; export SH_HOME_TMP
gov_file="$tmp/go-version.txt"
printf 'go1.27.1\ntime 2026-08-28T16:20:06Z\n' > "$gov_file"
t_is "$(SANDHOME_GO_VERSION_URL="file://$gov_file" tc_go_version_latest)" 'go1.27.1' \
    'go resolves the version from the first line'
nidx_file="$tmp/index.json"
printf '[\n{"version":"v26.10.0","date":"2026-09-21"},\n{"version":"v24.0.0","date":"2025-01-01"}\n]\n' > "$nidx_file"
t_is "$(SANDHOME_NODE_INDEX_URL="file://$nidx_file" tc_node_latest_tag)" 'v26.10.0' \
    'node resolves the newest version, which is not on the first line'
# ⛔ THE DIGEST IS LISTED IN dl/?mode=json AND NOT AT <file>.sha256, which is an
# HTML page. The source tarball's entry must not answer for the archive's.
gojson_file="$tmp/dl.json"
cat > "$gojson_file" <<'JSON'
[
 {
  "version": "go1.27.1",
  "files": [
   {
    "filename": "go1.27.1.src.tar.gz",
    "sha256": "aaa"
   },
   {
    "filename": "go1.27.1.linux-amd64.tar.gz",
    "sha256": "63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445"
   }
  ]
 }
]
JSON
t_is "$(tc_go_sha_from "$gojson_file" go1.27.1.linux-amd64.tar.gz)" \
    '63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445' \
    'go finds the archive digest, not the source digest'
t_is "$(tc_go_sha_from "$gojson_file" absent.tar.gz)" '' 'go answers nothing for a filename not listed'

rm -rf "$tmp"
t_end
