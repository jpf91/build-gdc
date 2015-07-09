module gdcb.builder;

import std.file, std.exception, std.path, std.stdio, vibe.data.json;
import std.algorithm, std.range;
import std.string : format;
import gdcb.database, gdcb.config, gdcb.util, gdcb.website;
import gdcb.backend.base, gdcb.backend.ctng;

/**
 * 
 */
class Builder
{
private:
    DownloadDB _db;

    // The toolchains we actually want to build
    Toolchain[] _target;
    // Complete ordered queue, including dependecies. Might contain duplicates
    Toolchain[][] _buildQueue;
    // List of already finished builds
    Toolchain[string] _buildCache;

    // List of available Backends
    Backend[] _backends;

    /**
     * Initialize the builder field in toolchain
     */
    void setBuilder(Toolchain toolchain)
    {
        auto backendR = find!"a.getType() == b"(_backends, toolchain.config.backend);
        enforce(!backendR.empty, format("Unknown backend %s", toolchain.config.backend));
        auto backend = backendR.front;

        toolchain.builder = backend.createInstance(toolchain);
    }

    /**
     * Put all dependencies of toolchain and toolchain into array
     * in correct order.
     */
    Toolchain[] addDependencies(Toolchain toolchain, ref string[] pending)
    {
        Toolchain[] result;

        if (pending.canFind(toolchain.toolchainID))
            throw new Exception(format("Circular dependency: %s=>%s", pending,
                toolchain.toolchainID));
        pending ~= toolchain.toolchainID;

        foreach (id; toolchain.builder.calculateDependencies())
        {
            auto depends = Toolchain.load(id, true);
            setBuilder(depends);
            result ~= addDependencies(depends, pending);
        }
        pending = pending[0 .. $ - 1];
        result ~= toolchain;
        return result;
    }

    void updateGDC()
    {
        writeln(": Updating GDC");
        gdcb.util.chdir(configuration.gdcFolder);
        execute("git", "remote", "update");
    }

    void updateConfigs()
    {
        writeln(": Updating build-gdc-config");
        gdcb.util.chdir(configuration.configBaseFolder);
        execute("git", "remote", "update");
    }

    void checkoutConfigs(GitID id)
    {
        writeln(": Checking out build-gdc-config");
        gdcb.util.chdir(configuration.configBaseFolder);
        execute("git", "checkout", id.value);
    }

    /**
     * Calculate dependencies and do the build.
     * 
     * Returns:
     *     false if one or more toolchains failed to build.
     */
    bool build()
    {
        bool result = true;

        scope (exit)
            gdcb.util.remove(configuration.resultTMPFolder);
        // Setup queue
        writeln("Calculating dependencies");
        foreach (toolchain; _target)
        {
            string[] tmp;
            auto dependencies = addDependencies(toolchain, tmp);
            if (verbose)
                writefln("    * '%s' => '%s'", toolchain.toolchainID, dependencies);
            _buildQueue ~= dependencies;
        }

        // Fixup dependencyOnly field of dependencies which we also want to keep
        foreach (set; _buildQueue)
        {
            foreach (entry; set)
            {
                if (_target.canFind!"a.toolchainID == b.toolchainID"(entry))
                    entry.dependencyOnly = false;
            }
        }

        if (verbose)
            writeln("Dumping build queue: ", _buildQueue);

        writeln();
        writeln();
        writeln("===============================================================================");

        foreach (set; _buildQueue)
        {
            writefln(": Building toolchain %s", set[$ - 1].toolchainID);
            foreach (entry; set[0 .. $ - 1])
            {
                if (entry.toolchainID in _buildCache)
                {
                    writefln(": Dependecy %s in cache", entry.toolchainID);
                }
                else
                {
                    writefln(": Building dependecy %s", entry.toolchainID);
                    build(entry);
                    _buildCache[entry.toolchainID] = entry;
                }
            }

            auto entry = set[$ - 1];
            if (entry.toolchainID in _buildCache)
            {
                entry = *(entry.toolchainID in _buildCache);
                writefln(": Toolchain %s in cache", entry.toolchainID);
            }
            else
            {
                writefln(": Now building toolchain %s", entry.toolchainID);
                build(entry);
                _buildCache[entry.toolchainID] = entry;
            }
            if (updateDB && !entry.failed)
                addDownloadToDB(entry);
            if (entry.failed)
                result = false;
            writeln();
            writeln(
                "-------------------------------------------------------------------------------");
        }

        return result;
    }

    /**
     * Build a single toolchain.
     */
    void build(Toolchain toolchain)
    {
        try
        {
            Toolchain[] dependencies;
            foreach (id; toolchain.builder.calculateDependencies())
            {
                enforce(id in _buildCache, format("Internal error: Dependency %s not built"));
                enforce(!_buildCache[id].failed, format("Dependency %s failed to build",
                    id));
                dependencies ~= _buildCache[id];
            }

            try
            {
                tryMkdir(toolchain.resultPath);
                writeln(": Initializing build");
                toolchain.builder.initilize();
                writeln(": Installing dependencies");
                toolchain.builder.installDependencies(dependencies);
                writeln(": Starting backend build function");
                toolchain.builder.build();
                if (verbose)
                    writefln(": Result is at '%s'", toolchain.resultFile);
                if (!toolchain.dependencyOnly)
                {
                    auto resultFolder = configuration.resultFolder.buildPath(
                        toolchain.resultPath.relativePath(configuration.resultTMPFolder));
                    tryMkdir(resultFolder);
                    writefln(": Saving result to '%s'", resultFolder);
                    copyContents(toolchain.resultPath, resultFolder);
                }
            }
            catch (Exception e)
            {
                auto resultFolder = configuration.resultFolder.buildPath(
                    toolchain.resultPath.relativePath(configuration.resultTMPFolder));
                tryMkdir(resultFolder);
                copyContents(toolchain.resultPath, resultFolder);
                throw e;
            }
            finally
            {
                toolchain.builder.cleanup();
            }

        }
        catch (Exception e)
        {
            writefln(": Build failed: %s", e.toString());
            toolchain.failed = true;
        }
    }

    /**
     * Add a download to the database.
     */
    void addDownloadToDB(Toolchain toolchain)
    {
        Download entry;

        auto host = _db.getHost(toolchain.config.host.triplet);
        if (host == Host.init)
        {
            host.name = toolchain.config.host.name;
            host.triplet = toolchain.config.host.triplet;
            host.archiveURL = toolchain.config.host.archiveURL;
            host.comment = toolchain.config.host.comment;
            host.id = _db.addHost(host);
        }

        entry.hostID = host.id;
        entry.setID = _db.getSet(host.id, toolchain.config.set).id;
        entry.target = toolchain.config.target;
        entry.dmdFE = toolchain.source.dmdFE;
        entry.runtime = toolchain.config.runtime;
        entry.gcc = toolchain.source.gccVersion;
        entry.gdcRev = toolchain.source.gdcRevision;
        entry.buildDate = format("%04d-%02d-%02d", toolchain.source.date.year,
            toolchain.source.date.month, toolchain.source.date.day);
        entry.url = format("http://gdcproject.org/downloads/binaries/%s/%s",
            toolchain.config.host.triplet, toolchain.filename);
        entry.comment = toolchain.config.comment;
        entry.runtimeLink = toolchain.config.runtimeLink;
        entry.multilib = toolchain.config.multilib;
        _db.addDownload(entry);
    }

    /**
     * Load build database.
     */
    void loadDB()
    {
        if (!configuration.resultDBFile.exists)
            copy(configuration.sourceDBFile, configuration.resultDBFile);

        _db = new DownloadDB(configuration.resultDBFile);
    }

    /**
     * Write download.json file.
     */
    void writeWebsite()
    {
        auto site = DownloadSite(_db);
        site.writeJSON(configuration.resultJSONFile);
    }

    /**
     * Initialize common folders
     */
    void initFolders()
    {
        if (!exists(configuration.tmpFolder))
            mkdirRecurse(configuration.tmpFolder);
        if (!exists(configuration.resultTMPFolder))
            mkdirRecurse(configuration.resultTMPFolder);
        if (!exists(configuration.sharedFolder))
            mkdirRecurse(configuration.sharedFolder);
        if (!exists(configuration.resultFolder))
            mkdirRecurse(configuration.resultFolder);

    }

public:
    bool updateDB = false;
    bool verbose = false;

    this()
    {
        import gdcb.backend.ctng;

        _backends ~= new CTNGBackend();
        initFolders();
    }

    /**
     * Load build database and regenerate downloads.json.
     */
    void updateWebsite()
    {
        loadDB();
        writeWebsite();
        _db.close();
    }

    /**
     * Build toolchains from ids.
     * 
     * Returns:
     *     true if all toolchains were built. false if one or more toolchains failed to build.
     * 
     * Throws:
     *     All kinds of exceptions on fatal errors.
     */
    bool buildToolchains(string[] ids, GitID[GCCVersion] sourceInfo = null,
        GitID configID = GitID("origin/master"))
    {
        if (updateDB)
        {
            writeln("Loading database");
            loadDB();
        }

        if (!(GCCVersion.snapshot in sourceInfo))
            sourceInfo[GCCVersion.snapshot] = GitID("origin/master");
        if (!(GCCVersion.V4_7 in sourceInfo))
            sourceInfo[GCCVersion.V4_7] = GitID("origin/gdc-4.7");
        if (!(GCCVersion.V4_8 in sourceInfo))
            sourceInfo[GCCVersion.V4_8] = GitID("origin/gdc-4.8");
        if (!(GCCVersion.V4_9 in sourceInfo))
            sourceInfo[GCCVersion.V4_9] = GitID("origin/gdc-4.9");
        if (!(GCCVersion.V5 in sourceInfo))
            sourceInfo[GCCVersion.V5] = GitID("origin/gdc-5");

        updateGDC();
        updateConfigs();
        checkoutConfigs(configID);

        writeln("Initializing backends");
        foreach (backend; _backends)
        {
            writeln("    * ", backend.getType());
            backend.initialize(sourceInfo, verbose);
        }

        writeln("Loading toolchain information");
        foreach (id; ids)
        {
            writeln("    * ", id);
            auto toolchain = Toolchain.load(id, true);
            setBuilder(toolchain);
            _target ~= toolchain;
        }

        auto result = build();

        if (updateDB)
        {
            writeln("Writing website information");
            writeWebsite();
            _db.close();
        }

        return result;
    }
}

enum GCCVersion
{
    snapshot,
    V4_7,
    V4_8,
    V4_9,
    V5
}

struct GitID
{
    string value;
}

class Toolchain
{
    /**
     * Only required as a dependency, don't save results.
     */
    bool dependencyOnly = false;

    /**
     * Attempted to build but failed.
     */
    bool failed = false;

    /**
     * The toolchain id is the path relative to the configs folder.
     */
    string toolchainID;

    /**
     * Json toolchain configuration.
     */
    ToolchainConfig config;

    /**
     * Information about the used source.
     */
    SourceInfo source;

    /**
     * Builder used to build this toolchain.
     */
    BuildInstance builder;

    /**
     * Set by builder.
     */
    string filename;

    this(ToolchainConfig config_, bool dependency = false)
    {
        this.config = config_;
        this.dependencyOnly = dependency;
        this.toolchainID = config.path.relativePath(configuration.configFolder);
    }

    /**
     * Base path where backend should copy files to keep.
     */
    @property string resultPath()
    {
        return buildPath(configuration.resultTMPFolder,
            config.path.relativePath(configuration.configFolder));
    }

    /**
     * Filename where backend generated the final toolchain tarball.
     */
    @property string resultFile()
    {
        return buildPath(configuration.resultTMPFolder, resultFilePart);
    }

    /**
     * Filename relative to result dir.
     */
    @property string resultFilePart()
    {
        return buildPath(config.path.relativePath(configuration.configFolder), filename);
    }

    static Toolchain load(string id, bool dependency = false)
    {
        auto parts = findSplit(id, dirSeparator);
        return Toolchain.load(parts[0], parts[2], dependency);
    }

    static Toolchain load(string host, string tag, bool dependency = false)
    {
        auto hostDir = configuration.configFolder.buildPath(host);
        auto hostFile = hostDir.buildPath("host.json");
        auto toolChainDir = hostDir.buildPath(tag);
        auto toolchainFile = toolChainDir.buildPath("config.json");

        if (!hostDir.exists || !hostDir.isDir)
            throw new Exception(format("Couldn't find host directory %s", hostDir));
        if (!hostFile.exists || !hostFile.isFile)
            throw new Exception(format("Couldn't find host.json in %s", hostDir));
        if (!toolChainDir.exists || !toolChainDir.isDir)
            throw new Exception(format("Couldn't find toolchain directory %s", toolChainDir));
        if (!toolchainFile.exists || !toolchainFile.isFile)
            throw new Exception(format("Couldn't find config.json in %s", toolchainFile));

        HostInfo hostinfo;
        hostinfo.deserializeJson(readText(hostFile).parseJsonString());
        hostinfo.triplet = hostDir.baseName();
        hostinfo.path = hostDir;

        ToolchainConfig config;
        config.deserializeJson(readText(toolchainFile).parseJsonString());
        config.path = absolutePath(toolChainDir);
        config.host = hostinfo;

        return new Toolchain(config, dependency);
    }

    override string toString()
    {
        return toolchainID;
    }
}
