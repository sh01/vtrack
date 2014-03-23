import core.stdc.errno;
import core.sys.posix.termios;
import core.time;
import std.stdio;
import std.string;

import eudorina.io;
import eudorina.logging;

import vtrack.mpwrap;

// This disables line-buffering on the specified terminal fd.
// Stdin typically is one in interactive use, and line-buffering is inappropriate for programs like mplayer.
void setBufs(t_fd fd) {
	termios tio;
	if (tcgetattr(fd, &tio)) {
		log(20, format("Unable to get terminal mode: %d", errno));
		return;
	}
	tio.c_lflag &= ~ICANON;
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 0;
	if (tcsetattr(fd, TCSANOW, &tio)) {
		log(20, format("Unable to set terminal mode: %d", errno));
		return;
	}
}

int main(string[] args) {
	SetupLogging();

	auto ed = new EventDispatcher();

	auto bw_stdout = new BufferWriter(ed, 1);
	auto bw_stderr = new BufferWriter(ed, 2);

	auto mprun = new MPRun(args[1..args.length], &bw_stdout.write, &bw_stderr.write);

	setBufs(0);
	mprun.setupPty(ed, 0);
	mprun.start(ed);
	mprun.linkErr(ed);

	ed.NewTimer(&mprun.copyTerm, dur!"msecs"(200));
	ed.Run();

	return 0;
}
