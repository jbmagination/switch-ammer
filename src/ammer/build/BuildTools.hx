package ammer.build;

import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

using StringTools;

class BuildTools {
  public static function inDir(path:String, f:() -> Void):Void {
    var cwd = Sys.getCwd();
    Sys.setCwd(path);
    f();
    Sys.setCwd(cwd);
  }

  public static function extensions(s:String):String {
    return s
      .replace("%OBJ%", Ammer.config.useMSVC ? "obj" : "o")
      .replace("%DLL%", switch (Sys.systemName()) {
        case "Windows": "dll";
        case "Mac": "dylib";
        case _: "so";
      });
  }

  public static function run(cmd:String, args:Array<String>):Bool {
    Sys.println('$cmd $args');
    return Sys.command(cmd, args) == 0;
  }

  public static function make(data:Array<MakeEntry>, dir:String, name:String):Void {
    // TODO: finer-grained configuration, e.g. choose compiler binary
    if (Ammer.config.useMakefiles) {
      var lb:LineBuf = new LineBuf();
      var phony = [];
      for (e in data) {
        lb.ai('${e.target}:');
        for (req in e.requires)
          lb.a(' $req');
        lb.a("\n");
        lb.indent(() -> {
          switch (e.command) {
            case Phony:
              lb.ai("@:");
              phony.push(e.target);
            case Copy:
              lb.ai('cp ${e.requires[0]} ${e.target}');
            case CompileObject(abi, opt):
              if (Ammer.config.useMSVC) {
                lb.ai('${Ammer.config.pathMSVC}cl /Fe:${e.target} /c ${e.requires.join(" ")}');
                for (path in opt.includePaths)
                  lb.a(' /I "$path"');
              } else {
                if (abi.match(Cpp | ObjectiveCpp)) lb.ai("g++");
                else lb.ai("cc");
                lb.a(' -fPIC -o ${e.target} -c ${e.requires.join(" ")}');
                if (abi.match(Cpp | ObjectiveCpp))
                  lb.a(" -std=c++11");
                for (path in opt.includePaths)
                  lb.a(' -I "$path"');
              }
            case LinkLibrary(abi, opt):
              if (Ammer.config.useMSVC) {
                lb.ai('${Ammer.config.pathMSVC}cl /Fe:${e.target} /LD ${e.requires.join(" ")}');
                for (d in opt.defines)
                  lb.a(' /D$d');
                lb.a(' /link');
                for (path in opt.libraryPaths)
                  lb.a(' /LIBPATH:"$path"');
                for (lib in opt.libraries.concat(opt.staticLibraries != null ? opt.staticLibraries : [])) // TODO: static/dynamic linking on Windows
                  lb.a(' $lib.lib');
              } else {
                if (abi.match(Cpp | ObjectiveCpp)) lb.ai("g++");
                else lb.ai("cc");
                lb.a(' -m64 ${Sys.systemName() == "Mac" ? "-dynamiclib" : "-fPIC -shared"} -o ${e.target} ${e.requires.join(" ")}');
                for (d in opt.defines)
                  lb.a(' -D $d');
                for (path in opt.libraryPaths)
                  lb.a(' -L"$path"');
                if (opt.staticLibraries != null) {
                  if (Sys.systemName() == "Mac") {
                    // TODO: mixing dynamic and static linking on Mac
                    // https://stackoverflow.com/questions/4576235/mixed-static-and-dynamic-link-on-mac-os
                    for (lib in opt.staticLibraries)
                      lb.a(' -l$lib');
                  } else {
                    lb.a(" -Wl,-Bstatic");
                    for (lib in opt.staticLibraries)
                      lb.a(' -l$lib');
                    lb.a(" -Wl,-Bdynamic");
                  }
                }
                for (lib in opt.libraries)
                  lb.a(' -l$lib');
              }
          }
        }, "\t");
        lb.a("\n\n");
      }
      lb.ai(".PHONY:");
      for (e in phony)
        lb.a(' $e');
      lb.a("\n");
      Utils.update('$dir/$name', lb.dump());
      if (Ammer.config.useMSVC) {
        BuildTools.inDir(dir, () -> {
          if (!run(Ammer.config.pathMSVC + "nmake", ["/f", name]))
            Context.fatalError("native compilation failed", Context.currentPos());
        });
      } else {
        if (!run("make", ["-C", dir, "-f", name]))
          Context.fatalError("native compilation failed", Context.currentPos());
      }
    } else {
      var targetMap = [ for (e in data) e.target => e ];
      BuildTools.inDir(dir, () -> {
        function build(name:String):Bool {
          if (!targetMap.exists(name)) {
            return FileSystem.exists(name);
          }
          var e = targetMap[name];
          var target = e.target;
          var requires = e.requires;
          for (req in requires)
            if (!build(req))
              return false;
          var needsUpdate = false;
          if (!FileSystem.exists(target)) {
            needsUpdate = true;
          } else {
            var mtime = FileSystem.stat(target).mtime.getTime();
            for (req in requires) {
              if (FileSystem.exists(req) && FileSystem.stat(req).mtime.getTime() > mtime) {
                needsUpdate = true;
                break;
              }
            }
          }
          if (!needsUpdate)
            return true;
          switch (e.command) {
            case Phony:
            case Copy:
              File.copy(e.requires[0], e.target);
            case CompileObject(abi, opt):
              if (Ammer.config.useMSVC) {
                var args = ['/Fe:${e.target}', "/c"];
                for (req in e.requires)
                  args.push(req);
                for (path in opt.includePaths) {
                  args.push("/I");
                  args.push(path);
                }
                return run('${Ammer.config.pathMSVC}cl', args);
              } else {
                var args = ["-fPIC", "-o", e.target, "-c"];
                for (req in e.requires)
                  args.push(req);
                if (abi == Cpp || abi == ObjectiveCpp) {
                  args.push("-std=c++11");
                }
                for (path in opt.includePaths) {
                  args.push("-I");
                  args.push(path);
                }
                return run(abi.match(Cpp | ObjectiveCpp) ? "g++" : "cc", args);
              }
            case LinkLibrary(abi, opt):
              if (Ammer.config.useMSVC) {
                var args = ['/Fe:${e.target}', "/LD"];
                for (req in e.requires)
                  args.push(req);
                for (d in opt.defines)
                  args.push(' /D$d');
                args.push("/link");
                for (path in opt.libraryPaths)
                  args.push('/LIBPATH:$path');
                for (lib in opt.libraries.concat(opt.staticLibraries != null ? opt.staticLibraries : [])) // TODO: static/dynamic linking on Windows
                  args.push('$lib.lib');
                return run('${Ammer.config.pathMSVC}cl', args);
              } else {
                var args = ["-m64", "-o", e.target];
                if (Sys.systemName() == "Mac") {
                  args.push("-dynamiclib");
                } else {
                  args.push("-shared");
                  args.push("-fPIC");
                }
                for (req in e.requires)
                  args.push(req);
                for (d in opt.defines) {
                  args.push("-D");
                  args.push(d);
                }
                for (path in opt.libraryPaths)
                  args.push('-L$path');
                if (opt.staticLibraries != null) {
                  if (Sys.systemName() == "Mac") {
                    // TODO: mixing dynamic and static linking on Mac
                    // https://stackoverflow.com/questions/4576235/mixed-static-and-dynamic-link-on-mac-os
                    for (lib in opt.staticLibraries)
                      args.push('-l$lib');
                  } else {
                    args.push("-Wl,-Bstatic");
                    for (lib in opt.staticLibraries)
                      args.push('-l$lib');
                    args.push("-Wl,-Bdynamic");
                  }
                }
                for (lib in opt.libraries)
                  args.push('-l$lib');
                return run(abi.match(Cpp | ObjectiveCpp) ? "g++" : "cc", args);
              }
          }
          return true;
        }
        if (!build("all"))
          Context.fatalError("native compilation failed", Context.currentPos());
      });
    }
  }
}

typedef MakeEntry = {
  target:String,
  requires:Array<String>,
  command:MakeCommand
};

typedef MakeCompileOptions = {
  includePaths:Array<String>
};

typedef MakeLinkOptions = {
  defines:Array<String>,
  libraryPaths:Array<String>,
  libraries:Array<String>,
  ?staticLibraries:Array<String>
};

enum MakeCommand {
  Phony;
  Copy;
  CompileObject(abi:ammer.Config.AmmerAbi, opt:MakeCompileOptions);
  LinkLibrary(abi:ammer.Config.AmmerAbi, opt:MakeLinkOptions);
}
