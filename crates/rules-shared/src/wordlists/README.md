# Word lists the engines avoid

The bundled dictionaries contain slurs: `HONKY` and `WOP` are both in
`sowpods.txt`, which predates the 2020 Collins removals. The denylist and the
greylist deal with that.

The denylist is empty and the greylist is populated.
[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md) owns how the
lists are generated and the runbooks for changing them.

| File | Contains | A person may play it | An engine may choose it |
| --- | --- | --- | --- |
| `denylist.txt` | slurs and hate speech only | no: removed from the dictionaries, so it is not a valid word | no: no engine can enumerate it |
| `greylist.txt` | what `rustrict` flags as `Type::ANY` (`PROFANE`, `OFFENSIVE`, `SEXUAL`, `MEAN`, `EVASIVE` and `SPAM`), and the words `greylist-stems.txt` names, less its exclusions and the denylist ([how it is generated](../../../../docs/4.3.5-word-lists-and-dictionaries.md#generating-the-greylist)) | yes: the dictionaries are unchanged | no |

`greylist-stems.txt` is the generator's input, which makes `greylist.txt`
reproducible; no run-time code reads it. `is_avoided_by_engines` consults
`denylist.txt` and `greylist.txt`, so what a bot never plays is the union of
both.

**The difference is the subject, not the severity.** A person who plays a rude
word is expressing themselves; a machine that does it reads as the game
insulting you. Humans keep the vocabulary they enjoy and the computer stays a
clean opponent.

**Keep the denylist narrow.** Widen it towards "rude" and it refuses words with
ordinary meanings (`BITCH` is a female dog, `ASS` is a donkey), and a player
blocked from a legitimate high-scoring word blames the game. The narrow line is
the one the game's governing bodies drew in 2020, which can be defended without
appeal to taste.

## Format

- one word per line, in any case;
- blank lines and `#` comments are ignored;
- the list is read with each entry trimmed and uppercased;
- a lookup is not normalised: callers pass the uppercase words the board forms.

**A word is matched whole, never as a substring.** A substring match removes
`SCUNTHORPE`, `ASSASSIN` and `BASEMENT`, silently.
`matching_is_whole_word_never_substring`
(`crates/rules-shared/src/wordlists.rs`) guards it.

## Filling these in

**The denylist is empty on purpose.** Its mechanism is built and tested, and its
contents are not invented: a list assembled from memory is wrong and
unaccountable. The greylist's count is in the header of `greylist.txt`. The
owner curates the denylist, with its candidates and sources, as
[4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md#curating-the-denylist)
says.

What was measured, with `rustrict` 0.7.38 over `sowpods.txt` (2026-08-11, and
again 2026-10-20):

| Check | Result |
| --- | --- |
| `Type::ANY` on the lowercased word | flags 2,431 words |
| `Type::ANY` on `NEGROES`, `NEGROID` and `SMUTTY` | flagged, but not `NEGRO` or `SMUT`; `MONG` is missed entirely, so its recall gaps are arbitrary and `greylist-stems.txt` closes them |
| `OFFENSIVE \| SEVERE` | flags 938 words, including `HOLOCAUST`, `SLAVERY`, `JEW`, `ANTIRACIST`, `AUTISTIC`, `NIGGARDLY` and `QUEER` |
| rated both `OFFENSIVE` and `SEVERE` | 185 words, including `NIGGLE`, `NIGER`, `NIQAB`, `HOAR`, `FAGOTTO` and `TAONGA` |

## Say "not a word", never "that word is offensive"

A player told a word is *banned* has learned where the boundary is and can
probe it; a player told it is not in the dictionary has learned nothing. Denied
words are removed from the dictionaries, so they fail the ordinary
not-in-the-dictionary path and produce the message every other invalid word
produces. Nothing special-cases them to say more.

## Not English

German and Spanish are out of scope: neither can be reviewed by somebody who
does not speak the language. The tiers differ too:

- **German:** the denylist tier is dominated by historical, political and
  xenophobic slurs, and is legally regulated there in a way English is not.
- **Spanish:** the tier targets nationality, race and sexual orientation, and
  the greylist varies so much by region that one global list is wrong at the
  edges.

## Design notes

- **Lists are files, and the dictionaries are edited from them:** the lists stay
  auditable, reviewable and re-appliable after a dictionary is re-sourced, and
  the dictionary edit is a separate regenerated commit
  ([4.3.5](../../../../docs/4.3.5-word-lists-and-dictionaries.md#removing-the-denied-words-from-a-list)).
  An unexplained deletion of several hundred lines from a word file is worse for
  review than a plain-text list with this note beside it.
