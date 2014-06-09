import eudorina.logging;
import eudorina.text;

import std.format: to;
import std.regex;
import std.string: format, strip;

class FN {
private:
	static auto RE_PARTIAL = ctRegex!r"^(.*)\.part$";
	static auto RE_EXT = ctRegex!r"^(.*)\.([a-zA-Z0-9]{0,3})$";
	static auto RE_CRC32_END = ctRegex!r"^(.*)([\[(][a-f0-9A-F]{8}[\]\)])(.*)$";
	static auto RE_CRC32 = ctRegex!r"^(.*)([\[(][a-f0-9A-F]{8}[\]\)])$";
	static auto RE_GROUP_START = ctRegex!r"^[\[(]([^\]\)]*)[\]\)](.*)$";
	static auto RE_SCHAR_START = ctRegex!r"^([^\[\]()]*)(.*)$";
	static auto RE_NUM = ctRegex!r"(^|[^A-Za-z0-9]|[Ee][Pp]?|SP|s)([0-9]+)(v[0-9]+[a-z]?)?([^A-Za-z0-9]|$)";
public:
	string fn;
	bool done;
	string ext, crc32, group, meta_misc, base, ver;
	int idx = -1;
	this(string fn) {
		this.fn = fn;
		this.parseFields();
	}
	bool okExt() {
		return ((this.ext == "mkv") || (this.ext == "ogm") || (this.ext == "mp4") || (this.ext == "avi"));
	}
	bool okToAdd() {
		return this.done && (this.idx > 0) && this.okExt();
	}
	override string toString() {
		return format("FN(%d; %d; %s %s %s; %s %s %s)", this.done, this.idx, cescape(this.ext), cescape(this.base), cescape(this.group), cescape(this.crc32), this.meta_misc, cescape(this.ver));
	}

	void parseFields() {
		string r = this.fn;
		// Identify trailing partial download indicator, and strip if present
		auto m = matchFirst(fn, RE_PARTIAL);
		this.done = (m.length == 0) && (this.fn.length > 0) && (this.fn[0] != '.');
		if (m.length > 0) r = m[1];
		// Identify traditional windows file extension and strip if present.
		m = matchFirst(r, RE_EXT);
		if (m.length > 0) {
			this.ext = m[2];
			r = m[1];
		}
		// Many filenames have embedded CRC32 values; see if we can find and remove it.
		m = matchFirst(r, RE_CRC32_END);
		if (m.length > 0) {
			this.crc32 = m[2];
			r = m[1];
		} else {
			// Not at the end. See if we can find it at an earlier point, then; this is rare, but does happen occasionally (whereas false-positive crc32 matches remain theoretical).
			m = matchFirst(r, RE_CRC32);
			if (m.length > 0) {
				this.crc32 = m[2];
				r = m[1] ~ m[3];
			}
		}
		// See if we can find a supplier/group id. Usually these are at the start - typically delineated by brackets, but some use parens instead.
		// If it's not at the beginning, it's easy to mix up with other metadata, and we should probably leave it out.
  		m = matchFirst(r, RE_GROUP_START);
		if (m.length > 0) {
			this.group = m[1];
			r = strip(m[2]);
		}
		// ...and some people put some more metadata brackets right at the beginning, too.
		while (true) {
			m = matchFirst(r, RE_GROUP_START);
			if (m.length > 0) {
				this.meta_misc ~= m[1];
				r = strip(m[2]);
			} else {
				break;
			}
		}
		// Sometimes there's various other pieces of metadata after the main id string, typically again containing brackets, parens or similar. We try to split it off, though this stuff is too heterogenous for us to try to parse it.
		m = matchFirst(r, RE_SCHAR_START);
		if (m.length > 0) {
			this.meta_misc ~= m[2];
			r = m[1];
		}
		this.base = strip(r);
		auto ms = matchAll(r, RE_NUM);
		
		foreach (m2; ms) {
			if (m2.length > 0) {
				this.idx = to!int(m2[2]);
				if (m2.length > 1) this.ver = m2[3];
			}
		}
	}
}
