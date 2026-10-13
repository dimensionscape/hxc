package hxc.core;

import haxe.io.Bytes;
import haxe.io.BytesOutput;

// Zip writer for jars (write side only). The container differs from the one haxe.zip.Writer produces:
// every local header carries flag bit 3 with a zeroed CRC and zeroed sizes, and the real values follow
// the data in a data descriptor record.

typedef ZipEntry = {
	var filename:String;
	var stored:Bool;
	var time:Int;
	var date:Int;
	var crc:Int;
	var compressedSize:Int;
	var uncompressedSize:Int;
	var fileOffset:Int;
}

class ZipError {
	public var filename:String;
	public var entryname:String;
	public var message:String;

	public function new(filename:String, entryname:String, message:String) {
		this.filename = filename;
		this.entryname = entryname;
		this.message = message;
	}
}

class Zip {
	var filename:String;
	var comment:String;
	var o:BytesOutput;
	// Insertion order, which is the order the central directory lists the entries in.
	var entries:Array<ZipEntry> = [];

	public function new(filename:String, comment:String = "") {
		if (comment.length >= 0x10000) throw new ZipError(filename, "", "comment too long");
		this.filename = filename;
		this.comment = comment;
		o = new BytesOutput();
	}

	static function dostimeOfUnixtime(t:Date):{time:Int, date:Int} {
		return {
			time: (t.getSeconds() >> 1) + (t.getMinutes() << 5) + (t.getHours() << 11),
			date: t.getDate() + ((t.getMonth() + 1) << 5) + ((t.getFullYear() - 1980) << 9)
		};
	}

	inline function write2(v:Int) {
		o.writeByte(v & 0xFF);
		o.writeByte((v >> 8) & 0xFF);
	}

	inline function write4(v:Int) {
		o.writeByte(v & 0xFF);
		o.writeByte((v >> 8) & 0xFF);
		o.writeByte((v >> 16) & 0xFF);
		o.writeByte((v >>> 24) & 0xFF);
	}

	public function addEntry(data:Bytes, name:String, level:Int, mtime:Date):Void {
		if (level < 0 || level > 9) throw new ZipError(filename, name, "wrong compression level");
		var nameBytes = Bytes.ofString(name);
		if (nameBytes.length >= 0x10000) throw new ZipError(filename, name, "filename too long");
		var pos = o.length;
		write4(0x04034b50); // signature
		var version = level == 0 ? 10 : 20;
		write2(version); // version needed to extract
		write2(8); // flags
		write2(level == 0 ? 0 : 8); // method
		var dt = dostimeOfUnixtime(mtime);
		write2(dt.time); // last mod time
		write2(dt.date); // last mod date
		write4(0); // CRC32, zero here: the data descriptor carries it
		write4(0); // compressed size, in the data descriptor
		write4(0); // uncompressed size, in the data descriptor
		write2(nameBytes.length); // filename length
		write2(0); // extra length
		o.write(nameBytes); // filename
		var crc = haxe.crypto.Crc32.make(data);
		var payload = data;
		if (level != 0) {
			// the zip stores a bare deflate stream, so the zlib header and adler trailer come off
			var z = haxe.zip.Compress.run(data, level);
			payload = z.sub(2, z.length - 6);
		}
		o.write(payload);
		write4(0x08074b50); // signature
		write4(crc); // CRC
		write4(payload.length); // compressed size
		write4(data.length); // uncompressed size
		entries.push({
			filename: name,
			stored: level == 0,
			time: dt.time,
			date: dt.date,
			crc: crc,
			compressedSize: payload.length,
			uncompressedSize: data.length,
			fileOffset: pos
		});
	}

	function writeDirectoryEntry(e:ZipEntry) {
		write4(0x02014b50); // signature
		var version = e.stored ? 10 : 20;
		write2(version); // version made by
		write2(version); // version needed to extract
		write2(8); // flags
		write2(e.stored ? 0 : 8); // method
		write2(e.time); // last mod time
		write2(e.date); // last mod date
		write4(e.crc); // CRC32
		write4(e.compressedSize); // compressed size
		write4(e.uncompressedSize); // uncompressed size
		var nameBytes = Bytes.ofString(e.filename);
		write2(nameBytes.length); // filename length
		write2(0); // extra length
		write2(0); // comment length
		write2(0); // disk number start
		write2(0); // internal attributes
		write4(0); // external attributes
		write4(e.fileOffset); // offset of local header
		o.write(nameBytes); // filename
	}

	public function close():Bytes {
		var startCd = o.length;
		for (e in entries) writeDirectoryEntry(e);
		var cdSize = o.length - startCd;
		var numEntries = entries.length;
		if (numEntries >= 0x10000) throw new ZipError(filename, "", "too many entries");
		write4(0x06054b50); // signature
		write2(0); // disk number
		write2(0); // number of disk with central dir
		write2(numEntries); // # entries in this disk
		write2(numEntries); // # entries in central dir
		write4(cdSize); // size of central dir
		write4(startCd); // offset of central dir
		var commentBytes = Bytes.ofString(comment);
		write2(commentBytes.length); // length of comment
		o.write(commentBytes); // comment
		return o.getBytes();
	}
}
