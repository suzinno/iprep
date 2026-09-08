---
description: Add a technology, technique or protocol to the essentials knowledgebase in .claude/kb.md.
argument-hint: <term> | <file>:<line> [--dry]
---

## Task

`$ARGUMENTS` names a term to write into `.claude/kb.md` — either the term itself, or a `<file>:<line>` reference to take it from. If that line holds more than one candidate term, ask which; do not guess. `--dry` prints the entry and writes nothing.

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

- **Tags** — one to three, drawn from the list in the file header, as backticked tokens on their own line directly under the heading. Add a tag to that header list only when none fits, and say that you did. Tag what the term *is*, never the neighbourhood it appears in: SCIM is `identity-provisioning`, not `authentication` — the **Boundary** field of its own entry says why. A tag is one token: hyphenate where the bare word means something else elsewhere in this file, since `provisioning` alone would collect infrastructure terms as readily as identity ones. A compound tag is already found by searching either of its parts, so do not also list the parts beside it.
- **The opening sentence** — plain language, mechanism first, understandable cold. No jargon that does not itself have an entry here. *Up to about 35 words.*
- **How it works** — the mechanism the one-liner cannot carry: what moves, in which direction, driven by whom. *Up to about 75 words.*
- **Boundary** — what it is *not*, what it is confused with, and what it pairs with. Usually the most valuable field: *SCIM cannot authenticate anyone.* State it as a contrast, not a caveat. *Up to about 50 words.*
- **Alternatives** — optional, and only where real equivalents exist: what you would reach for instead, and the one thing you would trade. This is substitution, where **Boundary** is category confusion; if a line would serve in either field, it belongs in **Boundary**. Omit rather than pad — a term with no genuine equivalent has no alternatives. One alternative sits inline after the label; two or more become a bulleted list, each opening with the alternative in bold. *At most three, up to about 30 words each.*
- **Example** — one concrete scenario or a short snippet. Not a restatement of **How it works** in other words. *Up to about 40 words.*

The budget is per field, so an entry earning its **Alternatives** is longer than one without rather than paying for them out of the mechanism. Every number above is a ceiling to stay under, never a target to fill, and none of them is a reason to trim a field into inaccuracy. No links, no source URLs.

## Placement

Insert under the fitting `## Category` heading, alphabetically by term. If none fits, add a new `## Category` in alphabetical order among the existing ones — but categories are broad, so prefer a near-fitting existing one over a new category that would hold a single term.

## Honesty

Write only what you are confident is correct. Say so where a detail is version- or vendor-specific rather than stating it flat, and leave out a mechanism you are unsure of — a short accurate entry beats a complete one carrying a wrong sentence. Write about the technology itself; do not take framing, requirements or characterisations from the case docs.

## Then

Write the file, print the entry as it landed, and name the file and category. Nothing else.
