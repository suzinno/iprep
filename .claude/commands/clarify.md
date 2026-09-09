---
description: Explain or rephrase a line in a case doc — concisely, in the terminal, writing nothing until asked.
argument-hint: <file>:<line>[-<line>] [what is unclear]
---

## Task

`$ARGUMENTS` names a place in a document: a path with a line or line range, optionally followed by what the user finds unclear. Read that line with enough surrounding context to be sure what it refers to — its heading, its paragraph, the table or list it sits in — then explain it in the terminal. Nothing is written anywhere until the user asks.

If the path does not exist, or no line is given and the text to explain is not otherwise identifiable, say so in one line and stop.

## Output

Print this and nothing else:

1. **The line** — the referenced text, quoted, trimmed to what matters. If it runs longer than about three lines, name it instead of quoting it.
2. **The explanation** — one to four sentences, or up to four short bullets. Use whichever the line actually needs: a rephrase in different words when the wording is the obstacle; plain language when the obstacle is jargon, expanding the term once and then using it; the *why* in a single clause when the line records a decision rather than a fact.
3. **The offer** — one line: `update the doc · save to clarifications · leave as is`.

No preamble, no restating the question, no closing summary. Brief is the point — more detail will be asked for explicitly, and only then do you expand.

## Grounding

Explain what the document says, not what you would have written. If the line depends on something defined elsewhere in the case, name that file rather than re-deriving its content. If the line is genuinely ambiguous, or looks wrong, say so in one sentence instead of smoothing it over — that is a finding, not a failure. Say "not stated in the docs" rather than filling the gap: never invent architecture, client detail, or candidate experience the case does not hold.

## Then wait

Do nothing until the user picks one:

- **update the doc** — edit those lines in place, minimally, and show the diff. If the edit would change a format owned by `references/output-conventions.md`, stop and say so instead.
- **save to clarifications** — append to `cases/<case>/tmp/clarifications.md`, where `<case>` is the case folder of the referenced path, creating the file if absent. One entry, appended, never rewriting what is already there:

```
## <path>:<line>
> <the original text>

<the explanation>
```

- **leave as is** — acknowledge in one line and stop.

Several references in one invocation: handle each in order, a full block per reference, then a single offer line covering all of them.
