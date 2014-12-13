import std.array: appender, split;
import std.conv: to;
import std.datetime: Clock, SysTime, DateTime;
import std.exception: assumeUnique;
import std.file;
import std.format: formattedRead;
import std.getopt;
import std.path: expandTilde, baseName, buildPath;
import std.regex;
import std.stdio: writef, stdin;
import std.string;

import eudorina.io: FD, BufferWriter, WNOHANG;
import eudorina.service_aggregation: ServiceAggregate;
import eudorina.text;
import eudorina.structured_text;
import eudorina.logging;
import eudorina.db.sqlit3;

import vtrack.base;
import vtrack.h_fnparse;
import vtrack.mpwrap;

alias int delegate(string[]) td_cli_cmd;

class InvalidSpec: Exception {
	this(string spec, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		auto msg = format("Invalid item %s.", cescape(spec));
		super(msg, file, line, next);
	};
}

class InvalidShowSetSpec: InvalidSpec {
	this(A...)(A a) { super (a); }
}

class InvalidShowSpec: InvalidSpec {
	this(A...)(A a) { super (a); }
}

class InvalidIntSpec: InvalidSpec {
	this(A...)(A a) { super (a); }
}

class InvalidEpSpec: InvalidSpec {
	this(A...)(A a) { super (a); }
}

// ---------------------------------------------------------------- Command helpers
bool parseInt(string spec, long *o) {
	if (spec == "") return false;
	uint vc;
	foreach (fmt; ["0x%x", "%d"]) {
		long i = -1;
		auto fin = spec;
		try {
			vc = formattedRead(fin, fmt, &i);
		} catch {
		}
		if ((fin == "") && (vc == 1)) {
			*o = i;
			return true;
		}
	}
	return false;
}

long parseIntExc(string spec) {
	long rv;
	if (!parseInt(spec, &rv)) throw new InvalidIntSpec(spec);
	return rv;
}

class Path {
	string[] p;
	this(string[] p) {
		this.p = p;
	}
	this(string spec) {
		this.p = split(spec,"/");
	}
	string opIndex(int i) { return p[i]; }
	Path drop(size_t count = 1) {
		if (count > p.length) count = p.length;
		p = p[count..$];
		return this;
	}
	Path dup() {
		return new Path(this.p);
	}
	Path dropEmpties() {
		while (p.length > 0 && p[0] == "") p = p[1..$];
		return this;
	}
	bool isEmpty() { return p.length < 1; }
	bool isEverything() {
		// Return if the current top level is an all-match.
		if (isEmpty()) return false;
		for (size_t i = 0; i < p.length; i++) {
			if (p[i] == "*") return true;
			if (p[i] != "") return false;
		}
		// We interpret trailing slash(es) the same as /*.
		return true;
	}
}

class ItemBase {
	int level;
	CLI c;
	this(CLI c, int level = 0) {
		this.c = c;
		this.level = level;
	}
	string formatHR() { throw new Exception("Not implemented."); }
	void formatLine(ANSILine l) {
		l.add(128).add(this.formatHR());
	}
	void formatSubTable(ANSITable t) {
		int indent = this.level*2;
		string prefix = "";
		if (this.level == 0) prefix = "==== ";
		prefix = format("%*s", indent, prefix);
		auto l = t.add();
		if (prefix.length > 0) l.add().add(prefix);
		this.formatLine(l);
	}
	ItemBase[] getChildren(Path spec) {
		return this.getChildren_(spec.dup);
	}
	ItemBase[] getChildren_(Path spec) {
		if (spec.dropEmpties().isEmpty()) return [this];
		throw new Exception("Not implemented.");
	}
	int level_delta() {
		return 0;
	}
}

class ItemLevelChange: ItemBase {
	int _level_delta;
	this(CLI c, int level, int level_delta) {
		super(c, level);
		this._level_delta = level_delta;
	}
	override int level_delta() {
		return this._level_delta;
	}
}

class ItemEpPath: ItemBase {
	string I;
	this(CLI c, string path, int level=0) {
		this.I = path;
		super(c, level);
	}
	override string formatHR() {
		return cescape(this.I);
	}
}

class ItemEpisode: ItemBase {
	TEpisode I;
	this(CLI c, TEpisode ep, int level = 0) {
		this.c = c;
		this.I = ep;
		super(c, level);
	}
	override ItemBase[] getChildren_(Path spec) {
		if (spec.isEmpty()) return [this];
		ItemBase[] rv;
		if (spec.isEverything()) {
			spec.drop();
			rv ~= this;
			rv ~= new ItemLevelChange(c, level, 1);
			foreach (p; this.c.store.getPaths(this.I)) rv ~= new ItemEpPath(c, p, level+1).getChildren(spec);
			rv ~= new ItemLevelChange(c, level, -1);
			return rv;
		}
		throw new InvalidSpec("Explicit path indexing not supported.");
	}
	override void formatLine(ANSILine l) {
		const(Color) *bc;
		switch (I.watch_state) {
		case TWatchState.TODO:
			bc = &CYellow;
			break;
		case TWatchState.DONE:
			bc = &CGreen;
			break;
		case TWatchState.SKIPPED:
			bc = &CBlue;
			break;
		default:
			bc = &CMagenta;
			break;
		}
		l.add().setFmt(*bc,null,true).addf("  %s", I.watch_state);
		l.add().addf("%.2f", I.wfrac);
		l.add().addf("%d", I.length);
		l.add().setFmt(CBlack,null,true).add(c.formatTime(I.ts_add)).resetFmt();
		l.add().add("/");
		l.add().setFmt(CBlack,null,true).add(c.formatTime(I.ts_sm)).resetFmt();
		l.add().add("/");
		l.add().setFmt(CBlack,null,true).add(c.formatTime(I.wfrac_ts_min)).resetFmt();
	}
}

class ItemShow: ItemBase {
	TShow I;
	this(CLI c, TShow s, int level = 0) {
		super(c, level);
		this.I = s;
	}
	override void formatLine(ANSILine l) {
		long[TWatchState] ecs;

		TWatchState s0, s1, s2;
		s0 = TWatchState.TODO;
		s1 = TWatchState.DONE;
		s2 = TWatchState.SKIPPED;
		ecs[s0] = 0;
		ecs[s1] = 0;
		ecs[s2] = 0;
		foreach (ep; I.eps) {
			if (ep is null) continue;
			ecs[ep.watch_state] += 1;
		}
		bool have_todo = ecs[s0] > 0;
		const(Color) *bc = have_todo ? &CYellow : &CWhite;
		l.add().setFmt(*bc, null, have_todo).addf("%3d", I.id);
		l.add().addf("%10s", I.title);
		l.add().setFmt(CYellow, null, true).addf("%2d", ecs[s0]).resetFmt();
		l.add().add("/");
		l.add().setFmt(CGreen, null, true).addf("%2d", ecs[s1]).resetFmt();
		l.add().add("/");
		l.add().setFmt(CBlue, null, true).addf("%2d", ecs[s2]).resetFmt();
	}
	override ItemBase[] getChildren_(Path spec) {
		ItemBase[] rv;
		if (spec.isEmpty()) return [this];
		if (spec.isEverything()) {
			spec.drop();
			rv ~= this;
			rv ~= new ItemLevelChange(c, level, 1);
			foreach (ep; this.I.eps) {
				if (ep is null) continue;
				rv ~= new ItemEpisode(c, ep, level+1).getChildren(spec);
			}
			rv ~= new ItemLevelChange(c, level, -1);
		} else {
			auto idx = parseIntExc(spec[0]);
			rv ~= new ItemLevelChange(c, level, 1);
			rv ~= new ItemEpisode(c, this.I.eps[idx]).getChildren(spec.drop());
			rv ~= new ItemLevelChange(c, level, -1);
		}
		return rv;
	}
}

class ItemShowSet: ItemBase {
	TShowSet I;
	this(CLI c, TShowSet ss, int level = 0) {
		this.I = ss;
		super(c, level);
	}
	override string formatHR() {
		return format("%3d: %s", this.I.id, this.I.desc);
	}
	override ItemBase[] getChildren_(Path spec) {
		ItemBase[] rv;
		if (spec.isEmpty()) return [this];
		if (spec.isEverything()) {
			spec.drop();
			rv ~= this;
			rv ~= new ItemLevelChange(c, level, 1);
			foreach (show; this.I.shows) rv ~= new ItemShow(c, show, level+1).getChildren(spec);
			rv ~= new ItemLevelChange(c, level, -1);
		} else {
			auto idx = parseIntExc(spec[0]);
			TShow s;
			long i = 0;
			foreach (show; this.I.shows) {
				if (i++ == idx) {
					s = show;
					break;
				}
			}
			if (s is null) throw new InvalidSpec(spec[0]);
			rv ~= new ItemLevelChange(c, level, 1);
			rv ~= new ItemShow(c, s).getChildren(spec.drop());
			rv ~= new ItemLevelChange(c, level, -1);
		}
		return rv;
	}
}

// ---------------------------------------------------------------- Command specs
class Cmd {
	int min_args = -1;
	string usage = "...";
	string[] commands;
	int run(CLI c, string[] s) {
		throw new Exception("Not implemented.");
	}
	void reg(Cmd[string] *map) {
		foreach (cmd; this.commands) {
			(*map)[cmd] = this;
		}
	}
}


private alias void delegate() td_v;

private class SeqPrint {
	string[] lines;
	this() {}
	td_v dPrintT(size_t min, size_t max) {
		void printT() {
			writef("%s\n", join(lines[min..max], "\n"));
		}
		return &printT;
	}
}

class CmdLS: Cmd {
	this() {
		this.min_args = 1;
		this.commands = ["ls"];
		this.usage = "ls ...";
	}
	override int run(CLI c, string[] args) {
		ItemBase[] items;
		td_v[] prints;
		size_t i;

		void printSub() {
			auto t = c.newTable();
			size_t lines_out = 0;
			size_t lines_buf = 0;
			auto lines = appender(cast(string[])[]);
			auto sp = new SeqPrint();

			for(; i < items.length; i++) {
				auto it = items[i];
				if (it.level_delta) {
					if (it.level_delta > 0) {
						prints ~= sp.dPrintT(lines_out, lines_out+lines_buf);
						lines_out += lines_buf;
						lines_buf = 0;
						i += 1;
						printSub();
						continue;
					} else {
						break;
					}
				}
				it.formatSubTable(t);
				lines_buf += 1;
			}
			prints ~= sp.dPrintT(lines_out, lines_out+lines_buf);
			lines ~= t.getLines();
			sp.lines = lines.data;
		}

		foreach (spec; args) {
			items = c.getItems(spec);
			i = 0;
			prints = [];
			printSub();
			foreach (d; prints) d();
		}
		return 0;
	}
}

class CmdMakeShowSet: Cmd {
	this() {
		this.min_args = 1;
		this.commands = ["mkss"];
		this.usage = "mkss <desc>";
	}
	override int run(CLI c, string[] args) {
		string desc = args[0];

		auto s = new TShowSet(desc);
		c.store.readAllShowSets();
		c.store.addShowSet(s);
		writef("Added: %d: %s\n", s.id, cescape(s.desc));
		return 0;
	}
}

class CmdModShowSet: Cmd {
	this() {
		this.min_args = 2;
		this.commands = ["modss"];
		this.usage = "modss <show set> (add <show spec...>)";
	}
	override int run(CLI c, string[] args) {
		TShowSet ss = c.getShowSet(args[0]);
		string cmd = args[1];
		if (cmd == "add") {
			TShow show = c.getShow(args[2]);
			c.store.addShowSetMember(ss, show);
			writef("Added: %d <- %d.\n", ss.id, show.id);
			return 0;
		}

		writef("Unknown subcommand %s.", cescape(cmd));
		return 200;
	}
}

class CmdMakeShow: Cmd {
	this() {
		this.min_args = 1;
		this.commands = ["mks"];
		this.usage = "mks <title> [alias...]";
	}
	override int run(CLI c, string[] args) {
		string title = args[0];
		auto aliases = args[1..args.length];

		auto show = new TShow(Clock.currTime(), title);
		c.store.addShow(show);
		foreach (key; aliases) {
			c.store.addShowAlias(show, key);
		}
		
		writef("Added: %d: %s %s\n", show.id, cescape(show.title), aliases);
		return 0;
	}
}

class CmdAddAlias: Cmd {
	this() {
		this.min_args = 2;
		this.commands = ["addalias"];
		this.usage = "addalias <show_spec> <alias>";
	}
	override int run(CLI c, string[] args) {
		auto show = c.getShow(args[0]);
		auto key = args[1];
		c.store.addShowAlias(show, key);
		return 0;
	}
}

class CmdMakeEp: Cmd {
	this() {
		this.min_args = 2;
		this.commands = ["mkep"];
		this.usage = "mkep <show_spec> <episode index>";
	}
	override int run(CLI c, string[] args) {
		TShow show = c.getShow(args[0]);
		long idx = parseIntExc(args[1]);
		auto ep = c.getEpisode(show, idx);
		if (ep !is null) {
			writef("Episode already exists.\n");
			return 30;
		}
		ep = c.getMakeEpisode(show, idx);
		writef("Episode added.\n");
		return 0;
	}
}

class CmdAddEpPath: Cmd {
	this() {
		this.min_args = 3;
		this.commands = ["addpath"];
		this.usage = "addpath <show_spec> <ep index> <path>";
	}
	override int run (CLI c, string[] args) {
		auto ep = c.getEpisodeExc(args[0], args[1]);
		auto path = args[2];
		if (!seePath(expandTilde(path))) {
			writef("Error: Unable to verify existence of path %s.\n", cescape(path));
			return 22;
		}
		c.store.addPath(ep, args[2]);
		writef("Added path: %d -> %s\n", ep.id, cescape(args[2]));
		return 0;
	}
}

class CmdDisplayTraces: Cmd {
	this() {
		this.min_args = 2;
		this.commands = ["lstrace"];
		this.usage = "lstrace <show_spec> <ep index>";
	}
	override int run (CLI c, string[] args) {
		auto ep = c.getEpisodeExc(args[0], args[1]);
		writef("== %d\n", ep.id);
		BitMask m = new BitMask;
		foreach (trace; c.store.getTraces(ep)) {
			writef("  %3d:   %s %s  %d: %s\n", trace.id, c.formatTime(trace.ts_start), c.formatTime(trace.ts_end), trace.m.countSet(), cescape(cast(char[])trace.m.mask));
			m |= trace.m;
		}
		writef("Cumulative mask: %s (%d)\n", cescape(cast(char[])m.mask), m.countSet());
		return 0;
	}
}

class CmdSAddScan: Cmd {
	this() {
		this.min_args = 2;
		this.commands = ["s_add_scan"];
		this.usage = "s_add_scan <show_spec> <path...>";
	}
	override int run (CLI c, string[] args) {
		auto show = c.getShow(args[0]);
		FN fn;
		long succ, ext, fail;
		foreach (pn; args[1..$]) {
			auto bp = expandTilde(pn);
			// Don't combine non-shallow span modes with followSymlink=true here; it makes the call stat every file, and error out on dangling symlinks; that's understandable behavior, but also rather undesirable for git-annex dirs.
			foreach (string fpn; dirEntries(bp, SpanMode.shallow)) {
				fn = new FN(baseName(fpn));
				if (!fn.okExtVideo()) {
					ext += 1;
				} else if (!fn.okToAdd()) {
					logf(30, "Not ok: %s", fn);
					fail += 1;
				} else {
					auto ep = c.store.getEpisode(show, fn.idx, true);
					logf(20, "Adding: %d -> %s", fn.idx, fn.fn);
					c.store.addPath(ep, fpn);
					succ += 1;
				}
			}
		}
		writef("Ext filtered: %d, Ok: %d Parse failures: %d\n", ext, succ, fail);
		return 0;
	}
}

int parseMpTime(const(char)[] tspec) {
	int h,m,rv;
	formattedRead(tspec, "%d:%d:%d", &h, &m, &rv);
	rv += 60*m+3600*h;
	return rv;
}

class CmdPlay: Cmd {
	ServiceAggregate sa = null;
	TEpisode ep;
	TStorage store;
	TWatchTrace trace = null;
	// In its standard config, mpv prints about 30 of these a second. A threshold of 10 seems reasonable.
	int status_rep_count_limit = 10;
	int push_delay = 16;
	int eof_slop_duration = 16;
	char[] status_tlt = std.string.makeTrans("\n","\r").dup;
	this() {
		this.min_args = 1;
		this.commands = ["play", "p"];
		this.usage = "play <show_spec> [ep index]";
	}

	void handleMPInit(MPRun mpr) { }

	int match_count = 0;
	int ts_last = -1;
	int push_counter = 0;
	void handleMediaTime(MPRun mpr) {
		auto ts_now = cast(int)mpr.mm.media_time;
		auto ep_length = cast(int)mpr.mm.media_length;

		if (ts_last == ts_now) {
			this.match_count += 1;
		} else {
			this.match_count = 0;
			this.ts_last = ts_now;
		}

		bool length_updated = false;
		if (ep_length != this.ep.length) {
			this.ep.length = ep_length;
			length_updated = true;
		}

		if (match_count == status_rep_count_limit) {
			// Figure out where we are and update our watch model accordingly.
			if (ts_now > ep_length) {
				logf(30, "Beyond end of ep: %d > %d. Ignoring status line.", ts_now, ep_length);
			} else {
				if (this.trace is null) {
					this.trace = this.store.newTrace(this.ep);
					trace.m.setLength(ep_length);
				}

				if (length_updated) {
					trace.m.setLength(ep_length);
					this.store.pushEp(this.ep);
				}

				// Mark this second as having been watched.
				trace.m[ts_now] = 1;
				this.push_counter += 1;
				if (push_counter >= this.push_delay) {
					// Push trace update to database.
					//log(20, "Flush.");
					this.flushData();
					this.push_counter = 0;
				}
				ts_last = ts_now;
			}
		}
	}

	void handleFinish(MPRun mpr) {
		if (sa.ed.shutdown) return; // No need to be spammy about it.
		logf(20, "Shutting down on mpv socket close.");
		this.sa.ed.shutdown = 1;
	}

	void flushData() {
		if (this.trace is null) return;

		this.trace.ts_end = Clock.currTime();
		this.store.pushTrace(trace);
	}
	string[] getCommand() {
		return [expandTilde("~/.vtrack/mp")];
	}
	override int run(CLI c, string[] args) {
		TShow show = c.getShow(args[0]);
		if (args.length >= 2) {
			ep = c.getEpisodeExc(args[0], args[1]);
		} else {
			logf(20, "Selecting first to-watch episode from show %d:%s.", show.id, cescape(show.title));
			// TODO: Insert ep-loading cmd here
			foreach (ep_; show.eps) {
				if ((ep_ is null) || !ep_.toWatch()) continue;
				ep = ep_;
				break;
			}
			if (ep is null) {
				log(40, "No to-watch episode found.");
				return 23;
			}
		}
		auto paths = c.store.getPaths(ep);
		string path = null;
		foreach (path_; paths) {
			string expp = expandTilde(path_);
			if (!seePath(expp)) {
				logf(20, "Unable to see file at %s.", cescape(path_));
				continue;
			}
			logf(20, "Found episode instance at %s; good.", cescape(path_));
			path = expp;
		}
		if (path is null) {
			log(40, "None of the registered paths worked. :(");
			return 24;
		}

		this.store = c.store;

		this.sa = new ServiceAggregate();
		this.sa.setupDefaults();
		auto ed = this.sa.ed;

		auto mprun = new MPRun(this.getCommand, [path]);
		mprun.upcallInitDone = &this.handleMPInit;
		mprun.upcallMediaTime = &this.handleMediaTime;
		mprun.upcallFinish = &this.handleFinish;
		//mprun.setupPty(ed, 0);
		mprun.start(ed);

		ed.Run();
		int rc;
		bool mp_gone = mprun.p.waitPid(&rc, WNOHANG) > 0;
		if (!mp_gone) {
			log(20, "Terminating player instance.");
			mprun.p.kill();
		}
		// Do final data flush here, so we do it in parallel to the player terminating.
		if (this.ts_last == this.ep.length-2) {
			// Last confirmed line is from END-1. There's a high chance either the media player was off by this much,
			// or the last fractional second wasn't long enough to reach our threshold.
			// We'll count the last one as watched also, in this case; this is very ugly, but should give us better results in practice.
			this.trace.m[this.ts_last+1] = 1;
		} else if (mprun.finishedFile() && (this.ts_last < this.ep.length-1) && (this.ts_last+eof_slop_duration >= this.ep.length-1)) {
			// mplayer signalled that it exited because it hit the end of its file just before quitting.
			// It's not very precise about playback duration; therefore, if we're still within the slop window,
			// fill up the rest of the mask so we don't end up with a time window we can never fill up with normal playback.
			// There's still some inaccuracy this way, but it's better than the simple alternative of just not doing this.
			logf(20, "Marking %d imaginary trailing seconds of episode as watched.", this.ep.length-1-this.ts_last);
			for (int ts = this.ts_last+1; ts < this.ep.length; ts++) this.trace.m[ts] = 1;
		}

		this.flushData();
		this.store.updateEpisodeWatched(ep, c.done_threshold);

		if (!mp_gone) mp_gone = mprun.p.waitPid(&rc, WNOHANG) > 0;
		if (!mp_gone) {
			log(20, "Killing player instance.");
			mprun.p.kill(9);
			mprun.p.waitPid(&rc);
		}
		log(20, "All done.");
		return 0;
	}
}

class CmdDbgFnParse: Cmd {
	this() {
		this.min_args = 0;
		this.commands = ["dbg_fn"];
		this.usage = "dbg_fn";
	}
	override int run (CLI c, string[] args) {
		FN fn;
		long succ, ext, fail;
		foreach (fn_; stdin.byLine()) {
			fn = new FN(fn_.idup);
			logf(20, "%s", fn);
			if (!fn.okExtVideo()) {
				ext += 1;
			} else if (!fn.okToAdd()) {
				logf(30, "Not ok: %s", fn);
				fail += 1;
			} else {
				succ += 1;
			}
		}
		writef("Ext filtered: %d, Successes: %d Failures: %d\n", ext, succ, fail);
		return 0;
	}
}

bool seePath(const char[] path) {
	try {
		getLinkAttributes(path);
	} catch (std.file.FileException e) {
		return false;
	}
	return true;
}

immutable DateTime unixBOT = DateTime(1970, 01, 01, 01, 00, 00);

class CLI {
private:
	Cmd[string] cmd_map;

public:
	TStorage store;
	SqliteConn db_conn;
	string base_dir;
	string db_fn = "db.sqlite";
	double done_threshold = 0.8;
	
	this() {
		this.base_dir = expandTilde("~/.vtrack/");

		Cmd[] cmds = [new Cmd(), new CmdMakeShowSet(), new CmdMakeShow(), new CmdMakeEp(), new CmdAddAlias(), new CmdAddEpPath, new CmdDisplayTraces, new CmdPlay(), new CmdDbgFnParse(), new CmdSAddScan(), new CmdModShowSet(), new CmdLS()];
		foreach (cmd; cmds) {
			cmd.reg(&this.cmd_map);
		}
	}
	auto newTable() {
		return new ANSITable();
	}
	void openStore() {
		this.db_conn = new SqliteConn(buildPath(this.base_dir, this.db_fn), SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOMUTEX);
		this.store = new TStorage(this.db_conn);
		this.store.readData();
	}
	TEpisode getMakeEpisode(TShow show, vt_id idx) {
		return this.store.getEpisode(show, idx, true);
	}
	TEpisode getEpisode(TShow show, vt_id idx) {
		return this.store.getEpisode(show, idx, false);
	}
	TEpisode getEpisodeExc(string show_spec, string idx_spec, TShow *show_out = null) {
		TShow show = this.getShow(show_spec);
		long idx = parseIntExc(idx_spec);
		auto ep = this.getEpisode(show, idx);
		if (ep is null) throw new InvalidEpSpec(format("%d::%d", show.id, idx));
		if (show_out != null) *show_out = show;
		return ep;
	}
	string formatTime(SysTime st) {
		auto dt = cast(DateTime)st;
		if (dt == unixBOT) return "?";
		return format("%04d-%02d-%02d_%02d:%02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
	}

	TShow getShow(string spec) {
		TShow rv = null;
		// First, attempt to parse it as hexadecimal or decimal show id.
		long i = -1;
		if (parseInt(spec, &i) && (i >= 0)) {
			rv = this.store.getShowById(i);
			if (rv !is null) return rv;
		}
		// ...no. Maybe it's an alias, then?
		if ((rv = this.store.getShowByAlias(spec)) !is null) return rv;
		// No idea, then. :(
		throw new InvalidShowSpec(spec);
	}
	TShowSet getShowSet(string spec) {
		vt_id id;
		if (parseInt(spec, &id) && (id >= 0)) return this.store.getShowSet(id);
		throw new InvalidShowSetSpec(spec);
	}
	ItemBase[] getItems(string spec) {
		auto p = new Path(spec);
		if (p.isEmpty()) throw new InvalidSpec(spec);

		ItemBase[] rv;
		// Shows
		if (p[0] == "s") {
			p.drop();
			if (p.isEverything() || p.isEmpty()) {
				// TODO: Insert a readShows() call here once we get lazy.
				foreach (show; this.store.shows) {
					if (show is null) continue;
					rv ~= new ItemShow(this, show).getChildren(p.dup.drop());
				}
			} else {
				p.dropEmpties();
				TShow show = this.getShow(p[0]);
				p.drop();
				rv ~= new ItemShow(this, show).getChildren(p);
			}
			return rv;
		}
		// Showsets
		if (p[0] == "S") {
			p.drop();
			if (p.isEverything() || p.isEmpty()) {
				this.store.readAllShowSets();
				p.drop();
				foreach (ss; this.store.showsets) {
					if (ss is null) continue;
					rv ~= new ItemShowSet(this, ss).getChildren(p);
				}
			} else {
				TShowSet ss = this.getShowSet(p[0]);
				p.drop();
				rv ~= new ItemShowSet(this, ss).getChildren(p);
			}
			return rv;
		}
		// No luck with the static prefixes. Try for heuristic show matching, then.
		TShow show;
		try {
			show = this.getShow(p[0]);
		} catch (InvalidShowSpec e) {};
		if (show !is null) {
			p.drop();
			// Convenience: Display eps by default if no sub-elements were specified.
			if (p.isEmpty()) p = new Path("*");
			rv ~= new ItemShow(this, show).getChildren(p);
			return rv;
		}
		logf(30, "Found nothing matching generic item spec %s :(", cescape(spec));
		return null;
	}
	// ---------------------------------------------------------------- Command processing
	int runCmd(string[] args) {
		if (args.length < 2) {
			writef("No command specified.\n");
			return 1;
		}
		auto cmd = args[1];
		auto ch = cmd in this.cmd_map;
		if (ch is null) {
			writef("Unknown command %s.\n", cescape(cmd));
			return 2;
		}
		if (args.length-2 < ch.min_args) {
			writef("Insufficient arguments.\nUsage: %s\n", ch.usage);
			return 3;
		}
		int rv;
		try {
			rv = ch.run(this, args[2..args.length]);
		} catch (InvalidShowSpec e) {
			writef("Error: %s\n", e.msg);
			return 4;
		} catch (InvalidIntSpec e) {
			writef("Error: %s\n", e.msg);
			return 5;
		} catch (InvalidEpSpec e) {
			writef("Error: %s\n", e.msg);
			return 6;
		} catch (InvalidSpec e) {
			writef("Error: %s\n", e.msg);
			return 7;
		}
		return rv;
	}
}

int main(string[] args) {
	SetupLogging();
	auto cli = new CLI();
	cli.openStore();
	return cli.runCmd(args);
}
