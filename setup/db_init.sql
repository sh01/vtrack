CREATE TABLE shows(id INTEGER, ts_add INTEGER, title TEXT, PRIMARY KEY (id ASC) ON CONFLICT ROLLBACK);
CREATE TABLE show_sets(id INTEGER, desc BLOB, PRIMARY KEY (id ASC) ON CONFLICT ROLLBACK);
CREATE TABLE show_set_in(id INTEGER, show_id INTEGER, PRIMARY KEY (id, show_id) ON CONFLICT ROLLBACK);
CREATE TABLE episodes(id INTEGER PRIMARY KEY ASC ON CONFLICT ROLLBACK AUTOINCREMENT, show_id INTEGER, idx INTEGER, ts_add INTEGER, length INTEGER, watch_state INTEGER, ts_sm INTEGER, wfrac DOUBLE, wfrac_ts_min INTEGER, UNIQUE (show_id, idx) ON CONFLICT ROLLBACK);
CREATE TABLE show_aliases(id INTEGER, alias TEXT, PRIMARY KEY (id, alias) ON CONFLICT ROLLBACK);
CREATE TABLE episode_paths(id INTEGER, path BLOB, UNIQUE (id, path) ON CONFLICT ROLLBACK);
CREATE TABLE watch_traces(id INTEGER PRIMARY KEY ASC ON CONFLICT ROLLBACK AUTOINCREMENT, ep_id INTEGER, mask BLOB, ts_start INTEGER, ts_end INTEGER);
