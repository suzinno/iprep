# iprep

Interview preparation pipeline. Two skills turn a CV project brief into a system design, two per-project interview guides, and answered question packs for a client's interview.

## Layout

Everything lives under `cases/`. A **case** is one engagement: any number of CV projects, plus at most one interview pack shared across all of them.

```
cases/01/
  projects/<name>/   inputs.txt · 00-overview.md…06-security.md
                     interview-questions.md · resps-questions.md
  interview/         candidate-profile.txt · language.txt · {soft-skills,tech}-questions.txt
                     {soft-skills,tech}-answers.md · {soft-skills,tech}-extra.md
```

Case folders are two digits by convention; project folder names are free-form. Cases are independent of one another — nothing links two cases, however similar their projects.

`cases/nn/` is the template, not a case. It carries the folder structure and the empty input files; copy it to start a case.

`cases/02/interview/topics/` is a hand-curated regroup of that case's technical questions into eight topic files. It is specific to that case and is not produced by any skill; `topics/README.md` owns what it holds.

## A new case

There is no scaffolding command yet. Copy the template and rename:

```
cp -r cases/nn cases/03
mv cases/03/projects/project-name cases/03/projects/my-project
```

Then **delete the input files the client did not give you** — `cases/03/interview/` ships all three empty, and an empty file is reported as present-but-unusable on every run, where a deleted one is cleanly absent.

For output in Russian, set the case language first — see [Output in another language](#output-in-another-language).

**Per project**, repeating for each project the case holds:

1. Fill in `cases/03/projects/my-project/inputs.txt`. The template ships the four headings — `Title:`, `Description:`, `Environment:`, `Responsibilities:` — and nothing else; a copy left unfilled is rejected rather than treated as a real brief.
2. `/system-design cases/03/projects/my-project` — writes the seven design docs beside it.
3. `/interview-prep from-design cases/03/projects/my-project` — writes `interview-questions.md`, a complete question **and answer** pack for that project, whose questions may name what the design docs hold.
4. `/interview-prep from-resps cases/03/projects/my-project` — writes `resps-questions.md`, a question and answer pack for an interviewer who has seen only the CV: questions per responsibility, using only what the CV states, with answers still drawn from the design docs.

**Per case**, once the projects are done. Drop whatever the client supplied into `cases/03/interview/` first — `tech-questions.txt` and `soft-skills-questions.txt` for their question lists, `candidate-profile.txt` for their brief on the candidate they want. All three are optional: a missing question file means that pack gets generated rather than answered, and a profile weights everything when present.

5. `/interview-prep answer cases/03` — writes `soft-skills-answers.md` and `tech-answers.md`, spanning every project in the case.
6. `/interview-prep extend cases/03` — writes `soft-skills-extra.md` and `tech-extra.md`, further questions that avoid what is already covered.

## Output in another language

The interview material can be written in Russian; the `/system-design` docs are always English. The language is set per case, as a file, so every mode — including one run in a later session — writes in the same language.

1. Write `ru` to `cases/03/interview/language.txt` before the first `/interview-prep` run. It covers every mode in the case, the per-project guides included. Without the file the output is English; a file holding anything other than `en` or `ru` also falls back to English, and the gate's notes say so.
2. The brief may be in Russian too. Keep the four headings in `inputs.txt` exactly as the template ships them — `/system-design` and the gate read them — and write everything under them in the language of the CV the interviewer will hold. Keep no translated copy of the brief: every mode reads `inputs.txt` and nothing else, and the design's traceability table quotes it as written.
3. Run the pipeline as usual, and check that the gate's `language:` note ends in `write the prose in ru`.

Switching an existing case is the same file. Packs already written stay in their language, and `extend` warns when its base answers do not match the case language.

What stays in English in a Russian pack, what is copied as written, and how technical terms are spelled is owned by the Output language rule in `.claude/skills/interview-prep/references/output-conventions.md`.

## An existing case

Run whichever step you need, with one ordering rule the gate enforces: every project with a brief must have its design docs before `answer` runs, because answers are bound to the architecture rather than to the stack list. Adding a project to a case is steps 1–4 against a new folder under `projects/` — `cp -r cases/nn/projects/project-name cases/03/projects/another-project` — after which `answer` and `extend` should be re-run so the case-level packs cover it. Replacing a client question file and re-running `answer` regenerates that pack.

Each mode checks its own prerequisites against files on disk, so it works the same in a fresh session and refuses rather than inventing an answer from missing inputs.

## Where a case stands

The precondition gate can be run directly, which is the quickest way to see what is missing:

```
.claude/skills/interview-prep/scripts/preflight.sh answer cases/02
```

`from-design` and `from-resps` take a project folder; `answer` and `extend` take a case folder. It exits `0` when ready, `1` when a prerequisite is missing — printing a runnable command to fix it — and `2` when the invocation itself is wrong.

## The skills

- `.claude/skills/system-design/` — reverse-engineers an architecture from `inputs.txt`.
- `.claude/skills/interview-prep/` — `SKILL.md` owns the modes and how they chain; `references/output-conventions.md` owns how every generated document looks.
