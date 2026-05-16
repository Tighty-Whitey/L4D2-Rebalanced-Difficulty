#pragma semicolon 1
#include <sourcemod>

#define VERSION                      "1.1"
#define PATH_PREFIX_ACTUAL           "cfg/"
#define PATH_PREFIX_VISIBLE          "mapconfig/"
#define PATH_PREFIX_VISIBLE_GENERAL  "mapconfig/general/"
#define PATH_PREFIX_VISIBLE_GAMETYPE "mapconfig/gametype/"
#define PATH_PREFIX_VISIBLE_MAP      "mapconfig/maps/"
#define PATH_PREFIX_VISIBLE_UNDEFINED "mapconfig/undefined/"
#define TYPE_GENERAL                 0
#define TYPE_MAP                     1
#define TYPE_GAMETYPE                2
#define TYPE_UNDEFINED               3

public Plugin:myinfo = {
    name        = "Extended mapconfig package",
    author      = "Milo",
    description = "Allows you to use seperate config files for each gametype and map. Now with undefined fallback config.",
    version     = VERSION,
    url         = "http://sourcemod.corks.nl/"
};

public OnPluginStart() {
    CreateConVar("extendedmapconfig_version", VERSION, "Current version of the extended mapconfig plugin", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
    createConfigFiles();
}

public OnConfigsExecuted() {
    new String:configFilename[PLATFORM_MAX_PATH];
    new String:name[PLATFORM_MAX_PATH];
    name = "all";
    getConfigFilename(configFilename, sizeof(configFilename), name, TYPE_GENERAL);
    PrintToServer("Loading mapconfig: general configfile (%s.cfg).", name);
    ServerCommand("exec \"%s\"", configFilename);
    GetCurrentMap(name, sizeof(name));
    if (SplitString(name, "_", name, sizeof(name)) != -1) {
        getConfigFilename(configFilename, sizeof(configFilename), name, TYPE_GAMETYPE);
        PrintToServer("Loading mapconfig: gametype configfile (%s.cfg).", name);
        ServerCommand("exec \"%s\"", configFilename);
    }
    GetCurrentMap(name, sizeof(name));
    new String:mapActualPath[PLATFORM_MAX_PATH];
    getConfigFilename(configFilename, sizeof(configFilename), name, TYPE_MAP);
    getConfigFilename(mapActualPath, sizeof(mapActualPath), name, TYPE_MAP, true);
    if (FileExists(mapActualPath) && !IsConfigFileEmpty(mapActualPath)) {
        PrintToServer("Loading mapconfig: mapspecific configfile (%s.cfg).", name);
        ServerCommand("exec \"%s\"", configFilename);
    } else {
        PrintToServer("Loading mapconfig: mapspecific config is empty or missing, loading undefined fallback.");
        ServerCommand("exec \"%s\"", "mapconfig/undefined/undefined.cfg");
    }
}

createConfigFiles() {
    new String:game[64];
    new String:name[PLATFORM_MAX_PATH];
    GetGameFolderName(game, sizeof(game));
    createConfigDir(PATH_PREFIX_VISIBLE, PATH_PREFIX_ACTUAL);
    createConfigDir(PATH_PREFIX_VISIBLE_GENERAL, PATH_PREFIX_ACTUAL);
    createConfigDir(PATH_PREFIX_VISIBLE_GAMETYPE, PATH_PREFIX_ACTUAL);
    createConfigDir(PATH_PREFIX_VISIBLE_MAP, PATH_PREFIX_ACTUAL);
    createConfigDir(PATH_PREFIX_VISIBLE_UNDEFINED, PATH_PREFIX_ACTUAL);
    createConfigFile("all", TYPE_GENERAL, "All maps");
    createConfigFile("undefined", TYPE_UNDEFINED, "Undefined maps (fallback)");
    if (strcmp(game, "tf", false) == 0) {
        createConfigFile("cp", TYPE_GAMETYPE, "Control-point maps");
        createConfigFile("ctf", TYPE_GAMETYPE, "Capture-the-Flag maps");
        createConfigFile("pl", TYPE_GAMETYPE, "Payload maps");
        createConfigFile("arena", TYPE_GAMETYPE, "Arena-style maps");
    } else if (strcmp(game, "cstrike", false) == 0) {
        createConfigFile("cs", TYPE_GAMETYPE, "Hostage maps");
        createConfigFile("de", TYPE_GAMETYPE, "Defuse maps");
        createConfigFile("as", TYPE_GAMETYPE, "Assasination maps");
        createConfigFile("es", TYPE_GAMETYPE, "Escape maps");
    }
    new Handle:adtMaps = CreateArray(16, 0);
    new serial = -1;
    ReadMapList(adtMaps, serial, "allexistingmaps__", MAPLIST_FLAG_MAPSFOLDER|MAPLIST_FLAG_NO_DEFAULT);
    new mapcount = GetArraySize(adtMaps);
    if (mapcount > 0) for (new i = 0; i < mapcount; i++) {
        GetArrayString(adtMaps, i, name, sizeof(name));
        createConfigFile(name, TYPE_MAP, name);
    }
}

getConfigFilename(String:buffer[], const maxlen, const String:filename[], const type=TYPE_MAP, const bool:actualPath=false) {
    new String:prefixVisible[PLATFORM_MAX_PATH];
    if (type == TYPE_GENERAL) {
        prefixVisible = PATH_PREFIX_VISIBLE_GENERAL;
    } else if (type == TYPE_GAMETYPE) {
        prefixVisible = PATH_PREFIX_VISIBLE_GAMETYPE;
    } else if (type == TYPE_UNDEFINED) {
        prefixVisible = PATH_PREFIX_VISIBLE_UNDEFINED;
    } else {
        prefixVisible = PATH_PREFIX_VISIBLE_MAP;
    }
    Format(buffer, maxlen, "%s%s%s.cfg", (actualPath ? PATH_PREFIX_ACTUAL : ""), prefixVisible, filename);
}

createConfigDir(const String:filename[], const String:prefix[]="") {
    new String:dirname[PLATFORM_MAX_PATH];
    Format(dirname, sizeof(dirname), "%s%s", prefix, filename);
    CreateDirectory(dirname, FPERM_U_READ + FPERM_U_WRITE + FPERM_U_EXEC + FPERM_G_READ + FPERM_G_WRITE + FPERM_G_EXEC + FPERM_O_READ + FPERM_O_WRITE + FPERM_O_EXEC);
}

createConfigFile(const String:filename[], type=TYPE_MAP, const String:label[]="") {
    new String:configFilename[PLATFORM_MAX_PATH];
    new String:configLabel[128];
    new Handle:fileHandle = INVALID_HANDLE;
    getConfigFilename(configFilename, sizeof(configFilename), filename, type, true);
    if (FileExists(configFilename)) return;
    fileHandle = OpenFile(configFilename, "w+");
    if (strlen(label) > 0) strcopy(configLabel, sizeof(configLabel), label);
    else strcopy(configLabel, sizeof(configLabel), configFilename);
    if (fileHandle != INVALID_HANDLE) {
        WriteFileLine(fileHandle, "// Configfile for: %s", configLabel);
        CloseHandle(fileHandle);
    }
}

stock bool:IsConfigFileEmpty(const String:path[]) {
    new Handle:file = OpenFile(path, "r");
    if (file == INVALID_HANDLE) return true;
    new String:line[256];
    while (!IsEndOfFile(file) && ReadFileLine(file, line, sizeof(line))) {
        TrimString(line);
        if (line[0] == '\0') continue;
        if (line[0] == '/' && line[1] == '/') continue;
        CloseHandle(file);
        return false;
    }
    CloseHandle(file);
    return true;
}