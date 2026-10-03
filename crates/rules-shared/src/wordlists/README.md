# Two word lists, with different subjects

The bundled dictionaries contain slurs — `HONKY` and `WOP` are both in
`sowpods.txt`, so it predates the 2020 Collins purge. These two files are how
that is dealt with, and they exist as files rather than as edits to the
dictionaries so the change stays auditable, reviewable, and re-appliable if a
dictionary is ever re-sourced.

| | applies to | contains | effect |
| --- | --- | --- | --- |
| `denylist.txt` | everyone, human and bot | slurs and hate speech only | removed from the dictionaries — the word is not valid, and no engine can enumerate it |
| `greylist.txt` | engines only | profanities and vulgar slang | dictionaries unchanged; a person may play these, an engine never chooses one |
| `greylist-stems.txt` | the generator | stems to expand, and their exclusions | not consulted at run time; it is the input that makes `greylist.txt` reproducible |

**What a bot will never play is the union of the first two**, because
`is_avoided_by_engines` consults both. So the boundary between them decides only
what a *person* may play — which is why the greylist can be filled in while the
denylist is still empty, and why that is the safe order to do it in.

**The difference is the subject, not the severity.** A person choosing to play a
rude word is expressing themselves; a machine doing it reads as the game
insulting you. So humans keep the vocabulary they enjoy and the computer stays a
clean opponent.

**Keeping the denylist narrow is a requirement, not a compromise.** Widen it
towards "rude" generally and it starts refusing words with ordinary meanings —
`BITCH` is a female dog, `ASS` is a donkey — and a player blocked from a
legitimate high-scoring word gets angry at the game rather than reflecting on
their vocabulary. The narrow line is also the one that can be defended by
pointing at what the game's own governing bodies did in 2020, rather than at our
taste.

## Why this file is uncomfortable, and why it exists anyway

A list of slurs, in a public repository, is not a pleasant thing to commit. The
alternative is an unexplained deletion of several hundred lines from a
267,000-line word file, which is worse for review and worse for anybody later
asking what happened. Plain text, with this note beside it.

## Format

One word per line, uppercase. Blank lines and `#` comments are ignored.

**Matched exactly, never as a substring.** Filtering a word list for anything
*containing* a banned word removes `SCUNTHORPE`, `ASSASSIN` and `BASEMENT`. That
is the classic way this goes wrong, it goes wrong silently, and it is guarded by
a test.

Words are normalised — trimmed and uppercased — on both sides before comparing,
so an entry's case here does not matter.

## Filling these in

**The denylist is empty; the greylist is not.** The greylist was generated on
2026-07-30 and carries 2,666 entries. The denylist's mechanism is built and
tested and its contents are deliberately not invented, because a list assembled
from memory would be both wrong and unaccountable — #116 owns filling it.

The process is settled and written up in
[`docs/3.5-word-lists-and-dictionaries.md`](../../../../docs/3.5-word-lists-and-dictionaries.md),
"Generating the denylist and the greylist". In short, and measured rather than
assumed (rustrict 0.7.38 against sowpods, 2026-08-11):

**`greylist.txt` is generated**, from `rustrict` plus the curated stems in
`greylist-stems.txt`. rustrict's `isnt(Type::ANY)` is the "clean" predicate —
note `is_clean()` does not exist in the crate — and it flags 2,431 words. The
stems exist because its recall gaps are arbitrary: it flags `NEGROES`,
`NEGROID` and `NEGROIDS` but not `NEGRO`, `SMUTTY` but not `SMUT`, and misses
`MONG` entirely. Together they come to about 2,570 words, 0.96% of the
dictionary.

**`denylist.txt` must be curated by a person.** rustrict cannot generate it at
any threshold — it is a chat moderator built to defeat evasion, so on isolated
dictionary words it fires on stems and topics. `OFFENSIVE | SEVERE` denies
`HOLOCAUST`, `SLAVERY`, `JEW`, `ANTIRACIST`, `AUTISTIC`, `NIGGARDLY`, `QUEER`
and `SCUNTHORPE` — the last being this file's own cautionary example, arriving
through the generator rather than through the matcher. Even the much narrower
`OFFENSIVE & SEVERE` intersection denies `NIGGLE`, `NIGER`, `NIQAB`, `HOAR`,
`FAGOTTO` and six Māori words including `TAONGA`. That 185-word intersection is
the right *candidate set* to review; it is not a list.

Record the crate version in `ATTRIBUTIONS.md` when generating — a regenerated
list that silently differs is worse than no list.

On the alternatives: the **2020 Collins/NASPA removals** remain the most
defensible source for `denylist.txt`, because those bodies drew the line at
slurs rather than profanity and adopting their line beats inventing one.
**LDNOOBW** ("the big list of naughty words") is worth cross-checking against —
it catches `NEGRO`, `MONG`, `POOF` and `POON`, which rustrict misses — but it
has **no slurs sub-list**: it is one flat file per language, `en` is 403 lines,
of which 279 are single words and 165 are playable. Expect to pick from it by
hand.

Record where a list came from, in this file, when it is filled in. A word list
with no provenance is a word list nobody can argue with later.

## Say "not a word", never "that word is offensive"

A player told their word was *banned* has learned where the boundary is and can
probe it; a player told it is not in the dictionary has learned nothing and
moves on. This falls out of the design rather than needing care: denylisted
words are removed from the dictionaries, so they fail the ordinary
not-in-the-dictionary path and produce the message every other invalid word
produces. Nothing anywhere should special-case them to say more.

## Not English

German (590k words) and Spanish (635k) are out of scope for a first pass, and
saying so explicitly beats leaving them looking done. The shape differs: the
German denylist tier is dominated by historical, political and xenophobic slurs
and is legally regulated there in a way it is not in English; the Spanish tier
targets nationality, race and sexual orientation, and its greylist varies so
much by region that a single global list will be wrong at the edges whatever it
contains.

Neither can be reviewed by somebody who does not speak the language, which is
the real blocker rather than the sourcing.
