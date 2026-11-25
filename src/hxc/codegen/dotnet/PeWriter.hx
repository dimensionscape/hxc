package hxc.codegen.dotnet;

import haxe.io.Bytes;

// The PE32 image around the IL and metadata (ECMA-335 II.25): headers, a .text section holding the
// IAT, CLI header, IL, metadata, manifest resources, debug directory, mscoree import and entry stub, and a
// .reloc section fixing up the stub. The MVID and timestamp come from a SHA-256 of the image, as in Roslyn's
// deterministic mode.

// The PDB the debug directory names: its file name, its 20-byte id (a GUID and a stamp) and its SHA-256.
typedef DebugDirectory = {pdbName:String, pdbId:Bytes, pdbHash:Bytes}

class PeWriter {
	// Where `il` starts: right after the 8-byte IAT and the 72-byte CLI header.
	public static inline var IL_RVA = 0x2050;

	static inline var TEXT_RVA = 0x2000;
	static inline var CLI_HEADER_RVA = 0x2008;
	static inline var CLI_HEADER_SIZE = 72;
	static inline var FILE_ALIGNMENT = 0x200;
	static inline var SECTION_ALIGNMENT = 0x2000;
	static inline var HEADERS_SIZE = 0x200;
	static inline var TIMESTAMP_OFFSET = 0x88;
	static inline var DEBUG_ENTRY_SIZE = 28;

	// The DOS header and stub of II.25.2.1; e_lfanew points at the PE signature at 0x80.
	static final dosHeader = Bytes.ofHex("4d5a90000300000004000000ffff0000b8000000000000004000000000000000"
		+ "0000000000000000000000000000000000000000000000000000000080000000"
		+ "0e1fba0e00b409cd21b8014ccd21546869732070726f6772616d2063616e6e6f"
		+ "742062652072756e20696e20444f53206d6f64652e0d0d0a2400000000000000");

	static inline function alignUp(v:Int, n:Int):Int {
		return (v + n - 1) & ~(n - 1);
	}

	// The debug directory (PE-COFF.md beside the Portable PDB spec) at `rva`, whose file position is
	// `rva - delta`: CodeView, PdbChecksum and Reproducible entries, in that order as Roslyn writes them,
	// then the first two's data.
	static function debugDirectory(d:DebugDirectory, rva:Int, delta:Int):Bytes {
		var name = Bytes.ofString(d.pdbName);
		var codeViewRva = rva + 3 * DEBUG_ENTRY_SIZE;
		var codeViewSize = 24 + name.length + 1;
		var checksumRva = alignUp(codeViewRva + codeViewSize, 4);
		var checksumSize = 7 + d.pdbHash.length;
		var b = new IlBytes();
		function entry(stamp:Int, major:Int, minor:Int, type:Int, size:Int, dataRva:Int) {
			b.u32(0);
			b.u32(stamp);
			b.u16(major);
			b.u16(minor);
			b.u32(type);
			b.u32(size);
			b.u32(dataRva);
			b.u32(size == 0 ? 0 : dataRva - delta);
		}
		// A portable CodeView entry's stamp is the id's last 4 bytes.
		entry(d.pdbId.getInt32(16), 0x0100, 0x504D, 2, codeViewSize, codeViewRva);
		entry(0, 1, 0, 19, checksumSize, checksumRva);
		entry(0, 0, 0, 16, 0, 0);
		b.bytes(Bytes.ofString("RSDS"));
		b.bytes(d.pdbId.sub(0, 16));
		b.u32(1); // age
		b.bytes(name);
		b.u8(0);
		b.align(4);
		b.bytes(Bytes.ofString("SHA256"));
		b.u8(0);
		b.bytes(d.pdbHash);
		return b.getBytes();
	}

	public static function write(img:{
		metadata:Bytes,
		mvidOffset:Int,
		il:Bytes,
		resources:Bytes,
		entryPoint:Int,
		isDll:Bool,
		debug:Null<DebugDirectory>
	}):Bytes {
		var imageBase = img.isDll ? 0x10000000 : 0x400000;
		var metadataRva = alignUp(IL_RVA + img.il.length, 4);
		// The resources blob follows the metadata, as Roslyn places it; with none, nothing moves.
		var resourcesRva = alignUp(metadataRva + img.metadata.length, 4);
		// The debug directory follows the resources; without one, nothing moves.
		var debugRva = alignUp(resourcesRva + img.resources.length, 4);
		var debug = img.debug == null ? Bytes.alloc(0) : debugDirectory(img.debug, debugRva, TEXT_RVA - HEADERS_SIZE);
		var importRva = alignUp(debugRva + debug.length, 4);
		var lookupRva = importRva + 40;
		var hintNameRva = lookupRva + 8;
		var dllNameRva = hintNameRva + 14;
		var stubRva = dllNameRva + 12;
		// The stub's operand, two bytes in, must be 4-aligned.
		while ((stubRva + 2) & 3 != 0) stubRva++;
		var textEnd = stubRva + 6;
		var textSize = textEnd - TEXT_RVA;
		var textRawSize = alignUp(textSize, FILE_ALIGNMENT);
		var relocRva = alignUp(textEnd, SECTION_ALIGNMENT);
		var relocSize = 12;
		var relocRawSize = alignUp(relocSize, FILE_ALIGNMENT);
		var imageSize = relocRva + alignUp(relocSize, SECTION_ALIGNMENT);

		var b = new IlBytes();
		b.bytes(dosHeader);
		b.u32(0x4550); // "PE\0\0"
		// COFF header; the timestamp is patched in last.
		b.u16(0x14C);
		b.u16(2);
		b.u32(0);
		b.u32(0);
		b.u32(0);
		b.u16(0xE0);
		b.u16(img.isDll ? 0x2102 : 0x0102);
		// PE32 optional header: standard fields, then the NT-specific ones.
		b.u16(0x10B);
		b.u8(48);
		b.u8(0);
		b.u32(textRawSize);
		b.u32(relocRawSize);
		b.u32(0);
		b.u32(stubRva);
		b.u32(TEXT_RVA);
		b.u32(relocRva);
		b.u32(imageBase);
		b.u32(SECTION_ALIGNMENT);
		b.u32(FILE_ALIGNMENT);
		b.u16(4); // OS version
		b.u16(0);
		b.u16(0); // image version
		b.u16(0);
		b.u16(4); // subsystem version
		b.u16(0);
		b.u32(0);
		b.u32(imageSize);
		b.u32(HEADERS_SIZE);
		b.u32(0); // checksum
		b.u16(3); // console subsystem
		b.u16(0x8540); // dynamic base, NX compatible, no SEH, terminal-server aware
		b.u32(0x100000);
		b.u32(0x1000);
		b.u32(0x100000);
		b.u32(0x1000);
		b.u32(0);
		b.u32(16);
		// Data directories: import, base relocation, debug (with -debug), IAT and CLI header are set.
		function dir(rva:Int, size:Int) {
			b.u32(rva);
			b.u32(size);
		}
		dir(0, 0);
		dir(importRva, dllNameRva + 12 - importRva);
		for (_ in 0...3) dir(0, 0);
		dir(relocRva, relocSize);
		if (img.debug == null) dir(0, 0) else dir(debugRva, 3 * DEBUG_ENTRY_SIZE);
		for (_ in 0...5) dir(0, 0);
		dir(TEXT_RVA, 8);
		dir(0, 0);
		dir(CLI_HEADER_RVA, CLI_HEADER_SIZE);
		dir(0, 0);
		function section(name:String, size:Int, rva:Int, rawSize:Int, rawPos:Int, flags:Int) {
			var n = Bytes.alloc(8);
			n.fill(0, 8, 0);
			n.blit(0, Bytes.ofString(name), 0, name.length);
			b.bytes(n);
			b.u32(size);
			b.u32(rva);
			b.u32(rawSize);
			b.u32(rawPos);
			b.u32(0);
			b.u32(0);
			b.u32(0);
			b.u32(flags);
		}
		section(".text", textSize, TEXT_RVA, textRawSize, HEADERS_SIZE, 0x60000020);
		section(".reloc", relocSize, relocRva, relocRawSize, HEADERS_SIZE + textRawSize, 0x42000040);
		b.align(HEADERS_SIZE);

		// .text, whose RVA is its file position plus `delta`.
		var delta = TEXT_RVA - HEADERS_SIZE;
		function at(rva:Int) {
			if (b.length + delta != rva) throw "PE layout mismatch at " + StringTools.hex(rva);
		}
		b.u32(hintNameRva); // IAT
		b.u32(0);
		at(CLI_HEADER_RVA);
		b.u32(CLI_HEADER_SIZE);
		b.u16(2);
		b.u16(5);
		b.u32(metadataRva);
		b.u32(img.metadata.length);
		b.u32(1); // COMIMAGE_FLAGS_ILONLY
		b.u32(img.entryPoint);
		var hasResources = img.resources.length > 0;
		b.u32(hasResources ? resourcesRva : 0);
		b.u32(img.resources.length);
		for (_ in 0...10) b.u32(0); // strong name, code manager, vtable fixups, exports, native header
		at(IL_RVA);
		b.bytes(img.il);
		b.align(4);
		at(metadataRva);
		var metadataPos = b.length;
		b.bytes(img.metadata);
		b.align(4);
		at(resourcesRva);
		b.bytes(img.resources);
		b.align(4);
		at(debugRva);
		b.bytes(debug);
		b.align(4);
		at(importRva);
		b.u32(lookupRva);
		b.u32(0);
		b.u32(0);
		b.u32(dllNameRva);
		b.u32(TEXT_RVA);
		for (_ in 0...5) b.u32(0);
		b.u32(hintNameRva); // import lookup table
		b.u32(0);
		b.u16(0);
		b.bytes(Bytes.ofString(img.isDll ? "_CorDllMain" : "_CorExeMain"));
		b.u8(0);
		at(dllNameRva);
		b.bytes(Bytes.ofString("mscoree.dll"));
		b.u8(0);
		while (b.length + delta < stubRva) b.u8(0);
		b.u8(0xFF);
		b.u8(0x25);
		b.u32(imageBase + TEXT_RVA);
		b.align(FILE_ALIGNMENT);

		// .reloc: one block holding the stub operand's HIGHLOW fixup and a padding entry.
		var fixup = stubRva + 2;
		b.u32(fixup & ~0xFFF);
		b.u32(relocSize);
		b.u16((3 << 12) | (fixup & 0xFFF));
		b.u16(0);
		b.align(FILE_ALIGNMENT);

		var image = b.getBytes();
		var hash = haxe.crypto.Sha256.make(image);
		var mvidPos = metadataPos + img.mvidOffset;
		image.blit(mvidPos, hash, 0, 16);
		image.set(mvidPos + 7, (hash.get(7) & 0x0F) | 0x40);
		image.set(mvidPos + 8, (hash.get(8) & 0x3F) | 0x80);
		image.setInt32(TIMESTAMP_OFFSET, hash.getInt32(16) | 0x80000000);
		return image;
	}
}
