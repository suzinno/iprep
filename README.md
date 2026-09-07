# iprep

Interview preparation pipeline. Two skills turn a CV project brief into a system design, a per-project interview guide, and answered question packs for a client's interview.

## Layout

Everything lives under `cases/`. A **case** is one engagement: any number of CV projects, plus at most one interview pack shared across all of them.

```
cases/01/
  projects/<name>/   inputs.txt · 00-overview.md…06-security.md · interview-questions.md
  interview/         candidate-profile.txt · {soft-skills,tech}-questions.txt
                     {soft-skills,tech}-answers.md · {soft-skills,tech}-extra.md
```

Case folders are two digits by convention; project folder names are free-form. Cases are independent of one another — nothing links two cases, however similar their projects.

`cases/nn/` is the template, not a case. It carries the folder structure and the empty input files; copy it to start a case.

## A new case

There is no scaffolding command yet. Copy the template and rename:

```
cp -r cases/nn cases/03
mv cases/03/projects/project-name cases/03/projects/my-project
```

Then **delete the input files the client did not give you** — `cases/03/interview/` ships all three empty, and an empty file is reported as present-but-unusable on every run, where a deleted one is cleanly absent.

**Per project**, repeating for each project the case holds:

1. Fill in `cases/03/projects/my-project/inputs.txt`. The template ships the four headings — `Title:`, `Description:`, `Environment:`, `Responsibilities:` — and nothing else; a copy left unfilled is rejected rather than treated as a real brief.
2. `/system-design cases/03/projects/my-project` — writes the seven design docs beside it.
3. `/interview-prep from-cv cases/03/projects/my-project` — writes `interview-questions.md`, a complete question **and answer** pack for that project.

**Per case**, once the projects are done. Drop whatever the client supplied into `cases/03/interview/` first — `tech-questions.txt` and `soft-skills-questions.txt` for their question lists, `candidate-profile.txt` for their brief on the candidate they want. All three are optional: a missing question file means that pack gets generated rather than answered, and a profile weights everything when present.

4. `/interview-prep answer cases/03` — writes `soft-skills-answers.md` and `tech-answers.md`, spanning every project in the case.
5. `/interview-prep extend cases/03` — writes `soft-skills-extra.md` and `tech-extra.md`, further questions that avoid what is already covered.

## An existing case

Run whichever step you need; nothing has to be redone in order. Adding a project to a case is steps 1–3 against a new folder under `projects/` — `cp -r cases/nn/projects/project-name cases/03/projects/another-project` — after which `answer` and `extend` should be re-run so the case-level packs cover it. Replacing a client question file and re-running `answer` regenerates that pack.

Each mode checks its own prerequisites against files on disk, so it works the same in a fresh session and refuses rather than inventing an answer from missing inputs.

## Where a case stands

The precondition gate can be run directly, which is the quickest way to see what is missing:

```
.claude/skills/interview-prep/scripts/preflight.sh answer cases/02
```

`from-cv` takes a project folder; `answer` and `extend` take a case folder. It exits `0` when ready, `1` when a prerequisite is missing — printing a runnable command to fix it — and `2` when the invocation itself is wrong.

## The skills

- `.claude/skills/system-design/` — reverse-engineers an architecture from `inputs.txt`.
- `.claude/skills/interview-prep/` — `SKILL.md` owns the modes and how they chain; `references/output-conventions.md` owns how every generated document looks.
