#!/usr/bin/env bash
# Verification harness for link-abbreviations.py.
#
# The linker rewrites prose that is hours of work and not identically
# reproducible, so it gets more scrutiny than the documents it edits. Every
# fixture is built from scratch in a temp directory; the harness must never
# read the live contents of cases/.
#
# Three states per check, never two: PASS, FAIL, and ERROR for could-not-run.
#
# Exits 0 when every check passed, the self-test confirmed the harness can
# detect a wrong expectation, and nothing errored.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINKER="$REPO/.claude/scripts/link-abbreviations.py"

pass=0; fail=0; err=0

FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

# check <want-exit> <want-substring|EMPTY> <args...>
check() {
    local want_exit="$1" want_text="$2"; shift 2
    local out rc label="$*"
    label="${label//$FIX/TMP}"
    if [ ! -f "$LINKER" ]; then
        printf 'ERROR  linker not found: %s\n' "$LINKER"; err=$((err+1)); return 1
    fi
    out="$(python3 "$LINKER" "$@" 2>&1)"; rc=$?
    if [ "$rc" -ne "$want_exit" ]; then
        printf 'FAIL   [%s] exit %s, wanted %s\n' "$label" "$rc" "$want_exit"; fail=$((fail+1)); return 1
    fi
    if [ "$want_text" != EMPTY ] && ! printf '%s' "$out" | grep -qF -- "$want_text"; then
        printf 'FAIL   [%s] exit %s ok, but output lacks: %s\n' "$label" "$rc" "$want_text"; fail=$((fail+1)); return 1
    fi
    printf 'PASS   [%s] exit %s\n' "$label" "$rc"; pass=$((pass+1)); return 0
}

# want_file <file> <HAS|LACKS> <substring>
want_file() {
    local file="$1" mode="$2" text="$3" label
    label="$(basename "$file") $mode: $text"
    if [ ! -f "$file" ]; then
        printf 'ERROR  [%s] no such file\n' "$label"; err=$((err+1)); return 1
    fi
    if grep -qF -- "$text" "$file"; then
        if [ "$mode" = HAS ]; then
            printf 'PASS   [%s]\n' "$label"; pass=$((pass+1)); return 0
        fi
        printf 'FAIL   [%s] present but must be absent\n' "$label"; fail=$((fail+1)); return 1
    fi
    if [ "$mode" = LACKS ]; then
        printf 'PASS   [%s]\n' "$label"; pass=$((pass+1)); return 0
    fi
    printf 'FAIL   [%s] absent but must be present\n' "$label"; fail=$((fail+1)); return 1
}

write_glossary() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'GLOSS'
# Glossary

## Linked terms

| Term | Expansion | Purpose | Source |
|---|---|---|---|
| SCIM | System for Cross-domain Identity Management | An open REST standard for provisioning users and groups between an identity provider and an application. | https://scim.cloud/ |
| ORM | Object-Relational Mapping | Maps relational rows onto objects so queries are written in the host language. | https://en.wikipedia.org/wiki/Object-relational_mapping |
| SHA | Secure Hash Algorithm | A family of cryptographic hash functions used for integrity checks and signatures. | https://csrc.nist.gov/projects/hash-functions |
| SHA-256 | Secure Hash Algorithm 256-bit | The 256-bit member of the SHA-2 family, the default choice for content hashing and HMAC. | https://csrc.nist.gov/projects/hash-functions |

## Deliberately not linked

| Term | Reason |
|---|---|
| CPU | Universally known; a link would be clutter. |
| PATIENT | A Mermaid node identifier, not prose. |
GLOSS
}

echo "--- malformed invocations are CANNOT-RUN, not findings ---"
write_glossary "$FIX/glossary.md"
printf '# Doc\n\nNothing to see.\n' > "$FIX/plain.md"
check 2 "usage" --glossary "$FIX/glossary.md"
check 2 "No such file" --glossary "$FIX/missing.md" "$FIX/plain.md"
check 2 "no such file" --glossary "$FIX/glossary.md" "$FIX/absent.md"

echo "--- a malformed glossary is CANNOT-RUN ---"
printf '# Glossary\n\n## Linked terms\n\n| Term | Expansion |\n|---|---|\n| X | Y |\n' > "$FIX/bad-cols.md"
check 2 "expected 4 columns" --glossary "$FIX/bad-cols.md" "$FIX/plain.md"

echo "--- a document with no glossary term is OK and unchanged ---"
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/plain.md"
want_file "$FIX/plain.md" HAS "Nothing to see."

echo "--- write mode links the first eligible occurrence only ---"
cat > "$FIX/prose.md" <<'DOC'
# Heading with SCIM in it

SCIM is the provisioning standard. A second SCIM mention must stay bare.

| Feature | Note |
|---|---|
| Provisioning | SCIM in a table cell is eligible |
DOC
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/prose.md"
want_file "$FIX/prose.md" HAS '[SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — An open REST standard'
want_file "$FIX/prose.md" HAS 'A second SCIM mention must stay bare.'
want_file "$FIX/prose.md" HAS '# Heading with SCIM in it'

echo "--- fenced blocks, inline code, headings and existing links are skipped ---"
cat > "$FIX/skips.md" <<'DOC'
## SCIM heading

```mermaid
graph TD
  A[SCIM] --> B
```

The `SCIM` service identifier is code, and [SCIM](https://example.com/) is already linked.

Only this bare SHA is eligible.
DOC
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/skips.md"
want_file "$FIX/skips.md" HAS '  A[SCIM] --> B'
# shellcheck disable=SC2016  # literal backticks: this asserts inline code, not a command substitution
want_file "$FIX/skips.md" HAS 'The `SCIM` service identifier'
want_file "$FIX/skips.md" HAS '[SCIM](https://example.com/) is already linked'
want_file "$FIX/skips.md" HAS 'Only this bare [SHA](https://csrc.nist.gov/projects/hash-functions "Secure Hash Algorithm — A family'

echo "--- a term inside a longer token is not matched ---"
printf '# T\n\nThe value SHA-256 appears, and nothing else does.\n' > "$FIX/longest.md"
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/longest.md"
want_file "$FIX/longest.md" HAS '[SHA-256](https://csrc.nist.gov/projects/hash-functions "Secure Hash Algorithm 256-bit'
want_file "$FIX/longest.md" LACKS '[SHA](https://csrc.nist.gov/projects/hash-functions "Secure Hash Algorithm —'
# SHA has no standalone occurrence here, so the only way it could appear is by
# matching inside SHA-256 -- which is exactly what longest-match-first prevents.

echo "--- a glossary term inside a longer token is never matched ---"
printf '# T\n\nThe tokens SCIMv2 and preORMap and SHAsum must all stay bare.\n' > "$FIX/boundary.md"
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/boundary.md"
want_file "$FIX/boundary.md" HAS 'The tokens SCIMv2 and preORMap and SHAsum must all stay bare.'

echo "--- where the prose already expands the term, the title carries purpose only ---"
printf '# T\n\nWe use Object-Relational Mapping (ORM) throughout.\n' > "$FIX/inline.md"
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/inline.md"
want_file "$FIX/inline.md" HAS 'Object-Relational Mapping ([ORM](https://en.wikipedia.org/wiki/Object-relational_mapping "Maps relational rows onto objects so queries are written in the host language."))'
want_file "$FIX/inline.md" LACKS 'Object-Relational Mapping — Maps relational rows'

echo "--- where it does not, the title carries expansion and purpose ---"
printf '# T\n\nThe ORM layer is generated.\n' > "$FIX/bare.md"
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/bare.md"
want_file "$FIX/bare.md" HAS '[ORM](https://en.wikipedia.org/wiki/Object-relational_mapping "Object-Relational Mapping — Maps relational rows'

echo "--- slash compounds link on both sides ---"
printf '# T\n\nThe SCIM/SHA pairing appears once.\n' > "$FIX/slash.md"
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/slash.md"
want_file "$FIX/slash.md" HAS '[SCIM](https://scim.cloud/'
want_file "$FIX/slash.md" HAS '[SHA](https://csrc.nist.gov/projects/hash-functions'

echo "--- a second run is a no-op ---"
cp "$FIX/prose.md" "$FIX/prose.first.md"
check 0 EMPTY --glossary "$FIX/glossary.md" "$FIX/prose.md"
if diff -q "$FIX/prose.first.md" "$FIX/prose.md" >/dev/null; then
    printf 'PASS   [idempotent: second run changed nothing]\n'; pass=$((pass+1))
else
    printf 'FAIL   [idempotent: second run modified the file]\n'; fail=$((fail+1))
    diff "$FIX/prose.first.md" "$FIX/prose.md" | head -5
fi

echo "--- self-test: the harness must be able to report a failure ---"
before=$fail
check 99 EMPTY --glossary "$FIX/glossary.md" "$FIX/plain.md" >/dev/null 2>&1
if [ "$fail" -eq $((before + 1)) ]; then
    fail=$before
    printf 'PASS   harness detects a wrong expectation\n'; pass=$((pass+1))
else
    printf 'ERROR  harness did NOT detect a planted wrong expectation\n'; err=$((err+1))
fi

printf '\npass=%s fail=%s error=%s\n' "$pass" "$fail" "$err"
[ "$fail" -eq 0 ] && [ "$err" -eq 0 ] || exit 1
echo "OK"
