---
description: Add one spoken interview answer for a topic to the quick-check practice file.
argument-hint: <topic> [--dry]
---

## Task

`$ARGUMENTS` is the topic to answer, for example `delivery guarantee` or `optimistic locking`. Write one answer for it and add it to `docs/common-kb/quick-check.md`. `--dry` prints the entry and writes nothing.

Every entry in that file is rehearsed out loud before an interview, and that single fact decides everything below: short, plain, and sayable under pressure. An entry that reads well but does not speak well has failed, however correct it is.

The file is committed, so a mistaken edit is recoverable from git. Even so, never rewrite an entry you were not asked to touch. If the file is missing, say so and ask before creating it.

## First, look

Read `.claude/b2-lang-rules.md`, all of it, and `docs/common-kb/quick-check.md`. If the topic already has an entry, print it, stop, and offer to rewrite or extend it — never add a second entry for the same topic. Match the topic case-insensitively and ignore spacing and punctuation, so `n+1` and `N + 1 problem` are the same topic.

## The entry

```
<details>
<summary><topic, lower case, worded as an interviewer would say it></summary>

**<the direct answer, one or two sentences>**

<how it works>

<how it works, a second paragraph only when the topic genuinely needs one>

<the trade-off, or the rule you choose by>

</details>
```

- **Answer first.** The bold line answers the question on its own, before any mechanism. If it only announces the subject ("There are three levels of X"), it is not an answer yet — say what they are, or what the thing is for.
- **Then the mechanism**, in one or two paragraphs: how it works, with the one detail an interviewer is listening for. Concrete beats complete.
- **Then one closing line**, carrying the trade-off or how you choose between the options. It may open with `My rule:`. It is never a list, and it never gets a label like `How I choose:` or `Worth knowing:`.
- **No bullets anywhere inside an entry.** A draft that wants sub-bullets is several entries, not one.
- **Spoken words.** Write what you would say at a whiteboard, not what you would publish. Where a term of art is expected, put the plain words first and the term after them in brackets: "safe to run twice (idempotent)", "wait a bit longer each time, with some randomness (backoff and jitter)". Read the draft aloud in your head; anything that sounds like documentation gets replaced.
- **Length: about 110 words.** Count with a tool, never by eye. Rules 16 and 17 of the language rules decide what goes — cut repetition, then examples, then side cases. Never cut a reason, a condition or a consequence to reach the number; report the overage instead, and name what you would cut next.
- **One owner.** If another entry already carries a fact, point at it in one short sentence that names it, instead of explaining it again. `delivery guarantee` doing this for `outbox` is the example to copy.
- **Honesty.** These are general-knowledge answers. Never write experience the case docs do not support, and follow the "Security and honesty rules" in `CLAUDE.md`.

## Placement

Topics are `##` sections, listed under `## Contents` at the top. Put the entry in the section it belongs to, next to the entries it relates to — `circuit breaker implementation` follows `timeout, retry, circuit breaker` because one continues the other. If no section fits, add one, and add its line to `## Contents` in the same order as the sections themselves. A section holds nothing but `<details>` blocks.

## Verify before reporting

Run all three from the repo root. Dispatch on what they print, not on what you expect.

```
# 1. words per entry — the new one should be near 110
awk '/^<summary>/{t=$0; w=0; next} /^<\/details>/{if(t){printf "%4d  %s\n", w, t; t=""}} t&&!/^</{w+=NF}' docs/common-kb/quick-check.md

# 2. no sentence over 25 words (language rule 6)
CHECK="sed 's/<[^>]*>//g; s/\*\*//g; s/\([0-9]\)\.\([0-9]\)/\1\2/g' | tr '\n' ' ' | grep -oE '[^.!?]+[.!?]' | awk 'NF>25{print NF\": \"\$0}'"
grep -v '^#' docs/common-kb/quick-check.md | eval "$CHECK"
# prove that check can fail, or its silence means nothing:
printf 'This one sentence is deliberately written to run well over the twenty five word limit so that the checker has something it must report back here.\n' | eval "$CHECK"

# 3. structure: blocks balanced, and every section listed in Contents
grep -c '<details>' docs/common-kb/quick-check.md; grep -c '</details>' docs/common-kb/quick-check.md
diff <(sed -n 's/^## //p' docs/common-kb/quick-check.md | grep -v '^Contents$') \
     <(sed -n 's/^- \[\([^]]*\)\].*/\1/p' docs/common-kb/quick-check.md)
```

Check 2 is silent when it passes, so the planted sentence is what tells you the check ran at all. If it prints nothing, treat the whole check as could-not-run and fix it before reporting.

## Report

Two or three lines: the topic, the section it went into, its word count, and anything you flagged — an overage, a fact you could not verify, or a duplication you spotted in a neighbouring entry. Do not reprint the entry; the user reads it in the file.

A reviewer subagent is not part of this command. One card does not need one. Offer it only when the user asks for a review pass over the whole file.
