import std.algorithm: cmp;
import std.container;
import std.conv: to;
import std.datetime;
import std.string;

import eudorina.logging;
import eudorina.text;
import eudorina.db.sqlit3;

alias long vt_id;

pragma(lib, "sqlit3");
pragma(lib, "sqlite3");

class StorageError: Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(msg, file, line, next);
	};
}

enum TWatchState {
	TODO, DONE, SKIPPED
}

class TEpisode {
private:
	vt_id _id;
public:
	double wfrac = 0;
	SysTime ts_add, wfrac_ts_min;
	TWatchState watch_state;
	int length = -1;
	string[] fns;
	this (vt_id id, SysTime ts_add, int length, TWatchState watch_state, double wfrac, SysTime wfrac_ts_min) {
		this._id = id;
		this.ts_add = ts_add;
		this.length = length;
		this.watch_state = watch_state;
		this.wfrac = wfrac;
		this.wfrac_ts_min = wfrac_ts_min;
	}
	this() {
		this.ts_add = Clock.currTime();
		this.wfrac_ts_min = unixTimeToStdTime(0);
	}
	vt_id id() { return this._id; }
	void update(SqliteStmt s) {
		s.reset();
		s.bind(this.ts_add.toUnixTime(), this.length, this.watch_state, this.wfrac, this.wfrac_ts_min.toUnixTime(), this._id);
		s.step();
	}
	void bindValues(SqliteStmt s, vt_id show_id, vt_id idx) {
		s.bind(show_id, idx, this.ts_add.toUnixTime(), this.length, this.watch_state, this.wfrac, this.wfrac_ts_min.toUnixTime());
	}
}

class TShow {
private:
	vt_id _id;
public:
	SysTime ts_add;
	string title;
	TEpisode[] eps;
	this(SysTime ts_add, string title, vt_id id=-1) {
		this._id = id;
		this.ts_add = ts_add;
		this.title = title;
	}
	this (SqliteStmt stmt) {
		long ts_unix;
		stmt.getRow(&this._id, &ts_unix, &this.title);
		this.ts_add = SysTime(unixTimeToStdTime(ts_unix));
	}
	vt_id id() { return this._id; }

	alias Object.opCmp opCmp;
	int opCmp(TShow other) {
		return cast(int)(this._id - other._id);
	}

	static immutable string sql_write = "INTO shows(id,ts_add,title) VALUES (?,?,?);";
	void write(SqliteStmt s) {
		s.reset();
		s.bind(this._id, this.ts_add.toUnixTime(), this.title);
		s.step();
	}
}

class TShowSet {
private:
	vt_id _id;
public:
	string desc;
	RedBlackTree!(TShow) shows;
	this(string desc, vt_id id=-1) {
		this._id = id;
		this.desc = desc;
	}
	vt_id id() { return this._id; }

	static immutable string sql_write_base = "INTO show_sets(id,desc) VALUES (?,?);";
	void write_base(SqliteStmt s) {
		s.reset();
		s.bind(this._id, this.desc);
		s.step();
	}
	static immutable string sql_write_members = "INTO show_set_in(id,show_id) VALUES (?,?);";
	void write_members(SqliteStmt s) {
		foreach (show; this.shows) {
			s.reset();
			s.bind(this._id, show._id);
			s.step();
		}
	}
}

class TShowAlias {
private:
	string key;
	vt_id show_id;

	alias Object.opCmp opCmp;
	this(vt_id show_id, string key) {
		this.show_id = show_id;
		this.key = key;
	}

	int opCmp(TShowAlias other) {
		return cmp(this.key, other.key);
	}
	static immutable string sql_write = " INTO show_aliases(id,alias) VALUES(?,?);";
	void write(SqliteStmt s) {
		s.reset();
		s.bind(this.show_id, this.key);
		s.step();
	}
}

class TStorage {
private:
	SqliteConn db_conn;
	SqliteStmt s_getshows, s_getshowbyalias, s_getshowbyid, s_getshowsets, s_getshowsetms, s_geteps, s_getepbyshowinfo, s_getpathsbyep, s_reppath, s_show_add, s_showalias_rep, s_show_rep, s_showset_add, s_showset_rep, s_showsetm_rep, s_newep;
public:
	TShow[] shows;
	TShowSet[] showsets;

	this(SqliteConn c) {
		this.db_conn = c;

		this.s_getshows = c.prepare(this.SQL_GETSHOWS ~ ";");
		this.s_getshowbyalias = c.prepare(this.SQL_GETSHOWBYALIAS ~ ";");
		this.s_getshowbyid = c.prepare(this.SQL_GETSHOWBYID ~ ";");

		this.s_getshowsets = c.prepare("SELECT id,desc FROM show_sets;");
		this.s_getshowsetms = c.prepare("SELECT id,show_id FROM show_set_in;");

		this.s_geteps = c.prepare(this.SQL_GETEPS ~ ";");
		this.s_getepbyshowinfo = c.prepare(this.SQL_GETEPBYSHOWINFO ~ ";");

		this.s_getpathsbyep = c.prepare(this.SQL_GETPATHSBYEP);
		this.s_reppath = c.prepare(this.SQL_REPPATH);

		this.s_show_add = c.prepare("INSERT " ~ TShow.sql_write);
		this.s_show_rep = c.prepare("REPLACE " ~ TShow.sql_write);
		this.s_showalias_rep = c.prepare("REPLACE " ~ TShowAlias.sql_write);
		this.s_showset_add = c.prepare("INSERT " ~ TShowSet.sql_write_base);
		this.s_showset_rep = c.prepare("REPLACE " ~ TShowSet.sql_write_base);
		this.s_showsetm_rep = c.prepare("REPLACE " ~ TShowSet.sql_write_members);

		this.s_newep = c.prepare(this.SQL_NEWEP);
	}

	private void readShows() {
		SqliteStmt s = this.s_getshows;
		for (s.reset(); s.step();) this.getShowBySql(s);
	}

	void readData() {
		SqliteStmt s;
		vt_id id, show_id;
		long ts_unix;
		SysTime ts;

		void add_item(A,E)(A a, E e) {
			if (a.length <= id)
				a.length = id+1;
			else if (a[id] !is null)
				return;
			(*a)[id] = e;
		}

		TShow getShow(vt_id id) {
			auto rv = this.shows[show_id];
			if (rv is null) {
				throw new StorageError(format("Invalid (%d,%d) pair in show_set_in: unknown show.", id, show_id));
			}
			return rv;
		}

		this.readShows();
		for (s = this.s_getshowsets, s.reset(); s.step();) {
			string desc;
			s.getRow(&id, &desc);
			add_item(&this.showsets, new TShowSet(desc, id));
		}
		for (s = this.s_getshowsetms, s.reset(); s.step();) {
			s.getRow(&id, &show_id);
			TShowSet set = this.showsets[id];
			if (set is null) {
				throw new StorageError(format("Invalid (%d,%d) pair in show_set_in: unknown showset.", id, show_id));
			}
			set.shows.stableInsert(getShow(id));
		}
		for (s = this.s_geteps, s.reset(); s.step();) {
			vt_id idx, ep_id;
			s.getRow(&ep_id, &show_id, &idx);

			auto eps = &getShow(show_id).eps;
			if (eps.length <= idx) eps.length = idx+1;
			this._storeEpFromSql(s);
		}
	}
	void addShow(TShow show) {
		vt_id id = this.shows.length;
		if (show._id >= 0) {
			throw new StorageError(format("Attempted to add show with id %d.", show._id));
		}
		show._id = id;
		this.shows ~= show;
		show.write(this.s_show_add);
	}
	void addShowSet(TShowSet set) {
		vt_id id = this.showsets.length;
		if (set._id >= 0) {
			throw new StorageError(format("Attempted to add show with id %d.", set._id));
		}
		set._id = id;
		this.showsets ~= set;
		set.write_base(this.s_showset_add);
	}
//---------------------------------------------------------------- Show getters
	private immutable static string SQL_GETSHOWS = "SELECT shows.id,shows.ts_add,shows.title FROM shows";
	private immutable static string SQL_GETSHOWBYALIAS = SQL_GETSHOWS ~ ",show_aliases WHERE ((show_aliases.alias==?) AND (shows.id == show_aliases.id))";

	private TShow getShowBySql(SqliteStmt stmt) {
		TShow show = new TShow(stmt);
		if (this.shows.length <= show.id) {
			this.shows.length = show.id+1;
		}
		if (this.shows[show.id] is null) {
			this.shows[show.id] = show;
		} else {
			show = this.shows[show.id];
		}
		return show;
	}
	private TShow getOneShowBySql(A...)(SqliteStmt stmt, A args) {
		long c = 0;
		TShow show = null;
		stmt.reset();
		stmt.bind(args);
		for (; stmt.step(); c++) show = this.getShowBySql(stmt);
		if (c > 1) throw new StorageError(format("Got %d (> 1) results for query.", c));
		return show;
	}

	TShow getShowByAlias(string alias_) {
		return this.getOneShowBySql(this.s_getshowbyalias, alias_);
	}
	private immutable static string SQL_GETSHOWBYID = SQL_GETSHOWS ~ " WHERE (shows.id == ?)";
	TShow getShowById(vt_id id) {
		return this.getOneShowBySql(this.s_getshowbyid, id);
	}

	private void _verifyShow(TShow show) {
		if (this.shows[show._id] !is show) throw new StorageError(format("Passed in unregistered show."));
	}
//---------------------------------------------------------------- Alias manipulation
	void addShowAlias(TShow show, string key) {
		this._verifyShow(show);
		auto a = new TShowAlias(show.id, key);
		a.write(this.s_showalias_rep);
	}
//---------------------------------------------------------------- Episode access
	private immutable static string SQL_GETEPS = "SELECT id,show_id,idx,ts_add,length,watch_state,wfrac,wfrac_ts_min FROM episodes";
	private immutable static string SQL_GETEPBYSHOWINFO = SQL_GETEPS ~ " WHERE ((show_id == ?) AND (idx == ?))";
	private TEpisode _storeEpFromSql(SqliteStmt stmt) {
		TEpisode rv;
		vt_id id, show_id, idx;
		long ts_add, wfrac_ts_min;
		int length, ws_;
		double wfrac;
		stmt.getRow(&id, &show_id, &idx, &ts_add, &length, &ws_, &wfrac, &wfrac_ts_min);
		rv = new TEpisode(id, SysTime(unixTimeToStdTime(ts_add)), length, to!TWatchState(ws_), wfrac, SysTime(unixTimeToStdTime(wfrac_ts_min)));
		this.shows[show_id].eps[idx] = rv;
		return rv;
	}

	private immutable static string SQL_NEWEP = "INSERT INTO episodes(show_id,idx,ts_add,length,watch_state,wfrac,wfrac_ts_min) VALUES (?,?,?,?,?,?,?);";
	TEpisode getEpisode(TShow show, vt_id idx, bool make_new = false) {
		this._verifyShow(show);
		TEpisode rv;
		// Look up episode in ram
		if (show.eps.length <= idx) {
			show.eps.length = idx+1;
		} else {
			rv = show.eps[idx];
			if (rv !is null) return rv;
		}
		// Get episode from database
		auto s = this.s_getepbyshowinfo;
		s.reset();
		s.bind(show.id, idx);
		if (s.step()) return this._storeEpFromSql(s);

		// No dice.
		if (!make_new) return null;

		// We'll need to build one from scratch.
		rv = new TEpisode();
		auto s2 = this.s_newep;
		s2.reset();
		rv.bindValues(s2, show.id, idx);
		s2.step();
		// Get the unique id for the new episode row.
		s.reset();
		s.bind(show.id, idx);
		s.step();
		vt_id id;
		s.getRow(&id);
		// Update id field, store episode value, and return it.
		rv._id = id;
		show.eps[idx] = rv;
		return rv;
	}
//---------------------------------------------------------------- pathname access
	private immutable static string SQL_GETPATHS = "SELECT id,path FROM episode_paths";
	private immutable static string SQL_GETPATHSBYEP = SQL_GETPATHS ~ " WHERE (id == ?) ORDER BY rowid DESC;";
	string[] getPaths(TEpisode ep) {
		string[] rv;
		auto s = this.s_getpathsbyep;
		s.reset();
		s.bind(ep._id);
		vt_id id;
		string path;
		for (; s.step();) {
			s.getRow(&id, &path);
			rv ~= path;
		}
		return rv;
	}
	private immutable static string SQL_REPPATH = "REPLACE INTO episode_paths(id,path) VALUES (?,?);";
	void addPath(TEpisode ep, string path) {
		auto s = this.s_reppath;
		s.reset();
		s.bind(ep._id, path);
		s.step();
	}
//---------------------------------------------------------------- show set manipulation
	void addShowSetMember(TShowSet set, TShow show) {
		this._verifyShow(show);
		if (this.showsets[set._id] !is set) throw new StorageError(format("Attempted to manipulate unregistered show set."));
		set.shows.stableInsert(show);
		set.write_members(this.s_showsetm_rep);
	}
}
