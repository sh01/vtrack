import std.file;
import std.path;

import eudorina.text;
import eudorina.logging;

import vtrack.h_fnparse;

void addFile(string[] *arr, size_t idx, string path) {
	if (arr.length <= idx) {
		arr.length = idx + 1;
	} else if ((*arr)[idx] != "") {
		return;
	}
	(*arr)[idx] = path;
}


class SubLinker {
	string dir, video_ext;
	string[] videos;
	string[] subs;
	this(string dir, string video_ext) {
		this.dir = dir;
		this.video_ext = video_ext;
	}
	void scan() {
		foreach (string fpn; dirEntries(this.dir, SpanMode.shallow)) {
			auto fn = new FN(baseName(fpn));
		 	if (!fn.okToAdd()) {
				logf(20, "Ignoring: %s", fn);
				continue;
			}
			auto idx = fn.idx;
			if (fn.ext == this.video_ext) {
				logf(20, "Video %d: %s", idx, fpn);
				addFile(&this.videos, idx, fpn);
				continue;
			}
			if (fn.okExtSub()) {
				logf(20, "Sub %d: %s", idx, fpn);
				addFile(&this.subs, idx, fpn);
				continue;
			}
		}
	}
	void linkSubs() {
		auto count = this.videos.length;
		if (this.subs.length < count) count = this.subs.length;
		for (size_t i = 0; i < count; i++) {
			auto vp = this.videos[i];
			auto sp = this.subs[i];
			if ((vp == "") || (sp == "")) {
				continue;
			}
			auto vfn = new FN(baseName(vp));
			auto sfn = new FN(baseName(sp));

			auto vbn = baseName(vp, vfn.ext);
			auto sub_dstf = vbn ~ sfn.ext;
			auto sub_dstp = buildPath(this.dir, sub_dstf);

			if (seePath(sub_dstp)) {
				logf(20, "Exists, skipped: %s", sub_dstp);
				continue;
			}
			logf(20, "Linking: %s -> %s", sfn.fn, sub_dstf);
			symlink(sfn.fn, sub_dstp);
		}
	}
}

int main(string[] args) {
	SetupLogging();
	auto video_ext = args[1];
	auto path = args[2];
	auto sl = new SubLinker(expandTilde(path), video_ext);
	sl.scan();
	sl.linkSubs();
	return 0;
}
