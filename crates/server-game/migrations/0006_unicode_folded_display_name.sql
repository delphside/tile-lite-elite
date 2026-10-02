-- Unicode-aware case-insensitive display names.
--
-- 0005's `NOCASE` unique index folds ASCII A-Z only, so accented / non-Latin
-- names (which this project supports) weren't matched case-insensitively. Move
-- to a stored folded column, computed in Rust — NFC-normalized + lowercased,
-- see persistence::fold_display_name — and enforce/look up uniqueness on it.
-- `display_name` still holds the exact original-case name for display.
--
-- Existing rows are backfilled with SQLite's lower(), which is ASCII-only and
-- doesn't NFC-normalize. That's only an approximation for a pre-existing name
-- containing an uppercase non-ASCII letter or a decomposed accent — but there
-- are none today (this feature is being *added*, so every current name is
-- ASCII, for which lower() and the Rust fold agree exactly). Such a row's
-- folded value is corrected the next time it's written.
--
-- PRE-DEPLOY CHECK: the new unique index fails (server won't boot) if two
-- existing rows fold to the same value. For ASCII data that's identical to
-- 0005's already-satisfied NOCASE uniqueness, so it won't trip in practice.
alter table players add column display_name_folded text;
update players set display_name_folded = lower(display_name);
drop index idx_players_display_name_nocase;
create unique index idx_players_display_name_folded on players (display_name_folded);
