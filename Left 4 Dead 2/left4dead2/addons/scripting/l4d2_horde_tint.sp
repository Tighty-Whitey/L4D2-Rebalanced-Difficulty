// l4d2_horde_tint.sp

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
	name = "[L4D2] Horde Tint",
	author = "Tighty-Whitey",
	description = "Triggers a cinematic tint during a mega horde.",
	version = "1.0",
	url = ""
};

// ---------------------------- CVARs ----------------------------
ConVar gCvarEnable;
ConVar gCvarModes;
ConVar gCvarDuration;
ConVar gCvarFadeIn;
ConVar gCvarFadeOut;
ConVar gCvarAlpha;
ConVar gCvarTest;
ConVar gCvarTestSeconds;
ConVar gCvarForceClear;

ConVar g_hMPGameMode;

// Palettes
ConVar gCvarColorL4D1;
ConVar gCvarColorL4D2;
ConVar gCvarColorPassing;

// Final tint controls
ConVar gCvarDarkScale;
ConVar gCvarPreHandoffMs;
ConVar gCvarFinalAlphaMatch;

// Persistence + intensity
ConVar gCvarPersistOnHurt;
ConVar gCvarIntensity;

// Finale toggle
ConVar gCvarFinaleEnable;

// ---------------------------- Constants ----------------------------
#define FFADE_IN        0x0001
#define FFADE_OUT       0x0002
#define FFADE_MODULATE  0x0004
#define FFADE_STAYOUT   0x0008
#define FFADE_PURGE     0x0010

#define TEAM_SURVIVOR   2

// ---------------------------- State ----------------------------
bool g_bModeAllowed = true;

bool g_bActive = false;
bool g_bPrePlaced = false;
bool g_bIsFinaleMap = false;

bool g_bIsL4D1Port = false;
bool g_bIsPassing = false;

int g_iColor[3] = {60, 170, 72};
int g_iColorL4D1[3] = {60, 170, 72};
int g_iColorL4D2[3] = {204, 160, 54};
int g_iColorPassing[3] = {210, 40, 150};

int g_iCurrentAlpha = 0;

Handle g_hEndTimer = null;
Handle g_hForceTimer = null;
Handle g_hPreTimer = null;

float g_fTintStartTime = 0.0;
float g_fPlannedEndTime = 0.0;

int g_iFadeR = 0;
int g_iFadeG = 0;
int g_iFadeB = 0;
int g_iFadeA = 0;

// ---------------------------- Helpers ----------------------------
static int ClampInt(int v, int lo, int hi)
{
	if (v < lo) return lo;
	if (v > hi) return hi;
	return v;
}

static int ScaleAlpha(int baseAlpha, float intensity)
{
	if (intensity < 0.0) intensity = 0.0;
	if (intensity > 1.0) intensity = 1.0;

	float a = float(baseAlpha) * intensity;
	if (a < 0.0) a = 0.0;
	if (a > 255.0) a = 255.0;

	return ClampInt(RoundToNearest(a), 0, 255);
}

static void KillTimerSafe(Handle &t)
{
	if (t == null)
		return;

	CloseHandle(t);
	t = null;
}

// ---------------------------- Mode filter ----------------------------
void UpdateAllowedGameMode()
{
	g_bModeAllowed = true;

	if (gCvarModes == null)
		return;

	char list[256];
	gCvarModes.GetString(list, sizeof(list));
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

public void Cvar_ModesChanged(ConVar c, const char[] ov, const char[] nv)
{
	UpdateAllowedGameMode();
}

// ---------------------------- Map detection ----------------------------
static bool IsKnownFinaleName(const char[] map)
{
	static const char finals[][] =
	{
		"c1m4_atrium",
		"c2m5_concert",
		"c3m4_plantation",
		"c4m5_milltown_escape",
		"c5m5_bridge",
		"c6m3_port",
		"c7m3_port",
		"c8m5_rooftop",
		"c9m2_lighthouse",
		"c10m5_docks",
		"c11m5_runway",
		"c12m5_cornfield",
		"c14m2_lighthouse" // Last Stand
	};

	for (int i = 0; i < sizeof(finals); i++)	
	{
		if (StrEqual(map, finals[i], false))
			return true;
	}
	return false;
}

void DetectFinaleMap()
{
	g_bIsFinaleMap = false;

	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "trigger_finale")) != -1)
	{
		g_bIsFinaleMap = true;
		return;
	}

	ent = -1;
	while ((ent = FindEntityByClassname(ent, "func_escapezone")) != -1)
	{
		g_bIsFinaleMap = true;
		return;
	}

	char map[64];
	GetCurrentMap(map, sizeof(map));
	g_bIsFinaleMap = IsKnownFinaleName(map);
}

void DetectCampaignKind()
{
	g_bIsL4D1Port = false;
	g_bIsPassing = false;

	char map[64];
	GetCurrentMap(map, sizeof(map));

	// The Passing
	if (strncmp(map, "c6m", 3, false) == 0)
	{
		g_bIsPassing = true;
		return;
	}

	// L4D1 ports: c8m..c12m
	if (strncmp(map, "c8m", 3, false) == 0 ||
		strncmp(map, "c9m", 3, false) == 0 ||
		strncmp(map, "c10m", 4, false) == 0 ||
		strncmp(map, "c11m", 4, false) == 0 ||
		strncmp(map, "c12m", 4, false) == 0 ||
		StrEqual(map, "c14m1_junkyard", false) ||
		StrEqual(map, "c14m2_lighthouse", false))
	{
		g_bIsL4D1Port = true;
	}
}

// ---------------------------- Palette parsing ----------------------------
void ParseRGB(const char[] s, int out[3], int defR, int defG, int defB)
{
	int r = defR, g = defG, b = defB;

	char parts[3][8];
	int n = ExplodeString(s, " ", parts, sizeof(parts), sizeof(parts[]));
	if (n >= 3)
	{
		r = StringToInt(parts[0]);
		g = StringToInt(parts[1]);
		b = StringToInt(parts[2]);
	}

	out[0] = ClampInt(r, 0, 255);
	out[1] = ClampInt(g, 0, 255);
	out[2] = ClampInt(b, 0, 255);
}

void ParsePaletteCvars()
{
	char buf[64];

	gCvarColorL4D1.GetString(buf, sizeof(buf));
	ParseRGB(buf, g_iColorL4D1, 60, 170, 72);

	gCvarColorL4D2.GetString(buf, sizeof(buf));
	ParseRGB(buf, g_iColorL4D2, 204, 160, 54);

	gCvarColorPassing.GetString(buf, sizeof(buf));
	ParseRGB(buf, g_iColorPassing, 210, 40, 150);
}

void SelectActivePalette()
{
	if (g_bIsPassing)
	{
		g_iColor[0] = g_iColorPassing[0];
		g_iColor[1] = g_iColorPassing[1];
		g_iColor[2] = g_iColorPassing[2];
	}
	else if (g_bIsL4D1Port)
	{
		g_iColor[0] = g_iColorL4D1[0];
		g_iColor[1] = g_iColorL4D1[1];
		g_iColor[2] = g_iColorL4D1[2];
	}
	else
	{
		g_iColor[0] = g_iColorL4D2[0];
		g_iColor[1] = g_iColorL4D2[1];
		g_iColor[2] = g_iColorL4D2[2];
	}
}

// ---------------------------- CVAR hooks ----------------------------
public void Cvar_PaletteChanged(ConVar c, const char[] ov, const char[] nv)
{
	ParsePaletteCvars();
	SelectActivePalette();
}

public void Cvar_AlphaChanged(ConVar c, const char[] ov, const char[] nv)
{
	g_iCurrentAlpha = ClampInt(gCvarAlpha.IntValue, 0, 255);
}

public void Cvar_TestChanged(ConVar c, const char[] ov, const char[] nv)
{
	if (!gCvarTest.BoolValue)
		return;

	float secs = gCvarTestSeconds.FloatValue;

	StartTintDebounced();

	KillTimerSafe(g_hEndTimer);
	g_hEndTimer = CreateTimer(secs, Timer_TestEnd, _, TIMER_FLAG_NO_MAPCHANGE);

	g_fTintStartTime = GetGameTime();
	g_fPlannedEndTime = g_fTintStartTime + secs;
}

// ---------------------------- Plugin lifecycle ----------------------------
public void OnPluginStart()
{
	gCvarEnable = CreateConVar("sm_hordetint_enable", "1", "Enable/disable tint on hordes", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	gCvarModes = CreateConVar("sm_hordetint_modes", "", "Enable in these game modes, comma-separated (no spaces). Empty = all.", FCVAR_NOTIFY);
	gCvarDuration = CreateConVar("sm_hordetint_seconds", "60.0", "Max seconds to keep tint active (0=disabled)", FCVAR_NOTIFY, true, 0.0);
	gCvarFadeIn = CreateConVar("sm_hordetint_fadein", "2.00", "Fade-in seconds", FCVAR_NOTIFY, true, 0.0);
	gCvarFadeOut = CreateConVar("sm_hordetint_fadeout", "1.20", "Fade-out seconds", FCVAR_NOTIFY, true, 0.0);
	gCvarAlpha = CreateConVar("sm_hordetint_alpha", "100", "Base tint alpha (0-255) before intensity", FCVAR_NOTIFY, true, 0.0, true, 255.0);
	gCvarTest = CreateConVar("sm_hordetint_test", "0", "Set 1 to run tint test; auto-resets", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	gCvarTestSeconds = CreateConVar("sm_hordetint_test_seconds", "6.0", "Test tint duration in seconds", FCVAR_NOTIFY, true, 1.0);
	gCvarForceClear = CreateConVar("sm_hordetint_forceclear", "0", "After fade-out, send a final zero overlay (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	gCvarColorL4D1 = CreateConVar("sm_hordetint_color_l4d1", "60 170 72", "L4D1 port palette RGB (R G B)", FCVAR_NOTIFY);
	gCvarColorL4D2 = CreateConVar("sm_hordetint_color_l4d2", "255 150 0", "L4D2 palette RGB (R G B)", FCVAR_NOTIFY);
	gCvarColorPassing = CreateConVar("sm_hordetint_color_passing", "210 40 150", "The Passing palette RGB (R G B)", FCVAR_NOTIFY);

	gCvarDarkScale = CreateConVar("sm_hordetint_dark_scale", "0.35", "Final darker overlay multiplier (0.10..0.95)", FCVAR_NOTIFY, true, 0.10, true, 0.95);
	gCvarPreHandoffMs = CreateConVar("sm_hordetint_prehandoff_ms", "0", "Final tint this many ms before end (0=disable)", FCVAR_NOTIFY, true, 0.0, true, 2000.0);
	gCvarFinalAlphaMatch = CreateConVar("sm_hordetint_final_alphamatch", "0.85", "Final alpha = current_alpha * this (0.50..1.00)", FCVAR_NOTIFY, true, 0.50, true, 1.00);

	gCvarPersistOnHurt = CreateConVar("sm_hordetint_persist_onhurt", "1", "Reassert on hurt (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	gCvarIntensity = CreateConVar("sm_hordetint_intensity", "1.00", "Global tint intensity (0.00..1.00)", FCVAR_NOTIFY, true, 0.00, true, 1.00);

	gCvarFinaleEnable = CreateConVar("sm_hordetint_finale_enable", "1", "Enable tint on finale maps (0=disable, 1=enable)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "l4d2_horde_tint");

	g_hMPGameMode = FindConVar("mp_gamemode");
	if (g_hMPGameMode != null)
	g_hMPGameMode.AddChangeHook(Cvar_ModesChanged);
	gCvarModes.AddChangeHook(Cvar_ModesChanged);

	gCvarColorL4D1.AddChangeHook(Cvar_PaletteChanged);
	gCvarColorL4D2.AddChangeHook(Cvar_PaletteChanged);
	gCvarColorPassing.AddChangeHook(Cvar_PaletteChanged);
	gCvarAlpha.AddChangeHook(Cvar_AlphaChanged);
	gCvarTest.AddChangeHook(Cvar_TestChanged);

	UpdateAllowedGameMode();
	DetectFinaleMap();
	DetectCampaignKind();
	ParsePaletteCvars();
	SelectActivePalette();
	g_iCurrentAlpha = ClampInt(gCvarAlpha.IntValue, 0, 255);

	HookEvent("create_panic_event", Event_PanicStart, EventHookMode_PostNoCopy);
	HookEvent("panic_event_finished", Event_PanicEnd, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_PanicEnd, EventHookMode_PostNoCopy);
	HookEvent("mission_lost", Event_PanicEnd, EventHookMode_PostNoCopy);
	HookEvent("finale_vehicle_leaving", Event_PanicEnd, EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_PanicEnd, EventHookMode_PostNoCopy);
	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
	UpdateAllowedGameMode();
	DetectFinaleMap();
	DetectCampaignKind();
	SelectActivePalette();
}

public void OnMapEnd()
{
	ClearAll();
}

// ---------------------------- Test timer ----------------------------
public Action Timer_TestEnd(Handle timer)
{
	StopTintSmooth();
	gCvarTest.SetBool(false);
	return Plugin_Stop;
}

// ---------------------------- Events ----------------------------
public void Event_PanicStart(Event event, const char[] name, bool dontBroadcast)
{
	StartTintDebounced();
}

public void Event_PanicEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bActive)
		return;

	StopTintSmooth();
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!gCvarPersistOnHurt.BoolValue || !g_bActive)
		return;

	float intens = gCvarIntensity.FloatValue;
	if (intens <= 0.0)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR)
		return;

	int alpha = ScaleAlpha(g_iCurrentAlpha, intens);
	int flags = FFADE_OUT | FFADE_MODULATE | FFADE_STAYOUT | FFADE_PURGE;
	SendFade(client, 0, 60, flags, g_iColor[0], g_iColor[1], g_iColor[2], alpha);
}

// ---------------------------- Tint control ----------------------------
void StartTintDebounced()
{
	if (!g_bModeAllowed)
		return;
	if (!gCvarEnable.BoolValue)
		return;
	if (!gCvarFinaleEnable.BoolValue && g_bIsFinaleMap)
		return;

	float intens = gCvarIntensity.FloatValue;
	if (intens <= 0.0)
		return;

	KillTimerSafe(g_hForceTimer);
	KillTimerSafe(g_hPreTimer);
	g_bPrePlaced = false;

	if (g_bActive)
	{
		StartEndTimer();
		return;
	}

	DetectCampaignKind();
	SelectActivePalette();

	int alpha = ScaleAlpha(ClampInt(gCvarAlpha.IntValue, 0, 255), intens);
	g_iCurrentAlpha = alpha;

	int flags = FFADE_OUT | FFADE_MODULATE | FFADE_PURGE | FFADE_STAYOUT;
	int durMs = RoundToCeil(gCvarFadeIn.FloatValue * 1000.0);

	for (int i = 1; i <= MaxClients; i++)	
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		SendFade(i, durMs, 1, flags, g_iColor[0], g_iColor[1], g_iColor[2], alpha);
	}

	g_fTintStartTime = GetGameTime();
	StartEndTimer();
	g_bActive = true;
}

void StartEndTimer()
{
	KillTimerSafe(g_hEndTimer);
	KillTimerSafe(g_hPreTimer);

	float seconds = gCvarDuration.FloatValue;
	if (seconds <= 0.0)
		return;

	g_hEndTimer = CreateTimer(seconds, Timer_End, _, TIMER_FLAG_NO_MAPCHANGE);
	g_fPlannedEndTime = g_fTintStartTime + seconds;

	int preMs = gCvarPreHandoffMs.IntValue;
	if (preMs >= 40)
	{
		float pre = float(preMs) * 0.001;
		if (seconds > pre + 0.001)
			g_hPreTimer = CreateTimer(seconds - pre, Timer_PreHandoff, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_PreHandoff(Handle timer)
{
	g_hPreTimer = null;

	if (!g_bActive)
		return Plugin_Stop;

	float intens = gCvarIntensity.FloatValue;
	if (intens <= 0.0)
		return Plugin_Stop;

	float s = gCvarDarkScale.FloatValue;
	if (s < 0.10) s = 0.10;
	if (s > 0.95) s = 0.95;

	int dr = ClampInt(RoundToNearest(float(g_iColor[0]) * s), 0, 255);
	int dg = ClampInt(RoundToNearest(float(g_iColor[1]) * s), 0, 255);
	int db = ClampInt(RoundToNearest(float(g_iColor[2]) * s), 0, 255);

	float am = gCvarFinalAlphaMatch.FloatValue;
	if (am < 0.50) am = 0.50;
	if (am > 1.00) am = 1.00;

	int daBase = ClampInt(RoundToNearest(float(g_iCurrentAlpha) * am), 0, 255);
	int da = ScaleAlpha(daBase, intens);

	int flags = FFADE_OUT | FFADE_MODULATE | FFADE_STAYOUT | FFADE_PURGE;
	for (int i = 1; i <= MaxClients; i++)	
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		SendFade(i, 0, 60, flags, dr, dg, db, da);
	}

	g_iFadeR = dr;
	g_iFadeG = dg;
	g_iFadeB = db;
	g_iFadeA = da;
	g_bPrePlaced = true;

	return Plugin_Stop;
}

public Action Timer_End(Handle timer)
{
	if (timer == g_hEndTimer)
		g_hEndTimer = null;

	StopTintSmooth();
	return Plugin_Stop;
}

void StopTintSmooth()
{
	if (!g_bActive)
		return;

	KillTimerSafe(g_hEndTimer);

	float intens = gCvarIntensity.FloatValue;
	if (intens <= 0.0)
	{
		g_bActive = false;
		return;
	}

	if (!g_bPrePlaced)
	{
		float s = gCvarDarkScale.FloatValue;
		if (s < 0.10) s = 0.10;
		if (s > 0.95) s = 0.95;

		g_iFadeR = ClampInt(RoundToNearest(float(g_iColor[0]) * s), 0, 255);
		g_iFadeG = ClampInt(RoundToNearest(float(g_iColor[1]) * s), 0, 255);
		g_iFadeB = ClampInt(RoundToNearest(float(g_iColor[2]) * s), 0, 255);

		float am = gCvarFinalAlphaMatch.FloatValue;
		if (am < 0.50) am = 0.50;
		if (am > 1.00) am = 1.00;

		int daBase = ClampInt(RoundToNearest(float(g_iCurrentAlpha) * am), 0, 255);
		g_iFadeA = ScaleAlpha(daBase, intens);
	}

	int flagsO = FFADE_OUT | FFADE_MODULATE | FFADE_STAYOUT | FFADE_PURGE;
	for (int i = 1; i <= MaxClients; i++)	
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		SendFade(i, 0, 60, flagsO, g_iFadeR, g_iFadeG, g_iFadeB, g_iFadeA);
	}

	int dur = RoundToCeil(gCvarFadeOut.FloatValue * 1000.0);
	int flagsIN = FFADE_IN | FFADE_PURGE;
	for (int i = 1; i <= MaxClients; i++)	
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		SendFade(i, dur, 0, flagsIN, g_iFadeR, g_iFadeG, g_iFadeB, g_iFadeA);
	}

	if (gCvarForceClear.BoolValue)
	{
		float delay = float(dur) * 0.001 + 0.05;
		KillTimerSafe(g_hForceTimer);
		g_hForceTimer = CreateTimer(delay, Timer_ForceClear, _, TIMER_FLAG_NO_MAPCHANGE);
	}

	g_bActive = false;
}

public Action Timer_ForceClear(Handle timer)
{
	if (timer == g_hForceTimer)
		g_hForceTimer = null;

	int flags = FFADE_IN | FFADE_PURGE;
	for (int i = 1; i <= MaxClients; i++)	
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		SendFade(i, 1, 0, flags, 0, 0, 0, 0);
	}
	return Plugin_Stop;
}

void ClearAll()
{
	KillTimerSafe(g_hEndTimer);
	KillTimerSafe(g_hForceTimer);
	KillTimerSafe(g_hPreTimer);

	g_bPrePlaced = false;
	g_bActive = false;

	int flags = FFADE_IN | FFADE_PURGE;
	for (int i = 1; i <= MaxClients; i++)	
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		SendFade(i, 1, 0, flags, 0, 0, 0, 0);
	}
}

// ---------------------------- Messaging ----------------------------
void SendFade(int client, int durationMs, int holdMs, int flags, int r, int g, int b, int a)
{
	Handle msg = StartMessageOne("Fade", client);
	if (msg == INVALID_HANDLE)
		return;

	if (GetFeatureStatus(FeatureType_Native, "GetUserMessageType") == FeatureStatus_Available && GetUserMessageType() == UM_Protobuf)
	{
		int c[4];
		c[0] = r;
		c[1] = g;
		c[2] = b;
		c[3] = a;

		PbSetInt(msg, "duration", durationMs);
		PbSetInt(msg, "hold_time", holdMs);
		PbSetInt(msg, "flags", flags);
		PbSetColor(msg, "clr", c);
	}
	else
	{
		BfWriteShort(msg, durationMs);
		BfWriteShort(msg, holdMs);
		BfWriteShort(msg, flags);
		BfWriteByte(msg, r);
		BfWriteByte(msg, g);
		BfWriteByte(msg, b);
		BfWriteByte(msg, a);
	}

	EndMessage();
}
