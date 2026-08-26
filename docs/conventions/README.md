# conventions

How this repository is written, rule by rule. ⛔ **These are binding.**
[`../AGENTS.md`](../AGENTS.md) routes you here; this is the authority.

| file | covers |
|---|---|
| [`prose.md`](prose.md) | how documents are written. The mechanical half is checked by CI |
| [`docs.md`](docs.md) | which documents exist, what each owns, and what keeps them true |
| [`git.md`](git.md) | ⛔ attribution, commit shape, what is never done to history |
| [`shell.md`](shell.md) | quoting, exit codes, line endings, and the traps this project has actually hit |
| [`code.md`](code.md) | the C, the generated files, and what a change to `src/` owes |
| [`forbidden-patterns.md`](forbidden-patterns.md) | a greppable table of mistakes that shipped, each with what it caused |

Adapted from [`Azathothas/TEMPLATE`](https://github.com/Azathothas/TEMPLATE)
`docs/conventions/`, with the rules this project learned the hard way folded
in. Where the template offered a convention this project already had in a
different form, the project's won.

---

## ⛔ Two deep reviews, and they are mandatory

⛔ **Before a session closes or a pull request opens, two review passes.** Not
one. ⛔ **And not two that ask the same question**, which is the failure mode
this rule exists to prevent: a second sweep for the same class of defect finds
the same nothing and reports twice the confidence.

**Each pass states, before it runs:**

1. **The question.** One sentence, and a different one from the other pass.
2. **The scope.** The paths or the commands it will actually cover.
3. **The falsifier.** What would have to be true for this pass to find nothing.

**And reports, after:**

4. **What it swept**, as paths or commands a reader can repeat.
5. **What it found**, or, if nothing, the falsifier from step 3 restated as a
   claim the reader can disagree with.

⚠ **A pass with no findings means it was too shallow.** That is not a figure of
speech and it is not a reason to invent a finding. It means the pass owes the
reader step 5 in full: what it swept, what it would have caught, and why the
absence is real rather than an artefact of where it looked.

⭐ **Two questions that are genuinely different.** Pick from different rows,
never two from one:

| the question | what it catches |
|---|---|
| does every claim added here hold when the command is actually run? | a documented behaviour nobody executed |
| can every guard added or touched here be made to refuse? | a gate that is decorative, and one that is stuck refusing everything |
| what did this change stop measuring? | a case that went green by skipping, or by asserting a condition that is now always true |
| what did I assert that I did not measure? | an inference wearing a measurement's clothes |
| what does this break that nothing in the tree covers? | the regression with no case |

⚠ There is precedent for looking harder. This repository's own passes found a
documented mitigation that was never delivered, a gate that could not fire, and
two gates that refused every build.

---

## ⭐ If a human wrote it, the conventions still apply

An agent reading this will follow it mechanically. A human contributor may not
have read it at all, and that is normal and fine.

⛔ **So when you find a script, a document, a test or a workflow in this
repository that breaks a rule here, do not silently rewrite it and do not
silently follow it.** Say what you found, name the rule, say what you would
change, and offer. The person who wrote it may have had a reason that is not
written down, and a rule applied over the top of an unstated reason is how a
working thing gets broken tidily.

[`../HUMANS.md`](../HUMANS.md) is the other side of this: what a human needs to
paste to get useful work out of a session.
