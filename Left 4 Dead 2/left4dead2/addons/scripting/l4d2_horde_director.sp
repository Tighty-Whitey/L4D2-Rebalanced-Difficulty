// File: l4d2_horde_director.sp
// Version: 1.0

#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

// Optional Left4DHooks natives (auto-detected)
native float L4D2_GetFurthestSurvivorFlow();
native float L4D2Direct_GetFlowDistance(int client);
native float L4D2Direct_GetMapMaxFlowDistance();
native float L4D2_GetScriptValueFloat(const char[] key, float defValue);
native void L4D2_ExecVScriptCode(const char[] code);

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define L4D2_ZOMBIECLASS_TANK 8

#define PLUGIN_PREFIX "l4d2_"
#define PLUGIN_NAME "horde_director"

public Plugin myinfo =
{
    name        = "[L4D2] Horde Director",
    author      = "Tighty-Whitey",
    description = "Horde director with timed triggers, flow-aware resume, trigger caps, and pace engine.",
    version     = "1.0",
    url         = ""
};

// --- Core state ---

bool g_bIsSurvivorFighting;
float g_fTimePast, g_fTimeCap;
int g_iSurvivorsLeft;

GlobalForward g_fwdOnTrigger, g_fwdOnTick;

// Core cvars

ConVar cAllow;
bool g_bAllow;
ConVar cTimeMin;
float g_fTimeMin;
ConVar cTimeMax;
float g_fTimeMax;
ConVar cCountDead;
bool g_bCountDead;
ConVar cCountBots;
bool g_bCountBots;
ConVar cScreamCue;
int g_iHordeType;
// 1 = z_spawn mob, 2 = director_force_panic_event;

// Survivor thresholds
ConVar cSurvivorMin;
int g_iSurvivorMin;
ConVar cSurvivorMax;
int g_iSurvivorMax;
ConVar g_hSurvivorLimit;
int g_iBaselineSurvivors = 4;

// Trigger gating
ConVar cAllowDuringTank;
bool g_bAllowDuringTank = false;
ConVar cBlockAliveFrac;
float g_fBlockAliveFrac = -1.0;

// Trigger cap
ConVar cTrigMax;
int g_iTrigMax;
ConVar cTrigReset;
bool g_bTrigReset;
int g_iTrigCount = 0;

// Debug
ConVar cDbg;
bool g_bDbg = false;

char g_sDbgLog[PLATFORM_MAX_PATH];

void InitDebugLog()
{
	BuildPath(Path_SM, g_sDbgLog, sizeof(g_sDbgLog), "logs/%s_debug.log", PLUGIN_NAME);
}

void DebugLog(const char[] fmt, any ...)
{
	if (!g_bDbg)
	return;

	char msg[512];
	VFormat(msg, sizeof(msg), fmt, 2);

	LogMessage("%s", msg);
	LogToFileEx(g_sDbgLog, "%s", msg);
}

// HUD (hint box)
ConVar cHudTimer;
bool g_bHudTimer = false;
Handle g_hHudTimer = null;

// Map blocklist: no timer accumulation and no horde trigger
ConVar cNoHordeMaps;
bool g_bNoHordeHere = false;

// Game mode filter (empty = all)
ConVar cModes;
ConVar g_hMPGameMode;
bool g_bModeAllowed = true;

// FF proportional override
ConVar cFFPercent;
float g_fFFPercent = 0.25;
int g_iRoundStartMax = 0;
bool g_bFFDead[MAXPLAYERS+1];

// Dynamic pace engine cvars/state
ConVar cPaceEnable;
bool g_bPaceEnable;
ConVar cPaceWindow;
float g_fPaceWindow;
ConVar cPaceLow;
float g_fPaceLow;
ConVar cPaceHigh;
float g_fPaceHigh;
ConVar cPaceBonusMax;
float g_fPaceBonusMax;
ConVar cPaceDecay;
float g_fPaceDecay;
ConVar cPaceAuto;
bool g_bPaceAuto;
ConVar cPaceAutoSecs;
float g_fPaceAutoSecs;
ConVar cPaceAutoLo;
float g_fPaceAutoLo;
ConVar cPaceAutoHi;
float g_fPaceAutoHi;

float g_fLastFlow = 0.0;
float g_fPaceBonus = 0.0;
float g_fPaceWindowSum = 0.0;
int g_iPaceWinCount = 0;
float g_fAutoStart = 0.0;
float g_fAutoSum = 0.0;
int g_iAutoCount = 0;

// Client sound on threshold (L4D1 only) with 15s cooldown
ConVar cPaceSoundEnable;
bool g_bPaceSoundEnable = true;
ConVar cPaceSound; char g_sPaceSound[96] = "Event.StartAtmosphere_Lighthouse";
float g_fPaceSoundNext = 0.0;

// Panic-ambient cue CVARs
ConVar cPanicAmbEnable;
bool g_bPanicAmbEnable = true;
ConVar cPanicAmbSound; char g_sPanicAmbSound[96] = "Event.AmbientMob";

// VScript buffer for L4D1/2 detection
ConVar g_hVSBuf;

// --- Backcap (slow-play clamp) CVARs/state ---

// CVARs
ConVar cBackcapEnable;
bool g_bBackcapEnable = true;
// master enable for clamp behavior;
ConVar cBackcapFrac;
float g_fBackcapFrac = -1.0;
// -1 = disabled (park-only clamp, no drain);
ConVar cBackRate;
float g_fBackRate = 1.5;
// drain rate when enabled;
ConVar cSlowHold;
float g_fSlowHold = 3.0;
// engage slow clamp after sustained slow;
ConVar cFastRelease;
float g_fFastRelease = 2.0;
// release after sustained fast;
ConVar cBackGrace;
float g_fBackGrace = 15.0;
// grace credit from prior fast play;
ConVar cBackDelay;
float g_fBackDelay = 3.0;
// dwell of no progress before draining above target;

// Derived/operational
float g_fPaceSpeed = 0.0; // set in PaceUpdate()
bool g_bSlowClamp = false; // clamp engaged
float g_fSlowAccum = 0.0;
float g_fFastAccum = 0.0;
float g_fPaceCredit = 0.0;
float g_fNoProgressAccum = 0.0; // dwell timer while above target before draining

// --- Helpers: parsing and clamps ---

static int ClampInt(int v, int lo, int hi){ if (v < lo) return lo;
if (v > hi) return hi;
return v;
}
static float FMin(float a, float b) { return (a < b) ? a : b; }
static float FMax(float a, float b) { return (a > b) ? a : b; }

int GetServerSurvivorLimit()
{
	if (g_hSurvivorLimit != null)
	{
		int v = g_hSurvivorLimit.IntValue;
		if (v > 0) return v;
	}
	return 4;
}

// Parse
int ParseCountOrPercent(const char[] input, int base)
{
	char s[32];
	strcopy(s, sizeof(s), input);
	TrimString(s);

	int len = strlen(s);
	if (len <= 0) return 0;

	bool hasPercent = (s[len-1] == '%');
	if (hasPercent)
	{
		s[len-1] = '\0';
		TrimString(s);
		float p = StringToFloat(s);
		if (p < 0.0) p = 0.0;
		if (p > 100.0) p = 100.0;
		int out = RoundToCeil(float(base) * (p * 0.01));
		return ClampInt(out, 0, base);
	}

	bool hasDot = (StrContains(s, ".", false) != -1);
	float f = StringToFloat(s);
	if (hasDot && f >= 0.0 && f <= 1.0)
	{
		int out = RoundToCeil(float(base) * f);
		return ClampInt(out, 0, base);
	}

	int n = StringToInt(s);
	return n;
}

// --- Natives registration ---

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("horde_director");
	CreateNative("HD_SetHordesTime", NativeSetTime);
	CreateNative("HD_GetHordesTime", NativeGetTime);
	CreateNative("HD_TriggerHordes", NativeTrigger);
	CreateNative("HD_GetTriggerCount", NativeGetTriggerCount);

	MarkNativeAsOptional("L4D2_GetFurthestSurvivorFlow");
	MarkNativeAsOptional("L4D2Direct_GetFlowDistance");
	MarkNativeAsOptional("L4D2Direct_GetMapMaxFlowDistance");
	MarkNativeAsOptional("L4D2_GetScriptValueFloat");
	MarkNativeAsOptional("L4D2_ExecVScriptCode");
	return APLRes_Success;
}

// --- Plugin start ---

public void OnPluginStart()
{
	cAllow = CreateConVar(PLUGIN_NAME ... "_allow", "1", "0=Plugin off, 1=Plugin on.", FCVAR_NOTIFY);

	// Timing + checks
	cTimeMin = CreateConVar(PLUGIN_NAME ... "_time_min", "180", "Horde timer starting number. (A number between minimum and maximum values will be selected depending on configuration and the amount of living survivors or present bots.)", FCVAR_NOTIFY);
	cTimeMax = CreateConVar(PLUGIN_NAME ... "_time_max", "240", "Horde timer maximum threshold number. (Horde may trigger earlier depending on configuration and the amount of living survivors or present bots.)", FCVAR_NOTIFY);
	cCountDead = CreateConVar(PLUGIN_NAME ... "_count_dead", "0", "Keep counting the timer when survivors are dead (0/1). (This prevents timer pausing if deaths drop below survivor_min)", FCVAR_NOTIFY);

	cCountBots = CreateConVar(PLUGIN_NAME ... "_count_bots", "1", "Keep counting the timer when survivors are bots (0/1). (This prevents timer pausing if only bots remain below survivor_min)", FCVAR_NOTIFY);

	// Survivor thresholds (fractions of baseline)
	cSurvivorMax = CreateConVar(PLUGIN_NAME ... "_survivor_max", "1.0", "Fraction of baseline survivors used as top end for timer scaling (0..1).", FCVAR_NOTIFY);
	cSurvivorMin = CreateConVar(PLUGIN_NAME ... "_survivor_min", "0.25", "Fraction of baseline survivors at/above which countdown is active (0..1).", FCVAR_NOTIFY);
	cScreamCue = CreateConVar(PLUGIN_NAME ... "_warn_cue", "1", "Keep the stock L4D's scream sound cue of a plugin's mega horde. (0/1).", FCVAR_NOTIFY);
	cAllowDuringTank = CreateConVar(PLUGIN_NAME ... "_allow_during_tank", "0", "Allow mega horde trigger while a Tank is alive (0/1).", FCVAR_NOTIFY);

	cBlockAliveFrac = CreateConVar(PLUGIN_NAME ... "_block_alive_frac", "-1", "Block mega horde trigger when alive survivors are at or below this fraction of survivor_limit (-1=off, 0..1).", FCVAR_NOTIFY);

	cTrigMax = CreateConVar(PLUGIN_NAME ... "_triggers_max", "-1", "Max action triggers per round (-1: infinite, 0: off)", FCVAR_NOTIFY);
	cTrigReset = CreateConVar(PLUGIN_NAME ... "_triggers_reset", "1", "Reset trigger counter on round start/transition", FCVAR_NOTIFY);

	cDbg = CreateConVar(PLUGIN_NAME ... "_debug", "0", "Debug logs", FCVAR_NONE);

	cHudTimer = CreateConVar(PLUGIN_NAME ... "_hud_timer", "0", "Show elapsed timer HintText HUD (0=off, 1=on).", FCVAR_NOTIFY);

	cFFPercent = CreateConVar(PLUGIN_NAME ... "_ff_death_percent", "0.25", "Proportion of round-start survivors dead by FF to lock scaling to max and bypass survivor_min gate (0..1)", FCVAR_NOTIFY);

	// Dynamic pace cvars (defaults updated)
	cPaceEnable = CreateConVar(PLUGIN_NAME ... "_pace_enable", "1", "Enable dynamic pace engine (0/1)", FCVAR_NOTIFY);
	cPaceWindow = CreateConVar(PLUGIN_NAME ... "_pace_window", "8.0", "Seconds in rolling flow-speed window", FCVAR_NOTIFY);
	cPaceLow = CreateConVar(PLUGIN_NAME ... "_pace_low", "70.0", "Speed where pacing starts (flow units/sec)", FCVAR_NOTIFY);
	cPaceHigh = CreateConVar(PLUGIN_NAME ... "_pace_high", "120.0", "Speed where pacing saturates (flow units/sec)", FCVAR_NOTIFY);
	cPaceBonusMax = CreateConVar(PLUGIN_NAME ... "_pace_bonus_max", "5.0","Max extra seconds per second at full pace", FCVAR_NOTIFY);
	cPaceDecay = CreateConVar(PLUGIN_NAME ... "_pace_decay", "0.25", "Seconds to decay pacing bonus when below threshold", FCVAR_NOTIFY);
	cPaceAuto = CreateConVar(PLUGIN_NAME ... "_pace_auto", "0", "Auto-calibrate pace thresholds from early-run baseline", FCVAR_NOTIFY);
	cPaceAutoSecs = CreateConVar(PLUGIN_NAME ... "_pace_auto_secs", "12.0","Seconds to gather baseline samples", FCVAR_NOTIFY);
	cPaceAutoLo = CreateConVar(PLUGIN_NAME ... "_pace_auto_lo", "1.05", "Low threshold multiplier of baseline", FCVAR_NOTIFY);
	cPaceAutoHi = CreateConVar(PLUGIN_NAME ... "_pace_auto_hi", "1.40", "High threshold multiplier of baseline", FCVAR_NOTIFY);

	// Client sound cvars
	cPaceSoundEnable = CreateConVar(PLUGIN_NAME ... "_pace_sound_enable", "1", "Play client sound when pace hits 30% of max (L4D1 only) (0/1)", FCVAR_NOTIFY);
	cPaceSound = CreateConVar(PLUGIN_NAME ... "_pace_sound", "Event.StartAtmosphere_Lighthouse", "Soundscript entry for playgamesound", FCVAR_NOTIFY);

	// Director panic ambient cue cvars
	cPanicAmbEnable = CreateConVar(PLUGIN_NAME ... "_panic_ambient_enable", "1", "Play ambient mob sound 5s after director panic event (0/1)", FCVAR_NOTIFY);
	cPanicAmbSound = CreateConVar(PLUGIN_NAME ... "_panic_ambient_sound", "Event.AmbientMob", "Soundscript entry for playgamesound after director panic", FCVAR_NOTIFY);

	// CSV of maps where this plugin is disabled (no timer, no horde)
	cNoHordeMaps = CreateConVar(PLUGIN_NAME ... "_no_horde_maps_csv", "c1m4_atrium,c2m5_concert,c3m1_plankcountry,c3m2_swamp,c3m3_shantytown,c3m4_plantation,c4m5_milltown_escape,c6m3_port,c7m3_port,c8m5_rooftop,c11m5_runway,c12m5_cornfield,c13m4_cutthroatcreek", "CSV of maps where this plugin is disabled (no timer, no horde).", FCVAR_NOTIFY);

	// Game modes allowlist. Empty = all.
	cModes = CreateConVar(PLUGIN_NAME ... "_modes", "", "Enable this plugin in these game modes, comma-separated, no spaces. Empty = all.", FCVAR_NOTIFY);

	// Backcap cvars (slow-play clamp)
	cBackcapEnable = CreateConVar(PLUGIN_NAME ... "_pace_backcap_enable", "1", "Enable slow-play clamp (0/1). If frac<0, clamp parks time with no drain.", FCVAR_NOTIFY);
	cBackcapFrac = CreateConVar(PLUGIN_NAME ... "_pace_backcap_frac", "0.5", "Backcap fraction of current cap (-1 disables drain; 0..1 enables)", FCVAR_NOTIFY);
	cBackRate = CreateConVar(PLUGIN_NAME ... "_pace_back_rate", "1.5", "Seconds per tick to pull back while clamping (frac>=0)", FCVAR_NOTIFY);
	cSlowHold = CreateConVar(PLUGIN_NAME ... "_pace_slow_hold", "15.0", "Seconds below low threshold to engage clamp", FCVAR_NOTIFY);
	cFastRelease = CreateConVar(PLUGIN_NAME ... "_pace_fast_release", "2.0", "Seconds above release threshold to disengage clamp", FCVAR_NOTIFY);
	cBackGrace = CreateConVar(PLUGIN_NAME ... "_pace_back_grace", "30.0", "Grace credit seconds earned by fast play, burned while slow", FCVAR_NOTIFY);
	cBackDelay = CreateConVar(PLUGIN_NAME ... "_pace_back_delay", "60.0", "Seconds of no progress before drain starts when above frac target", FCVAR_NOTIFY);

	// External baseline and hooks
	g_hSurvivorLimit = FindConVar("survivor_limit");
	if (g_hSurvivorLimit != null) g_hSurvivorLimit.AddChangeHook(OnConVarChanged);

	g_hMPGameMode = FindConVar("mp_gamemode");
	if (g_hMPGameMode != null) g_hMPGameMode.AddChangeHook(OnConVarChanged);

	AutoExecConfig(true, PLUGIN_PREFIX ... PLUGIN_NAME);

	InitDebugLog();
	ApplyCvars();
	StartOrStopHud();

	UpdateAllowedGameMode();
	// Silence time cvars
	MakeCvarSilent(cTimeMin);
	MakeCvarSilent(cTimeMax);

	RegConsoleCmd("hd_pace", Cmd_PaceDump);

	// Hooks cAllow.AddChangeHook(OnConVarChanged);

	cTimeMin.AddChangeHook(OnConVarChanged);
	cTimeMax.AddChangeHook(OnConVarChanged);
	cCountDead.AddChangeHook(OnConVarChanged);
	cCountBots.AddChangeHook(OnConVarChanged);
	cSurvivorMin.AddChangeHook(OnConVarChanged);
	cSurvivorMax.AddChangeHook(OnConVarChanged);
	cScreamCue.AddChangeHook(OnConVarChanged);
	cAllowDuringTank.AddChangeHook(OnConVarChanged);
	cBlockAliveFrac.AddChangeHook(OnConVarChanged);
	cTrigMax.AddChangeHook(OnConVarChanged);
	cTrigReset.AddChangeHook(OnConVarChanged);
	cDbg.AddChangeHook(OnConVarChanged);
	cHudTimer.AddChangeHook(OnConVarChanged);
	cFFPercent.AddChangeHook(OnConVarChanged);
	cPaceEnable.AddChangeHook(OnConVarChanged);
	cPaceWindow.AddChangeHook(OnConVarChanged);
	cPaceLow.AddChangeHook(OnConVarChanged);
	cPaceHigh.AddChangeHook(OnConVarChanged);
	cPaceBonusMax.AddChangeHook(OnConVarChanged);
	cPaceDecay.AddChangeHook(OnConVarChanged);
	cPaceAuto.AddChangeHook(OnConVarChanged);
	cPaceAutoSecs.AddChangeHook(OnConVarChanged);
	cPaceAutoLo.AddChangeHook(OnConVarChanged);
	cPaceAutoHi.AddChangeHook(OnConVarChanged);
	cPaceSoundEnable.AddChangeHook(OnConVarChanged);
	cPaceSound.AddChangeHook(OnConVarChanged);
	cPanicAmbEnable.AddChangeHook(OnConVarChanged);
	cPanicAmbSound.AddChangeHook(OnConVarChanged);
	cNoHordeMaps.AddChangeHook(OnConVarChanged);

	cModes.AddChangeHook(OnConVarChanged);
	// Backcap change hooks
	cBackcapEnable.AddChangeHook(OnConVarChanged);
	cBackcapFrac.AddChangeHook(OnConVarChanged);
	cBackRate.AddChangeHook(OnConVarChanged);
	cSlowHold.AddChangeHook(OnConVarChanged);
	cFastRelease.AddChangeHook(OnConVarChanged);
	cBackGrace.AddChangeHook(OnConVarChanged);
	cBackDelay.AddChangeHook(OnConVarChanged);

	HookEvent("round_start", E_RoundStart);
	HookEvent("player_left_safe_area", E_LeftSafeArea);
	HookEvent("player_death", E_PlayerDeath);
	HookEvent("player_spawn", E_PlayerSpawn);
	HookEvent("survivor_rescued", E_PlayerRescued);
	HookEvent("defibrillator_used", E_DefibUsed);
	HookEvent("map_transition", E_RoundEnd);
	HookEvent("finale_vehicle_leaving", E_RoundEnd);
	HookEvent("mission_lost", E_RoundEnd);
	HookEvent("round_end", E_RoundEnd);

	g_fwdOnTrigger = new GlobalForward("OnHordeDirectorTrigger", ET_Event, Param_FloatByRef, Param_Float, Param_CellByRef);
	g_fwdOnTick = new GlobalForward("OnHordeDirectorContinuing", ET_Event, Param_FloatByRef, Param_Float);

	// VScript buffer for L4D1 detection
	g_hVSBuf = FindConVar("l4d2_vscript_return");
	if (g_hVSBuf == null) g_hVSBuf = CreateConVar("l4d2_vscript_return", "", "VScript return buffer", FCVAR_DONTRECORD);
}

// --- Utility ---

void SafeKillTimer(Handle &h)
{
	if (h != null)
	{
		if (IsValidHandle(h))
		KillTimer(h);
		h = null;
	}
}

void StartOrStopHud()
{
	if (g_hHudTimer != null && !IsValidHandle(g_hHudTimer))
	g_hHudTimer = null;

	if (g_bHudTimer)
	{
		if (g_hHudTimer != null)
		SafeKillTimer(g_hHudTimer);

		g_hHudTimer = CreateTimer(1.0, T_Hud, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		if (g_hHudTimer != null)
		SafeKillTimer(g_hHudTimer);
	}
}

public Action T_Hud(Handle t, any data)
{
	if (!g_bHudTimer)
	return Plugin_Stop;
	if (!g_bIsSurvivorFighting || !g_bAllow || !g_bModeAllowed || g_bNoHordeHere)
	return Plugin_Continue;
	int secs = RoundToFloor(g_fTimePast + 0.0001);

	char line[64];
	Format(line, sizeof(line), "Timer: %d", secs);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != TEAM_SURVIVOR)
		continue;

		if (!CheckCommandAccess(i, "hordedirector_hudtimer", ADMFLAG_GENERIC, true))

		continue;

		PrintHintText(i, "%s", line);
	}

	return Plugin_Continue;
}

void MakeCvarSilent(ConVar cv)
{
	if (cv == null) return;

	int f = cv.Flags;
	int s = f & ~(FCVAR_NOTIFY | FCVAR_REPLICATED);

	if (s != f)
	cv.Flags = s;
}

void SetFloatSilent(ConVar cv, float v)
{
	if (cv == null) return;

	int f = cv.Flags;
	cv.Flags = f & ~(FCVAR_NOTIFY | FCVAR_REPLICATED);

	cv.SetFloat(v);

	cv.Flags = f;
}

void RecomputeSurvivorThresholds()
{
	g_iBaselineSurvivors = GetServerSurvivorLimit();

	char sMax[32];
	cSurvivorMax.GetString(sMax, sizeof(sMax));
	int maxCount = ParseCountOrPercent(sMax, g_iBaselineSurvivors);
	if (maxCount <= 0) maxCount = g_iBaselineSurvivors;
	g_iSurvivorMax = maxCount;

	char sMin[32];
	cSurvivorMin.GetString(sMin, sizeof(sMin));
	int minCount = ParseCountOrPercent(sMin, g_iSurvivorMax);
	if (minCount < 0) minCount = 0;
	if (minCount > g_iSurvivorMax) minCount = g_iSurvivorMax;
	g_iSurvivorMin = minCount;
}

void ApplyCvars()
{
	g_bAllow = cAllow.BoolValue;

	g_fTimeMin = cTimeMin.FloatValue;
	g_fTimeMax = cTimeMax.FloatValue;
	g_iHordeType = (cScreamCue.IntValue <= 0) ? 1 : 2;
	g_bCountDead = cCountDead.BoolValue;
	g_bCountBots = cCountBots.BoolValue;
	g_bAllowDuringTank = cAllowDuringTank.BoolValue;
	g_fBlockAliveFrac = cBlockAliveFrac.FloatValue;
	if (g_fBlockAliveFrac > 1.0) g_fBlockAliveFrac = 1.0;
	if (g_fBlockAliveFrac < -1.0) g_fBlockAliveFrac = -1.0;
	g_iTrigMax = cTrigMax.IntValue;
	g_bTrigReset = cTrigReset.BoolValue;
	g_bDbg = cDbg.BoolValue;
	g_bHudTimer = cHudTimer.BoolValue;

	g_fFFPercent = cFFPercent.FloatValue;
	RecomputeSurvivorThresholds();

	g_bPaceEnable = cPaceEnable.BoolValue;
	g_fPaceWindow = cPaceWindow.FloatValue;
	g_fPaceLow = cPaceLow.FloatValue;
	g_fPaceHigh = cPaceHigh.FloatValue;
	g_fPaceBonusMax = cPaceBonusMax.FloatValue;
	g_fPaceDecay = cPaceDecay.FloatValue;
	g_bPaceAuto = cPaceAuto.BoolValue;
	g_fPaceAutoSecs = cPaceAutoSecs.FloatValue;
	g_fPaceAutoLo = cPaceAutoLo.FloatValue;
	g_fPaceAutoHi = cPaceAutoHi.FloatValue;

	g_bPaceSoundEnable = cPaceSoundEnable.BoolValue;
	cPaceSound.GetString(g_sPaceSound, sizeof(g_sPaceSound));

	g_bPanicAmbEnable = cPanicAmbEnable.BoolValue;
	cPanicAmbSound.GetString(g_sPanicAmbSound, sizeof(g_sPanicAmbSound));

	// Backcap cache (runtime enable is tied to pace enable)
	bool rawBackcap = cBackcapEnable.BoolValue;
	g_bBackcapEnable = (g_bPaceEnable && rawBackcap);
	g_fBackcapFrac = cBackcapFrac.FloatValue;
	g_fBackRate = cBackRate.FloatValue;
	g_fSlowHold = cSlowHold.FloatValue;
	g_fFastRelease = cFastRelease.FloatValue;
	g_fBackGrace = cBackGrace.FloatValue;
	g_fBackDelay = cBackDelay.FloatValue;

	// If pace engine is disabled, fully clear all pace/backcap state.
	if (!g_bPaceEnable)
	{
		g_fPaceBonus = 0.0;
		g_fPaceWindowSum = 0.0;
		g_iPaceWinCount = 0;
		g_fAutoStart = 0.0;
		g_fAutoSum = 0.0;
		g_iAutoCount = 0;
		g_fPaceSoundNext = 0.0;

		g_fPaceSpeed = 0.0;
		g_bSlowClamp = false;
		g_fSlowAccum = 0.0;
		g_fFastAccum = 0.0;
		g_fPaceCredit = 0.0;
		g_fNoProgressAccum= 0.0;
	}
}

void UpdateNoHordeMapFlag()
{
	g_bNoHordeHere = false;

	if (cNoHordeMaps == null)
	return;

	char list[512];
	cNoHordeMaps.GetString(list, sizeof(list));
	TrimString(list);

	if (!list[0])
	return;

	char cur[64];
	GetCurrentMap(cur, sizeof(cur));

	// Lowercase current map
	for (int i = 0; cur[i] != '\0'; i++)
	cur[i] = CharToLower(cur[i]);

	char parts[64][64];
	int count = ExplodeString(list, ",", parts, sizeof(parts), sizeof(parts[]), true);

	for (int i = 0; i < count; i++)
	{
		TrimString(parts[i]);
		if (!parts[i][0])
		continue;

		for (int k = 0; parts[i][k] != '\0'; k++)
		parts[i][k] = CharToLower(parts[i][k]);

		if (StrEqual(cur, parts[i], false))
		{
			g_bNoHordeHere = true;
			break;
		}
	}
}

void UpdateAllowedGameMode()
{
	g_bModeAllowed = true;

	if (cModes == null)
	return;

	char list[256];
	cModes.GetString(list, sizeof(list));
	TrimString(list);

	// Empty = all.
	if (!list[0])
	return;

	if (g_hMPGameMode == null)
	g_hMPGameMode = FindConVar("mp_gamemode");

	if (g_hMPGameMode == null)
	{
		g_bModeAllowed = false;
		return;
	}

	char mode[64];
	g_hMPGameMode.GetString(mode, sizeof(mode));
	TrimString(mode);

	char hay[320];
	char needle[96];
	Format(hay, sizeof(hay), ",%s,", list);
	Format(needle, sizeof(needle), ",%s,", mode);

	g_bModeAllowed = (StrContains(hay, needle, false) != -1);
}

void OnConVarChanged(ConVar c, const char[] o, const char[] n)
{
	ApplyCvars();
	MakeCvarSilent(cTimeMin);
	MakeCvarSilent(cTimeMax);

	if (c == cNoHordeMaps)
	{
		UpdateNoHordeMapFlag();
	}

	if (c == cHudTimer)
	StartOrStopHud();

	if (c == cModes || c == g_hMPGameMode)
	UpdateAllowedGameMode();
}

public void OnConfigsExecuted()
{
	ApplyCvars();
	MakeCvarSilent(cTimeMin);
	MakeCvarSilent(cTimeMax);

	UpdateNoHordeMapFlag();
	UpdateAllowedGameMode();
	StartOrStopHud();
}

public void OnMapStart()
{
	CreateTimer(1.0, T_Tick, _, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT);

	UpdateNoHordeMapFlag();
	UpdateAllowedGameMode();
	StartOrStopHud();
}

public void OnMapEnd()
{
	SafeKillTimer(g_hHudTimer);
}

public void OnPluginEnd()
{
	SafeKillTimer(g_hHudTimer);
}

bool IsL4D1Campaign()
{
	if (GetFeatureStatus(FeatureType_Native, "L4D2_ExecVScriptCode") == FeatureStatus_Available && g_hVSBuf != null)
	{
		L4D2_ExecVScriptCode(
		"try{" ...
		"local s=-1;" ...
		"if (\"SessionOptions\" in getroottable() && ::SessionOptions!=null) {" ...
		" if (\"SurvivorSet\" in ::SessionOptions) s = ::SessionOptions.SurvivorSet;" ...
		" else if (\"DefaultSurvivorSet\" in ::SessionOptions) s = ::SessionOptions.DefaultSurvivorSet;" ...
		"}" ...
		"Convars.SetValue(\"l4d2_vscript_return\",\"\"+s);" ...
		"}catch(e){Convars.SetValue(\"l4d2_vscript_return\",\"-1\");}"
		);
		char buf[32];
		g_hVSBuf.GetString(buf, sizeof(buf));
		int set = StringToInt(buf);
		if (set == 1) return true;
		if (set == 2) return false;
	}

	char map[64];
	GetCurrentMap(map, sizeof(map));
	if (strncmp(map, "c8m", 3, false) == 0) return true;
	if (strncmp(map, "c9m", 3, false) == 0) return true;
	if (strncmp(map, "c10m", 4, false) == 0) return true;
	if (strncmp(map, "c11m", 4, false) == 0) return true;
	if (strncmp(map, "c12m", 4, false) == 0) return true;
	if (strncmp(map, "c13m", 4, false) == 0) return true;
	if (strncmp(map, "c14m", 4, false) == 0) return true;

	if (StrContains(map, "l4d_", false) == 0) return true;
	if (StrContains(map, "hospital", false) != -1) return true;
	if (StrContains(map, "airport", false) != -1) return true;
	if (StrContains(map, "farm", false) != -1) return true;
	if (StrContains(map, "smalltown", false) != -1) return true;
	if (StrContains(map, "lighthouse", false) != -1) return true;

	return false;
}

// --- Round lifecycle ---

void E_RoundStart(Event e, const char[] n, bool b)
{
	g_iRoundStartMax = CountAliveSurvivors();
	for (int i = 1; i <= MaxClients; i++) g_bFFDead[i] = false;

	g_fLastFlow = GetFurthestFlow();
	g_fPaceBonus = 0.0;
	g_fPaceWindowSum = 0.0;
	g_iPaceWinCount = 0;

	g_iAutoCount = 0;
	g_fAutoSum = 0.0;
	g_fAutoStart = 0.0;
	g_fPaceSoundNext = 0.0;

	// Backcap runtime state
	g_bSlowClamp = false;
	g_fSlowAccum = 0.0;
	g_fFastAccum = 0.0;
	g_fPaceCredit = 0.0;
	g_fNoProgressAccum = 0.0;
}

void E_LeftSafeArea(Event e, const char[] n, bool b)
{
	g_bIsSurvivorFighting = true;
	g_fTimePast = 0.0;
	int alive = CountAliveSurvivors();
	if (g_iRoundStartMax < g_iSurvivorMax) g_iRoundStartMax = g_iSurvivorMax;
	if (g_iRoundStartMax < alive) g_iRoundStartMax = alive;

	g_fLastFlow = GetFurthestFlow();
	g_fPaceBonus = 0.0;
	g_fPaceWindowSum = 0.0;
	g_iPaceWinCount = 0;

	g_iAutoCount = 0;
	g_fAutoSum = 0.0;
	g_fAutoStart = GetEngineTime();
	if (g_bTrigReset) g_iTrigCount = 0;

	g_fPaceSoundNext = 0.0;

	// Backcap runtime reset
	g_bSlowClamp = false;
	g_fSlowAccum = 0.0;
	g_fFastAccum = 0.0;
	g_fPaceCredit = 0.0;
	g_fNoProgressAccum = 0.0;
}

void E_RoundEnd(Event e, const char[] n, bool b)
{
	g_bIsSurvivorFighting = false;

	g_fPaceBonus = 0.0;
	g_fPaceWindowSum = 0.0;
	g_iPaceWinCount = 0;
	g_iAutoCount = 0;
	g_fAutoSum = 0.0;
	g_fAutoStart = 0.0;

	for (int i = 1; i <= MaxClients; i++) g_bFFDead[i] = false;
	if (g_bTrigReset) g_iTrigCount = 0;

	g_fPaceSoundNext = 0.0;

	// Backcap runtime reset
	g_bSlowClamp = false;
	g_fSlowAccum = 0.0;
	g_fFastAccum = 0.0;
	g_fPaceCredit = 0.0;
	g_fNoProgressAccum = 0.0;
}

// --- Events ---

void E_PlayerDeath(Event e, const char[] n, bool b)
{
	int client = GetClientOfUserId(e.GetInt("userid"));
	int attacker = GetClientOfUserId(e.GetInt("attacker"));
	if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR) return;

	bool ff = (attacker > 0 && IsClientInGame(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR && attacker != client);
	if (ff) g_bFFDead[client] = true;
}

void E_PlayerSpawn(Event e, const char[] n, bool b)
{
	int c = GetClientOfUserId(e.GetInt("userid"));
	if (c > 0)
	g_bFFDead[c] = false;
}

void E_PlayerRescued(Event e, const char[] n, bool b)
{
	int c = GetClientOfUserId(e.GetInt("victim"));
	if (c > 0)
	g_bFFDead[c] = false;
}

void E_DefibUsed(Event e, const char[] n, bool b)
{
	int c = GetClientOfUserId(e.GetInt("subject"));
	if (c > 0)
	g_bFFDead[c] = false;
}

// --- Backcap update ---

void BackcapUpdate()
{
	if (!g_bBackcapEnable) {
		g_bSlowClamp = false;
		g_fSlowAccum = 0.0;
		g_fFastAccum = 0.0;
		g_fNoProgressAccum = 0.0;
		return;
	}

	// Earn grace credit while pacing positively; burn during slow
	if (g_fPaceBonus > 0.0)
	g_fPaceCredit = FMin(g_fPaceCredit + g_fPaceBonus, g_fBackGrace);

	// Thresholds from pace cvars
	float slowTh = g_fPaceLow;
	float fastTh = (g_fPaceLow + g_fPaceHigh) * 0.5; // mid hysteresis

	float dt = 1.0; // per-second tick cadence

	if (g_fPaceSpeed <= slowTh) {
		g_fSlowAccum += dt;
		g_fFastAccum = 0.0;
	} else if (g_fPaceSpeed >= fastTh) {
		g_fFastAccum += dt;
		g_fSlowAccum = 0.0;
	} else {
		// middle band: decay both
		g_fSlowAccum = FMax(0.0, g_fSlowAccum - 0.5 * dt);
		g_fFastAccum = FMax(0.0, g_fFastAccum - 0.5 * dt);
	}

	// Credit burns only during slow dwell
	if (g_fPaceSpeed <= slowTh && g_fPaceCredit > 0.0)
	{
		g_fPaceCredit = FMax(0.0, g_fPaceCredit - dt);
	}

	// Engage clamp when sustained slow and no remaining grace
	if (!g_bSlowClamp && g_fSlowAccum >= g_fSlowHold && g_fPaceCredit <= 0.0)
	{
		g_bSlowClamp = true;
		g_fFastAccum = 0.0;
		g_fNoProgressAccum = 0.0; // Reset dwell timer on engage
	}

	// Release clamp when sustained fast; count stops during release window until this hits
	if (g_bSlowClamp && g_fFastAccum >= g_fFastRelease)
	{
		g_bSlowClamp = false;
		g_fSlowAccum = 0.0;
		g_fNoProgressAccum = 0.0;
	}

}

// --- Tick ---
static bool s_WasFrozen = false;
static int s_UnfreezeGraceTicks = 0;
static int s_FrozenTickCount = 0;

public Action T_Tick(Handle t)
{
	if (!g_bIsSurvivorFighting)
	return Plugin_Continue;

	if (!g_bAllow)
	return Plugin_Continue;
	if (!g_bModeAllowed)
	return Plugin_Continue;

	if (g_bNoHordeHere)
	return Plugin_Continue;

	UpdateSurvivorCountsAndCap();
	if (!ShouldLockToMaxScaling() && g_iSurvivorsLeft < g_iSurvivorMin) return Plugin_Continue;
	Action act = Plugin_Continue;

	Call_StartForward(g_fwdOnTick);
	Call_PushFloatRef(g_fTimePast);
	Call_PushFloat(g_fTimeCap);
	Call_Finish(act);

	bool freeze = false;
	bool changed = false;
	if (act == Plugin_Changed) changed = true;
	else if (act != Plugin_Continue) freeze = true;

	// Convert freeze/changed flags into an Action.
	if (freeze)
	{
		act = Plugin_Stop; // any non-Continue/non-Changed means "frozen"
	}
	else if (changed)
	{
		act = Plugin_Changed;
	}

	// If frozen (or any veto), reset pace state and enter freeze bookkeeping.
	if (act != Plugin_Continue && act != Plugin_Changed)
	{
		// Reset pace/backcap state on freeze.
		g_fPaceBonus = 0.0;
		g_fPaceWindowSum = 0.0;
		g_iPaceWinCount = 0;

		g_bSlowClamp = false;
		g_fSlowAccum = 0.0;
		g_fFastAccum = 0.0;
		g_fNoProgressAccum = 0.0;

		s_FrozenTickCount++;
		s_WasFrozen = true;
		s_UnfreezeGraceTicks = 0;

		return Plugin_Continue;
	}

	// Unfreeze grace (real freeze): after 2+ frozen ticks, give a small grace window.
	if (s_WasFrozen && s_FrozenTickCount >= 2)
	{
		s_WasFrozen = false;
		s_FrozenTickCount = 0;

		// Reset pace/backcap state on unfreeze and resync flow baseline.
		g_fPaceBonus = 0.0;
		g_fPaceWindowSum = 0.0;
		g_iPaceWinCount = 0;

		g_fLastFlow = GetFurthestFlow();

		g_bSlowClamp = false;
		g_fSlowAccum = 0.0;
		g_fFastAccum = 0.0;
		g_fNoProgressAccum = 0.0;

		s_UnfreezeGraceTicks = 3;
		return Plugin_Continue;
	}

	// If we were flagged frozen but it wasn't a "real freeze", clear the flag.
	if (s_WasFrozen)
	{
		s_WasFrozen = false;
		s_FrozenTickCount = 0;
	}

	// Apply post-unfreeze grace ticks (plain +1.0 per tick, no pace/backcap).
	if (s_UnfreezeGraceTicks > 0)
	{
		s_UnfreezeGraceTicks--;
		g_fLastFlow = GetFurthestFlow();

		g_fTimePast += 1.0;
		if (g_fTimePast >= g_fTimeCap)
		TryTrigger();

		return Plugin_Continue;
	}

	// Pace disabled: plain +1.0 per tick.
	if (!g_bPaceEnable)
	{
		g_fTimePast += 1.0;
		if (g_fTimePast >= g_fTimeCap)
		TryTrigger();

		return Plugin_Continue;
	}

	// Pace enabled: compute bonus and apply backcap logic.
	PaceUpdate();     // computes g_fPaceBonus and sets g_fPaceSpeed
	BackcapUpdate();  // decides clamp state and manages credit

	float add = 1.0 + g_fPaceBonus;

	// Backcap clamp overrides add (and may drain g_fTimePast).
	if (g_bSlowClamp)
	{
		// frac < 0: park time (no gain).
		if (g_fBackcapFrac < 0.0)
		{
			add = 0.0;
		}
		else
		{
			float target = FMax(0.0, g_fTimeCap * g_fBackcapFrac);

			if (g_fTimePast > target)
			{
				// Optional dwell before draining.
				if (g_fBackDelay > 0.0)
				{
					if (g_fPaceSpeed <= g_fPaceLow)
					g_fNoProgressAccum += 1.0;
					else
					g_fNoProgressAccum = 0.0;

					if (g_fNoProgressAccum >= g_fBackDelay)
					{
						float back = (g_fBackRate > 0.0) ? g_fBackRate : 0.0;
						g_fTimePast = FMax(target, g_fTimePast - back);
					}

					add = 0.0; // always no gain while clamped above target
				}
				else
				{
					// No dwell: always drain.
					float back = (g_fBackRate > 0.0) ? g_fBackRate : 0.0;
					g_fTimePast = FMax(target, g_fTimePast - back);
					add = 0.0;
				}
			}
			else
			{
				// At/below target while clamped: park and reset dwell.
				add = 0.0;
				g_fNoProgressAccum = 0.0;
			}
		}
	}

	g_fTimePast += add;
	if (g_fTimePast >= g_fTimeCap)
	TryTrigger();

	return Plugin_Continue;

} // end of T_Tick()

// --- Pace engine ---

void PaceUpdate()
{
	if (!g_bPaceEnable)
	{
		g_fPaceBonus = 0.0;
		g_fPaceSpeed = 0.0;
		return;
	}

	float cur = GetFurthestFlow();
	float df = cur - g_fLastFlow;
	if (df < 0.0) df = 0.0;
	g_fLastFlow = cur;

	float winSec = (g_fPaceWindow > 0.5) ? g_fPaceWindow : 0.5;
	g_fPaceWindowSum += df;
	g_iPaceWinCount++;

	int cap = RoundToNearest(winSec);
	if (g_iPaceWinCount > cap)
	{
		g_fPaceWindowSum -= (g_fPaceWindowSum / float(g_iPaceWinCount));
		g_iPaceWinCount = cap;
	}

	float speed = (g_iPaceWinCount > 0) ? (g_fPaceWindowSum / float(g_iPaceWinCount)) : 0.0;
	g_fPaceSpeed = speed;

	if (g_bPaceAuto && g_fAutoStart > 0.0 && (GetEngineTime() - g_fAutoStart) <= g_fPaceAutoSecs)
	{
		g_fAutoSum += speed;
		g_iAutoCount++;

		if ((GetEngineTime() - g_fAutoStart) >= g_fPaceAutoSecs)
		{
			float base = (g_iAutoCount > 0) ? (g_fAutoSum / float(g_iAutoCount)) : speed;
			g_fPaceLow = base * g_fPaceAutoLo;
			g_fPaceHigh = base * g_fPaceAutoHi;

			if (g_fPaceHigh <= g_fPaceLow)
			g_fPaceHigh = g_fPaceLow + 1.0;

			g_fAutoStart = 0.0;
		}
	}

	float gain = 0.0;
	if (speed > g_fPaceLow)
	gain = (speed >= g_fPaceHigh) ? 1.0 : (speed - g_fPaceLow) / (g_fPaceHigh - g_fPaceLow);

	float target = gain * g_fPaceBonusMax;

	if (target < g_fPaceBonus)
	{
		float decay = (g_fPaceDecay > 0.01) ? g_fPaceDecay : 0.01;
		float step = (g_fPaceBonus - target) * (1.0 / decay);

		g_fPaceBonus -= step;
		if (g_fPaceBonus < target)
		g_fPaceBonus = target;
	}
	else
	{
		g_fPaceBonus = target;
	}

	if (g_bDbg)
	{
		DebugLog("[PACE] flow=%.1f speed=%.1f gain=%.2f bonus=%.2f low=%.1f high=%.1f win=%.1f",
		cur, speed, gain, g_fPaceBonus, g_fPaceLow, g_fPaceHigh, g_fPaceWindow);
	}

	float need = g_fPaceBonusMax * 0.30;
	if (g_bPaceSoundEnable
	&& IsL4D1Campaign()
	&& g_fPaceBonus >= (need - 0.0001)
	&& GetEngineTime() >= g_fPaceSoundNext)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

			ClientCommand(i, "playgamesound %s", g_sPaceSound);
		}

		g_fPaceSoundNext = GetEngineTime() + 15.0;
	}
}

// --- Survivor math and cap ---
void UpdateSurvivorCountsAndCap()
{
	int alive = CountAliveSurvivors();
	g_iSurvivorsLeft = alive;

	int effective = alive;
	if (ShouldLockToMaxScaling())
	{
		int refMax = g_iRoundStartMax;
		if (refMax < g_iSurvivorMax) refMax = g_iSurvivorMax;
		if (refMax < alive) refMax = alive;
		effective = refMax;
	}

	float denom = float(g_iSurvivorMax - g_iSurvivorMin);
	float step = (denom > 0.0) ? ((g_fTimeMax - g_fTimeMin) / denom) : 0.0;
	g_fTimeCap = g_fTimeMax - step * float(effective - g_iSurvivorMin);
}

int CountAliveSurvivors()
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		continue;

		if (GetClientTeam(i) != TEAM_SURVIVOR)
		continue;

		if (!g_bCountDead && !IsPlayerAlive(i))
		continue;

		if (!g_bCountBots && IsFakeClient(i))
		continue;

		count++;
	}

	return count;
}

bool ShouldLockToMaxScaling()
{
	if (g_fFFPercent <= 0.0 || g_iRoundStartMax <= 0) return false;
	int ffDead = 0;
	for (int i = 1;
	i <= MaxClients;
	i++) if (g_bFFDead[i]) ffDead++;
	float frac = float(ffDead) / float(g_iRoundStartMax);
	return frac >= g_fFFPercent;
}

// --- Flow helpers ---
float GetFurthestFlow()
{
	if (GetFeatureStatus(FeatureType_Native, "L4D2_GetFurthestSurvivorFlow") == FeatureStatus_Available)
	return L4D2_GetFurthestSurvivorFlow();

	float maxf = 0.0;
	if (GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetFlowDistance") == FeatureStatus_Available)
	{
		for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR)
		{
			float f = L4D2Direct_GetFlowDistance(i);
			if (f > maxf) maxf = f;
		}
	}
	return maxf;
}

float GetMapMaxFlow()
{
	if (GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetMapMaxFlowDistance") == FeatureStatus_Available)
	return L4D2Direct_GetMapMaxFlowDistance();
	return 0.0;
}

/// --------------- Trigger pipeline ---------------
bool TryTrigger()
{
	if (!g_bAllow)
	return false;

	if (!g_bModeAllowed)
	return false;

	if (g_bNoHordeHere)
	return false;

	if (g_iTrigMax == 0)
	return false;

	if (g_iTrigMax > 0 && g_iTrigCount >= g_iTrigMax)
	return false;

	if (!g_bAllowDuringTank && IsTankAlive())
	return false;

	if (g_fBlockAliveFrac >= 0.0)
	{
		int limit = GetServerSurvivorLimit();
		int thr = RoundToCeil(float(limit) * g_fBlockAliveFrac);
		thr = ClampInt(thr, 0, limit);

		if (thr > 0 && g_iSurvivorsLeft <= thr)
		return false;
	}

	int horde_type = g_iHordeType;

	Action act = Plugin_Continue;
	Call_StartForward(g_fwdOnTrigger);
	Call_PushFloatRef(g_fTimePast);
	Call_PushFloat(g_fTimeCap);
	Call_PushCellRef(horde_type);
	Call_Finish(act);

	if (act != Plugin_Continue && act != Plugin_Changed)
	return false;

	if (g_fTimePast >= g_fTimeCap && SummonHordes(horde_type))
	{
		g_iTrigCount++;
		g_fTimePast = 0.0;
		return true;
	}

	return false;
}

bool SummonHordes(int horde_type)
{
	if (!g_bAllow)
	return false;

	if (!g_bModeAllowed)
	return false;

	if (g_bNoHordeHere)
	return false;

	int client = GetRandomSurvivor();
	if (client == 0) return false;

	// 1 = z_spawn mob (no scream cue), 2 = director_force_panic_event (stock scream cue).
	if (horde_type == 1)
	{
		CheatCommand(client, "z_spawn", "mob");
		if (g_bPanicAmbEnable)
		CreateTimer(5.0, T_PlayAmbientAfterPanic, _, TIMER_FLAG_NO_MAPCHANGE);
		return true;
	}
	else if (horde_type == 2)
	{
		CheatCommand(client, "director_force_panic_event");

		if (g_bPanicAmbEnable)
		{
			CreateTimer(5.0, T_PlayAmbientAfterPanic, _, TIMER_FLAG_NO_MAPCHANGE);
		}
		return true;
	}

	return false;
}

void CheatCommand(int client, const char[] command, const char[] arguments = "")
{
	int flags = GetCommandFlags(command);
	SetCommandFlags(command, flags & ~FCVAR_CHEAT);
	if (arguments[0]) FakeClientCommand(client, "%s %s", command, arguments);
	else FakeClientCommand(client, "%s", command);
	SetCommandFlags(command, flags);
}

public Action T_PlayAmbientAfterPanic(Handle t, any data)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != TEAM_SURVIVOR)
		continue;
		ClientCommand(i, "playgamesound %s", g_sPanicAmbSound);
	}
	return Plugin_Stop;
}

int GetRandomSurvivor()
{
	static ArrayList a;
	if (!a) a = new ArrayList();
	a.Clear();

	for (int i = 1; i <= MaxClients; i++)
	if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
	a.Push(i);

	if (a.Length > 0)
	{
		SetRandomSeed(GetGameTickCount());
		return a.Get(GetRandomInt(0, a.Length - 1));
	}
	return 0;
}

bool IsTankAlive()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED)
		continue;

		if (IsPlayerAlive(client) &&
		GetEntProp(client, Prop_Send, "m_zombieClass") == L4D2_ZOMBIECLASS_TANK)
		return true;
	}

	return false;
}

int NativeSetTime(Handle plugin, int numParams)
{
	g_fTimePast = view_as<float>(GetNativeCell(1));
	return 0;
}

any NativeGetTime(Handle plugin, int numParams)
{
	return g_fTimePast;
}

int NativeTrigger(Handle plugin, int numParams)
{
	if (g_fTimePast < g_fTimeCap)
	g_fTimePast = g_fTimeCap;   // force “ready to trigger”

	return TryTrigger();
}

any NativeGetTriggerCount(Handle plugin, int numParams)
{
	return g_iTrigCount;
}

// --- On-demand pace dump ---
public Action Cmd_PaceDump(int client, int args)
{
	float speed = (g_iPaceWinCount > 0) ? (g_fPaceWindowSum / float(g_iPaceWinCount)) : 0.0;
	PrintToServer("[HD] pace: speed=%.1f bonus=%.2f low=%.1f high=%.1f win=%.1f enable=%d",
	speed, g_fPaceBonus, g_fPaceLow, g_fPaceHigh, g_fPaceWindow, g_bPaceEnable ? 1 : 0);
	return Plugin_Handled;
}
