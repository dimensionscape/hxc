package hxc.optimization;


import hxc.ast.Ast;
import hxc.context.Context;

enum DebugKind {
	DebugNone;
	DebugDot;
	DebugFull;
}

@:structInit
class AnalyzerConfig {
	public var optimize:Bool;
	public var constPropagation:Bool;
	public var copyPropagation:Bool;
	public var localDce:Bool;
	public var fusion:Bool;
	public var purityInference:Bool;
	public var debugKind:DebugKind;
	public var detailTimes:Int;
	public var userVarFusion:Bool;
	public var fusionDebug:Bool;

	public function new(optimize:Bool, constPropagation:Bool, copyPropagation:Bool, localDce:Bool,
			fusion:Bool, purityInference:Bool, debugKind:DebugKind, detailTimes:Int,
			userVarFusion:Bool, fusionDebug:Bool) {
		this.optimize = optimize;
		this.constPropagation = constPropagation;
		this.copyPropagation = copyPropagation;
		this.localDce = localDce;
		this.fusion = fusion;
		this.purityInference = purityInference;
		this.debugKind = debugKind;
		this.detailTimes = detailTimes;
		this.userVarFusion = userVarFusion;
		this.fusionDebug = fusionDebug;
	}

	public function copy():AnalyzerConfig {
		return new AnalyzerConfig(optimize, constPropagation, copyPropagation, localDce,
			fusion, purityInference, debugKind, detailTimes, userVarFusion, fusionDebug);
	}

	// Whether @:analyzer carries the given ident option
	static function hasAnalyzerOption(meta:Metadata, s:String):Bool {
		for (m in meta) {
			if (m.name != ":analyzer") continue;
			for (p in m.params) switch (p.expr) {
				case EConst(CIdent(v)) if (v == s): return true;
				case _:
			}
		}
		return false;
	}

	public static function isIgnored(meta:Metadata):Bool {
		return hasAnalyzerOption(meta, "ignore");
	}

	public static function getBaseConfig(com:Context):AnalyzerConfig {
		var userVarFusion = switch (com.platform) {
			case Flash | Java: false;
			case _: true;
		};
		userVarFusion = userVarFusion && (com.defines.rawDefined("analyzer_user_var_fusion")
			|| (!com.debug && !com.defines.rawDefined("analyzer_no_user_var_fusion")));
		return {
			optimize: com.defines.rawDefined("analyzer_optimize"),
			constPropagation: !com.defines.rawDefined("analyzer_no_const_propagation"),
			copyPropagation: !com.defines.rawDefined("analyzer_no_copy_propagation"),
			localDce: !com.defines.rawDefined("analyzer_no_local_dce"),
			fusion: !com.defines.rawDefined("analyzer_no_fusion"),
			purityInference: !com.defines.rawDefined("analyzer_no_purity_inference"),
			debugKind: DebugNone,
			detailTimes: {
				var v = Std.parseInt(com.defines.rawDefinedValueSafe("analyzer_times", "0"));
				v == null ? 0 : v;
			},
			userVarFusion: userVarFusion,
			fusionDebug: false,
		};
	}

	public static function updateConfigFromMeta(com:Context, config:AnalyzerConfig, ml:Metadata):AnalyzerConfig {
		var config = config.copy();
		for (m in ml) {
			switch (m.name) {
				case ":analyzer":
					for (p in m.params) switch (p.expr) {
						case EConst(CIdent(s)):
							switch (s) {
								case "optimize": config.optimize = true;
								case "no_optimize": config.optimize = false;
								case "const_propagation": config.constPropagation = true;
								case "no_const_propagation": config.constPropagation = false;
								case "copy_propagation": config.copyPropagation = true;
								case "no_copy_propagation": config.copyPropagation = false;
								case "local_dce": config.localDce = true;
								case "no_local_dce": config.localDce = false;
								case "fusion": config.fusion = true;
								case "no_fusion": config.fusion = false;
								case "user_var_fusion": config.userVarFusion = true;
								case "no_user_var_fusion": config.userVarFusion = false;
								case "dot_debug": config.debugKind = DebugDot;
								case "full_debug": config.debugKind = DebugFull;
								case "fusion_debug": config.fusionDebug = true;
								case "as_var":
								case other:
									com.warning(WOptimizer, [], "Unrecognized analyzer option: " + other, p.pos);
							}
						case _:
							com.warning(WOptimizer, [], "Unrecognized analyzer option", p.pos);
					}
				case ":has_untyped" | ":hasUntyped":
					config.optimize = false;
				case _:
			}
		}
		return config;
	}

	public static function getClassConfig(com:Context, c:hxc.core.Type.TClass):AnalyzerConfig {
		return updateConfigFromMeta(com, getBaseConfig(com), c.meta);
	}

	public static function getFieldConfig(com:Context, c:hxc.core.Type.TClass, cf:hxc.core.Type.TClassField):AnalyzerConfig {
		return updateConfigFromMeta(com, getClassConfig(com, c), cf.meta);
	}
}
