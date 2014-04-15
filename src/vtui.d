import std.conv: to;
import std.datetime: Clock;
import std.exception: assumeUnique;
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
		this.usage = "ds <desc>";
	}
	override int run(CLI c, string[] args) {
		string spec = args[0];
		TShow show = c.getShow(spec);
		if (show is null) {
			writef("No show matching %s.\n", cescape(spec));
			return 1;
		}
		writef("Got show: %d %s\n", show.id, cescape(show.title));
		return 0;
	}
}

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

		Cmd[] cmds = [new Cmd(), new CmdListSets(), new CmdMakeShowSet(), new CmdMakeShow(), new CmdAddAlias(), new CmdDisplayShow()];
		foreach (cmd; cmds) {
			cmd.reg(&this.cmd_map);
		}
	}
	void openStore() {
		this.db_conn = new SqliteConn(buildPath(this.base_dir, this.db_fn), SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOMUTEX);
		this.store = new TStorage(this.db_conn);
		this.store.readData();
	}
	TShow getShow(string spec) {
		TShow rv = null;
		// First, attempt to parse it as hexadecimal or decimal show id.
		foreach (fmt; ["0x%x", "%d"]) {
			long i = -1;
			auto fin = spec;
			try {
				formattedRead(fin, fmt, &i);
			} catch {
			}
			if ((fin == "") && (i >= 0)) {
				rv = this.store.getShowById(i);
				if (rv !is null) return rv;
			}
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
			writef("%s\n", e.msg);
			return 4;
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
