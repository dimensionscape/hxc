package hxc.eval;

// The id of each name the interpreter hashes as a literal. EvalHash gives ids out in first-seen order, so
// a name is hashed where it is first used, as the plain call would have hashed it, and kept from then on.
// Each is kept as id + 1: the zero a static holds before any initializer runs means not hashed yet.
class EvalNames {
	static var hDollarCache:Int = 0;

	public static function hDollar():Int {
		if (hDollarCache == 0) hDollarCache = EvalHash.hash("$") + 1;
		return hDollarCache - 1;
	}

	static var hArrayTypeCache:Int = 0;

	public static function hArrayType():Int {
		if (hArrayTypeCache == 0) hArrayTypeCache = EvalHash.hash("Array") + 1;
		return hArrayTypeCache - 1;
	}

	static var hDateCache:Int = 0;

	public static function hDate():Int {
		if (hDateCache == 0) hDateCache = EvalHash.hash("Date") + 1;
		return hDateCache - 1;
	}

	static var hERegCache:Int = 0;

	public static function hEReg():Int {
		if (hERegCache == 0) hERegCache = EvalHash.hash("EReg") + 1;
		return hERegCache - 1;
	}

	static var hIAllCache:Int = 0;

	public static function hIAll():Int {
		if (hIAllCache == 0) hIAllCache = EvalHash.hash("IAll") + 1;
		return hIAllCache - 1;
	}

	static var hIAsNameCache:Int = 0;

	public static function hIAsName():Int {
		if (hIAsNameCache == 0) hIAsNameCache = EvalHash.hash("IAsName") + 1;
		return hIAsNameCache - 1;
	}

	static var hINormalCache:Int = 0;

	public static function hINormal():Int {
		if (hINormalCache == 0) hINormalCache = EvalHash.hash("INormal") + 1;
		return hINormalCache - 1;
	}

	static var hNoneCache:Int = 0;

	public static function hNone():Int {
		if (hNoneCache == 0) hNoneCache = EvalHash.hash("None") + 1;
		return hNoneCache - 1;
	}

	static var hStdCache:Int = 0;

	public static function hStd():Int {
		if (hStdCache == 0) hStdCache = EvalHash.hash("Std") + 1;
		return hStdCache - 1;
	}

	static var hStringCache:Int = 0;

	public static function hString():Int {
		if (hStringCache == 0) hStringCache = EvalHash.hash("String") + 1;
		return hStringCache - 1;
	}

	static var hStringBufCache:Int = 0;

	public static function hStringBuf():Int {
		if (hStringBufCache == 0) hStringBufCache = EvalHash.hash("StringBuf") + 1;
		return hStringBufCache - 1;
	}

	static var hValueTypeCache:Int = 0;

	public static function hValueType():Int {
		if (hValueTypeCache == 0) hValueTypeCache = EvalHash.hash("ValueType") + 1;
		return hValueTypeCache - 1;
	}

	static var hXmlCache:Int = 0;

	public static function hXml():Int {
		if (hXmlCache == 0) hXmlCache = EvalHash.hash("Xml") + 1;
		return hXmlCache - 1;
	}

	static var hHxcAbortCache:Int = 0;

	public static function h___hxcAbort():Int {
		if (hHxcAbortCache == 0) hHxcAbortCache = EvalHash.hash("__hxcAbort") + 1;
		return hHxcAbortCache - 1;
	}

	static var hRttiCache:Int = 0;

	public static function h___rtti():Int {
		if (hRttiCache == 0) hRttiCache = EvalHash.hash("__rtti") + 1;
		return hRttiCache - 1;
	}

	static var hDoubleUnderscoreTCache:Int = 0;

	public static function h___t():Int {
		if (hDoubleUnderscoreTCache == 0) hDoubleUnderscoreTCache = EvalHash.hash("__t") + 1;
		return hDoubleUnderscoreTCache - 1;
	}

	static var hAccessCache:Int = 0;

	public static function hAccess():Int {
		if (hAccessCache == 0) hAccessCache = EvalHash.hash("access") + 1;
		return hAccessCache - 1;
	}

	static var hAcquireCache:Int = 0;

	public static function hAcquire():Int {
		if (hAcquireCache == 0) hAcquireCache = EvalHash.hash("acquire") + 1;
		return hAcquireCache - 1;
	}

	static var hAddCache:Int = 0;

	public static function hAdd():Int {
		if (hAddCache == 0) hAddCache = EvalHash.hash("add") + 1;
		return hAddCache - 1;
	}

	static var hAddFeatureCache:Int = 0;

	public static function hAddFeature():Int {
		if (hAddFeatureCache == 0) hAddFeatureCache = EvalHash.hash("addFeature") + 1;
		return hAddFeatureCache - 1;
	}

	static var hArgsCache:Int = 0;

	public static function hArgs():Int {
		if (hArgsCache == 0) hArgsCache = EvalHash.hash("args") + 1;
		return hArgsCache - 1;
	}

	static var hArrayCache:Int = 0;

	public static function hArray():Int {
		if (hArrayCache == 0) hArrayCache = EvalHash.hash("array") + 1;
		return hArrayCache - 1;
	}

	static var hBinopsCache:Int = 0;

	public static function hBinops():Int {
		if (hBinopsCache == 0) hBinopsCache = EvalHash.hash("binops") + 1;
		return hBinopsCache - 1;
	}

	static var hBroadcastCache:Int = 0;

	public static function hBroadcast():Int {
		if (hBroadcastCache == 0) hBroadcastCache = EvalHash.hash("broadcast") + 1;
		return hBroadcastCache - 1;
	}

	static var hBuildMetaDataCache:Int = 0;

	public static function hBuildMetaData():Int {
		if (hBuildMetaDataCache == 0) hBuildMetaDataCache = EvalHash.hash("buildMetaData") + 1;
		return hBuildMetaDataCache - 1;
	}

	static var hCCache:Int = 0;

	public static function hC():Int {
		if (hCCache == 0) hCCache = EvalHash.hash("c") + 1;
		return hCCache - 1;
	}

	static var hCaptureCache:Int = 0;

	public static function hCapture():Int {
		if (hCaptureCache == 0) hCaptureCache = EvalHash.hash("capture") + 1;
		return hCaptureCache - 1;
	}

	static var hChildErrorsCache:Int = 0;

	public static function hChildErrors():Int {
		if (hChildErrorsCache == 0) hChildErrorsCache = EvalHash.hash("childErrors") + 1;
		return hChildErrorsCache - 1;
	}

	static var hConstraintsCache:Int = 0;

	public static function hConstraints():Int {
		if (hConstraintsCache == 0) hConstraintsCache = EvalHash.hash("constraints") + 1;
		return hConstraintsCache - 1;
	}

	static var hConstructorCache:Int = 0;

	public static function hConstructor():Int {
		if (hConstructorCache == 0) hConstructorCache = EvalHash.hash("constructor") + 1;
		return hConstructorCache - 1;
	}

	static var hConstructsCache:Int = 0;

	public static function hConstructs():Int {
		if (hConstructsCache == 0) hConstructsCache = EvalHash.hash("constructs") + 1;
		return hConstructsCache - 1;
	}

	static var hCustomParamsCache:Int = 0;

	public static function hCustomParams():Int {
		if (hCustomParamsCache == 0) hCustomParamsCache = EvalHash.hash("customParams") + 1;
		return hCustomParamsCache - 1;
	}

	static var hDefaultTypeCache:Int = 0;

	public static function hDefaultType():Int {
		if (hDefaultTypeCache == 0) hDefaultTypeCache = EvalHash.hash("defaultType") + 1;
		return hDefaultTypeCache - 1;
	}

	static var hDefineCache:Int = 0;

	public static function hDefine():Int {
		if (hDefineCache == 0) hDefineCache = EvalHash.hash("define") + 1;
		return hDefineCache - 1;
	}

	static var hDocCache:Int = 0;

	public static function hDoc():Int {
		if (hDocCache == 0) hDocCache = EvalHash.hash("doc") + 1;
		return hDocCache - 1;
	}

	static var hEvalVectorCache:Int = 0;

	public static function hEvalVector():Int {
		if (hEvalVectorCache == 0) hEvalVectorCache = EvalHash.hash("eval.Vector") + 1;
		return hEvalVectorCache - 1;
	}

	static var hEvalLuvAddressFamilyCache:Int = 0;

	public static function hEvalLuvAddressFamily():Int {
		if (hEvalLuvAddressFamilyCache == 0) hEvalLuvAddressFamilyCache = EvalHash.hash("eval.luv.AddressFamily") + 1;
		return hEvalLuvAddressFamilyCache - 1;
	}

	static var hEvalLuvReceiveHandleCache:Int = 0;

	public static function hEvalLuvReceiveHandle():Int {
		if (hEvalLuvReceiveHandleCache == 0) hEvalLuvReceiveHandleCache = EvalHash.hash("eval.luv.ReceiveHandle") + 1;
		return hEvalLuvReceiveHandleCache - 1;
	}

	static var hEvalLuvSocketTypeCache:Int = 0;

	public static function hEvalLuvSocketType():Int {
		if (hEvalLuvSocketTypeCache == 0) hEvalLuvSocketTypeCache = EvalHash.hash("eval.luv.SocketType") + 1;
		return hEvalLuvSocketTypeCache - 1;
	}

	static var hEvalVmNativeSocketCache:Int = 0;

	public static function hEvalVmNativeSocket():Int {
		if (hEvalVmNativeSocketCache == 0) hEvalVmNativeSocketCache = EvalHash.hash("eval.vm.NativeSocket") + 1;
		return hEvalVmNativeSocketCache - 1;
	}

	static var hEvalVmNativeThreadCache:Int = 0;

	public static function hEvalVmNativeThread():Int {
		if (hEvalVmNativeThreadCache == 0) hEvalVmNativeThreadCache = EvalHash.hash("eval.vm.NativeThread") + 1;
		return hEvalVmNativeThreadCache - 1;
	}

	static var hExcludeCache:Int = 0;

	public static function hExclude():Int {
		if (hExcludeCache == 0) hExcludeCache = EvalHash.hash("exclude") + 1;
		return hExcludeCache - 1;
	}

	static var hExprCache:Int = 0;

	public static function hExpr():Int {
		if (hExprCache == 0) hExprCache = EvalHash.hash("expr") + 1;
		return hExprCache - 1;
	}

	static var hExtraCache:Int = 0;

	public static function hExtra():Int {
		if (hExtraCache == 0) hExtraCache = EvalHash.hash("extra") + 1;
		return hExtraCache - 1;
	}

	static var hExtractCache:Int = 0;

	public static function hExtract():Int {
		if (hExtractCache == 0) hExtractCache = EvalHash.hash("extract") + 1;
		return hExtractCache - 1;
	}

	static var hFieldCache:Int = 0;

	public static function hField():Int {
		if (hFieldCache == 0) hFieldCache = EvalHash.hash("field") + 1;
		return hFieldCache - 1;
	}

	static var hFieldsCache:Int = 0;

	public static function hFields():Int {
		if (hFieldsCache == 0) hFieldsCache = EvalHash.hash("fields") + 1;
		return hFieldsCache - 1;
	}

	static var hFileCache:Int = 0;

	public static function hFile():Int {
		if (hFileCache == 0) hFileCache = EvalHash.hash("file") + 1;
		return hFileCache - 1;
	}

	static var hFileNameCache:Int = 0;

	public static function hFileName():Int {
		if (hFileNameCache == 0) hFileNameCache = EvalHash.hash("fileName") + 1;
		return hFileNameCache - 1;
	}

	static var hFromCache:Int = 0;

	public static function hFrom():Int {
		if (hFromCache == 0) hFromCache = EvalHash.hash("from") + 1;
		return hFromCache - 1;
	}

	static var hGenerateStatementCache:Int = 0;

	public static function hGenerateStatement():Int {
		if (hGenerateStatementCache == 0) hGenerateStatementCache = EvalHash.hash("generateStatement") + 1;
		return hGenerateStatementCache - 1;
	}

	static var hGenerateValueCache:Int = 0;

	public static function hGenerateValue():Int {
		if (hGenerateValueCache == 0) hGenerateValueCache = EvalHash.hash("generateValue") + 1;
		return hGenerateValueCache - 1;
	}

	static var hGetCache:Int = 0;

	public static function hGet():Int {
		if (hGetCache == 0) hGetCache = EvalHash.hash("get") + 1;
		return hGetCache - 1;
	}

	static var hGetResolverCache:Int = 0;

	public static function hGetResolver():Int {
		if (hGetResolverCache == 0) hGetResolverCache = EvalHash.hash("getResolver") + 1;
		return hGetResolverCache - 1;
	}

	static var hGetMessageCache:Int = 0;

	public static function hGetMessage():Int {
		if (hGetMessageCache == 0) hGetMessageCache = EvalHash.hash("get_message") + 1;
		return hGetMessageCache - 1;
	}

	static var hGuardCache:Int = 0;

	public static function hGuard():Int {
		if (hGuardCache == 0) hGuardCache = EvalHash.hash("guard") + 1;
		return hGuardCache - 1;
	}

	static var hHasCache:Int = 0;

	public static function hHas():Int {
		if (hHasCache == 0) hHasCache = EvalHash.hash("has") + 1;
		return hHasCache - 1;
	}

	static var hHasFeatureCache:Int = 0;

	public static function hHasFeature():Int {
		if (hHasFeatureCache == 0) hHasFeatureCache = EvalHash.hash("hasFeature") + 1;
		return hHasFeatureCache - 1;
	}

	static var hHasNextCache:Int = 0;

	public static function hHasNext():Int {
		if (hHasNextCache == 0) hHasNextCache = EvalHash.hash("hasNext") + 1;
		return hHasNextCache - 1;
	}

	static var hHaxeExceptionCache:Int = 0;

	public static function hHaxeException():Int {
		if (hHaxeExceptionCache == 0) hHaxeExceptionCache = EvalHash.hash("haxe.Exception") + 1;
		return hHaxeExceptionCache - 1;
	}

	static var hHaxeJsonCache:Int = 0;

	public static function hHaxeJson():Int {
		if (hHaxeJsonCache == 0) hHaxeJsonCache = EvalHash.hash("haxe.Json") + 1;
		return hHaxeJsonCache - 1;
	}

	static var hHaxeSerializerCache:Int = 0;

	public static function hHaxeSerializer():Int {
		if (hHaxeSerializerCache == 0) hHaxeSerializerCache = EvalHash.hash("haxe.Serializer") + 1;
		return hHaxeSerializerCache - 1;
	}

	static var hHaxeStackItemCache:Int = 0;

	public static function hHaxeStackItem():Int {
		if (hHaxeStackItemCache == 0) hHaxeStackItemCache = EvalHash.hash("haxe.StackItem") + 1;
		return hHaxeStackItemCache - 1;
	}

	static var hHaxeUnserializerCache:Int = 0;

	public static function hHaxeUnserializer():Int {
		if (hHaxeUnserializerCache == 0) hHaxeUnserializerCache = EvalHash.hash("haxe.Unserializer") + 1;
		return hHaxeUnserializerCache - 1;
	}

	static var hHaxeUtf8Cache:Int = 0;

	public static function hHaxeUtf8():Int {
		if (hHaxeUtf8Cache == 0) hHaxeUtf8Cache = EvalHash.hash("haxe.Utf8") + 1;
		return hHaxeUtf8Cache - 1;
	}

	static var hHaxeInt64Int64Cache:Int = 0;

	public static function h_haxe__Int64____Int64():Int {
		if (hHaxeInt64Int64Cache == 0) hHaxeInt64Int64Cache = EvalHash.hash("haxe._Int64.___Int64") + 1;
		return hHaxeInt64Int64Cache - 1;
	}

	static var hHaxeDsIntMapCache:Int = 0;

	public static function hHaxeDsIntMap():Int {
		if (hHaxeDsIntMapCache == 0) hHaxeDsIntMapCache = EvalHash.hash("haxe.ds.IntMap") + 1;
		return hHaxeDsIntMapCache - 1;
	}

	static var hHaxeDsListCache:Int = 0;

	public static function hHaxeDsList():Int {
		if (hHaxeDsListCache == 0) hHaxeDsListCache = EvalHash.hash("haxe.ds.List") + 1;
		return hHaxeDsListCache - 1;
	}

	static var hHaxeDsStringMapCache:Int = 0;

	public static function hHaxeDsStringMap():Int {
		if (hHaxeDsStringMapCache == 0) hHaxeDsStringMapCache = EvalHash.hash("haxe.ds.StringMap") + 1;
		return hHaxeDsStringMapCache - 1;
	}

	static var hHaxeDsListListNodeCache:Int = 0;

	public static function h_haxe_ds__List_ListNode():Int {
		if (hHaxeDsListListNodeCache == 0) hHaxeDsListListNodeCache = EvalHash.hash("haxe.ds._List.ListNode") + 1;
		return hHaxeDsListListNodeCache - 1;
	}

	static var hHaxeFormatJsonParserCache:Int = 0;

	public static function hHaxeFormatJsonParser():Int {
		if (hHaxeFormatJsonParserCache == 0) hHaxeFormatJsonParserCache = EvalHash.hash("haxe.format.JsonParser") + 1;
		return hHaxeFormatJsonParserCache - 1;
	}

	static var hHaxeFormatJsonPrinterCache:Int = 0;

	public static function hHaxeFormatJsonPrinter():Int {
		if (hHaxeFormatJsonPrinterCache == 0) hHaxeFormatJsonPrinterCache = EvalHash.hash("haxe.format.JsonPrinter") + 1;
		return hHaxeFormatJsonPrinterCache - 1;
	}

	static var hHaxeIoBytesCache:Int = 0;

	public static function hHaxeIoBytes():Int {
		if (hHaxeIoBytesCache == 0) hHaxeIoBytesCache = EvalHash.hash("haxe.io.Bytes") + 1;
		return hHaxeIoBytesCache - 1;
	}

	static var hHaxeIoBytesBufferCache:Int = 0;

	public static function hHaxeIoBytesBuffer():Int {
		if (hHaxeIoBytesBufferCache == 0) hHaxeIoBytesBufferCache = EvalHash.hash("haxe.io.BytesBuffer") + 1;
		return hHaxeIoBytesBufferCache - 1;
	}

	static var hHaxeIoEofCache:Int = 0;

	public static function hHaxeIoEof():Int {
		if (hHaxeIoEofCache == 0) hHaxeIoEofCache = EvalHash.hash("haxe.io.Eof") + 1;
		return hHaxeIoEofCache - 1;
	}

	static var hHaxeIoErrorCache:Int = 0;

	public static function hHaxeIoError():Int {
		if (hHaxeIoErrorCache == 0) hHaxeIoErrorCache = EvalHash.hash("haxe.io.Error") + 1;
		return hHaxeIoErrorCache - 1;
	}

	static var hHaxeIoOutputCache:Int = 0;

	public static function hHaxeIoOutput():Int {
		if (hHaxeIoOutputCache == 0) hHaxeIoOutputCache = EvalHash.hash("haxe.io.Output") + 1;
		return hHaxeIoOutputCache - 1;
	}

	static var hHaxeIteratorsArrayKeyValueIteratorCache:Int = 0;

	public static function hHaxeIteratorsArrayKeyValueIterator():Int {
		if (hHaxeIteratorsArrayKeyValueIteratorCache == 0) hHaxeIteratorsArrayKeyValueIteratorCache = EvalHash.hash("haxe.iterators.ArrayKeyValueIterator") + 1;
		return hHaxeIteratorsArrayKeyValueIteratorCache - 1;
	}

	static var hHaxeIteratorsMapKeyValueIteratorCache:Int = 0;

	public static function hHaxeIteratorsMapKeyValueIterator():Int {
		if (hHaxeIteratorsMapKeyValueIteratorCache == 0) hHaxeIteratorsMapKeyValueIteratorCache = EvalHash.hash("haxe.iterators.MapKeyValueIterator") + 1;
		return hHaxeIteratorsMapKeyValueIteratorCache - 1;
	}

	static var hHaxeMacroContextCache:Int = 0;

	public static function hHaxeMacroContext():Int {
		if (hHaxeMacroContextCache == 0) hHaxeMacroContextCache = EvalHash.hash("haxe.macro.Context") + 1;
		return hHaxeMacroContextCache - 1;
	}

	static var hHaxeMacroDisplayModeCache:Int = 0;

	public static function hHaxeMacroDisplayMode():Int {
		if (hHaxeMacroDisplayModeCache == 0) hHaxeMacroDisplayModeCache = EvalHash.hash("haxe.macro.DisplayMode") + 1;
		return hHaxeMacroDisplayModeCache - 1;
	}

	static var hHaxeMacroErrorCache:Int = 0;

	public static function hHaxeMacroError():Int {
		if (hHaxeMacroErrorCache == 0) hHaxeMacroErrorCache = EvalHash.hash("haxe.macro.Error") + 1;
		return hHaxeMacroErrorCache - 1;
	}

	static var hHaxeMacroExprErrorCache:Int = 0;

	public static function hHaxeMacroExprError():Int {
		if (hHaxeMacroExprErrorCache == 0) hHaxeMacroExprErrorCache = EvalHash.hash("haxe.macro.Expr.Error") + 1;
		return hHaxeMacroExprErrorCache - 1;
	}

	static var hHaxeMacroImportModeCache:Int = 0;

	public static function hHaxeMacroImportMode():Int {
		if (hHaxeMacroImportModeCache == 0) hHaxeMacroImportModeCache = EvalHash.hash("haxe.macro.ImportMode") + 1;
		return hHaxeMacroImportModeCache - 1;
	}

	static var hHaxeMacroMessageCache:Int = 0;

	public static function hHaxeMacroMessage():Int {
		if (hHaxeMacroMessageCache == 0) hHaxeMacroMessageCache = EvalHash.hash("haxe.macro.Message") + 1;
		return hHaxeMacroMessageCache - 1;
	}

	static var hHaxeMacroPositionCache:Int = 0;

	public static function hHaxeMacroPosition():Int {
		if (hHaxeMacroPositionCache == 0) hHaxeMacroPositionCache = EvalHash.hash("haxe.macro.Position") + 1;
		return hHaxeMacroPositionCache - 1;
	}

	static var hHaxeMacroRefCache:Int = 0;

	public static function hHaxeMacroRef():Int {
		if (hHaxeMacroRefCache == 0) hHaxeMacroRefCache = EvalHash.hash("haxe.macro.Ref") + 1;
		return hHaxeMacroRefCache - 1;
	}

	static var hHaxeMacroUnsafeCache:Int = 0;

	public static function hHaxeMacroUnsafe():Int {
		if (hHaxeMacroUnsafeCache == 0) hHaxeMacroUnsafeCache = EvalHash.hash("haxe.macro.Unsafe") + 1;
		return hHaxeMacroUnsafeCache - 1;
	}

	static var hHaxeZipCompressCache:Int = 0;

	public static function hHaxeZipCompress():Int {
		if (hHaxeZipCompressCache == 0) hHaxeZipCompressCache = EvalHash.hash("haxe.zip.Compress") + 1;
		return hHaxeZipCompressCache - 1;
	}

	static var hHaxeZipUncompressCache:Int = 0;

	public static function hHaxeZipUncompress():Int {
		if (hHaxeZipUncompressCache == 0) hHaxeZipUncompressCache = EvalHash.hash("haxe.zip.Uncompress") + 1;
		return hHaxeZipUncompressCache - 1;
	}

	static var hIdCache:Int = 0;

	public static function hId():Int {
		if (hIdCache == 0) hIdCache = EvalHash.hash("id") + 1;
		return hIdCache - 1;
	}

	static var hImplCache:Int = 0;

	public static function hImpl():Int {
		if (hImplCache == 0) hImplCache = EvalHash.hash("impl") + 1;
		return hImplCache - 1;
	}

	static var hIndexCache:Int = 0;

	public static function hIndex():Int {
		if (hIndexCache == 0) hIndexCache = EvalHash.hash("index") + 1;
		return hIndexCache - 1;
	}

	static var hInitCache:Int = 0;

	public static function hInit():Int {
		if (hInitCache == 0) hInitCache = EvalHash.hash("init") + 1;
		return hInitCache - 1;
	}

	static var hInterfacesCache:Int = 0;

	public static function hInterfaces():Int {
		if (hInterfacesCache == 0) hInterfacesCache = EvalHash.hash("interfaces") + 1;
		return hInterfacesCache - 1;
	}

	static var hIsAbstractCache:Int = 0;

	public static function hIsAbstract():Int {
		if (hIsAbstractCache == 0) hIsAbstractCache = EvalHash.hash("isAbstract") + 1;
		return hIsAbstractCache - 1;
	}

	static var hIsExternCache:Int = 0;

	public static function hIsExtern():Int {
		if (hIsExternCache == 0) hIsExternCache = EvalHash.hash("isExtern") + 1;
		return hIsExternCache - 1;
	}

	static var hIsFinalCache:Int = 0;

	public static function hIsFinal():Int {
		if (hIsFinalCache == 0) hIsFinalCache = EvalHash.hash("isFinal") + 1;
		return hIsFinalCache - 1;
	}

	static var hIsInterfaceCache:Int = 0;

	public static function hIsInterface():Int {
		if (hIsInterfaceCache == 0) hIsInterfaceCache = EvalHash.hash("isInterface") + 1;
		return hIsInterfaceCache - 1;
	}

	static var hIsKeywordCache:Int = 0;

	public static function hIsKeyword():Int {
		if (hIsKeywordCache == 0) hIsKeywordCache = EvalHash.hash("isKeyword") + 1;
		return hIsKeywordCache - 1;
	}

	static var hIsOfTypeCache:Int = 0;

	public static function hIsOfType():Int {
		if (hIsOfTypeCache == 0) hIsOfTypeCache = EvalHash.hash("isOfType") + 1;
		return hIsOfTypeCache - 1;
	}

	static var hIsPrivateCache:Int = 0;

	public static function hIsPrivate():Int {
		if (hIsPrivateCache == 0) hIsPrivateCache = EvalHash.hash("isPrivate") + 1;
		return hIsPrivateCache - 1;
	}

	static var hIsPublicCache:Int = 0;

	public static function hIsPublic():Int {
		if (hIsPublicCache == 0) hIsPublicCache = EvalHash.hash("isPublic") + 1;
		return hIsPublicCache - 1;
	}

	static var hIsStaticCache:Int = 0;

	public static function hIsStatic():Int {
		if (hIsStaticCache == 0) hIsStaticCache = EvalHash.hash("isStatic") + 1;
		return hIsStaticCache - 1;
	}

	static var hIteratorCache:Int = 0;

	public static function hIterator():Int {
		if (hIteratorCache == 0) hIteratorCache = EvalHash.hash("iterator") + 1;
		return hIteratorCache - 1;
	}

	static var hKindCache:Int = 0;

	public static function hKind():Int {
		if (hKindCache == 0) hKindCache = EvalHash.hash("kind") + 1;
		return hKindCache - 1;
	}

	static var hLenCache:Int = 0;

	public static function hLen():Int {
		if (hLenCache == 0) hLenCache = EvalHash.hash("len") + 1;
		return hLenCache - 1;
	}

	static var hLengthCache:Int = 0;

	public static function hLength():Int {
		if (hLengthCache == 0) hLengthCache = EvalHash.hash("length") + 1;
		return hLengthCache - 1;
	}

	static var hLineNumberCache:Int = 0;

	public static function hLineNumber():Int {
		if (hLineNumberCache == 0) hLineNumberCache = EvalHash.hash("lineNumber") + 1;
		return hLineNumberCache - 1;
	}

	static var hMainCache:Int = 0;

	public static function hMain():Int {
		if (hMainCache == 0) hMainCache = EvalHash.hash("main") + 1;
		return hMainCache - 1;
	}

	static var hMajorWordsCache:Int = 0;

	public static function hMajorWords():Int {
		if (hMajorWordsCache == 0) hMajorWordsCache = EvalHash.hash("major_words") + 1;
		return hMajorWordsCache - 1;
	}

	static var hMaxCache:Int = 0;

	public static function hMax():Int {
		if (hMaxCache == 0) hMaxCache = EvalHash.hash("max") + 1;
		return hMaxCache - 1;
	}

	static var hMbedtlsConfigCache:Int = 0;

	public static function hMbedtlsConfig():Int {
		if (hMbedtlsConfigCache == 0) hMbedtlsConfigCache = EvalHash.hash("mbedtls.Config") + 1;
		return hMbedtlsConfigCache - 1;
	}

	static var hMbedtlsCtrDrbgCache:Int = 0;

	public static function hMbedtlsCtrDrbg():Int {
		if (hMbedtlsCtrDrbgCache == 0) hMbedtlsCtrDrbgCache = EvalHash.hash("mbedtls.CtrDrbg") + 1;
		return hMbedtlsCtrDrbgCache - 1;
	}

	static var hMbedtlsEntropyCache:Int = 0;

	public static function hMbedtlsEntropy():Int {
		if (hMbedtlsEntropyCache == 0) hMbedtlsEntropyCache = EvalHash.hash("mbedtls.Entropy") + 1;
		return hMbedtlsEntropyCache - 1;
	}

	static var hMbedtlsPkContextCache:Int = 0;

	public static function hMbedtlsPkContext():Int {
		if (hMbedtlsPkContextCache == 0) hMbedtlsPkContextCache = EvalHash.hash("mbedtls.PkContext") + 1;
		return hMbedtlsPkContextCache - 1;
	}

	static var hMbedtlsSslCache:Int = 0;

	public static function hMbedtlsSsl():Int {
		if (hMbedtlsSslCache == 0) hMbedtlsSslCache = EvalHash.hash("mbedtls.Ssl") + 1;
		return hMbedtlsSslCache - 1;
	}

	static var hMbedtlsX509CrtCache:Int = 0;

	public static function hMbedtlsX509Crt():Int {
		if (hMbedtlsX509CrtCache == 0) hMbedtlsX509CrtCache = EvalHash.hash("mbedtls.X509Crt") + 1;
		return hMbedtlsX509CrtCache - 1;
	}

	static var hMessageCache:Int = 0;

	public static function hMessage():Int {
		if (hMessageCache == 0) hMessageCache = EvalHash.hash("message") + 1;
		return hMessageCache - 1;
	}

	static var hMetaCache:Int = 0;

	public static function hMeta():Int {
		if (hMetaCache == 0) hMetaCache = EvalHash.hash("meta") + 1;
		return hMetaCache - 1;
	}

	static var hMetadataCache:Int = 0;

	public static function hMetadata():Int {
		if (hMetadataCache == 0) hMetadataCache = EvalHash.hash("metadata") + 1;
		return hMetadataCache - 1;
	}

	static var hMinCache:Int = 0;

	public static function hMin():Int {
		if (hMinCache == 0) hMinCache = EvalHash.hash("min") + 1;
		return hMinCache - 1;
	}

	static var hMinorWordsCache:Int = 0;

	public static function hMinorWords():Int {
		if (hMinorWordsCache == 0) hMinorWordsCache = EvalHash.hash("minor_words") + 1;
		return hMinorWordsCache - 1;
	}

	static var hModeCache:Int = 0;

	public static function hMode():Int {
		if (hModeCache == 0) hModeCache = EvalHash.hash("mode") + 1;
		return hModeCache - 1;
	}

	static var hModuleCache:Int = 0;

	public static function hModule():Int {
		if (hModuleCache == 0) hModuleCache = EvalHash.hash("module") + 1;
		return hModuleCache - 1;
	}

	static var hNameCache:Int = 0;

	public static function hName():Int {
		if (hNameCache == 0) hNameCache = EvalHash.hash("name") + 1;
		return hNameCache - 1;
	}

	static var hNamePosCache:Int = 0;

	public static function hNamePos():Int {
		if (hNamePosCache == 0) hNamePosCache = EvalHash.hash("namePos") + 1;
		return hNamePosCache - 1;
	}

	static var hNameUnderscorePosCache:Int = 0;

	public static function hNameUnderscorePos():Int {
		if (hNameUnderscorePosCache == 0) hNameUnderscorePosCache = EvalHash.hash("name_pos") + 1;
		return hNameUnderscorePosCache - 1;
	}

	static var hNamesCache:Int = 0;

	public static function hNames():Int {
		if (hNamesCache == 0) hNamesCache = EvalHash.hash("names") + 1;
		return hNamesCache - 1;
	}

	static var hNativeCache:Int = 0;

	public static function hNative():Int {
		if (hNativeCache == 0) hNativeCache = EvalHash.hash("native") + 1;
		return hNativeCache - 1;
	}

	static var hNextCache:Int = 0;

	public static function hNext():Int {
		if (hNextCache == 0) hNextCache = EvalHash.hash("next") + 1;
		return hNextCache - 1;
	}

	static var hObjCache:Int = 0;

	public static function hObj():Int {
		if (hObjCache == 0) hObjCache = EvalHash.hash("obj") + 1;
		return hObjCache - 1;
	}

	static var hOpCache:Int = 0;

	public static function hOp():Int {
		if (hOpCache == 0) hOpCache = EvalHash.hash("op") + 1;
		return hOpCache - 1;
	}

	static var hOptCache:Int = 0;

	public static function hOpt():Int {
		if (hOptCache == 0) hOptCache = EvalHash.hash("opt") + 1;
		return hOptCache - 1;
	}

	static var hOutputFileCache:Int = 0;

	public static function hOutputFile():Int {
		if (hOutputFileCache == 0) hOutputFileCache = EvalHash.hash("outputFile") + 1;
		return hOutputFileCache - 1;
	}

	static var hOverloadsCache:Int = 0;

	public static function hOverloads():Int {
		if (hOverloadsCache == 0) hOverloadsCache = EvalHash.hash("overloads") + 1;
		return hOverloadsCache - 1;
	}

	static var hOverridesCache:Int = 0;

	public static function hOverrides():Int {
		if (hOverridesCache == 0) hOverridesCache = EvalHash.hash("overrides") + 1;
		return hOverridesCache - 1;
	}

	static var hPackCache:Int = 0;

	public static function hPack():Int {
		if (hPackCache == 0) hPackCache = EvalHash.hash("pack") + 1;
		return hPackCache - 1;
	}

	static var hParamsCache:Int = 0;

	public static function hParams():Int {
		if (hParamsCache == 0) hParamsCache = EvalHash.hash("params") + 1;
		return hParamsCache - 1;
	}

	static var hParseCache:Int = 0;

	public static function hParse():Int {
		if (hParseCache == 0) hParseCache = EvalHash.hash("parse") + 1;
		return hParseCache - 1;
	}

	static var hPathCache:Int = 0;

	public static function hPath():Int {
		if (hPathCache == 0) hPathCache = EvalHash.hash("path") + 1;
		return hPathCache - 1;
	}

	static var hPosCache:Int = 0;

	public static function hPos():Int {
		if (hPosCache == 0) hPosCache = EvalHash.hash("pos") + 1;
		return hPosCache - 1;
	}

	static var hPostFixCache:Int = 0;

	public static function hPostFix():Int {
		if (hPostFixCache == 0) hPostFixCache = EvalHash.hash("postFix") + 1;
		return hPostFixCache - 1;
	}

	static var hPrintCache:Int = 0;

	public static function hPrint():Int {
		if (hPrintCache == 0) hPrintCache = EvalHash.hash("print") + 1;
		return hPrintCache - 1;
	}

	static var hProcCache:Int = 0;

	public static function hProc():Int {
		if (hProcCache == 0) hProcCache = EvalHash.hash("proc") + 1;
		return hProcCache - 1;
	}

	static var hQuoteStringCache:Int = 0;

	public static function hQuoteString():Int {
		if (hQuoteStringCache == 0) hQuoteStringCache = EvalHash.hash("quoteString") + 1;
		return hQuoteStringCache - 1;
	}

	static var hQuotesCache:Int = 0;

	public static function hQuotes():Int {
		if (hQuotesCache == 0) hQuotesCache = EvalHash.hash("quotes") + 1;
		return hQuotesCache - 1;
	}

	static var hReleaseCache:Int = 0;

	public static function hRelease():Int {
		if (hReleaseCache == 0) hReleaseCache = EvalHash.hash("release") + 1;
		return hReleaseCache - 1;
	}

	static var hRemoveCache:Int = 0;

	public static function hRemove():Int {
		if (hRemoveCache == 0) hRemoveCache = EvalHash.hash("remove") + 1;
		return hRemoveCache - 1;
	}

	static var hResolveCache:Int = 0;

	public static function hResolve():Int {
		if (hResolveCache == 0) hResolveCache = EvalHash.hash("resolve") + 1;
		return hResolveCache - 1;
	}

	static var hResolveWriteCache:Int = 0;

	public static function hResolveWrite():Int {
		if (hResolveWriteCache == 0) hResolveWriteCache = EvalHash.hash("resolveWrite") + 1;
		return hResolveWriteCache - 1;
	}

	static var hRetCache:Int = 0;

	public static function hRet():Int {
		if (hRetCache == 0) hRetCache = EvalHash.hash("ret") + 1;
		return hRetCache - 1;
	}

	static var hRunCache:Int = 0;

	public static function hRun():Int {
		if (hRunCache == 0) hRunCache = EvalHash.hash("run") + 1;
		return hRunCache - 1;
	}

	static var hSerializeCache:Int = 0;

	public static function hSerialize():Int {
		if (hSerializeCache == 0) hSerializeCache = EvalHash.hash("serialize") + 1;
		return hSerializeCache - 1;
	}

	static var hSerializeExceptionCache:Int = 0;

	public static function hSerializeException():Int {
		if (hSerializeExceptionCache == 0) hSerializeExceptionCache = EvalHash.hash("serializeException") + 1;
		return hSerializeExceptionCache - 1;
	}

	static var hSerializeFieldsCache:Int = 0;

	public static function hSerializeFields():Int {
		if (hSerializeFieldsCache == 0) hSerializeFieldsCache = EvalHash.hash("serializeFields") + 1;
		return hSerializeFieldsCache - 1;
	}

	static var hSerializeRefCache:Int = 0;

	public static function hSerializeRef():Int {
		if (hSerializeRefCache == 0) hSerializeRefCache = EvalHash.hash("serializeRef") + 1;
		return hSerializeRefCache - 1;
	}

	static var hSerializeStringCache:Int = 0;

	public static function hSerializeString():Int {
		if (hSerializeStringCache == 0) hSerializeStringCache = EvalHash.hash("serializeString") + 1;
		return hSerializeStringCache - 1;
	}

	static var hSetCurrentClassCache:Int = 0;

	public static function hSetCurrentClass():Int {
		if (hSetCurrentClassCache == 0) hSetCurrentClassCache = EvalHash.hash("setCurrentClass") + 1;
		return hSetCurrentClassCache - 1;
	}

	static var hSetResolverCache:Int = 0;

	public static function hSetResolver():Int {
		if (hSetResolverCache == 0) hSetResolverCache = EvalHash.hash("setResolver") + 1;
		return hSetResolverCache - 1;
	}

	static var hSetTypeAccessorCache:Int = 0;

	public static function hSetTypeAccessor():Int {
		if (hSetTypeAccessorCache == 0) hSetTypeAccessorCache = EvalHash.hash("setTypeAccessor") + 1;
		return hSetTypeAccessorCache - 1;
	}

	static var hSignalCache:Int = 0;

	public static function hSignal():Int {
		if (hSignalCache == 0) hSignalCache = EvalHash.hash("signal") + 1;
		return hSignalCache - 1;
	}

	static var hSocketCache:Int = 0;

	public static function hSocket():Int {
		if (hSocketCache == 0) hSocketCache = EvalHash.hash("socket") + 1;
		return hSocketCache - 1;
	}

	static var hStackCache:Int = 0;

	public static function hStack():Int {
		if (hStackCache == 0) hStackCache = EvalHash.hash("stack") + 1;
		return hStackCache - 1;
	}

	static var hStaticsCache:Int = 0;

	public static function hStatics():Int {
		if (hStaticsCache == 0) hStaticsCache = EvalHash.hash("statics") + 1;
		return hStaticsCache - 1;
	}

	static var hStatusCache:Int = 0;

	public static function hStatus():Int {
		if (hStatusCache == 0) hStatusCache = EvalHash.hash("status") + 1;
		return hStatusCache - 1;
	}

	static var hStringifyCache:Int = 0;

	public static function hStringify():Int {
		if (hStringifyCache == 0) hStringifyCache = EvalHash.hash("stringify") + 1;
		return hStringifyCache - 1;
	}

	static var hSubCache:Int = 0;

	public static function hSub():Int {
		if (hSubCache == 0) hSubCache = EvalHash.hash("sub") + 1;
		return hSubCache - 1;
	}

	static var hSuperClassCache:Int = 0;

	public static function hSuperClass():Int {
		if (hSuperClassCache == 0) hSuperClassCache = EvalHash.hash("superClass") + 1;
		return hSuperClassCache - 1;
	}

	static var hSysIoFileInputCache:Int = 0;

	public static function hSysIoFileInput():Int {
		if (hSysIoFileInputCache == 0) hSysIoFileInputCache = EvalHash.hash("sys.io.FileInput") + 1;
		return hSysIoFileInputCache - 1;
	}

	static var hSysIoFileOutputCache:Int = 0;

	public static function hSysIoFileOutput():Int {
		if (hSysIoFileOutputCache == 0) hSysIoFileOutputCache = EvalHash.hash("sys.io.FileOutput") + 1;
		return hSysIoFileOutputCache - 1;
	}

	static var hSysIoProcessNativeProcessCache:Int = 0;

	public static function h_sys_io__Process_NativeProcess():Int {
		if (hSysIoProcessNativeProcessCache == 0) hSysIoProcessNativeProcessCache = EvalHash.hash("sys.io._Process.NativeProcess") + 1;
		return hSysIoProcessNativeProcessCache - 1;
	}

	static var hSysThreadConditionCache:Int = 0;

	public static function hSysThreadCondition():Int {
		if (hSysThreadConditionCache == 0) hSysThreadConditionCache = EvalHash.hash("sys.thread.Condition") + 1;
		return hSysThreadConditionCache - 1;
	}

	static var hSysThreadDequeCache:Int = 0;

	public static function hSysThreadDeque():Int {
		if (hSysThreadDequeCache == 0) hSysThreadDequeCache = EvalHash.hash("sys.thread.Deque") + 1;
		return hSysThreadDequeCache - 1;
	}

	static var hSysThreadLockCache:Int = 0;

	public static function hSysThreadLock():Int {
		if (hSysThreadLockCache == 0) hSysThreadLockCache = EvalHash.hash("sys.thread.Lock") + 1;
		return hSysThreadLockCache - 1;
	}

	static var hSysThreadMutexCache:Int = 0;

	public static function hSysThreadMutex():Int {
		if (hSysThreadMutexCache == 0) hSysThreadMutexCache = EvalHash.hash("sys.thread.Mutex") + 1;
		return hSysThreadMutexCache - 1;
	}

	static var hSysThreadSemaphoreCache:Int = 0;

	public static function hSysThreadSemaphore():Int {
		if (hSysThreadSemaphoreCache == 0) hSysThreadSemaphoreCache = EvalHash.hash("sys.thread.Semaphore") + 1;
		return hSysThreadSemaphoreCache - 1;
	}

	static var hSysThreadTlsCache:Int = 0;

	public static function hSysThreadTls():Int {
		if (hSysThreadTlsCache == 0) hSysThreadTlsCache = EvalHash.hash("sys.thread.Tls") + 1;
		return hSysThreadTlsCache - 1;
	}

	static var hTCache:Int = 0;

	public static function hT():Int {
		if (hTCache == 0) hTCache = EvalHash.hash("t") + 1;
		return hTCache - 1;
	}

	static var hToCache:Int = 0;

	public static function hTo():Int {
		if (hToCache == 0) hToCache = EvalHash.hash("to") + 1;
		return hToCache - 1;
	}

	static var hToStringCache:Int = 0;

	public static function hToString():Int {
		if (hToStringCache == 0) hToStringCache = EvalHash.hash("toString") + 1;
		return hToStringCache - 1;
	}

	static var hTryAcquireCache:Int = 0;

	public static function hTryAcquire():Int {
		if (hTryAcquireCache == 0) hTryAcquireCache = EvalHash.hash("tryAcquire") + 1;
		return hTryAcquireCache - 1;
	}

	static var hTypeCache:Int = 0;

	public static function hType():Int {
		if (hTypeCache == 0) hTypeCache = EvalHash.hash("type") + 1;
		return hTypeCache - 1;
	}

	static var hTypesCache:Int = 0;

	public static function hTypes():Int {
		if (hTypesCache == 0) hTypesCache = EvalHash.hash("types") + 1;
		return hTypesCache - 1;
	}

	static var hUnopsCache:Int = 0;

	public static function hUnops():Int {
		if (hUnopsCache == 0) hUnopsCache = EvalHash.hash("unops") + 1;
		return hUnopsCache - 1;
	}

	static var hUnserializeCache:Int = 0;

	public static function hUnserialize():Int {
		if (hUnserializeCache == 0) hUnserializeCache = EvalHash.hash("unserialize") + 1;
		return hUnserializeCache - 1;
	}

	static var hVCache:Int = 0;

	public static function hV():Int {
		if (hVCache == 0) hVCache = EvalHash.hash("v") + 1;
		return hVCache - 1;
	}

	static var hValueCache:Int = 0;

	public static function hValue():Int {
		if (hValueCache == 0) hValueCache = EvalHash.hash("value") + 1;
		return hValueCache - 1;
	}

	static var hValuesCache:Int = 0;

	public static function hValues():Int {
		if (hValuesCache == 0) hValuesCache = EvalHash.hash("values") + 1;
		return hValuesCache - 1;
	}

	static var hWaitCache:Int = 0;

	public static function hWait():Int {
		if (hWaitCache == 0) hWaitCache = EvalHash.hash("wait") + 1;
		return hWaitCache - 1;
	}
}
