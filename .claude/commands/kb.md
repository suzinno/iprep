---
description: Add a technology, technique or protocol to the essentials knowledgebase in .claude/kb.md.
argument-hint: <term> [--dry]
---

## Task

`$ARGUMENTS` is the term to write into `.claude/kb.md`. `--dry` prints the entry and writes nothing.

## First, look

Read `.claude/kb.md`. If the term is already there, print the existing entry and stop, offering to extend or rewrite it — never append a second entry for the same term. Match case-insensitively and ignore punctuation, so `back-pressure` and `backpressure` are the same term.

## The entry

```
### <Term>
`<tag>` `<tag>`

<one or two sentences saying what it is>

<details><summary>Details</summary>

**How it works:** <the mechanism>
**Boundary:** <what it is not>
**Alternatives:** <optional — what you would use instead>
**Example:** <one concrete scenario>

</details>
```

The opening sentence carries no label; its position under the tags identifies it, and the file header explains the shape once for every entry. The fields inside the block keep their labels, because some are optional and their position does not.

**Accuracy first, then the facts that make the term click, then brevity — in that order.** Length is what falls out of choosing the right facts; it is never a thing to hit. Do not count words, do not report lengths, and never lengthen or shorten a sentence to reach a number. If an entry reads long, remove a fact belonging to another field or another entry — never compress a sentence until it is vague. If it reads short, leave it short: a term that takes one sentence to explain is finished in one sentence. The entries already in `.claude/kb.md` are the reference for register; match them, and where a term genuinely needs more room than any of them, take it.

- **Tags** — one to three, drawn from the list in the file header, as backticked tokens on their own line directly under the heading. Add a tag to that header list only when none fits, and say that you did. A tag is one token, hyphenated where the bare word means something else elsewhere in this file: `provisioning` alone would collect infrastructure terms as readily as identity ones.
- **The opening sentence** — what it is and what it does, in language someone meeting the term cold would follow. Mechanism first. No jargon that does not itself have an entry here. Everything else waits for the block.
- **How it works** — the mechanism the opening sentence cannot carry: what moves, in which direction, driven by whom, plus any vocabulary a reader needs in order to follow the **Example**. One mechanism, told once; a second concept large enough to need explaining is a second entry.
- **Boundary** — what it is *not*, what it is confused with, and what it pairs with. Usually the most valuable field: *SCIM cannot authenticate anyone.* State it as a contrast, not a caveat.
- **Alternatives** — optional: what you would reach for instead of this term, and the one thing you would trade. Omit the field rather than pad it; a term with no genuine equivalent has no alternatives. One alternative sits inline after the label; two or more become a bulleted list, each opening with the alternative in bold.
- **Example** — one concrete scenario or a short snippet, using only vocabulary the entry has already introduced. Not a restatement of **How it works** in other words.

No links, no source URLs.

## Verify the draft before writing it

Draft the entry, then hand it to a subagent for review. It gets the draft, the current contents of `.claude/kb.md`, and the checks below — but no part of this conversation, because the point is a reader that did not talk itself into the draft's mistakes. Withholding the conversation is what buys independence; withholding the file would only blind it to the entries the new one has to sit beside.

Brief it to:

- answer every check with `PASS`, or with the offending line quoted and one sentence on why it fails;
- close with an overall verdict of `SOUND` or `CHANGES NEEDED`, so that finding nothing has a shape to report rather than feeling like a job undone;
- name what makes a factual finding wrong — the standard, the version, the counter-example — rather than asserting it, and say so where it is uncertain rather than stating it flat or dropping it;
- flag a claim that contradicts an entry already in the file, or a term the file already covers;
- report only: it does not rewrite the entry, or it is merely laundering its own opinion into the file.

Tell it both of these, and in the same breath. **A draft that is sound is a valid and expected result** — `PASS` throughout is a real verdict, and a reviewer that must find something will invent something. **And do not soften a genuine finding** to arrive at a clean sheet — an instruction not to fabricate is not an instruction to approve. Uncertainty is reportable as uncertainty; silence is not.

Then act on what comes back. Apply each finding, or reject it and say which and why when you report the entry.

1. **Is every alternative the same kind of thing as the term?** Protocol against protocol, product against product, pattern against pattern. Kafka replaces RabbitMQ, not AMQP. Something that fills the same slot in an architecture without being the same kind of thing is not an alternative.
2. **Is anything in Alternatives something the term is normally deployed *alongside*?** That is a complement, not a substitute, however often the two are discussed together — move it to **Boundary**.
3. **Would any Alternatives line serve equally well in Boundary?** Then it belongs in **Boundary**. Alternatives is substitution; Boundary is category confusion.
4. **Does the Example use a word the entry never introduced?** Introduce it in **How it works**, or change the example.
5. **Does Boundary answer a confusion a reader would actually arrive with**, rather than listing things the term happens not to be?
6. **Is every tag what the term is**, rather than the neighbourhood it appears in? SCIM is `identity-provisioning`, not `authentication` — its own **Boundary** says why.
7. **Is there a sentence that is not certainly true?** Cut it, or qualify it as version- or vendor-specific.

Each check exists because the mistake it names has already been made here. The review buys independence from this conversation, not from the model: it catches momentum and carelessness, and can still share a blind spot with the draft it is reading.

## Placement

Insert under the fitting `## Category` heading, alphabetically by term. If none fits, add a new `## Category` in alphabetical order among the existing ones — but categories are broad, so prefer a near-fitting existing one over a new category that would hold a single term.

## Honesty

Write only what you are confident is correct. Say so where a detail is version- or vendor-specific rather than stating it flat, and leave out a mechanism you are unsure of — a short accurate entry beats a complete one carrying a wrong sentence. Write about the technology itself; do not take framing, requirements or characterisations from the case docs.

## Then

Write the file, print the entry as it landed, and name the file and category. Add a line for any check the review raised — including one you rejected, with why — and a line for any tag added to the header list. Nothing else.
