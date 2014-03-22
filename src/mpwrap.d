import core.sys.posix.unistd;

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

	FD fd_i, fd_o, fd_e;

	this(string[] argv, td_io_writer oo, td_io_writer oe) {
		this.argv = argv;
		this.oo = oo;
		this.oe = oe;
		this.p = new SubProcess();
	}

	void linkInput(EventDispatcher ed, t_fd fd) {
		this.fd_i = ed.WrapFD(fd);
		auto bw_stdin = new BufferWriter(ed, this.p.fd_i);
		this.fd_i.setCallbacks(makeCopier(this.fd_i, &bw_stdin.write));
		this.fd_i.AddIntent(IOI_READ);
	}

	void start(EventDispatcher ed) {
		this.p.Spawn(this.argv);
		this.fd_o = ed.WrapFD(this.p.fd_o);
		this.fd_o.setCallbacks(makeCopier(this.fd_o, this.oo));
		this.fd_o.AddIntent(IOI_READ);

		this.fd_e = ed.WrapFD(this.p.fd_e);
		this.fd_e.setCallbacks(makeCopier(this.fd_e, this.oe));
		this.fd_e.AddIntent(IOI_READ);
	}
}
