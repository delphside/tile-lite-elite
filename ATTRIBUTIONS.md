# Attributions

Third-party data bundled into this repository, and where it came from.

The project's own code is dual-licensed under [MIT](LICENSE-MIT) and
[Apache 2.0](LICENSE-APACHE). The third-party entries in this file are not the
project's own work; the stems, apart from the section taken from a third-party
list, and the board layouts it notes are.

## Word lists

Each edition's word list is compiled into every native binary from
`crates/rules-shared/src/`, and the server serves it verbatim at
`GET /dictionaries/{name}` (sign-in required). All four were normalised on
import to one uppercase word per line, at most 15 letters, restricted to
that edition's alphabet — so none of them is byte-identical to its upstream
file. They are stored sorted and deduped in byte order. The rules and the test
that holds each list to them are in
[4.3.5](docs/4.3.5-word-lists-and-dictionaries.md#stage-3-normalising-a-list).

**Every entry in this section was re-verified on 2026-08-12** by fetching the
upstream file, running it through `import-wordlist`, and comparing: the three
of known origin reproduce the committed list byte-for-byte, and `sowpods.txt`
differs from its source by one word (see *Deviation from that source*). The
checksums are of the upstream files as fetched that day, so a later mismatch
means upstream moved.

### `enable2k.txt` — 169,266 words

- **Upstream:** <https://github.com/BartMassey/wordlists> (`enable2k.txt.gz`),
  SHA-256 `2c1093669cd16439bdb0a693a0058626c9c9f82e59244c9b0bde89515d44d3ad`
- **Verified 2026-08-12:** 173,528 words in, 169,266 out, byte-identical to
  the committed file.
- **Licence:** ENABLE2K was placed in the public domain by its creators; the
  hosting repository is MIT. See `README-enable2k.txt` upstream for the
  original distribution's own statement.
- **Notes:** ENABLE ("Enhanced North American Benchmark LExicon"), compiled
  by Alan Beale, used here in place of the North American tournament list
  (TWL/NWL), which is copyright Merriam-Webster/Hasbro and not freely
  redistributable.

### `german.txt` — 590,511 words

- **Upstream:** <https://github.com/enz/german-wordlist> (the `words` file),
  SHA-256 `445c8e09e0efe63e76beadc25607f521c7e09893ac68d585a822c7c6ecbebf7b`
- **Verified 2026-08-12:** 685,789 words in, 590,511 out, byte-identical to
  the committed file.
- **Licence:** CC0 (public domain dedication)
- **Notes:** Built for word games, so proper nouns, abbreviations and
  archaic spellings are already excluded. Uppercased with ß → SS, since
  German Scrabble sets have no ß tile and such words are physically played
  as two S tiles. Loanwords using letters outside the German Scrabble
  alphabet (é, ç, å, …) were dropped.

### `spanish.txt` — 635,090 words

- **Upstream:** <https://github.com/words/an-array-of-spanish-words>
  (`index.json`), SHA-256
  `c43d6d90db76f9fa38f6885227895562bde7c4c70cd6cfe23b37f369c1f7b4a1`
- **Verified 2026-08-12:** 636,598 words in, 635,090 out, byte-identical to
  the committed file.
- **Licence:** MIT
- **Notes:** The upstream README states the list is derived from the
  Letterpress word list; that further derivation has not been verified.
  Filtered to `A–Z` without `K` and `W`, plus `Ñ`.

### `sowpods.txt` — 267,752 words

- **Upstream:** not recorded at the time; **identified by comparison**
  2026-08-12 as a mirror of SOWPODS, the informal name for the international
  tournament word list, matched against
  <https://raw.githubusercontent.com/jesstess/Scrabble/master/scrabble/sowpods.txt>
  (267,751 words, SHA-256
  `8fa1b8384c6121b2cd16697f68c46569570b788204ca2633a79b2b61ef71886b`)
- **Verified 2026-08-12:** 267,751 words in, 267,752 out, identical after
  normalisation except for one added word (see *Deviation from that source*).
- **Licence:** unrecorded. Identifying the source does not supply one.
- **Edition:** Collins Scrabble Words 2007 (CSW2007), the list the name
  SOWPODS refers to. Dated from the data, not a label:
  - 124 two-letter words, with `OK`, `EW` and `ZE` absent: before CSW2019,
    which added those three;
  - `EMOJI` and `TWERK` absent: before CSW2015;
  - `QI` and `ZA` present: CSW2007 or later;
  - 267,751 words, the count of CSW2007.
- **Deviation from that source: one word.** The committed file adds `FRACKS`
  and is otherwise identical after normalisation, verified by running the
  upstream file through `import-wordlist` and diffing. The addition was made by
  hand before this project began, in the original `scrabble` crate (`6be7eb6`,
  2025-09-19).
- **Why that word:** the upstream list carries `FRACK`, `FRACKING` and
  `FRACKINGS` but not `FRACKS`, a verb whose third-person singular is missing.
- **Notes:** The list is published in its current form as Collins Scrabble
  Words, copyright HarperCollins. Matching a mirror establishes **provenance,
  not a licence**, and `jesstess/Scrabble` is itself a mirror rather than an
  origin. Replacing the list with one of known origin remains an open
  question; the edition is known, so a replacement can be compared against it.

## Greylist generation

`crates/rules-shared/src/wordlists/greylist.txt` is generated, not written. It
is the list of words no engine will choose. Every dictionary stays as
*Word lists* gives it, so a person may play any word in it.

- **Tool:** [`rustrict`](https://github.com/finnbear/rustrict) **0.7.38**,
  pinned exactly in `crates/wordlist-tools/Cargo.toml`
- **Licence:** MIT OR Apache-2.0
- **Used as:** a dependency of `wordlist-tools`, for `generate-greylist` only.
  It is absent from the server, the desktop client and the wasm client: the
  generated list is committed as plain text and that is what ships.
- **Predicate:** `is(Type::ANY)` — anything it flags, at any severity — over
  `sowpods.txt` and `enable2k.txt` combined, plus the curated stems in
  `greylist-stems.txt`. 2,666 words, 0.99% of the 268,214 in those two lists.

The version is pinned because the output is committed: a regenerated list that
silently differed would be indistinguishable from an edited one. Changing the
version follows
[4.3.5](docs/4.3.5-word-lists-and-dictionaries.md#changing-the-rustrict-version),
which records the new version and count here.

The stems in `greylist-stems.txt` are the project's own judgement, drafted
against measured recall gaps in the tool (it flags `NEGROES` but not `NEGRO`),
except one section. That section, "Sexual and vulgar base words rustrict
misses", is taken from the `en` list of LDNOOBW (List of Dirty, Naughty,
Obscene, and Otherwise Bad Words), restricted to entries playable on a board.

`denylist.txt` is empty and has no attribution to make. See
[`wordlists/README.md`](crates/rules-shared/src/wordlists/README.md#filling-these-in)
for why the greylist was filled first.

### LDNOOBW `en` list

- **Upstream:** <https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words>
  (the `en` file)
- **Licensor:** © 2012–2020 Shutterstock, Inc., per the upstream README.
- **Licence:** [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), per
  the `LICENSE` file in that repository, read 2026-11-11. The attribution is
  this entry.
- **Modified:** yes. A selection of its entries, those playable on a board, is
  written as stems into `greylist-stems.txt`, which the generator expands to
  dictionary words.

## Rules and board

The premium-square layouts (`house_premiums()` and, for the `spicy` edition,
`spicy_premiums()` in `crates/rules-shared/src/model.rs`) are the project's own
design, not any existing game's board.

Letter values and tile distributions for the `official` (which `spicy` also
uses), `north_american` and `german` editions are the standard published sets
for those games;
`spanish` follows the traditional Castilian set including its CH/LL/RR
digraph tiles. The retired `wordfeud` edition, which `model.rs` keeps so that
games created under it still resolve, takes the same kind of data. These are
functional game data rather than creative work.

Scrabble is a trademark of Hasbro in the United States and Canada and of
Mattel elsewhere. This project is not affiliated with, endorsed by or
derived from either.
