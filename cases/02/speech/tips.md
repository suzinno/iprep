> the early decisions, made before I joined, were "**some good, some bad, some who cares**".

yeah, early decisions always look different two years later. The people who made them knew less than we know now, so I'd first **find out why something was decided before calling it wrong**. What helps most is **writing down why a decision was made** (a short decision record), so the next person inherits the reason and not just the result.

---

> **InterSystems IRIS** was kept from the old system; there are **occasional issues**

Every database has its quirks — I'd rather **learn where they are than fight them**. And if something does go wrong, I'd take it to whoever owns the database, **with the query and the numbers**.

---

> The **modular monolith that turned back into a monolith** - wore the module boundaries down; the goal is **clean boundaries and loosely coupled services by the end of the year**.

That happens to any shared codebase when people come and go — it's not anyone's fault, **the rules just lived in people's heads instead of in the pipeline**. On my last project we **split the app into separate modules and pulled a couple of services out**, so I know what it looks like when it works. I'd be glad to help get the boundaries back.
**A pipeline check that fails when one module reaches into another's internals stops the boundaries wearing down** again."

**Longer:** minimal-prep-package.txt, concept 5.

---

> **today's state of the art can be tomorrow's legacy**.

Right — that's why I care less about which framework we pick and more about **clean boundaries and good tests**. Those are what let you **swap something out in five years** without rewriting everything around it.

---

> **Freedom for developers, guardrails in the pipeline**.

I like that balance. When the pipeline checks style and the common security rules, **code reviews can be concentrated on design instead of formatting**. On my last project we set up that kind of gate — **ruff, pyright and SonarQube** before anything deployed — so I'm used to working inside one."

Tip: "If the same comment keeps coming up in reviews, **that's usually a sign it should become a rule the tool checks**."

---

> the project is the company's **pilot for using AI well**, with an outside partner, **cost control and measured results**.

the rules I already follow are simple: **approved tools only, nothing confidential goes in**, and I **read and understand every line** before it reaches a merge request. And I like that you want to measure it — it's **easy to spend a lot on AI and change nothing**.

**Longer:** soft-skills-answers.md Q6; soft-skills-extra.md Q35–Q39.

**Optional but nice-to:** "Is the champion role only about development tooling, or could it grow into AI features in the product later?"

---

> The third team **mixes new and existing people**.

That makes sense, and I'd be happy in either. As a newcomer I **learn fastest from people who've been there a while**. And I'd **write down whatever wasn't obvious to me** in the first weeks, so the next person — maybe in the third team — doesn't trip over the same things.

**Longer:** soft-skills-extra.md Q18.

---

> I'm always honest and **never lie to anyone's face**.

I prefer it that way. **Tell me early** if something isn't right and I'll fix it. And it works both ways: if I'm stuck or a task is taking longer than estimated, **you'll hear it from me first**, not at the end of the sprint.

**Longer:** soft-skills-extra.md Q53, Q55.

---

> A **knowledge base for less experienced developers**, who **still delivers**.

That's something I enjoy and find as a win-win case. Mostly I do it in code review — I **explain why something is risky, not just which line to change**, so the person spots the next one themselves. For the tricky things, like a migration on a big table or permissions, I'd rather **sit down together once**. And **it goes both ways**: the internal people know the business and the old systems far better than I will for a long time.

**Longer:** soft-skills-extra.md Q19, Q20.

---

> a **team that trusts each other performs best**.

I agree — and it ties back to what you said about today's tech being tomorrow's legacy: **knowledge goes out of date, how you treat people doesn't**. For me trust comes from small things: **doing what you said you'd do, owning your mistakes, giving credit**, and **raising a disagreement with the person directly**, not in a group chat.

**Longer:** soft-skills-extra.md Q40, Q43.

---

> **Eight to ten years**, and **identifying with the project**.

That's exactly what appeals to me. **On a long project you design more carefully**. And honestly, since I naturally **care more about quality then speed**, long-term agreements look more preferable to me. What also keeps me on a project for years is **growing and a team I trust**. You've just described both.

---

> whether **visiting Austria for one or two days** is okay?

**Yes, gladly**. With a team spread over four countries, **meeting once in person makes every call afterwards easier** — you know the person behind the camera.

---

> Start as a **backend developer**; a possible **path into the leads**.

That sounds right to me. First I want to **learn the project and the people and deliver solid work**. If more responsibility grows out of that over time, I'd be glad — but **I'd rather earn it than ask for it**.

---

> **Concepts go to the leads**; **decisions by vote**.

I like that — more eyes on a design catch problems early. If I disagree, **I say it once, clearly, with my reason**. If the vote goes the other way, I **build it properly as agreed**. I'd just note my concern and what would make us look at it again, so **it's not a grudge, it's a note for later**.

**Longer:** soft-skills-answers.md Q7; soft-skills-extra.md Q57.

---

> Not the loudest — **the one who is there when it gets rough**.

Agreed. When something breaks, **the most useful person is the calm one**: get the facts, keep everyone updated in one place, fix it, and afterwards write down what happened **without blaming anyone**. On my last project we kept release and incident notes in one shared place for exactly that reason.

**Longer:** soft-skills-extra.md Q13.

---

> "I'm more from Java — **I know real programming**".

(smiling): "Fair enough — though with type hints and pyright checking everything, **Python is a lot closer to Java than it used to be**."






---

My questions

during conversation:
- "What's already running on the new system today, and what still runs on the old ones?"
- "What do the teams need most to get the boundaries back by the end of the year?"

in the end:
- "Are there already defined milestones for the third team — what will it own first?"
- "Are there manual QA and test automation engineers on the project, or is quality mainly the developers' job?"


Sounds awesome. Frankly, I'm pretty impressed — it's rare to hear a lead talk about the team first.

Thank you, I really enjoyed the interview. Have a nice day, see you later.
