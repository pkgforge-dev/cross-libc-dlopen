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
