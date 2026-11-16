# Word lists the engines avoid

This folder holds the lists that keep slurs and rude words from the engines, and slurs from the
dictionaries. The bundled dictionaries contain slurs: `HONKY` and `WOP` are
both in `sowpods.txt`, which predates the 2020 Collins removals. The greylist
holds `HONKY`; `WOP` is on neither list.

[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md)
owns how the greylist is generated, how the denylist is curated and the
runbooks for changing them.

| File | Contains | A player may play it | An engine may choose it |
| --- | --- | --- | --- |
| [`denylist.txt`](denylist.txt) | slurs and hate speech only | no: removed from the dictionaries, so it is not a valid word | no: no engine can enumerate it |
| [`greylist.txt`](greylist.txt) | what `rustrict` flags as `Type::ANY` (`PROFANE`, `OFFENSIVE`, `SEXUAL`, `MEAN`, `EVASIVE` and `SPAM`), adjusted by `greylist-stems.txt` ([how it is generated](../../../../docs/4.3.5-word-lists-and-dictionaries.md#generating-the-greylist)) | yes: the dictionaries are unchanged | no |
| [`greylist-stems.txt`](greylist-stems.txt) | the stems and exclusions the generator reads, which make `greylist.txt` reproducible | yes | no, once regenerated into `greylist.txt` |

`is_avoided_by_engines` consults `denylist.txt` and `greylist.txt`.

**The difference is the subject, not the severity.** A player who plays a rude
word is expressing themselves; an engine that does it reads as the game
insulting the player. Players keep the vocabulary they enjoy and the engines
stay clean opponents.

**The owner keeps the denylist narrow.** Widen it towards *rude* and it refuses
words with ordinary meanings (`BITCH` is a female dog, `ASS` is a donkey), and
a player blocked from a legitimate high-scoring word blames the game. The
narrow line is the one the game's governing bodies drew in 2020, which can be
defended without appeal to taste.

## Format

`denylist.txt` and `greylist.txt` are read the same way:

- one word per line, upper or lower case;
- blank lines, and lines starting with `#`, are ignored;
- each entry is trimmed and uppercased;
- a lookup is exact: callers pass the uppercase words the board forms.

`greylist-stems.txt` has its own syntax, which
[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md#generating-the-greylist)
gives.

**A word is matched whole, never as a substring.** A substring match removes
`SCUNTHORPE`, `ASSASSIN` and `BASEMENT`, silently.
`matching_is_whole_word_never_substring`
(`crates/rules-shared/src/wordlists.rs`) guards it.

## Filling these in

**The denylist is empty on purpose.** Its mechanism is built and tested, but a
list assembled from memory is wrong and unaccountable, so the owner curates its
contents, with their candidates and sources, as
[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md#curating-the-denylist)
says.

What was measured, with `rustrict` 0.7.38 over `sowpods.txt` (2026-08-11, and
again 2026-10-20):

| Check | Result |
| --- | --- |
| `Type::ANY` on the lowercased word | flags 2,431 words |
| `Type::ANY` on `NEGROES`, `NEGROID` and `SMUTTY` | flagged, but not `NEGRO` or `SMUT`; `MONG` is missed entirely |
| `Type::OFFENSIVE \| Type::SEVERE` | flags 938 words, including `HOLOCAUST`, `SLAVERY`, `JEW`, `ANTIRACIST`, `AUTISTIC`, `NIGGARDLY` and `QUEER` |
| `is(Type::OFFENSIVE) && is(Type::SEVERE)`: offensive at any level, and severe in any category | 185 words, including `NIGGLE`, `NIGER`, `NIQAB`, `HOAR`, `FAGOTTO` and `TAONGA` |

Why these results confine rustrict to the greylist is in
[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md#design-notes-on-the-word-lists).

## Say "not a word", never "that word is offensive"

A player told a word is *banned* has learned where the boundary is and can
probe it; a player told it is not in the dictionary has learned nothing. A
denied word is removed from the dictionaries, so it fails the ordinary
not-in-the-dictionary path and produces the message every other invalid word
produces.

## Not English

Both lists are drawn from English words: only a reviewer who speaks a language
can review its candidates, so German and Spanish words are not reviewed. A
denied word is still removed from all four dictionaries, German and Spanish
included.

## Design notes

- **Why denied words are removed through a list file, not by hand**: the list
  stays auditable, reviewable and re-appliable after a dictionary is re-sourced
  ([4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md#removing-the-denied-words-from-a-list)),
  where a bare deletion from a word file shows no reason.
