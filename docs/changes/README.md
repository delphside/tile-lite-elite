# Change Notes

Working documents for one change each: the shape agreed before the code is
written, and the reasoning behind it. They describe a *transition* — what is
wrong now, what replaces it, what migration does — which is the one thing the
numbered documents in `docs/` deliberately never do.

**These are temporary.** A change note is deleted when its change ships. What
survives is in the numbered documents: the end state goes to 1.x/2.x, the
as-built facts to 4.x, and any decision worth citing later becomes a rule in
[1.0 Rules](../1.0-rules.md) with an id. If something in a note is still worth
reading after the change has landed, it belonged in one of those and should be
moved there rather than kept here.

The reasoning is not lost when the note goes: it is in the commits and in the
issue, which is where provenance lives anyway.

## Conventions

**Named for the issue** — `NN-short-name.md`. The numbered documents carry no
issue numbers, because they outlive the tracker; a change note does not, and
the number is how you find the discussion behind it.

**Permanent documents change on the same branch.** A change note is not a
place to keep a second copy of the truth. Where a change alters a diagram or a
schema, the numbered document is edited in the same commits as the code, so
every commit is internally consistent and the note never becomes the only
current description of anything.

The exception is while a change is still a proposal: a diagram of the *agreed*
design may live in the note before any code exists to make it true, and moves
into its permanent home as the code lands.

**Say what is being decided.** A note is written to be argued with, so unlike
the numbered documents it may record what was rejected and why — that is its
subject. Once the argument is settled that material stops being useful, which
is another reason these do not survive.
