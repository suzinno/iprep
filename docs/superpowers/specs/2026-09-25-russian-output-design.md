# Russian output for interview-prep — design

## Goal

`interview-prep` can write a case's generated prose in Russian. `system-design` output stays English: the design docs are source material, not what the candidate rehearses from.

## Decisions

- **The language is an artifact, not an argument.** `<interview>/language.txt` holds `en` or `ru` for the whole case. `extend` runs in a later session and must write in the language `answer` used; session state and invocation arguments do not survive that. The gate reports the file like every other optional input.
- **A bad value falls back to `en` and never blocks.** An empty file, an unreadable one or an unknown value prints a `PRESENT BUT …` note and the run continues in English. The note is what stops the fallback being silent.
- **Fixed text stays English.** Block labels, document titles and header notes, `**Project:**` and the index heading are strings the linker and the review checklist match. Only prose changes language, so the linker needed no change.
- **Abbreviations expand in English.** The linker recognises an inline expansion only in the glossary's English wording.
- **No Russian readability rules.** The reader is a native speaker; `b2-lang-rules.md` governs English output only.
- **`extend` follows `language.txt`** even when the base answers are in another language, and tells the user about the mismatch.

## Rejected

- A `--lang` argument: session state, lost between `answer` and `extend`.
- A line in `candidate-profile.txt`: that file is confidential client material and usually absent.
- Blocking on a bad value: the first optional input that could block; a loud fallback was judged enough.
- Translating the labels: needs a linker change and its mutation suite for no reader benefit.

## Where it lives

The rule: `output-conventions.md`, Output language. How the file is read: `preflight.sh`, `report_language`. Proof: `gate-check.sh` language section, and the Cyrillic fixtures in `link-abbreviations-check.sh`.
