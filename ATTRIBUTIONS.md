# Attributions

Third-party data bundled into this repository, and where it came from.

The project's own code is dual-licensed under [MIT](LICENSE-MIT) and
[Apache 2.0](LICENSE-APACHE). Nothing below is the project's own work.

## Word lists

Each edition compiles its word list straight into the binary from
`crates/rules-shared/src/`, and the server serves it verbatim at
`GET /dictionaries/{name}` (sign-in required). All four were normalised on
import to one uppercase word per line, at most 15 letters, restricted to
that edition's alphabet — so none of them is byte-identical to its upstream
file.

They are also stored sorted and deduped in byte order, so dictionary
construction can trust the file rather than re-establishing those properties
on every startup. Re-normalise with the `import-wordlist` tool, never a
locale-aware sort: byte order matches the code-point order the prefix
cursor's binary search assumes, whereas German collation would file `Ä`
beside `A` and silently break lookups on the two non-ASCII lists. The
invariant is enforced by
`every_word_list_is_a_fixed_point_of_the_normaliser` in
`crates/rules-shared/src/dictionary.rs` — each committed list must be exactly
what `normalise` produces from it.

**Every entry below was re-verified on 2026-08-12** by fetching the upstream
file, running it through `import-wordlist`, and comparing: all three of known
origin reproduce the committed list byte-for-byte, and `sowpods.txt` differs
from its source by one word (see its entry). The checksums are of the
upstream files as fetched that day, so a later mismatch means upstream moved
rather than that we did.

### `enable2k.txt` — 169,266 words

- **Upstream:** <https://github.com/BartMassey/wordlists> (`enable2k.txt.gz`),
  SHA-256 `2c1093669cd16439bdb0a693a0058626c9c9f82e59244c9b0bde89515d44d3ad`
- **Verified 2026-08-12:** 173,528 words in, 169,266 out, byte-identical to
  the committed file — and 173,528 is exactly the import count recorded below,
  so this is the same upstream the original import used.
- **Licence:** ENABLE2K was placed in the public domain by its creators; the
  hosting repository is MIT. See `README-enable2k.txt` upstream for the
  original distribution's own statement.
- **Notes:** ENABLE ("Enhanced North American Benchmark LExicon"), compiled
  by Alan Beale, used here in place of the North American tournament list
  (TWL/NWL), which is copyright Merriam-Webster/Hasbro and not freely
  redistributable. Imported at 173,528 words.

### `german.txt` — 590,511 words

- **Upstream:** <https://github.com/enz/german-wordlist> (the `words` file),
  SHA-256 `445c8e09e0efe63e76beadc25607f521c7e09893ac68d585a822c7c6ecbebf7b`
- **Verified 2026-08-12:** 685,789 words in, 590,511 out, byte-identical to
  the committed file. Note the input count does not match the 675,522 recorded
  below — yet the output does, exactly. Either that figure was measured
  differently at import or upstream has since added words this edition's
  alphabet cannot write. The reproduction is the fact worth trusting; the
  historical count is not.
- **Licence:** CC0 (public domain dedication)
- **Notes:** Built for word games, so proper nouns, abbreviations and
  archaic spellings are already excluded. Uppercased with ß → SS, since
  German Scrabble sets have no ß tile and such words are physically played
  as two S tiles. Loanwords using letters outside the German Scrabble
  alphabet (é, ç, å, …) were dropped. Imported at 675,522 words.

### `spanish.txt` — 635,090 words

- **Upstream:** <https://github.com/words/an-array-of-spanish-words>
  (`index.json`), SHA-256
  `c43d6d90db76f9fa38f6885227895562bde7c4c70cd6cfe23b37f369c1f7b4a1`
- **Verified 2026-08-12:** 636,598 words in, 635,090 out, byte-identical to
  the committed file.
- **Licence:** MIT
- **Notes:** The upstream README states the list is derived from the
  Letterpress word list; that further derivation has not been verified
  here. Filtered to `A–Z` plus `Ñ`. Imported at roughly 636,000 words.

### `sowpods.txt` — 267,752 words

- **Upstream:** not recorded at the time; **identified by comparison**
  2026-08-12 as the widely-mirrored SOWPODS list, matched against
  <https://raw.githubusercontent.com/jesstess/Scrabble/master/scrabble/sowpods.txt>
  (267,751 words, SHA-256
  `8fa1b8384c6121b2cd16697f68c46569570b788204ca2633a79b2b61ef71886b`)
- **Licence:** unrecorded, and see below — identifying the source does not
  supply one
- **Edition:** CSW2007, the list the name SOWPODS actually refers to. Dated
  from the data rather than a label: 124 two-letter words with `OK`, `EW` and
  `ZE` absent puts it before CSW2019, which added exactly those three;
  `EMOJI` and `TWERK` absent puts it before CSW2015; `QI` and `ZA` present
  puts it at CSW2007 or later. The word count matches CSW2007's 267,751.
- **Deviation from that source: one word.** Ours adds `FRACKS` and is
  otherwise identical after normalisation — verified by running the upstream
  file through `import-wordlist` and diffing, which reported that single
  difference. The addition was made by hand before this project began: until
  commit `25e9e09` (app 0.4.12) the file read `FRACK, FRACKS, FRACKING,
  FRACKINGS`, grouped by inflection family instead of alphabetically, which
  is what somebody does when inserting a word under the one it belongs with.
  It also carried a stray blank line. Both were fixed by that commit, which is
  why this file is *not* byte-identical to the one that arrived with the
  original `scrabble` crate (`6be7eb6`, 19 September 2025).
- **Why that word:** the upstream list carries `FRACK`, `FRACKING` and
  `FRACKINGS` but not `FRACKS`, which reads as an omission in it rather than
  a deliberate exclusion — a verb whose third-person singular is missing. The
  hand edit appears to have been a correction.
- **Notes:** SOWPODS is the informal name for the international tournament
  word list, published in its current form as Collins Scrabble Words and
  copyright HarperCollins. Matching a mirror establishes **provenance, not a
  licence**: knowing which circulating copy this descends from says nothing
  about the right to redistribute it, and `jesstess/Scrabble` is itself a
  mirror rather than an origin. Replacing it with a list of known origin
  remains an open question, and is now a better-informed one — the edition is
  known, so a replacement can be compared against it rather than guessed at.

## Greylist generation

`crates/rules-shared/src/wordlists/greylist.txt` is generated, not written. It
is the list of words no engine will choose; it does not change any dictionary,
so nothing here affects what a person may play.

- **Tool:** [`rustrict`](https://github.com/finnbear/rustrict) **0.7.38**,
  pinned exactly in `crates/rules-shared/Cargo.toml`
- **Licence:** MIT OR Apache-2.0
- **Used as:** a dependency of `wordlist-tools`, for `generate-greylist` only. It is
  not linked into the server, the desktop client or the wasm client — the
  generated list is committed as plain text and that is what ships.
- **Predicate:** `is(Type::ANY)` — anything it flags, at any severity — over
  `sowpods.txt` and `enable2k.txt` combined, plus the curated stems in
  `greylist-stems.txt`. 2,573 words, 0.96% of the 268,214 in those two lists.

The version is pinned because the output is committed: a regenerated list that
silently differed would be indistinguishable from an edited one. Record a new
version here when changing it, along with the resulting count.

The stems are the project's own judgement, drafted against measured recall gaps
in the tool (it flags `NEGROES` but not `NEGRO`). They are not derived from any
third-party list, though LDNOOBW's `en` file was consulted as a cross-check.

`denylist.txt` is empty and has no attribution to make. See
`docs/3.5-word-lists-and-dictionaries.md` for why the greylist was filled first.

## Rules and board

The premium-square layout (`house_premiums()` in
`crates/rules-shared/src/model.rs`) is the project's own design, not any
existing game's board.

Letter values and tile distributions for the `official`, `north_american`
and `german` editions are the standard published sets for those games;
`spanish` follows the traditional Castilian set including its CH/LL/RR
digraph tiles. These are functional game data rather than creative work.

Scrabble is a trademark of Hasbro in the United States and Canada and of
Mattel elsewhere. This project is not affiliated with, endorsed by, or
derived from either.
