# Bundled .NET reference assemblies

The `net-20`, `net-40` and `net-45` directories are copied unchanged from hxcs
(https://github.com/HaxeFoundation/hxcs, `netlib/`). They are Mono's class libraries, which Mono
licenses under the MIT X11 licence; `LICENSE` is Mono's licensing notice as hxcs ships it (in
`netlib/net-20`).

hxc embeds them when it is built (`NetlibBuild`), so `--cs` and `--dotnet` type-check against
`-D net-ver=20` (the default), `40` or `45` without hxcs installed. When hxcs is installed it is still
used, as Haxe uses it, and its `netlib` directory comes first; the files are the same bytes. hxcs's
other directories (`net-50`, `netcore-*`) are Microsoft's assemblies and are not bundled: those need
hxcs or `--net-std`.
