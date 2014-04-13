import core.stdc.errno;
import core.sys.posix.termios;
import core.sys.posix.unistd: read;
import core.sys.posix.sys.ioctl;

import eudorina.io;
import eudorina.logging;
import std.string;


alias void delegate(char[]) td_io_writer;
alias void delegate() td_voidfunc;

td_voidfunc makeCopier(size_t bufsize=1024)(FD fd, td_io_writer out_) {
	void copy() {
		char buf[bufsize];
		auto v = read(fd.fd, buf.ptr, bufsize);
		if (v <= 0) {
			fd.close();
			return;
		}
		out_(buf[0..v]);
	}
	return &copy;
}

class MPRun {
	string[] argv;
	SubProcess p;
	td_io_writer oo, oe;

	FD fd_o, fd_e; // subprocess stdio pipe ends

	this(string[] argv, td_io_writer oo, td_io_writer oe) {
		this.argv = argv;
		this.oo = oo;
		this.oe = oe;
		this.p = new SubProcess();
	}

	void setupPty(EventDispatcher ed, t_fd fd_i_source) {
		auto fd_pty_master = this.p.setupPty();
		auto fd_pty_slave = this.p.fd_o;

		// We don't want to use the pty for subprocess stdin; interfacing works best and easiest if mplayer just takes our stdin and manipulates it however it feels is appropriate. The stdout pty is required, though, since it doesn't even try to manipulate stdin settings if that's not there.
		this.p.fd_i = 0;

		this.fd_o = ed.WrapFD(fd_pty_master);
		this.fd_o.setCallbacks(makeCopier(this.fd_o, this.oo));
		this.fd_o.AddIntent(IOI_READ);

		// Copy window size
		winsize wsz;
		ioctl(fd_i_source, TIOCGWINSZ, &wsz);
		ioctl(fd_pty_master, TIOCSWINSZ, &wsz);
	}

	void linkErr(EventDispatcher ed, t_fd fd=-1) {
		if (fd == -1) fd = this.p.fd_e;
		this.fd_e = ed.WrapFD(this.p.fd_e);
		this.fd_e.setCallbacks(makeCopier(this.fd_e, this.oe));
		this.fd_e.AddIntent(IOI_READ);
	}

	void start(EventDispatcher ed) {
		this.p.Spawn(this.argv);
	}
}
