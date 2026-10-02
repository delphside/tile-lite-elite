-- A daily record of what the database holds.
--
-- Nothing recorded the shape of the data over time, so "is this unusual?" could
-- not be answered the first time it was asked. #89 argues that the *problematic*
-- threshold can be reasoned out from capacity today, while the *unusual* one has
-- to be collected — this is the collecting, and it has to run for a while before
-- that question can be answered honestly.
--
-- A table rather than a file beside the container: this one is snapshotted
-- before every deploy and restored by every rollback, which a file would not be.
--
-- `recorded_on` is a `YYYY-MM-DD` day rather than the timestamp, and unique, so
-- "once a day" is enforced by the schema instead of by whoever remembers to
-- check. The writer is the lazy sweep that runs off `list_games`, so a day with
-- no requests records nothing at all — **a gap means quiet, not broken**, and
-- anything reading this series must not confuse the two.
create table database_size_history (
    recorded_on text primary key,
    recorded_at integer not null,
    players integer not null,
    sessions integer not null,
    games integer not null,
    invitations integer not null,
    -- Rows in `game_messages`, whose table name predates the feature being
    -- called chat everywhere else.
    chat_messages integer not null,
    -- From `pragma page_count * page_size`: the file as SQLite sees it,
    -- including free pages a delete has released but not returned to the disk.
    database_bytes integer not null,
    -- Every game is held in memory as well as on disk (see #29), so this is the
    -- number that grows toward a limit rather than toward a bill.
    games_in_memory integer not null
);
