#!/usr/bin/env bash
# Precondition gate for the interview-prep skill.
#
# Every mode takes exactly one argument, but not all of them take the same kind
# of thing. A case holds any number of CV projects and at most one interview pack:
#
#   <case>/projects/<name>  inputs.txt, the /system-design docs, interview-questions.md
#   <case>/interview        candidate-profile.txt, *-questions.txt, *-answers.md, *-extra.md
#
#   from-cv <project>   per project: reads one project, writes that project's guide
#   answer  <case>      case level: one pack spanning every project in the case
#   extend  <case>      case level
#
# from-cv is per project because a case-level verdict would have to block on the
# least-ready project, or invent a fourth "partly ready" state. The candidate
# profile is case level, so the project modes derive the case from the project
# path and report the profile path they resolved.
#
# Only the folder passed has to exist. A case with no projects, or with no
# interview pack yet, is an ordinary "not started yet" state and is reported as
# BLOCKED with a remedy, not as a malformed invocation.
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
# candidate-profile.txt, the two *-questions.txt files and the project briefs are
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
    printf '  preflight.sh from-cv <case>/projects/<name>\n'
    printf '  preflight.sh answer  <case>\n'
    printf '  preflight.sh extend  <case>\n'
    printf '\nfrom-cv takes one project; answer and extend take the whole case.\n'
}

cannot_run() {
    printf 'VERDICT: CANNOT-RUN\n  %s\n' "$1"
    usage
    exit "$EXIT_CANNOT_RUN"
}

# require <path> <remedy> [<predicate>] -- records a problem if the file is not a
# usable input. The optional predicate is a function name run on a file that is
# otherwise fine; use it where "non-empty" is not the same as "filled in".
require() {
    local path="$1" remedy="$2" predicate="${3:-}"
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
    elif [ -n "$predicate" ] && ! "$predicate" "$path"; then
        problems+=("not filled:  $path")
        remedies+=("$remedy")
    else
        checked+=("$path")
    fi
}

require_dir() {
    [ -n "$1" ] || cannot_run "no folder given"
    [ -e "$1" ] || cannot_run "no such folder: $1"
    [ -d "$1" ] || cannot_run "not a directory: $1"
    [ -r "$1" ] || cannot_run "unreadable directory: $1"
}

# The two argument kinds are told apart by the parent directory, so passing a case
# where a project belongs (or the reverse) is caught as CANNOT-RUN rather than
# silently reported as a pile of missing files.
require_project_dir() {
    require_dir "$1"
    [ "$(basename "$(dirname "$1")")" = "projects" ] || cannot_run "not a project folder: $1 (expected <case>/projects/<name>)"
}

require_case_dir() {
    require_dir "$1"
    [ "$(basename "$(dirname "$1")")" != "projects" ] || cannot_run "that is a project folder, not a case: $1"
}

# case_of <project> -- the interview pack lives one level up from projects/
case_of() { dirname "$(dirname "$1")"; }

require_design_docs() {
    local project="$1" doc
    for doc in 00-overview 01-requirements 02-high-level-design \
               03-data-modeling 04-deep-dive 05-reliability 06-security; do
        require "$project/$doc.md" "run: /system-design $project"
    done
}

is_usable_file() { [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]; }

# has_questions <file> -- true when at least one line carries >=15 non-space chars,
# which distinguishes a real question set from a stub or a whitespace-only file.
has_questions() {
    is_usable_file "$1" || return 1
    awk '{ line = $0; gsub(/[[:space:]]/, "", line); if (length(line) >= 15) c++ } END { exit !(c > 0) }' "$1"
}

# has_brief_content <file> -- true when a CV brief carries text beyond the bare
# heading labels /system-design defines. cases/nn ships those labels and nothing
# else, so a -s test reports an unfilled copy of the template as a usable source.
# The labels are stripped before measuring: "Responsibilities:" is 17 characters
# and would otherwise clear the threshold on its own.
has_brief_content() {
    is_usable_file "$1" || return 1
    awk '{
        line = $0
        sub(/^[[:space:]]*(Title|Description|Environment|Responsibilities):/, "", line)
        gsub(/[[:space:]]/, "", line)
        if (length(line) >= 15) c++
    } END { exit !(c > 0) }' "$1"
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

# report_projects <case> -- the CV projects in a case are OPTIONAL inputs to answer
# and extend, and never block on their own. Every project is reported by name.
# Sets PROJECT_SOURCED=1 when at least one has a usable brief, and collects those
# in SOURCED_PROJECTS so extend can require each one's guide.
PROJECT_SOURCED=0
SOURCED_PROJECTS=()
report_projects() {
    local case_dir="$1" found=0 dir name brief
    for dir in "$case_dir"/projects/*/; do
        [ -d "$dir" ] || continue          # unmatched glob stays literal; skip it
        found=1
        dir="${dir%/}"
        name="${dir##*/}"
        brief="$dir/inputs.txt"
        if [ ! -e "$brief" ]; then
            notes+=("project $name: NO BRIEF ($brief) -- not usable as a source")
        elif [ ! -f "$brief" ] || [ ! -r "$brief" ]; then
            notes+=("project $name: PRESENT BUT UNUSABLE (not a readable file): $brief -- tell the user before generating")
        elif [ ! -s "$brief" ]; then
            notes+=("project $name: PRESENT BUT EMPTY: $brief -- tell the user before generating")
        elif ! has_brief_content "$brief"; then
            notes+=("project $name: PRESENT BUT NOT FILLED IN ($brief) -- still the cases/nn headings; not a source, tell the user")
        else
            notes+=("project $name: SOURCED $brief")
            PROJECT_SOURCED=1
            SOURCED_PROJECTS+=("$dir")
        fi
    done
    [ "$found" -eq 1 ] || notes+=("projects: NONE ($case_dir/projects) -- this case has no CV project; generate without project grounding")
}

[ "$#" -ge 1 ] || cannot_run "no mode given"

mode="$1"
shift

case "$mode" in
    from-cv|answer|extend) ;;
    *) cannot_run "unknown mode: $mode" ;;
esac

[ "$#" -eq 1 ] || cannot_run "mode '$mode' takes exactly one folder; got $#"

target="${1%/}"

case "$mode" in
    from-cv)
        require_project_dir "$target"
        project="$target"
        interview="$(case_of "$project")/interview"

        require "$project/inputs.txt" "write the CV brief to $project/inputs.txt" has_brief_content
        require_design_docs "$project"
        report_profile "$interview"
        ;;

    answer)
        require_case_dir "$target"
        case_dir="$target"
        interview="$case_dir/interview"

        report_questions "$interview/soft-skills-questions.txt" "soft-skills"
        report_questions "$interview/tech-questions.txt"        "tech"
        report_profile "$interview"
        report_projects "$case_dir"

        # A brief lists the stack and the responsibilities; the design docs carry the
        # architecture, data models and failure modes an answer has to be specific
        # about. Grounding a pack in the brief alone yields answers that recite the
        # Environment line, so a project in play must be fully specified.
        if [ "${#SOURCED_PROJECTS[@]}" -gt 0 ]; then
            for project in "${SOURCED_PROJECTS[@]}"; do
                require_design_docs "$project"
            done
        fi

        # Something must drive generation. With no question set, no profile and no
        # project there is nothing to build a pack from, and inventing one would be
        # the worst possible silent success.
        if [ "$QUESTIONS_SOURCED" -eq 0 ] && [ "$PROFILE_USABLE" -eq 0 ] && [ "$PROJECT_SOURCED" -eq 0 ]; then
            problems+=("no source to generate from: no usable question file, no candidate profile, no project brief")
            remedies+=("add questions to $interview, add $interview/candidate-profile.txt, or add a project under $case_dir/projects")
        fi
        ;;

    extend)
        require_case_dir "$target"
        case_dir="$target"
        interview="$case_dir/interview"

        # Optional: when absent, extend derives topics and style from the base answers.
        report_questions "$interview/soft-skills-questions.txt" "soft-skills"
        report_questions "$interview/tech-questions.txt"        "tech"

        # extend reads the base answers to avoid re-asking what they already cover.
        require "$interview/soft-skills-answers.md" "run: /interview-prep answer $case_dir"
        require "$interview/tech-answers.md"        "run: /interview-prep answer $case_dir"

        report_profile "$interview"
        report_projects "$case_dir"

        # Each project's guide is a further body of covered ground. Only projects
        # that actually have a brief can have one, so a case with no projects is a
        # supported shape and blocks on nothing here.
        if [ "${#SOURCED_PROJECTS[@]}" -gt 0 ]; then
            for project in "${SOURCED_PROJECTS[@]}"; do
                require "$project/interview-questions.md" "run: /interview-prep from-cv $project"
            done
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
