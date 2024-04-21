package hxia;

// The record carried inside a script artifact (a RESOURCES sidecar): the profile it was
// compiled under, the capability atoms it requests, the format/ABI versions, and an
// optional SDK surface hash. Read/written by hxia.ManifestIo.
typedef Manifest = {
	profile:String,
	requires:Array<String>,
	formatVersion:Int,
	abiLevel:Int,
	?sdkSurfaceHash:String,
}
