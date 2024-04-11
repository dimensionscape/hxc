package hxia;

// The scoped authority atoms a script may request and a host may grant.
enum Capability {
	FsRead(pathPrefix:String);
	FsWrite(pathPrefix:String);
	NetClient(hostPattern:String);
	NetServer(portRange:String);
	Proc; // Unscoped; nullifies fs/net scopes
	Env(namePrefix:String);
	SysInfo;
	// No `thread` in v1: concurrency is host-owned, not a portable atom
}
