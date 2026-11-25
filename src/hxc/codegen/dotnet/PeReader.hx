package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.codegen.dotnet.PeData;

// reads the PE headers of an assembly and locates its CLI header.
class PeReader {
	// the machine types the reference knows; any other one is an assertion failure there.
	static function machineTypeOfInt(i:Int):Int {
		return switch (i) {
			case 0x0 | 0x014c | 0x0162 | 0x0166 | 0x0168 | 0x0169 | 0x0184 | 0x01a2 | 0x01a3 | 0x01a4 | 0x01a6 | 0x01a8
				| 0x01c0 | 0x01c2 | 0x01c4 | 0xaa64 | 0xebc | 0x01d3 | 0x01f0 | 0x01f1 | 0x0200 | 0x0266 | 0x0284
				| 0x0366 | 0x0466 | 0x0520 | 0x8664 | 0x9041 | 0xC020 | 0xFD1D:
				i;
			case _: throw "Assertion failed: unknown machine type " + i;
		}
	}

	static function subsystemOfInt(i:Int):Int {
		return switch (i) {
			case 0 | 1 | 2 | 3 | 7 | 9 | 10 | 11 | 12 | 13 | 14: i;
			case _: throw new PeErrorMessage("Unknown subsystem " + i);
		}
	}

	static function peMagicOfInt(i:Int):PeMagic {
		return switch (i) {
			case 0x10b: P32;
			case 0x107: PRom;
			case 0x20b: P64;
			case _: throw new PeErrorMessage("Unknown PE magic number: " + i);
		}
	}

	static function getDir(idx:Int, pe:PeFile):DataDir {
		var dirs = pe.peHeader.dataDirs;
		if (idx < 0 || idx >= dirs.length)
			throw new PeErrorMessage("The directory '" + DirectoryType.name(idx) + "' of index '" + idx + "' is required but is missing on this file");
		return dirs[idx];
	}

	static inline function readRva(i:PeInput):Int return i.readI32();

	static function readWord(is64:Bool, i:PeInput):haxe.Int64 {
		if (is64) return i.readI64();
		return haxe.Int64.make(0, i.readI32());
	}

	static function readCoffHeader(i:PeInput):CoffHeader {
		var machine = machineTypeOfInt(i.readUi16());
		var nsections = i.readUi16();
		var stamp = i.readI32();
		var symbolTablePointer = readRva(i);
		var nsymbols = i.readI32();
		var optheaderSize = i.readUi16();
		var props = i.readUi16();
		return {
			machine: machine,
			nsections: nsections,
			timestamp: stamp,
			symbolTablePointer: symbolTablePointer,
			nsymbols: nsymbols,
			optheaderSize: optheaderSize,
			props: props,
		};
	}

	static function readPeHeader(i:PeInput, header:CoffHeader):PeHeader {
		var sectionsOffset = i.pos + header.optheaderSize;
		var magic = peMagicOfInt(i.readUi16());
		var major = i.readByte();
		var minor = i.readByte();
		var codeSize = i.readI32();
		var initSize = i.readI32();
		var uinitSize = i.readI32();
		var entryAddr = readRva(i);
		var baseCode = readRva(i);
		var is64 = magic == P64;
		var baseData = is64 ? 0 : readRva(i);

		// COFF Windows extension
		var imageBase = readWord(is64, i);
		var sectionAlignment = i.readI32();
		var fileAlignment = i.readI32();
		var majorOsver = i.readUi16();
		var minorOsver = i.readUi16();
		var majorImgver = i.readUi16();
		var minorImgver = i.readUi16();
		var majorSubsysver = i.readUi16();
		var minorSubsysver = i.readUi16();
		i.readI32(); // reserved
		var imageSize = i.readI32();
		var headersSize = i.readI32();
		var checksum = i.readI32();
		var subsystem = subsystemOfInt(i.readUi16());
		var dllProps = i.readUi16();
		var stackReserve = readWord(is64, i);
		var stackCommit = readWord(is64, i);
		var heapReserve = readWord(is64, i);
		var heapCommit = readWord(is64, i);
		i.readI32(); // reserved
		var ndataDir = i.readI32();
		var dataDirs = [for (_ in 0...ndataDir) {
			var addr = readRva(i);
			var size = readRva(i);
			{addr: addr, size: size};
		}];
		i.pos = sectionsOffset;
		var sections = [for (_ in 0...header.nsections) {
			var raw = i.nread(8);
			var len = 0;
			while (len < 8 && raw.get(len) != 0) len++;
			var name = raw.getString(0, len);
			var vsize = readRva(i);
			var vaddr = readRva(i);
			var rawSize = readRva(i);
			var rawPointer = i.readI32();
			var relocPointer = i.readI32();
			var lineNumPointer = i.readI32();
			var nrelocs = i.readUi16();
			var nlineNums = i.readUi16();
			var props = readRva(i);
			{
				name: name,
				vsize: vsize,
				vaddr: vaddr,
				rawSize: rawSize,
				rawPointer: rawPointer,
				relocPointer: relocPointer,
				lineNumPointer: lineNumPointer,
				nrelocs: nrelocs,
				nlineNums: nlineNums,
				props: props,
			};
		}];
		return {
			coffHeader: header,
			magic: magic,
			major: major,
			minor: minor,
			codeSize: codeSize,
			initSize: initSize,
			uinitSize: uinitSize,
			entryAddr: entryAddr,
			baseCode: baseCode,
			baseData: baseData,
			imageBase: imageBase,
			sectionAlignment: sectionAlignment,
			fileAlignment: fileAlignment,
			majorOsver: majorOsver,
			minorOsver: minorOsver,
			majorImgver: majorImgver,
			minorImgver: minorImgver,
			majorSubsysver: majorSubsysver,
			minorSubsysver: minorSubsysver,
			imageSize: imageSize,
			headersSize: headersSize,
			checksum: checksum,
			subsystem: subsystem,
			dllProps: dllProps,
			stackReserve: stackReserve,
			stackCommit: stackCommit,
			heapReserve: heapReserve,
			heapCommit: heapCommit,
			ndataDir: ndataDir,
			dataDirs: dataDirs,
			sections: sections,
		};
	}

	// converts an RVA into a file offset.
	public static function convertRva(pe:PeFile, rva:Int):Int {
		var sections = pe.peHeader.sections;
		var n = 0;
		while (true) {
			if (n >= sections.length) throw new PeErrorMessage("The RVA " + StringTools.hex(rva).toLowerCase() + " is outside sections bounds!");
			var sec = sections[n];
			if (rva >= sec.vaddr && rva < sec.vaddr + sec.rawSize)
				return sec.rawPointer + (rva - sec.vaddr);
			n++;
		}
	}

	public static function seekRva(pe:PeFile, rva:Int):Void {
		pe.input.pos = convertRva(pe, rva);
	}

	public static function readClrHeader(pe:PeFile):ClrHeader {
		var dir = getDir(DirectoryType.ClrRuntimeHeader, pe);
		if (dir.addr == 0 || dir.size == 0) throw new PeErrorMessage("This PE file does not have managed content");
		seekRva(pe, dir.addr);
		var i = pe.input;
		var cb = i.readI32();
		var major = i.readUi16();
		var minor = i.readUi16();
		function readTbl():DataDir {
			var rva = readRva(i);
			var size = i.readI32();
			return {addr: rva, size: size};
		}
		var meta = readTbl();
		var corflags = i.readI32();
		var entryPoint = readRva(i);
		var res = readTbl();
		var clrsig = readTbl();
		var codeman = readTbl();
		var vtableFix = readTbl();
		var exportAddr = readTbl();
		return {
			cb: cb,
			major: major,
			minor: minor,
			meta: meta,
			flags: corflags,
			entryPoint: entryPoint,
			res: res,
			sig: clrsig,
			codeman: codeman,
			vtableFix: vtableFix,
			exportAddress: exportAddr,
		};
	}

	public static function read(bytes:Bytes):PeFile {
		var i = new PeInput(bytes);
		if (i.readByte() != "M".code || i.readByte() != "Z".code)
			throw new PeErrorMessage("MZ magic header not found: Is the target file really a PE?");
		i.pos = 0x3c;
		var peSigOffset = i.readI32();
		i.pos = peSigOffset;
		var sig = i.nread(4);
		if (sig.get(0) != "P".code || sig.get(1) != "E".code || sig.get(2) != 0 || sig.get(3) != 0)
			throw new PeErrorMessage("Invalid PE header signature: PE expected");
		var header = readCoffHeader(i);
		var peHeader = readPeHeader(i, header);
		return {input: i, peHeader: peHeader};
	}
}
