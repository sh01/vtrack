import core.stdc.errno;
import core.sys.posix.termios;
import core.sys.posix.unistd;
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
			fd.Close();
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

	FD fd_o, fd_e, fd_i; // subprocess stdio pipe ends
    FD fd_i_s; // data source to copy to subprocess stdin

	this(string[] argv, td_io_writer oo, td_io_writer oe) {
		this.argv = argv;
		this.oo = oo;
		this.oe = oe;
		this.p = new SubProcess();
	}

	void copyTerm() {
		termios tio;
		if (tcgetattr(this.fd_i.fd, &tio)) {
			log(20, format("Unable to get terminal mode: %d", errno));
			return;
		}

		tio.c_lflag &= ~ICANON;
		tio.c_cc[VMIN] = 0;
		tio.c_cc[VTIME] = 0;
		
		if (tcsetattr(this.fd_i_s.fd, TCSANOW, &tio)) {
			log(20, format("Unable to set terminal mode: %d", errno));
			return;
		}
		if (tcsetattr(this.fd_i.fd, TCSANOW, &tio)) {
			log(20, format("Unable to set terminal mode: %d", errno));
			return;
		}
	}

	void setupPty(EventDispatcher ed, t_fd fd_i_source) {
		auto fd_pty_master = this.p.setupPty();
		auto fd_pty_slave = this.p.fd_i;
		
		auto bw_stdin = new BufferWriter(ed, fd_pty_master);

		this.fd_i_s = ed.WrapFD(fd_i_source);
		this.fd_i_s.setCallbacks(makeCopier(this.fd_i_s, &bw_stdin.write));
		this.fd_i_s.AddIntent(IOI_READ);

		this.fd_i = bw_stdin.fd;
		this.fd_o = bw_stdin.fd;
		this.fd_o.setCallbacks(makeCopier(this.fd_o, this.oo));
		this.fd_o.AddIntent(IOI_READ);

		// Copy window size
		winsize wsz;
		ioctl(fd_i_source, TIOCGWINSZ, &wsz);
		ioctl(fd_pty_master, TIOCSWINSZ, &wsz);
	}

	void linkInput(EventDispatcher ed, t_fd fd, t_fd fd_slave=-1) {
		if (fd_slave == -1) fd_slave = this.p.fd_i;
		this.fd_i = ed.WrapFD(fd);
		auto bw_stdin = new BufferWriter(ed, fd_slave);
		this.fd_i.setCallbacks(makeCopier(this.fd_i, &bw_stdin.write));
		this.fd_i.AddIntent(IOI_READ);
	}

	void linkOut(EventDispatcher ed, t_fd fd=-1) {
		if (fd == -1) fd = this.p.fd_o;
		this.fd_o = ed.WrapFD(fd);
		this.fd_o.setCallbacks(makeCopier(this.fd_o, this.oo));
		this.fd_o.AddIntent(IOI_READ);
	}

	void linkErr(EventDispatcher ed, t_fd fd=-1) {
		if (fd == -1) fd = this.p.fd_e;
		this.fd_e = ed.WrapFD(this.p.fd_e);
		this.fd_e.setCallbacks(makeCopier(this.fd_e, this.oe));
		this.fd_e.AddIntent(IOI_READ);
	}

	void start(EventDispatcher ed) {
		//this.p.ctl_term = 0;
		this.p.Spawn(this.argv);
	}
}
