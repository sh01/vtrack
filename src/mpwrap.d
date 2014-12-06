import core.stdc.errno;
import core.sys.posix.termios;
import core.sys.posix.unistd: read;
import core.sys.posix.sys.ioctl;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.un;

import eudorina.io;
import eudorina.logging;
import std.array: appender, Appender;
import std.algorithm: find;
import std.process: getpid;
import std.string;


// testing ...
import std.stdio: writef;
import core.thread: sleep;


alias void delegate(char[]) td_io_writer;
alias void delegate() td_voidfunc;
alias void delegate(FD) td_close_handler;

class MPRun {
	td_io_writer oo, oe;
	td_close_handler co, ce;

	FD fd_o, fd_e; // subprocess stdio pipe ends

	void thisss(string[] argv, td_io_writer oo, td_io_writer oe, td_close_handler co = null, td_close_handler ce = null) {
		this.argv = argv;
		this.oo = oo;
		this.oe = oe;
		this.p = new SubProcess();
		this.co = co ? co : &this.eatClose;
		this.ce = ce ? ce : &this.eatClose;
	}

	void eatClose(FD fd) { }

	td_voidfunc makeCopier(size_t bufsize=1024)(FD fd, td_io_writer out_, td_close_handler close_) {
		void copy() {
			char buf[bufsize];
			auto v = read(fd.fd, buf.ptr, bufsize);
			if (v <= 0) {
				close_(fd);
				fd.close();
				return;
			}
			out_(buf[0..v]);
		}
		return &copy;
	}

	void setupPty(EventDispatcher ed, t_fd fd_i_source) {
		auto fd_pty_master = this.p.setupPty(StdFd.OUT);

		// We don't want to use the pty for subprocess stdin; interfacing works best and easiest if mplayer just takes our stdin and manipulates it however it feels is appropriate. The stdout pty is required, though, since it doesn't even try to manipulate stdin settings if that's not there.
		this.p.fd_i = 0;

		this.fd_o = ed.WrapFD(fd_pty_master);
		this.fd_o.setCallbacks(makeCopier(this.fd_o, this.oo, this.co));
		this.fd_o.AddIntent(IOI_READ);

		// Copy window size
		winsize wsz;
		ioctl(fd_i_source, TIOCGWINSZ, &wsz);
		ioctl(fd_pty_master, TIOCSWINSZ, &wsz);
	}

	void linkErr(EventDispatcher ed, t_fd fd_i_source) {
		auto fd_pty_master = this.p.fd_e; //FIXME
		//auto fd_pty_master = this.p.setupPty(StdFd.ERR);
		//winsize wsz;
		//ioctl(fd_i_source, TIOCGWINSZ, &wsz);
		//ioctl(fd_pty_master, TIOCSWINSZ, &wsz);

		this.fd_e = ed.WrapFD(fd_pty_master);
		this.fd_e.setCallbacks(makeCopier(this.fd_e, this.oe, this.ce));
		this.fd_e.AddIntent(IOI_READ);
	}

	SubProcess p;
	string[] argv;
	string sock_name;
	MPMaster mm;
	this(string argv_base[], string targets[]) {
		this.sock_name = format("/tmp/mpwrap.%d", getpid());
		this.argv = argv_base.dup;
		this.argv ~= ["--input-unix-socket", this.sock_name];
		this.argv ~= targets;
		this.p = new SubProcess();
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

	void start(EventDispatcher ed) {
		this.p.Spawn(this.argv);
		sleep(1);
		auto fd = this.pokeSock();
		logf(20, "Sock connect rv: %d", fd);
		this.mm = new MPMaster(ed.WrapFD(fd));
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

class MPMaster {
	FD sock;
	size_t bufsize;
	LineSplitter ls;
	this(FD sock) {
		this.sock = sock;
		this.bufsize = 1;
		this.ls = new LineSplitter();

		sock.setCallbacks(&this.processInput);
		sock.AddIntent(IOI_READ);
	}

	void processInput() {
		// Read input
		auto bsz = this.bufsize;
		char buf[];
		buf.length = bsz;

		auto fd = this.sock.fd;
		auto v = read(fd, buf.ptr, bsz);
		if (v <= 0) {
			close_(fd);
			this.sock.close();
			return;
		}
		this.ls.pushData(buf);

		auto lines = this.ls.popLines();
		foreach (line; lines) {
			logf(10, "mpv JSON: %s", line);
		}
	}
}

