// Copyright © 2012-2015, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.driver;

import io = watt.io.std : output, error;

import watt.path : temporaryFilename, dirSeparator;
import watt.process : spawnProcess, wait;
import watt.io.file : remove, exists, read;
import watt.conv : toLower;
import watt.text.diff : diff;
import watt.text.format : format;
import watt.text.string : endsWith;

import volt.util.path;
import volt.util.perf : Perf, perf;
import volt.exceptions;
import volt.interfaces;
import volt.errors;
import volt.arg;
import ir = volt.ir.ir;

import volt.parser.parser;
import volt.semantic.languagepass;
import volt.llvm.backend;
import volt.util.mangledecoder;

import volt.visitor.visitor;
import volt.visitor.prettyprinter;
import volt.visitor.debugprinter;
import volt.visitor.docprinter;
import volt.visitor.jsonprinter;


/**
 * Default implementation of @link volt.interfaces.Driver Driver@endlink, replace
 * this if you wish to change the basic operation of the compiler.
 */
class VoltDriver : Driver
{
public:
	VersionSet ver;
	Settings settings;
	Frontend frontend;
	LanguagePass languagePass;
	Backend backend;

	Pass[] debugVisitors;

protected:
	bool mLinkWithLinker;
	bool mLinkWithCC;
	bool mLinkWithMSVC;
	string mCC;
	string mLinker;

	string[] mIncludes;
	string[] mSourceFiles;
	string[] mBitcodeFiles;
	string[] mObjectFiles;

	string[] mLibraryFiles;
	string[] mLibraryPaths;

	string[] mFrameworkNames;
	string[] mFrameworkPaths;

	ir.Module[] mCommandLineModules;

	/// Temporary files created during compile.
	string[] mTemporaryFiles;

	/// Used to track if we should debug print on error.
	bool mDebugPassesRun;

public:
	this(VersionSet ver, Settings s)
	in {
		assert(s !is null);
		assert(ver !is null);
	}
	body {
		this.ver = ver;
		this.settings = s;
		this.frontend = new Parser();

		Driver drv = this;
		languagePass = new VoltLanguagePass(drv, ver, s, frontend);

		if (!s.noBackend) {
			backend = new LlvmBackend(languagePass);
		}

		mIncludes = settings.includePaths;

		mLibraryPaths = settings.libraryPaths;
		mLibraryFiles = settings.libraryFiles;

		mFrameworkNames = settings.frameworkNames;
		mFrameworkPaths = settings.frameworkPaths;

		// Should we add the standard library.
		if (!settings.emitBitcode &&
		    !settings.noLink &&
		    !settings.noStdLib) {
			foreach (file; settings.stdFiles) {
				addFile(file);
			}
		}


		if (settings.linker !is null &&
		    settings.platform == Platform.MSVC) {
			mLinker = settings.linker;
			mLinkWithMSVC = true;
		} else if (settings.linker !is null) {
			mLinker = settings.linker;
			mLinkWithLinker = true;
		} else if (settings.cc !is null) {
			mCC = settings.cc;
			mLinkWithCC = true;
		} else if (settings.platform == Platform.EMSCRIPTEN) {
			mLinker = "emcc";
			mLinkWithCC = true;
		} else if (settings.platform == Platform.MSVC) {
			mLinker = "link.exe";
			mLinkWithMSVC = true;
		} else {
			mLinkWithCC = true;
			mCC = "gcc";
		}

		debugVisitors ~= new DebugMarker("Running DebugPrinter:");
		debugVisitors ~= new DebugPrinter();
		debugVisitors ~= new DebugMarker("Running PrettyPrinter:");
		debugVisitors ~= new PrettyPrinter();
	}


	/*
	 *
	 * Driver functions.
	 *
	 */

	/**
	 * Retrieve a Module by its name. Returns null if none is found.
	 */
	override ir.Module loadModule(ir.QualifiedName name)
	{
		string[] validPaths;
		foreach (path; mIncludes) {
			auto paths = genPossibleFilenames(path, name.strings);

			foreach (possiblePath; paths) {
				if (exists(possiblePath)) {
					validPaths ~= possiblePath;
				}
			}
		}

		if (validPaths.length == 0) {
			return null;
		}
		if (validPaths.length > 1) {
			throw makeMultipleValidModules(name, validPaths);
		}

		return loadAndParse(validPaths[0]);
	}

	override ir.Module[] getCommandLineModules()
	{
		return mCommandLineModules;
	}

	override void close()
	{
		frontend.close();
		languagePass.close();
		if (backend !is null) {
			backend.close();
		}

		settings = null;
		frontend = null;
		languagePass = null;
		backend = null;
	}


	/*
	 *
	 * Misc functions.
	 *
	 */

	void addFile(string file)
	{
		file = settings.replaceEscapes(file);
		version (Windows) {
			// VOLT TEST.VOLT  REM Reppin' MS-DOS
			file = toLower(file);
		}

		if (endsWith(file, ".d", ".volt") > 0) {
			mSourceFiles ~= file;
		} else if (endsWith(file, ".bc")) {
			mBitcodeFiles ~= file;
		} else if (endsWith(file, ".o", ".obj")) {
			mObjectFiles ~= file;
		} else {
			auto str = format("unknown file type '%s'", file);
			throw new CompilerError(str);
		}
	}

	void addFiles(string[] files)
	{
		foreach (file; files) {
			addFile(file);
		}
	}

	int compile()
	{
		mDebugPassesRun = false;
		scope (success) {
			debugPasses();

			foreach (f; mTemporaryFiles) {
				if (f.exists()) {
					f.remove();
				}
			}

			perf.mark(Perf.Mark.EXIT);
		}

		if (settings.noCatch) {
			return intCompile();
		}

		try {
			return intCompile();
		} catch (CompilerPanic e) {
			io.error.writefln(e.msg);
			if (e.file !is null) {
				io.error.writefln("%s:%s", e.file, e.line);
			}
			return 2;
		} catch (CompilerError e) {
			io.error.writefln(e.msg);
			debug if (e.file !is null) {
				io.error.writefln("%s:%s", e.file, e.line);
			}
			return 1;
		} catch (object.Throwable t) {
			io.error.writefln("panic: %s", t.msg);
			if (t.file !is null) {
				io.error.writefln("%s:%s", t.file, t.line);
			}
			return 2;
		}

		version (Volt) assert(false);
	}

protected:
	/**
	 * Loads a file and parses it.
	 */
	ir.Module loadAndParse(string file)
	{
		auto src = cast(string) read(file);
		return frontend.parseNewFile(src, file);
	}

	int intCompile()
	{
		perf.mark(Perf.Mark.PARSING);

		// Load all modules to be compiled.
		// Don't run phase 1 on them yet.
		auto dp = new DocPrinter(languagePass);
		auto jp = new JsonPrinter(languagePass);
		foreach (file; mSourceFiles) {
			debugPrint("Parsing %s.", file);

			auto m = loadAndParse(file);
			languagePass.addModule(m);
			mCommandLineModules ~= m;

			if (settings.writeDocs) {
				dp.transform(m);
			}
		}
		if (settings.writeJson) {
			jp.transform(mCommandLineModules);
		}

		// Skip setting up the pointers incase object
		// was not loaded, after that we are done.
		if (settings.removeConditionalsOnly) {
			languagePass.phase1(mCommandLineModules);
			return 0;
		}

		// After we have loaded all of the modules
		// setup the pointers, this allows for suppling
		// a user defined object module.
		auto lp = cast(VoltLanguagePass)languagePass;
		lp.setupOneTruePointers();

		// Setup diff buffers.
		auto ppstrs = new string[](mCommandLineModules.length);
		auto dpstrs = new string[](mCommandLineModules.length);

		preDiff(mCommandLineModules, "Phase 1", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE1);

		// Force phase 1 to be executed on the modules.
		// This might load new modules.
		languagePass.phase1(mCommandLineModules);
		postDiff(mCommandLineModules, ppstrs, dpstrs);

		// New modules have been loaded,
		// make sure to run everthing on them.
		auto allMods = languagePass.getModules();

		preDiff(mCommandLineModules, "Phase 2", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE2);

		// All modules need to be run through phase2.
		languagePass.phase2(allMods);
		postDiff(mCommandLineModules, ppstrs, dpstrs);

		preDiff(mCommandLineModules, "Phase 3", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE3);

		// All modules need to be run through phase3.
		languagePass.phase3(allMods);
		postDiff(mCommandLineModules, ppstrs, dpstrs);

		debugPasses();

		if (settings.noBackend) {
			return 0;
		}
		perf.mark(Perf.Mark.BACKEND);

		// We will be modifing this later on,
		// but we don't want to change mBitcodeFiles.
		string[] bitcodeFiles = mBitcodeFiles;
		string subdir = getTemporarySubdirectoryName();


		foreach (m; mCommandLineModules) {
			string o = temporaryFilename(".bc", subdir);
			backend.setTarget(o, TargetType.LlvmBitcode);
			debugPrint("Backend %s.", m.name.toString());
			backend.compile(m);
			bitcodeFiles ~= o;
			mTemporaryFiles ~= o;
		}

		string bc, obj, of;

		// Setup files bc.
		if (settings.emitBitcode) {
			bc = settings.getOutput(DEFAULT_BC);
		} else {
			if (bitcodeFiles.length == 1) {
				bc = bitcodeFiles[0];
				bitcodeFiles = null;
			} else {
				bc = temporaryFilename(".bc", subdir);
				mTemporaryFiles ~= bc;
			}
		}

		// Link bitcode files.
		if (bitcodeFiles.length > 0) {
			perf.mark(Perf.Mark.BITCODE);
			linkModules(bc, bitcodeFiles);
		}

		// When outputting bitcode we are now done.
		if (settings.emitBitcode) {
			return 0;
		}

		// Setup object files and output for linking.
		if (settings.noLink) {
			obj = settings.getOutput(DEFAULT_OBJ);
		} else {
			of = settings.getOutput(DEFAULT_EXE);
			obj = temporaryFilename(".o", subdir);
			mTemporaryFiles ~= obj;
		}

		// If we are compiling on the emscripten platform ignore .o files.
		if (settings.platform == Platform.EMSCRIPTEN) {
			perf.mark(Perf.Mark.LINK);
			return emscriptenLink(mLinker, bc, of);
		}

		// Native compilation, turn the bitcode into native code.
		perf.mark(Perf.Mark.ASSEMBLE);
		writeObjectFile(settings, obj, bc);

		// When not linking we are now done.
		if (settings.noLink) {
			return 0;
		}

		// And finally call the linker.
		perf.mark(Perf.Mark.LINK);
		return nativeLink(obj, of);
	}

	int nativeLink(string obj, string of)
	{
		if (mLinkWithMSVC) {
			return msvcLink(mLinker, obj, of);
		} else if (mLinkWithLinker) {
			return ccLink(mLinker, false, obj, of);
		} else if (mLinkWithCC) {
			return ccLink(mCC, true, obj, of);
		} else {
			assert(false);
		}
	}

	int ccLink(string linker, bool cc, string obj, string of)
	{
		string[] args = ["-o", of];

		if (cc) {
			final switch (settings.arch) with (Arch) {
			case X86: args ~= "-m32"; break;
			case X86_64: args ~= "-m64"; break;
			case LE32: throw panic("unsupported arch with cc");
			}
		}

		foreach (objectFile; mObjectFiles ~ obj) {
			args ~= objectFile;
		}
		foreach (libraryPath; mLibraryPaths) {
			args ~= "-L" ~ libraryPath;
		}
		foreach (libraryFile; mLibraryFiles) {
			args ~= "-l" ~ libraryFile;
		}
		foreach (frameworkPath; mFrameworkPaths) {
			args ~= "-F";
			args ~= frameworkPath;
		}
		foreach (frameworkName; mFrameworkNames) {
			args ~= "-framework";
			args ~= frameworkName;
		}
		if (cc) {
			foreach (xcc; settings.xcc) {
				args ~= xcc;
			}
			foreach (xLink; settings.xlinker) {
				args ~= "-Xlinker";
				args ~= xLink;
			}
		} else {
			foreach (xLink; settings.xlinker) {
				args ~= xLink;
			}
		}

		return spawnProcess(linker, args).wait();
	}

	int msvcLink(string linker, string obj, string of)
	{
		string[] args = [
			"/MACHINE:x64",
			"/defaultlib:libcmt",
			"/defaultlib:oldnames",
			"/nologo",
			"/out:" ~ of];

		foreach (objectFile; mObjectFiles ~ obj) {
			args ~= objectFile;
		}
		foreach (libraryPath; mLibraryPaths) {
			args ~= "/LIBPATH:" ~ libraryPath;
		}
		foreach (libraryFile; mLibraryFiles) {
			args ~= libraryFile;
		}
		// We are using msvc link directly so this is
		// linker arguments.
		foreach (xLink; settings.xlinker) {
			args ~= xLink;
		}

		return spawnProcess(linker, args).wait();
	}

	int emscriptenLink(string linker, string bc, string of)
	{
		string[] args = ["-o", of];
		return spawnProcess(linker, ["-o", of, bc]).wait();
	}

private:
	/**
	 * If we are debugging print messages.
	 */
	void debugPrint(string msg, string s)
	{
		if (settings.internalDebug) {
			io.output.writefln(msg, s);
		}
	}

	void debugPasses()
	{
		if (settings.internalDebug && !mDebugPassesRun) {
			mDebugPassesRun = true;
			foreach (pass; debugVisitors) {
				foreach (mod; mCommandLineModules) {
					pass.transform(mod);
				}
			}
		}
	}

	void preDiff(ir.Module[] mods, string title, string[] ppstrs, string[] dpstrs)
	{
		if (!settings.internalDiff) {
			return;
		}

		assert(mods.length == ppstrs.length && mods.length == dpstrs.length);
		StringBuffer ppBuf, dpBuf;
		version (Volt) {
			auto diffPP = new PrettyPrinter(" ", ppBuf.sink);
			auto diffDP = new DebugPrinter(" ", dpBuf.sink);
		} else {
			auto diffPP = new PrettyPrinter(" ", &ppBuf.sink);
			auto diffDP = new DebugPrinter(" ", &dpBuf.sink);
		}
		foreach (i, m; mods) {
			ppBuf.clear();
			dpBuf.clear();
			io.output.writefln("Transformations performed by %s:", title);
			diffPP.transform(m);
			diffDP.transform(m);
			ppstrs[i] = ppBuf.str;
			dpstrs[i] = dpBuf.str;
		}
		diffPP.close();
		diffDP.close();
	}

	void postDiff(ir.Module[] mods, string[] ppstrs, string[] dpstrs)
	{
		if (!settings.internalDiff) {
			return;
		}
		assert(mods.length == ppstrs.length && mods.length == dpstrs.length);
		StringBuffer sb;
		version (Volt) {
			auto pp = new PrettyPrinter(" ", sb.sink);
			auto dp = new DebugPrinter(" ", sb.sink);
		} else {
			auto pp = new PrettyPrinter(" ", &sb.sink);
			auto dp = new DebugPrinter(" ", &sb.sink);
		}
		foreach (i, m; mods) {
			sb.clear();
			dp.transform(m);
			diff(dpstrs[i], sb.str);
			sb.clear();
			pp.transform(m);
			diff(ppstrs[i], sb.str);
		}
		pp.close();
		dp.close();
	}
}

string getOutput(Settings settings, string def)
{
	return settings.outputFile is null ? def : settings.outputFile;
}

version (Windows) {
	enum DEFAULT_BC = "a.bc";
	enum DEFAULT_OBJ = "a.obj";
	enum DEFAULT_EXE = "a.exe";
} else {
	enum DEFAULT_BC = "a.bc";
	enum DEFAULT_OBJ = "a.obj";
	enum DEFAULT_EXE = "a.out";
}
