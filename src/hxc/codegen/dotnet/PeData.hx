package hxc.codegen.dotnet;

import haxe.io.Bytes;

// the parts of a PE file the CLI metadata reader needs: headers, data directories and sections.

typedef CoffHeader = {
	machine:Int,
	nsections:Int,
	timestamp:Int,
	symbolTablePointer:Int,
	nsymbols:Int,
	optheaderSize:Int,
	props:Int,
};

typedef PeSection = {
	name:String,
	vsize:Int,
	vaddr:Int,
	rawSize:Int,
	rawPointer:Int,
	relocPointer:Int,
	lineNumPointer:Int,
	nrelocs:Int,
	nlineNums:Int,
	props:Int,
};

typedef DataDir = {addr:Int, size:Int};

enum PeMagic {
	P32;
	PRom;
	P64;
}

typedef PeHeader = {
	coffHeader:CoffHeader,
	magic:PeMagic,
	major:Int,
	minor:Int,
	codeSize:Int,
	initSize:Int,
	uinitSize:Int,
	entryAddr:Int,
	baseCode:Int,
	baseData:Int,
	imageBase:haxe.Int64,
	sectionAlignment:Int,
	fileAlignment:Int,
	majorOsver:Int,
	minorOsver:Int,
	majorImgver:Int,
	minorImgver:Int,
	majorSubsysver:Int,
	minorSubsysver:Int,
	imageSize:Int,
	headersSize:Int,
	checksum:Int,
	subsystem:Int,
	dllProps:Int,
	stackReserve:haxe.Int64,
	stackCommit:haxe.Int64,
	heapReserve:haxe.Int64,
	heapCommit:haxe.Int64,
	ndataDir:Int,
	dataDirs:Array<DataDir>,
	sections:Array<PeSection>,
};

typedef ClrHeader = {
	cb:Int,
	major:Int,
	minor:Int,
	meta:DataDir,
	flags:Int,
	entryPoint:Int,
	res:DataDir,
	sig:DataDir,
	codeman:DataDir,
	vtableFix:DataDir,
	exportAddress:DataDir,
};

typedef ClrStreamHeader = {offset:Int, size:Int, name:String};

// the file and a read position over it, like the reference's channel.
class PeInput {
	public var bytes(default, null):Bytes;
	public var pos:Int = 0;

	public function new(bytes:Bytes) {
		this.bytes = bytes;
	}

	inline function need(n:Int):Void {
		if (pos < 0 || pos + n > bytes.length) throw "No more input";
	}

	public function readByte():Int {
		need(1);
		return bytes.get(pos++);
	}

	public function readUi16():Int {
		need(2);
		var v = bytes.getUInt16(pos);
		pos += 2;
		return v;
	}

	public function readI32():Int {
		need(4);
		var v = bytes.getInt32(pos);
		pos += 4;
		return v;
	}

	public function readI64():haxe.Int64 {
		need(8);
		var v = bytes.getInt64(pos);
		pos += 8;
		return v;
	}

	public function nread(n:Int):Bytes {
		need(n);
		var b = bytes.sub(pos, n);
		pos += n;
		return b;
	}

	public function nreadString(n:Int):String {
		return nread(n).getString(0, n);
	}
}

// the reference's PeReader.Error_message, which its compiler prints as the raw exception.
class PeErrorMessage extends haxe.Exception {
	public function new(msg:String) {
		super('PeReader.Error_message("' + msg + '")');
	}
}

typedef PeFile = {
	input:PeInput,
	peHeader:PeHeader,
};

// the data directory indices and the names the missing-directory error uses.
class DirectoryType {
	public static inline var ImportTable = 1;
	public static inline var ClrRuntimeHeader = 14;

	public static function name(idx:Int):String {
		return switch (idx) {
			case 0: "ExportTable";
			case 1: "ImportTable";
			case 2: "ResourceTable";
			case 3: "ExceptionTable";
			case 4: "CertificateTable";
			case 5: "RelocTable";
			case 6: "DebugTable";
			case 7: "ArchTable";
			case 8: "GlobalPointer";
			case 9: "TlsTable";
			case 10: "LoadConfigTable";
			case 11: "BuildImportTable";
			case 12: "ImportAddressTable";
			case 13: "DelayImport";
			case 14: "ClrRuntimeHeader";
			case 15: "Reserved";
			case i: "Custom" + i;
		}
	}
}
