#!/usr/bin/env bash
# Verification harness for preflight.sh.
#
# The gate is the only thing between a confident wrong answer and a correct one,
# so it gets more scrutiny than the content it guards. This proves the invariants
# in CLAUDE.md that are provable: the three-state exit contract, content-based
# rejection of stub inputs, that every optional input is reported, that answer
# needs a source, that from-cv is per project while answer and extend are per
# case, and that a BLOCKED verdict names a runnable remedy.
#
# Every fixture is built from scratch in a temp directory. The harness must never
# depend on the live contents of cases/ -- those change as real work is done, and
# a check whose expectation goes stale reports a failure the gate did not cause.
# cases/nn is the one exception: it is a committed contract, and an unfilled copy
# of it must never be mistaken for a real CV brief.
#
# Three states per check, never two: PASS, FAIL, and ERROR for could-not-run.
# Collapsing could-not-run into either of the others is how a broken harness
# reports whatever you already expected.
#
# Exits 0 when every check passed, the self-test confirmed the harness can detect
# a wrong expectation, and nothing errored.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PF="$REPO/.claude/skills/interview-prep/scripts/preflight.sh"
TEMPLATE="$REPO/cases/nn"

pass=0; fail=0; err=0

FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

# check <want-exit> <want-substring|EMPTY> <args...>
check() {
    local want_exit="$1" want_text="$2"; shift 2
    local out rc label="$*"
    label="${label//$FIX/TMP}"
    if [ ! -x "$PF" ]; then
        printf 'ERROR  gate not executable: %s\n' "$PF"; err=$((err+1)); return 1
    fi
    out="$("$PF" "$@" 2>&1)"; rc=$?
    if [ "$rc" -ne "$want_exit" ]; then
        printf 'FAIL   [%s] exit %s, wanted %s\n' "$label" "$rc" "$want_exit"; fail=$((fail+1)); return 1
    fi
    if [ "$want_text" != EMPTY ] && ! printf '%s' "$out" | grep -qF -- "$want_text"; then
        printf 'FAIL   [%s] exit %s ok, but output lacks: %s\n' "$label" "$rc" "$want_text"; fail=$((fail+1)); return 1
    fi
    printf 'PASS   [%s] exit %s\n' "$label" "$rc"; pass=$((pass+1)); return 0
}

# --- fixture builders -------------------------------------------------------

DOCS="00-overview 01-requirements 02-high-level-design 03-data-modeling 04-deep-dive 05-reliability 06-security"

write_brief() {
    cat > "$1/inputs.txt" <<'BRIEF'
Title: Fleet Telemetry Ingest

Description:
Collects telemetry from field units and stores it for later analysis.

Environment:
Python, FastAPI, RabbitMQ, PostgreSQL

Responsibilities:
    • Built the MQTT ingestion path and the decoding pipeline;
BRIEF
}

write_design_docs() { local d; for d in $DOCS; do printf '# %s\n\nbody\n' "$d" > "$1/$d.md"; done; }
write_guide()   { printf '# Interview Questions\n\n### Q1. A question with enough text to be real.\n' > "$1/interview-questions.md"; }
write_answers() { printf '# Answers\n\n### Q1. A question.\n' > "$1/soft-skills-answers.md"
                  printf '# Answers\n\n### Q1. A question.\n' > "$1/tech-answers.md"; }
write_questions() { printf '1 A question long enough to count as a real question set.\n' > "$1/tech-questions.txt"; }

new_project() { mkdir -p "$1"; }

# --- fixtures ---------------------------------------------------------------

if [ ! -d "$TEMPLATE" ]; then
    printf 'ERROR  template missing: %s\n' "$TEMPLATE"; err=$((err+1))
fi

# complete: one fully-worked project, interview pack answered
new_project "$FIX/complete/projects/alpha"; mkdir -p "$FIX/complete/interview"
write_brief "$FIX/complete/projects/alpha"
write_design_docs "$FIX/complete/projects/alpha"
write_guide "$FIX/complete/projects/alpha"
write_questions "$FIX/complete/interview"
write_answers "$FIX/complete/interview"
printf 'The client wants deep RabbitMQ experience and careful migrations.\n' > "$FIX/complete/interview/candidate-profile.txt"

# nodocs: brief written, /system-design not yet run
new_project "$FIX/nodocs/projects/alpha"; write_brief "$FIX/nodocs/projects/alpha"

# noguide: designed but from-cv not yet run, answers present
new_project "$FIX/noguide/projects/alpha"; mkdir -p "$FIX/noguide/interview"
write_brief "$FIX/noguide/projects/alpha"; write_design_docs "$FIX/noguide/projects/alpha"
write_answers "$FIX/noguide/interview"

# multi: alpha complete, beta has a brief but no guide
new_project "$FIX/multi/projects/alpha"; new_project "$FIX/multi/projects/beta"; mkdir -p "$FIX/multi/interview"
write_brief "$FIX/multi/projects/alpha"; write_design_docs "$FIX/multi/projects/alpha"; write_guide "$FIX/multi/projects/alpha"
write_brief "$FIX/multi/projects/beta"
write_answers "$FIX/multi/interview"

# noprojects: an interview pack and no CV project at all
mkdir -p "$FIX/noprojects/interview"; write_questions "$FIX/noprojects/interview"

# nobrief: a project folder holding nothing
new_project "$FIX/nobrief/projects/ghost"

# bare: a case with nothing in it
mkdir -p "$FIX/bare"

# stub: a question file that is non-empty but holds no question
mkdir -p "$FIX/stub/interview"; printf '1 \n' > "$FIX/stub/interview/tech-questions.txt"

# fresh / filled: copies of the committed template, one untouched, one filled in
if [ -d "$TEMPLATE" ]; then
    cp -r "$TEMPLATE" "$FIX/fresh"
    cp -r "$TEMPLATE" "$FIX/filled"; write_brief "$FIX/filled/projects/project-name"
fi

# --- checks -----------------------------------------------------------------

echo "--- exit-code contract: READY / BLOCKED ---"
check 0 EMPTY                                          from-cv "$FIX/complete/projects/alpha"
check 0 EMPTY                                          answer  "$FIX/complete"
check 0 EMPTY                                          extend  "$FIX/complete"
check 1 "run: /system-design $FIX/nodocs/projects/alpha" from-cv "$FIX/nodocs/projects/alpha"
check 1 "run: /interview-prep answer $FIX/nodocs"      extend  "$FIX/nodocs"
check 1 "run: /interview-prep from-cv $FIX/noguide/projects/alpha" extend "$FIX/noguide"

echo "--- CANNOT-RUN is never folded into BLOCKED ---"
check 2 "unknown mode: frobnicate"                     frobnicate "$FIX/complete"
check 2 "no mode given"
check 2 "takes exactly one folder; got 2"              answer  "$FIX/complete" "$FIX/bare"
check 2 "no such folder"                               answer  "$FIX/does-not-exist"
check 2 "not a directory"                              answer  "$FIX/complete/projects/alpha/inputs.txt"
check 2 "not a project folder"                         from-cv "$FIX/complete"
check 2 "that is a project folder, not a case"         answer  "$FIX/complete/projects/alpha"

echo "--- every optional input is reported ---"
check 0 "candidate profile: FOUND"                     answer "$FIX/complete"
check 0 "tech questions: SOURCED"                      answer "$FIX/complete"
check 0 "soft-skills questions: ABSENT"                answer "$FIX/complete"
check 0 "project alpha: SOURCED"                       answer "$FIX/complete"
check 0 "projects: NONE"                               answer "$FIX/noprojects"
check 1 "project ghost: NO BRIEF"                      answer "$FIX/nobrief"

echo "--- answer needs at least one source ---"
check 1 "no source to generate from"                   answer "$FIX/bare"

echo "--- stub inputs are rejected on content, not on -s ---"
check 1 "PRESENT BUT HOLDS NO QUESTIONS"               answer "$FIX/stub"
if [ -d "$TEMPLATE" ]; then
    check 1 "PRESENT BUT NOT FILLED IN"                answer  "$FIX/fresh"
    check 1 "not filled"                               from-cv "$FIX/fresh/projects/project-name"
    check 0 "project project-name: SOURCED"            answer  "$FIX/filled"
fi

echo "--- extend requires a guide for every project that has a brief ---"
check 1 "run: /interview-prep from-cv $FIX/multi/projects/beta" extend "$FIX/multi"
write_guide "$FIX/multi/projects/beta"
check 0 EMPTY                                          extend "$FIX/multi"

echo "--- self-test: the harness must be able to report a failure ---"
before=$fail
check 99 EMPTY answer "$FIX/complete" >/dev/null 2>&1
if [ "$fail" -eq $((before + 1)) ]; then
    fail=$before
    printf 'PASS   harness detects a wrong expectation\n'; pass=$((pass+1))
else
    printf 'ERROR  harness did NOT detect a planted wrong expectation\n'; err=$((err+1))
fi

printf '\npass=%s fail=%s error=%s\n' "$pass" "$fail" "$err"
[ "$fail" -eq 0 ] && [ "$err" -eq 0 ] || exit 1
echo "OK"
