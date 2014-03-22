import core.stdc.errno;
import core.sys.posix.termios;
import std.stdio;
import std.string;

import eudorina.io;
import eudorina.logging;

import vtrack.mpwrap;

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
	mprun.start(ed);

	setBufs(0);
	stdin.setvbuf(0, _IONBF);
	mprun.linkInput(ed, 0);

	ed.Run();

	return 0;
}
