#!/usr/bin/env bash
# Precondition gate for the interview-prep skill.
#
# Every mode takes exactly one argument: a case folder. A case holds at most one
# project and optionally one interview pack, at fixed relative paths:
#
#   <case>/project    inputs.txt, the /system-design docs, interview-questions.md
#   <case>/interview  candidate-profile.txt, *-questions.txt, *-answers.md, *-extra.md
#
# Both sides are derived from the case, never passed separately. Only the case
# folder itself has to exist -- a missing project or interview side is an ordinary
# "not started yet" state and is reported as BLOCKED with a remedy, not as a
# malformed invocation.
#
# Dependencies between modes are expressed as the artifacts a prior step leaves
# on disk, never as "skill X was invoked" -- that state does not survive a new
# session and cannot be checked.
#
# Exit codes (dispatch on these, not on the printed text):
#   0  READY       preconditions satisfied
#   1  BLOCKED     a prerequisite artifact is missing/empty/unreadable
#   2  CANNOT-RUN  the invocation itself is wrong (bad mode, bad arg count, bad path)
#
# candidate-profile.txt, the two *-questions.txt files and the project brief are
# OPTIONAL inputs to answer and extend, and never block on their own. Their
# presence or absence is always reported, because an optional input that goes
# unnoticed is how the weighting, or the switch to a generated pack, silently
# fails to happen.
#
# A question file counts as a source only if it actually holds questions. A stub
# such as a lone "1 " is non-empty and would pass a -s test, so usability here is
# content-based: at least one line carrying real text.

set -u

EXIT_READY=0
EXIT_BLOCKED=1
EXIT_CANNOT_RUN=2

problems=()
remedies=()
checked=()
notes=()

usage() {
    printf '\nusage:\n'
    printf '  preflight.sh from-cv <case>\n'
    printf '  preflight.sh answer  <case>\n'
    printf '  preflight.sh extend  <case>\n'
    printf '\nthe project side is <case>/project and the interview side <case>/interview.\n'
}

cannot_run() {
    printf 'VERDICT: CANNOT-RUN\n  %s\n' "$1"
    usage
    exit "$EXIT_CANNOT_RUN"
}

# require <path> <remedy> -- records a problem if the file is not a usable input
require() {
    local path="$1" remedy="$2"
    if [ ! -e "$path" ]; then
        problems+=("missing:    $path")
        remedies+=("$remedy")
    elif [ ! -f "$path" ]; then
        problems+=("not a file: $path")
        remedies+=("$remedy")
    elif [ ! -r "$path" ]; then
        problems+=("unreadable: $path")
        remedies+=("$remedy")
    elif [ ! -s "$path" ]; then
        problems+=("empty:      $path")
        remedies+=("$remedy")
    else
        checked+=("$path")
    fi
}

require_dir() {
    [ -n "$1" ] || cannot_run "no case folder given"
    [ -e "$1" ] || cannot_run "no such case folder: $1"
    [ -d "$1" ] || cannot_run "not a directory: $1"
    [ -r "$1" ] || cannot_run "unreadable directory: $1"
}

is_usable_file() { [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]; }

# has_questions <file> -- true when at least one line carries >=15 non-space chars,
# which distinguishes a real question set from a stub or a whitespace-only file.
has_questions() {
    is_usable_file "$1" || return 1
    awk '{ line = $0; gsub(/[[:space:]]/, "", line); if (length(line) >= 15) c++ } END { exit !(c > 0) }' "$1"
}

# report_questions <file> <label> -- optional input, never blocks.
# Sets QUESTIONS_SOURCED=1 when the file is a usable question set.
QUESTIONS_SOURCED=0
report_questions() {
    local path="$1" label="$2"
    if [ ! -e "$path" ]; then
        notes+=("$label questions: ABSENT ($path) -- generate this pack instead of answering one")
    elif has_questions "$path"; then
        notes+=("$label questions: SOURCED $path")
        QUESTIONS_SOURCED=1
    else
        notes+=("$label questions: PRESENT BUT HOLDS NO QUESTIONS ($path) -- treat as absent and generate this pack; tell the user")
    fi
}

# report_profile <interview-dir> -- optional input, never blocks
PROFILE_USABLE=0
report_profile() {
    local path="$1/candidate-profile.txt"
    if [ ! -e "$path" ]; then
        notes+=("candidate profile: ABSENT ($path) -- generate without client weighting")
    elif [ ! -f "$path" ] || [ ! -r "$path" ]; then
        notes+=("candidate profile: PRESENT BUT UNUSABLE (not a readable file): $path -- tell the user before generating")
    elif [ ! -s "$path" ]; then
        notes+=("candidate profile: PRESENT BUT EMPTY: $path -- tell the user before generating")
    else
        notes+=("candidate profile: FOUND $path -- read references/candidate-profile.md and weight the output toward it")
        PROFILE_USABLE=1
    fi
}

# report_project <project-dir> -- optional input to answer and extend, never blocks.
# Sets PROJECT_SOURCED=1 when this case has a usable CV project brief.
PROJECT_SOURCED=0
report_project() {
    local path="$1/inputs.txt"
    if [ ! -e "$path" ]; then
        notes+=("project brief: ABSENT ($path) -- this case has no CV project; generate without it")
    elif [ ! -f "$path" ] || [ ! -r "$path" ]; then
        notes+=("project brief: PRESENT BUT UNUSABLE (not a readable file): $path -- tell the user before generating")
    elif [ ! -s "$path" ]; then
        notes+=("project brief: PRESENT BUT EMPTY: $path -- tell the user before generating")
    else
        notes+=("project brief: SOURCED $path -- ground the output in this project")
        PROJECT_SOURCED=1
    fi
}

[ "$#" -ge 1 ] || cannot_run "no mode given"

mode="$1"
shift

case "$mode" in
    from-cv|answer|extend) ;;
    *) cannot_run "unknown mode: $mode" ;;
esac

[ "$#" -eq 1 ] || cannot_run "mode '$mode' takes exactly one case folder; got $#"

case_dir="${1%/}"
require_dir "$case_dir"

project="$case_dir/project"
interview="$case_dir/interview"

case "$mode" in
    from-cv)
        require "$project/inputs.txt" "write the CV brief to $project/inputs.txt"

        # Output contract of the system-design skill.
        for doc in 00-overview 01-requirements 02-high-level-design \
                   03-data-modeling 04-deep-dive 05-reliability 06-security; do
            require "$project/$doc.md" "run: /system-design $project"
        done

        report_profile "$interview"
        ;;

    answer)
        report_questions "$interview/soft-skills-questions.txt" "soft-skills"
        report_questions "$interview/tech-questions.txt"        "tech"
        report_profile "$interview"
        report_project "$project"

        # Something must drive generation. With no question set, no profile and no
        # project there is nothing to build a pack from, and inventing one would be
        # the worst possible silent success.
        if [ "$QUESTIONS_SOURCED" -eq 0 ] && [ "$PROFILE_USABLE" -eq 0 ] && [ "$PROJECT_SOURCED" -eq 0 ]; then
            problems+=("no source to generate from: no usable question file, no candidate profile, no project brief")
            remedies+=("add questions to $interview, add $interview/candidate-profile.txt, or write the CV brief to $project/inputs.txt")
        fi
        ;;

    extend)
        # Optional: when absent, extend derives topics and style from the base answers.
        report_questions "$interview/soft-skills-questions.txt" "soft-skills"
        report_questions "$interview/tech-questions.txt"        "tech"

        # extend reads the base answers to avoid re-asking what they already cover.
        require "$interview/soft-skills-answers.md" "run: /interview-prep answer $case_dir"
        require "$interview/tech-answers.md"        "run: /interview-prep answer $case_dir"

        report_profile "$interview"
        report_project "$project"

        # Conditional: only when this case actually has a project does the CV guide
        # exist to dedupe against. A case with no project is a supported shape.
        if [ "$PROJECT_SOURCED" -eq 1 ]; then
            require "$project/interview-questions.md" "run: /interview-prep from-cv $case_dir"
        fi
        ;;
esac

print_notes() {
    if [ "${#notes[@]}" -gt 0 ]; then
        printf '\nnotes:\n'
        printf '  %s\n' "${notes[@]}"
    fi
}

if [ "${#problems[@]}" -gt 0 ]; then
    printf 'VERDICT: BLOCKED\n'
    printf '\nunsatisfied preconditions:\n'
    printf '  %s\n' "${problems[@]}"
    printf '\nto unblock:\n'
    printf '  %s\n' "${remedies[@]}" | sort -u
    print_notes
    exit "$EXIT_BLOCKED"
fi

printf 'VERDICT: READY\n'
if [ "${#checked[@]}" -gt 0 ]; then
    printf '\nverified:\n'
    printf '  %s\n' "${checked[@]}"
fi
print_notes
exit "$EXIT_READY"
