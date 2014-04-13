import std.exception: assumeUnique;
import std.getopt;
import std.path: expandTilde, buildPath;
import std.stdio: writef;

import eudorina.text;
import eudorina.logging;
import eudorina.db.sqlit3;

import vtrack.base;

alias int delegate(string[]) td_cli_cmd;

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
		long id = 0;
		string desc = args[0];

		auto s = new TShowSet(desc);
		c.store.addShowSet(s);
		writef("Added: %d: %s\n", s.id, cescape(s.desc));
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

		Cmd[] cmds = [new Cmd(), new CmdListSets(), new CmdMakeShowSet()];
		foreach (cmd; cmds) {
			cmd.reg(&this.cmd_map);
		}
	}
	void openStore() {
		this.db_conn = new SqliteConn(buildPath(this.base_dir, this.db_fn), SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOMUTEX);
		this.store = new TStorage(this.db_conn);
		this.store.readData();
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
		return ch.run(this, args[2..args.length]);
	}
}

int main(string[] args) {
	SetupLogging();
	auto cli = new CLI();
	cli.openStore();
	return cli.runCmd(args);
}
