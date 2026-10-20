# Two word lists, with different subjects

The bundled dictionaries contain slurs: `HONKY` and `WOP` are both in
`sowpods.txt`, which predates the 2020 Collins removals. These files deal with
that. They are files, not edits to the dictionaries, so the change stays
auditable, reviewable and re-appliable after a dictionary is re-sourced.

The denylist is empty and the greylist is populated.
[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md) owns how the
lists are generated and the runbooks for changing them.

| file | applies to | contains | effect |
| --- | --- | --- | --- |
| `denylist.txt` | everyone, human and bot | slurs and hate speech only | removed from the dictionaries: the word is not valid, and no engine can enumerate it |
| `greylist.txt` | engines only | profanities and vulgar slang | dictionaries unchanged; a person may play these, an engine never chooses one |
| `greylist-stems.txt` | the generator | stems to expand, and their exclusions | not consulted at run time; the input that makes `greylist.txt` reproducible |

**What a bot never plays is the union of the first two**, because
`is_avoided_by_engines` consults both. The boundary between them decides only
what a *person* may play, so the greylist can be filled while the denylist is
empty.

**The difference is the subject, not the severity.** A person who plays a rude
word is expressing themselves; a machine that does it reads as the game
insulting you. Humans keep the vocabulary they enjoy and the computer stays a
clean opponent.

**Keep the denylist narrow.** Widen it towards "rude" and it refuses words with
ordinary meanings (`BITCH` is a female dog, `ASS` is a donkey), and a player
blocked from a legitimate high-scoring word blames the game. The narrow line is
the one the game's governing bodies drew in 2020, which can be defended without
appeal to taste.

## Why the denylist is a file in a public repository

A list of slurs is unpleasant to commit. The alternative is an unexplained
deletion of several hundred lines from a word file, which is worse for review
and for anybody later asking what happened. Plain text, with this note beside
it.

## Format

- one word per line, uppercase;
- blank lines and `#` comments are ignored;
- each entry is trimmed and uppercased when the list is read, so an entry's
  case does not matter;
- a lookup is not normalised: callers pass the uppercase words the board forms.

**A word is matched whole, never as a substring.** A substring match removes
`SCUNTHORPE`, `ASSASSIN` and `BASEMENT`, silently. `matching_is_whole_word_never_substring`
(`crates/rules-shared/src/wordlists.rs`) guards it.

## Filling these in

**The denylist is empty on purpose.** Its mechanism is built and tested, and its
contents are not invented: a list assembled from memory is wrong and
unaccountable. The greylist's count is in the header of `greylist.txt`. How to
change either list is
[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md#stage-4-the-greylist-and-the-denylist).

What was measured, with `rustrict` 0.7.38 over `sowpods.txt` (2026-08-11, and
again 2026-10-20):

| check | result |
| --- | --- |
| `Type::ANY` | flags 2,431 words |
| `Type::ANY` on `NEGROES`, `NEGROID` and `SMUTTY` | flagged, but not `NEGRO` or `SMUT`; `MONG` is missed entirely, so its recall gaps are arbitrary and `greylist-stems.txt` closes them |
| `OFFENSIVE \| SEVERE` | flags 938 words, including `HOLOCAUST`, `SLAVERY`, `JEW`, `ANTIRACIST`, `AUTISTIC`, `NIGGARDLY` and `QUEER` |
| rated both `OFFENSIVE` and `SEVERE` | 185 words, including `NIGGLE`, `NIGER`, `NIQAB`, `HOAR`, `FAGOTTO` and `TAONGA` |

- **`greylist.txt` is generated**, from `rustrict` and the stems.
- **`denylist.txt` is curated by a person.** `rustrict` is a chat moderator
  built to defeat evasion, so on isolated dictionary words it fires on stems and
  topics, and at no threshold generates a denylist. The 185 are the candidate
  set to review, not a list.
- **Sources for the denylist:** the 2020 Collins and NASPA removals are the most
  defensible, because those bodies drew the line at slurs and not profanity.
  [LDNOOBW](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words)
  catches `NEGRO`, `MONG`, `POOF` and `POON`, which `rustrict` misses, but has
  no slurs sub-list: its English file is 403 lines, of which 279 are single
  words and 165 are in `sowpods.txt`. Pick from it by hand.
- **Provenance:** record where a list came from in this file when it is filled
  in, and the `rustrict` version in `ATTRIBUTIONS.md` when the greylist is
  generated.

## Say "not a word", never "that word is offensive"

A player told a word is *banned* has learned where the boundary is and can probe
it; a player told it is not in the dictionary has learned nothing. Denied words
are removed from the dictionaries, so they fail the ordinary not-in-the-dictionary
path and produce the message every other invalid word produces. Nothing
special-cases them to say more.

## Not English

German and Spanish are out of scope: neither can be reviewed by somebody who
does not speak the language, which is the blocker, not sourcing. The tiers
differ too:

- **German:** the denylist tier is dominated by historical, political and
  xenophobic slurs, and is legally regulated there in a way English is not.
- **Spanish:** the tier targets nationality, race and sexual orientation, and
  the greylist varies so much by region that one global list is wrong at the
  edges.
