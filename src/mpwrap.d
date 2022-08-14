import core.stdc.errno;
import core.sys.posix.termios;
import core.sys.posix.unistd: read;
import core.sys.posix.sys.ioctl;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.un;
import core.time;

import eudorina.io;
import eudorina.logging;
import eudorina.text;
import std.array: appender, Appender;
import std.algorithm: find;
import std.container: DList;
import std.json: JSONValue, JSONException, parseJSON, toJSON, JSON_TYPE;
import core.sys.posix.unistd: getpid;
import std.string;

alias void delegate(char[]) td_io_writer;
alias void delegate() td_voidfunc;
alias void delegate(FD) td_close_handler;

alias void delegate(MPRun) MprUpcall;

class MPRun {
	SubProcess p;
	string[] argv;
	string sock_name;
	MPMaster mm;
	MprUpcall upcallInitDone, upcallMediaTime, upcallFinish;
	bool finished;

	this(string argv_base[], string targets[]) {
		this.sock_name = format("/tmp/mpwrap.%d", getpid());
		this.argv = argv_base.dup;
		this.argv ~= ["--input-ipc-server=" ~ this.sock_name, "--pause"];
		this.argv ~= targets;
		auto p = this.p = new SubProcess();
		p.fd_i = 0;
		p.fd_o = 1;
		p.fd_e = 2;

		this.upcallInitDone = &this.noop;
		this.upcallMediaTime = &this.noop;
		this.upcallFinish = &this.noop;
	}

	t_fd pokeSock() {
		auto fd = socket(AF_UNIX, SOCK_STREAM, 0);
		sockaddr_un addr;
		addr.sun_family = AF_UNIX;
		addr.sun_path[0..this.sock_name.length] = cast(byte[])this.sock_name.dup;
		addr.sun_path[this.sock_name.length] = 0;

		auto rv = connect(fd, cast(sockaddr*)&addr, cast(int)addr.sizeof);
		if (rv < 0) {
			close_(fd);
			return rv;
		}
		return fd;
	}

	void noop(MPRun mpr) {}

	void handleMediaTime(MPMaster mpm) {
		this.upcallMediaTime(this);
	}
	void handleInitDone(MPMaster mpm) {
		logf(20, "Init done: %f", mpm.media_length);
		this.upcallInitDone(this);
	}
	void handleFinish(MPMaster mpm) {
		this.finished = true;
		this.upcallFinish(this);
	}
	bool finishedFile() {
		if (this.mm is null) return false;
		return this.mm.finished_file;
	}

	Timer connect_timer;
	void tryConnect() {
		if (this.mm !is null) {
			this.connect_timer.stop();
			return;
		}
		auto fd = this.pokeSock();
		if (fd < 0) return;
		logf(20, "Sock connect rv: %d", fd);
		this.connect_timer.stop();

		this.mm = new MPMaster(ed.WrapFD(fd));
		this.mm.upcallMediaTime = &this.handleMediaTime;
		this.mm.upcallInitDone = &this.handleInitDone;
		this.mm.upcallFinish = &this.handleFinish;
	}

	EventDispatcher ed;
	void start(EventDispatcher ed) {
		this.ed = ed;
		this.finished = false;

		this.p.Spawn(this.argv);
		this.connect_timer = ed.NewTimer(&this.tryConnect, dur!"msecs"(20), true);
	}
}

class LineSplitter {
	char sep;
	Appender!(char[]) buf;

	this(char sep = '\n') {
		this.sep = sep;
		this.buf = appender!(char[]);
	}
	void pushData(char data[]) {
		this.buf ~= data;
	}
	char[][] popLines() {
		auto lines = appender!(char[][]);
		size_t idx = 0;
		size_t idx_e = -1;
		while (true) {
			auto ss = this.buf.data[idx..$];
			auto end_seq = find(ss, this.sep);
			if (end_seq.length == 0) break;

			idx_e = this.buf.data.length - end_seq.length + 1;
			lines ~= this.buf.data[idx..idx_e];
			idx = idx_e;
		}
		if (idx != 0) {
			// clear parsed buffer contents
			auto nseq = this.buf.data[idx..$];
			this.buf.clear();
			this.buf ~= nseq;
		}
		return lines.data;
	}
}

alias JSONValue MpMsg;
alias void delegate(MpMsg) MsgHandler;
alias void delegate(MPMaster) MpmUpcall;
alias void delegate(bool, MpMsg) MpmCallback;

class MPParseError: Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(msg, file, line, next);
	};
}

class MPCommand {
	MpMsg msg;
	MpmCallback cb;
	this(MpMsg msg, MpmCallback cb = null) {
		this.msg = msg;
		this.cb = cb;
	};

	void callback(bool success, MpMsg msg) {
		if (this.cb is null) return;
		if (!success) {
			logf(30, "Command execution failed. Cmd: %s Reply: %s", cescape(toJSON(this.msg)), cescape(toJSON(msg)));
		}
		this.cb(success, msg);
	}
}

class MPMaster {
	FD sock;
	size_t bufsize;
	LineSplitter ls;
	bool paused;
	bool finished_file = false;
	BufferWriter bw;
	real media_time = -1; //seconds since {file, stream} start
	real media_length = -1; //seconds
	MsgHandler[string] msgHandlers;
	MpmUpcall upcallInitDone, upcallFinish, upcallMediaTime;
	DList!MPCommand pending_commands;

	this(FD sock) {
		this.sock = sock;
		this.bufsize = 1;
		this.bw = new BufferWriter(sock);
		this.ls = new LineSplitter();

		sock.setCallbacks(&this.processInput);
		sock.AddIntent(IOI_READ);
		this.initMsgHandlers();
		this.observeProperty("playback-time");
		this.observeProperty("duration");
		this.getProperty("duration", &this.handleLength);
		this.setProperty("pause", false);

		this.upcallInitDone = &this.noop;
		this.upcallMediaTime = &this.noop;
		this.upcallFinish = &this.noop;
	}

	void noop(MPMaster mpm) { }
	void initMsgHandlers() {
		immutable auto prefix = "handleMsg";
		immutable auto namePrefix = "nameMsg";

		foreach (m_name; __traits(allMembers, MPMaster)) {
			static if (startsWith(m_name, prefix)) {
				MsgHandler eh = &__traits(getMember, this, m_name);
				const string e_iname = m_name[prefix.length..$];
				string e_name = __traits(getMember, this, namePrefix ~ e_iname);

				this.msgHandlers[e_name] = eh;
			}
		}
	}

	void updateLength(MpMsg msg) {
		auto data = ("data" in msg.object);
		if ((data !is null) && (data.type is JSON_TYPE.FLOAT)) {
			if (this.media_length != data.floating) {
				this.media_length = data.floating;
				logf(20, "Setting length: %f", data.floating);
			}
		} else {
			logf(30, "Unable to parse mp length reply: %s", cescape(toJSON(msg)));
		}
	}

	void handleLength(bool success, MpMsg msg) {
		if (success) {
			this.updateLength(msg);
		} else {
			logf(30, "MP length query failed: %s", cescape(toJSON(msg)));
		}
		this.upcallInitDone(this);
	}

	string nameMsgPause = "pause";
	void handleMsgPause(MpMsg msg) {
		this.paused = true;
	}

	string nameMsgUnpause = "unpause";
	void handleMsgUnpause(MpMsg msg) {
		this.paused = false;
	}
	string nameMsgEndFile = "end-file";
	void handleMsgEndFile(MpMsg msg) {
		this.finished_file = true;
	}

	string nameMsgPropertyChange = "property-change";
	void handleMsgPropertyChange(MpMsg msg) {
	    auto name = ("name" in msg.object);
		if ((name is null) || name.type !is JSON_TYPE.STRING) {
			throw new MPParseError("Missing msg property 'name'.");
		}
		auto data = ("data" in msg.object);
		if (data is null) {
			throw new MPParseError("Missing msg property 'data'.");
		}

		switch (name.str) {
		   case "playback-time":
			   if (this.paused) break;
			   if (data.type !is JSON_TYPE.FLOAT) {
				   throw new MPParseError(format("Invalid playback-time data type %s.", data.type));
			   }
			   this.media_time = data.floating;
			   this.finished_file = false;
			   this.upcallMediaTime(this);
			   break;
		   case "duration":
			   this.updateLength(msg);
			   break;
		   default:
			   throw new MPParseError(format("Ignoring change in unknown mpv property %s.", cescape(name.str)));
		}
	}

	void handleCmdResponse(MpMsg msg) {
		auto err = ("error" in msg.object);
		if ((err is null) || err.type !is JSON_TYPE.STRING) {
			throw new MPParseError(format("Ignoring command response with unparseable 'error' element."));
		}
		string err_str = err.str;
		bool succ = err_str == "success";
		
		MPCommand cmd;
		try {
			cmd = this.pending_commands.front();
		} catch (Error exc) {
			logf(35, "Ignoring reply for missing command: %s", cescape(toJSON(msg)));
			return;
		}
		this.pending_commands.removeFront();
		cmd.callback(succ, msg);
	}

	void sendCommand(JSONValue[] args, MpmCallback cb = null) {
		auto msg = JSONValue([ "command": JSONValue(args)]);
		auto msg_text = toJSON(msg);

		auto cmd = new MPCommand(msg, cb);
		this.pending_commands.insertBack(cmd);
		
		this.bw.write(format("%s\n", msg_text));		
	}
	void observeProperty(string property) {
		this.sendCommand([JSONValue("observe_property"), JSONValue(1), JSONValue(property)]);
	}

	void getProperty(string property, MpmCallback cb) {
		this.sendCommand([JSONValue("get_property"), JSONValue(property)], cb);
	}
	void setPropertyString(string property, string val) {
		this.sendCommand([JSONValue("set_property_string"), JSONValue(property), JSONValue(val)]);
	}
	void setProperty(string property, bool val) {
		string val_str = val ? "yes" : "no";
		this.setPropertyString(property, val_str);
	}

	void processInput() {
		// Read input
		auto bsz = this.bufsize;
		char buf[];
		buf.length = bsz;

		auto fd = this.sock.fd;
		auto v = read(fd, buf.ptr, bsz);
		if (v <= 0) {
			this.sock.close();
			this.upcallFinish(this);
			return;
		}
		this.ls.pushData(buf);

		auto lines = this.ls.popLines();
		foreach (line; lines) {
			// Deserialize mpv data line JSON.
			JSONValue val;
			JSONValue[string] msg;
			try {
				val = parseJSON(line);
				msg = val.object;
			} catch (JSONException exc) {
				logf(30, "Failed to parse mpv json %s: %s", cescape(line), cescape(exc.toString()));
				continue;
			}
			//logf(10, "mp JSON: %s", cescape(toJSON(val)));

			// Classify line type and pass data on.
			JSONValue *msgtype;
			msgtype = ("event" in msg);
			if (msgtype !is null && msgtype.type is JSON_TYPE.STRING) {
				// mpv-side triggered status updates
				auto eh = (msgtype.str in this.msgHandlers);
				if (eh is null) {
					//logf(30, "Unknown event type in mpv json; ignoring: %s", cescape(line));
					continue;
				}
				try {
					(*eh)(val);
				} catch (MPParseError exc) {
					logf(30, "Unable to process mpv msg %s: %s", cescape(line), cescape(exc.msg));
				}
				continue;
			}

			msgtype = ("error" in msg);
			if (msgtype !is null) {
				try {
					this.handleCmdResponse(val);
				} catch (MPParseError exc) {
					logf(30, "Unable to process mpv msg %s: %s", cescape(line), cescape(exc.msg));
				}
				continue;
			}

			logf(30, "Unable to classify line type for mpv JSON; ignoring: %s", cescape(line));
		}
	}
}

