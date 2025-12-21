// File: l4d2_front_mob_direction.sp

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// Left4DHooks natives (optional)
native float L4D2_GetFurthestSurvivorFlow();
native float L4D2Direct_GetFlowDistance(int client);
native void  L4D2_ExecVScriptCode(const char[] code);

#define PLUGIN_VERSION "1.0"

ConVar g_hCvarGap;
ConVar g_hCvarInterval;
ConVar g_hCvarDebug;

float g_fGap;
float g_fInterval;
bool  g_bDebug;

bool g_bApplied;
bool g_bFight;

int  g_iOrigMobDir;
bool g_bHaveOrigDir;

ConVar g_hVSBuf;
Handle g_hTimer;

public APLRes AskPluginLoad2(Handle self, bool late, char[] err, int errMax)
{
	RegPluginLibrary("l4d2_front_mob_direction");

	MarkNativeAsOptional("L4D2_GetFurthestSurvivorFlow");
	MarkNativeAsOptional("L4D2Direct_GetFlowDistance");
	MarkNativeAsOptional("L4D2_ExecVScriptCode");

	return APLRes_Success;
}

public Plugin myinfo =
{
	name = "[L4D2] Front Mob Direction",
	author = "Tighty-Whitey",
	description = "Forces mobs to spawn in front when survivor flow gap between players is large.",
	version = "1.0",
	url = ""
};

public void OnPluginStart()
{
	g_hCvarGap      = CreateConVar("l4d2_front_mob_gap", "2000", "Flow gap to force front mob direction.", FCVAR_NOTIFY);
	g_hCvarInterval = CreateConVar("l4d2_front_mob_interval", "0.5", "Seconds between flow checks.", FCVAR_NOTIFY);
	g_hCvarDebug    = CreateConVar("l4d2_front_mob_debug", "0", "Debug logging.", FCVAR_NONE);

	AutoExecConfig(true, "l4d2_front_mob_direction");

	g_hCvarGap.AddChangeHook(OnCvarChanged);
	g_hCvarInterval.AddChangeHook(OnCvarChanged);
	g_hCvarDebug.AddChangeHook(OnCvarChanged);

	RefreshCvars();

	g_hVSBuf = FindConVar("l4d2_vscript_return");
	if (g_hVSBuf == null)
	{
		g_hVSBuf = CreateConVar("l4d2_vscript_return", "", "VScript return buffer. Do not use.", FCVAR_DONTRECORD);
	}

	HookEvent("player_left_safe_area", E_LeftSafe, EventHookMode_PostNoCopy);

	HookEvent("round_end", E_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("map_transition", E_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("finale_vehicle_leaving", E_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("mission_lost", E_RoundEnd, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
	ResetState();
	CaptureOriginalDir();
	StartThinkTimer();
}

public void OnMapEnd()
{
	StopThinkTimer();

	if (g_bApplied)
		RestoreOriginal();

	ResetState();
}

public void OnConfigsExecuted()
{
	RefreshCvars();
	RestartThinkTimer();
}

void ResetState()
{
	g_bApplied = false;
	g_bFight = false;

	g_bHaveOrigDir = false;
	g_iOrigMobDir = -1;
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	RefreshCvars();
	RestartThinkTimer();
}

void RefreshCvars()
{
	g_fGap = g_hCvarGap.FloatValue;

	float iv = g_hCvarInterval.FloatValue;
	if (iv < 0.1)
		iv = 0.1;
	g_fInterval = iv;

	g_bDebug = g_hCvarDebug.BoolValue;
}

void StopThinkTimer()
{
	if (g_hTimer != null)
	{
		KillTimer(g_hTimer);
		g_hTimer = null;
	}
}

void StartThinkTimer()
{
	if (g_hTimer != null)
		return;

	g_hTimer = CreateTimer(g_fInterval, T_Think, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void RestartThinkTimer()
{
	StopThinkTimer();
	StartThinkTimer();
}

public Action T_Think(Handle timer)
{
	if (!g_bFight)
		return Plugin_Continue;

	float furthest = GetFurthestFlow();
	float slowest  = GetSlowestFlow();
	float gap      = furthest - slowest;

	if (gap > g_fGap)
	{
		if (!g_bApplied)
			ApplyFront();
	}
	else
	{
		if (g_bApplied)
			RestoreOriginal();
	}

	return Plugin_Continue;
}

public void E_LeftSafe(Event event, const char[] name, bool dontBroadcast)
{
	g_bFight = true;

	CaptureOriginalDir();
	StartThinkTimer();
}

public void E_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bFight = false;

	if (g_bApplied)
		RestoreOriginal();

	StopThinkTimer();
}

float GetFurthestFlow()
{
	if (GetFeatureStatus(FeatureType_Native, "L4D2_GetFurthestSurvivorFlow") == FeatureStatus_Available)
		return L4D2_GetFurthestSurvivorFlow();

	float maxf = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2)
			continue;

		float f = GetFlowDistance(i);
		if (f > maxf)
			maxf = f;
	}

	return maxf;
}

float GetSlowestFlow()
{
	float minf = 0.0;
	bool any = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2)
			continue;

		float f = GetFlowDistance(i);
		if (!any || f < minf)
		{
			minf = f;
			any = true;
		}
	}

	return any ? minf : 0.0;
}

float GetFlowDistance(int client)
{
	if (GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetFlowDistance") == FeatureStatus_Available)
		return L4D2Direct_GetFlowDistance(client);

	return 0.0;
}

void CaptureOriginalDir()
{
	g_bHaveOrigDir = false;
	g_iOrigMobDir = -1;

	if (g_hVSBuf == null)
		return;

	if (GetFeatureStatus(FeatureType_Native, "L4D2_ExecVScriptCode") != FeatureStatus_Available)
		return;

	// One string literal: SourcePawn doesn't auto-concatenate adjacent strings.
	L4D2_ExecVScriptCode("try{ local v=-1; if(\"SessionOptions\" in getroottable() && ::SessionOptions!=null && (\"PreferredMobDirection\" in ::SessionOptions)) v=::SessionOptions.PreferredMobDirection; else if(\"DirectorOptions\" in getroottable() && ::DirectorOptions!=null && (\"PreferredMobDirection\" in ::DirectorOptions)) v=::DirectorOptions.PreferredMobDirection; Convars.SetValue(\"l4d2_vscript_return\",\"\"+v);}catch(e){ Convars.SetValue(\"l4d2_vscript_return\",\"-1\"); }");

	char s[32];
	g_hVSBuf.GetString(s, sizeof(s));

	g_iOrigMobDir = StringToInt(s);
	g_bHaveOrigDir = true;

	if (g_bDebug)
		LogMessage("[FMD] Original PreferredMobDirection=%d", g_iOrigMobDir);
}

void ApplyFront()
{
	if (GetFeatureStatus(FeatureType_Native, "L4D2_ExecVScriptCode") != FeatureStatus_Available)
		return;

	L4D2_ExecVScriptCode("try{ if(\"SessionOptions\" in getroottable() && ::SessionOptions!=null) ::SessionOptions.PreferredMobDirection = SPAWN_IN_FRONT_OF_SURVIVORS; else if(\"DirectorOptions\" in getroottable() && ::DirectorOptions!=null) ::DirectorOptions.PreferredMobDirection = SPAWN_IN_FRONT_OF_SURVIVORS; }catch(e){}");

	g_bApplied = true;

	if (g_bDebug)
		LogMessage("[FMD] Applied front mob direction");
}

void RestoreOriginal()
{
	if (GetFeatureStatus(FeatureType_Native, "L4D2_ExecVScriptCode") != FeatureStatus_Available)
	{
		g_bApplied = false;
		return;
	}

	int dir = (g_bHaveOrigDir ? g_iOrigMobDir : -1);

	char code[256];
	Format(code, sizeof(code),
		"try{ if(\"SessionOptions\" in getroottable() && ::SessionOptions!=null) ::SessionOptions.PreferredMobDirection = %d; else if(\"DirectorOptions\" in getroottable() && ::DirectorOptions!=null) ::DirectorOptions.PreferredMobDirection = %d; }catch(e){}",
		dir, dir
	);

	L4D2_ExecVScriptCode(code);

	g_bApplied = false;

	if (g_bDebug)
		LogMessage("[FMD] Restored mob direction=%d", dir);
}
