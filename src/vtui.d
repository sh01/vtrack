import std.conv: to;
import std.datetime: Clock, SysTime, DateTime;
import std.exception: assumeUnique;
import std.file: getLinkAttributes;
import std.format: formattedRead;
import std.getopt;
import std.path: expandTilde, buildPath;
import std.stdio: writef;
import std.string;

import eudorina.text;
import eudorina.logging;
import eudorina.db.sqlit3;

import vtrack.base;

alias int delegate(string[]) td_cli_cmd;

class InvalidShowSpec: Exception {
	this(string spec, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		auto msg = format("Unknown show %s.", cescape(spec));
		super(msg, file, line, next);
	};
}

class InvalidIntSpec: Exception {
	this(string spec, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		auto msg = format("Invalid integer %s.", cescape(spec));
		super(msg, file, line, next);
	};
}

class InvalidEpSpec: Exception {
	this(string spec, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		auto msg = format("Unknown episode %s.", spec);
		super(msg, file, line, next);
	};
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

class CmdListSets: Cmd {
	this() {
		this.min_args = 0;
		this.commands = ["ls", "lsss"];
		this.usage = "ls";
	}

	override int run(CLI c, string[] args) {
		long id = 0;
		foreach (s; c.store.showsets) {
			writef("%d: %s\n", id++, s.desc);
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
		c.store.addShowSet(s);
		writef("Added: %d: %s\n", s.id, cescape(s.desc));
		return 0;
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

class CmdDisplayShow: Cmd {
	this() {
		this.min_args = 1;
		this.commands = ["ds"];
		this.usage = "ds <show_spec>";
	}
	override int run(CLI c, string[] args) {
		string spec = args[0];
		TShow show = c.getShow(spec);
		if (show is null) {
			writef("No show matching %s.\n", cescape(spec));
			return 20;
		}
		writef("Got show: %s\n", c.formatShow(show));
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

class CmdListEps: Cmd {
	this() {
		this.min_args = 0;
		this.commands = ["lseps"];
		this.usage = "lseps [show...]";
	}
	override int run(CLI c, string[] args) {
		if (args.length > 0) {
			TShow show;
			foreach (spec; args) {
				try {
					show = c.getShow(spec);
				} catch (InvalidShowSpec e) {
					writef("%s\n", e);
				}
				writef("== %s\n", c.formatShow(show));
				c.printEpisodes(show);
			}
		} else {
			foreach (show; c.store.shows) {
				writef("== %s\n", c.formatShow(show));
				c.printEpisodes(show);
			}
		}
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

class CmdDisplayEpPaths: Cmd {
	this() {
		this.min_args = 2;
		this.commands = ["lspaths"];
		this.usage = "lspaths <show_spec> <ep index>";
	}
	override int run (CLI c, string[] args) {
		auto ep = c.getEpisodeExc(args[0], args[1]);
		auto paths = c.store.getPaths(ep);
		writef("== %d\n", ep.id);
		foreach (path; paths) {
			writef("  %s\n", cescape(path));
		}
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

immutable DateTime unixBOT = DateTime(1970, 01, 01, 01, 00, 00);

class CLI {
private:
	Cmd[string] cmd_map;

public:
	TStorage store;
	SqliteConn db_conn;
	string base_dir;
	string db_fn = "db.sqlite";
	
	this() {
		this.base_dir = expandTilde("~/.vtrack/");

		Cmd[] cmds = [new Cmd(), new CmdListSets(), new CmdListEps(), new CmdMakeShowSet(), new CmdMakeShow(), new CmdMakeEp(), new CmdAddAlias(), new CmdAddEpPath, new CmdDisplayEpPaths(), new CmdDisplayShow()];
		foreach (cmd; cmds) {
			cmd.reg(&this.cmd_map);
		}
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
	string formatShow(TShow show) {
		return format("%d %s", show.id, cescape(show.title));
	}
	string formatEpisode(TEpisode ep) {
		return format("%s %.2f %d   %s / %s", ep.watch_state, ep.wfrac, ep.length, formatTime(ep.ts_add), formatTime(ep.wfrac_ts_min));
	}
	void printEpisodes(TShow show) {
		int idx = 0;
		foreach (ep; show.eps) {
			if (!ep) {
				if (idx != 0) writef("%d: ?\n", idx);
				continue;
			}
			writef("  %d: %s\n", idx, this.formatEpisode(ep));
			idx++;
		}
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
