#!/usr/bin/env bash
# Verification harness for check-anchors.py.
#
# A table of contents that points nowhere looks fine until someone clicks it,
# so the checker that guards it gets more scrutiny than the documents it reads.
# Every fixture is built from scratch in a temp directory; the harness never
# reads the live contents of cases/.
#
# One fixture, one behaviour: each fixture's link can resolve only through the
# behaviour its section names, so a mutation of that behaviour flips its verdict.
#
# Three states per check, never two: PASS, FAIL, and ERROR for could-not-run.
#
# Exits 0 when every check passed, the self-test confirmed the harness can
# detect a wrong expectation, and nothing errored.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$REPO/.claude/scripts/check-anchors.py"

pass=0; fail=0; err=0

FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

# check <want-exit> <want-substring|EMPTY> <args...>
check() {
    local want_exit="$1" want_text="$2"; shift 2
    local out rc label="$*"
    label="${label//$FIX/TMP}"
    if [ ! -f "$CHECKER" ]; then
        printf 'ERROR  checker not found: %s\n' "$CHECKER"; err=$((err+1)); return 1
    fi
    out="$(python3 "$CHECKER" "$@" 2>&1)"; rc=$?
    if [ "$rc" -ne "$want_exit" ]; then
        printf 'FAIL   [%s] exit %s, wanted %s\n' "$label" "$rc" "$want_exit"; fail=$((fail+1)); return 1
    fi
    if [ "$want_text" != EMPTY ] && ! printf '%s' "$out" | grep -qF -- "$want_text"; then
        printf 'FAIL   [%s] exit %s ok, but output lacks: %s\n' "$label" "$rc" "$want_text"; fail=$((fail+1)); return 1
    fi
    printf 'PASS   [%s] exit %s\n' "$label" "$rc"; pass=$((pass+1)); return 0
}

echo "--- malformed invocations are CANNOT-RUN, not findings ---"
check 2 "usage"
check 2 "no such file" "$FIX/absent.md"

echo "--- a document whose links all resolve is OK ---"
printf '# Title\n\n- [Setup](#setup)\n\n## Setup\n\nText.\n' > "$FIX/ok.md"
check 0 EMPTY "$FIX/ok.md"

echo "--- a link to a heading that does not exist is a finding ---"
printf '# Title\n\n- [Setup](#set-up)\n\n## Setup\n' > "$FIX/broken.md"
check 1 "no heading for #set-up" "$FIX/broken.md"

echo "--- Cyrillic letters are kept in the anchor ---"
printf '# T\n\n- [Витрины](#r1-витрины-данных)\n\n## R1. Витрины данных\n' > "$FIX/cyrillic.md"
check 0 EMPTY "$FIX/cyrillic.md"

echo "--- punctuation is dropped without collapsing the hyphens it leaves ---"
printf '# T\n\n- [A](#r1-databases--витрины)\n\n## R1. Databases — витрины\n' > "$FIX/dash.md"
check 0 EMPTY "$FIX/dash.md"

echo "--- underscores are kept, unlike other punctuation ---"
# shellcheck disable=SC2016  # literal backticks: the heading holds inline code, not a command substitution
printf '# T\n\n- [S](#schema-tms_db)\n\n## Schema `tms_db`\n' > "$FIX/underscore.md"
check 0 EMPTY "$FIX/underscore.md"

echo "--- a link in a heading contributes only its text ---"
printf '# T\n\n- [S](#see-guide)\n\n## See [guide](https://example.com/a)\n' > "$FIX/heading-link.md"
check 0 EMPTY "$FIX/heading-link.md"

echo "--- a repeated heading gets a numbered suffix ---"
printf '# T\n\n- [Second](#notes-1)\n\n## Notes\n\n## Notes\n' > "$FIX/dup.md"
check 0 EMPTY "$FIX/dup.md"

echo "--- a '#' line inside a fence is not a heading ---"
cat > "$FIX/fence.md" <<'DOC'
# T

- [Comment](#only-in-a-fence)

```python
# only in a fence
```
DOC
check 1 "no heading for #only-in-a-fence" "$FIX/fence.md"

echo "--- a link written inside a fence is not checked ---"
cat > "$FIX/fenced-link.md" <<'DOC'
# T

```markdown
- [Example](#nowhere)
```
DOC
check 0 EMPTY "$FIX/fenced-link.md"

echo "--- self-test: the harness must be able to report a failure ---"
before=$fail
check 99 EMPTY "$FIX/ok.md" >/dev/null 2>&1
if [ "$fail" -eq $((before + 1)) ]; then
    fail=$before
    printf 'PASS   harness detects a wrong expectation\n'; pass=$((pass+1))
else
    printf 'ERROR  harness did NOT detect a planted wrong expectation\n'; err=$((err+1))
fi

printf '\npass=%s fail=%s error=%s\n' "$pass" "$fail" "$err"
[ "$fail" -eq 0 ] && [ "$err" -eq 0 ] || exit 1
echo "OK"
