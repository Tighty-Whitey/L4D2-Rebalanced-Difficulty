// File: l4d2_horde_director_helper.sp
// Version: 1.0
#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>

// Optional Left4DHooks.
native float L4D2Direct_GetFlowDistance(int client);
native float L4D2_GetScriptValueFloat(const char[] key, float defValue);
native void  L4D2_ExecVScriptCode(const char[] code);

// Horde Director API
native int   HD_SetHordesTime(float timePast);
native any   HD_GetHordesTime();

#define TEAM_SURVIVOR 2

// Retry policy for reading RelaxMaxFlowTravel after map change
#define RELAX_MAX_RETRY   10
#define RELAX_RETRY_SECS  0.75

public Plugin myinfo =
{
	name = "[L4D2] Horde Director - Freeze Controller",
	author      = "Tighty-Whitey",
	description = "Freeze controller for Horde Director",
	version     = "1.0",
	url         = ""
};

// --- Forwards / prototypes ---
public void E_PlayerRescued(Event e, const char[] n, bool b);
public void E_DefibUsed(Event e, const char[] n, bool b);

public int   CountIncapSurvivors();
public float GetFarthestFlowSurvivor(int &farId);
public float GetSlowestIncapFlow();
public float GetSlowestLimpFlow();
public float GetRelaxDistance();
public void  ResetAllState(bool onStart);

// CVARs
ConVar gC_Enable, gC_CollectiveNeed, gC_ScaleByMax;
ConVar gC_FFGrace, gC_Spread, gC_ResumeFlow, gC_ResumeDelay, gC_IncapFreeze;

ConVar gC_Debug, gC_DbgTrace, gC_DbgRate, gC_DbgHud, gC_DbgFile, gC_DbgTraceTarget, gC_DbgVerbose;

ConVar g_hSurvivorLimit, g_hVSBuf;

// State
enum FreezeMode
{
	FREEZE_NONE = 0,
	FREEZE_COLLECTIVE,
	FREEZE_GATING_RELAX,
	FREEZE_GATING_AFTER_RETURN,
	FREEZE_POST_INCAP
};
FreezeMode g_Freeze = FREEZE_NONE;

bool g_bEnable = true;
int g_iCollectiveNeed = 3;
bool g_bScaleByMax = true;
float g_fFFGrace = 8.0;
float g_fSpread = 1750.0;
float g_fResumeFlow = -1.0;
float g_fResumeDelay = 30.0;
bool g_bFFDeathOccurred = false;
bool g_bIncapFreeze = true;

float g_fGateStartFlow = 0.0, g_fRelaxAuto = 0.0;
bool g_bUnfrozenBySpread = false, g_bForceUnfreezeNoReset = false;
int g_iSpreadHelper = 0;

float g_fKillResumeEarliest = 0.0;

// FF limp windows
bool  g_bFFWindowActive[MAXPLAYERS+1];
float g_fFFWindowEnd[MAXPLAYERS+1];
int   g_iFFWindowShooter[MAXPLAYERS+1];
bool  g_bFFWindowCausedIncap[MAXPLAYERS+1], g_bFFForgiven[MAXPLAYERS+1];
int   g_iReviveTargetOfHelper[MAXPLAYERS+1];

// Debugger
bool g_bDbg = false, g_bDbgTrace=false, g_bDbgHud=false, g_bDbgFile=false, g_bDbgVerbose=false;
float g_fDbgRate = 0.5, g_fNextTrace=0.0;
int g_iDbgTraceTarget = -1;
Handle g_hHudTimer = null, g_hEnforceTimer=null, g_hInitTimer=null, g_hRelaxTimer=null;
char  g_sDbgPath[PLATFORM_MAX_PATH];

// Config paths
char g_sCfgPath[PLATFORM_MAX_PATH];
char g_sCfgExec[64] = "sourcemod/l4d2_horde_director_freeze_ext.cfg";

// Forward probe
bool g_bForwardSeen = false;
float g_fLastForward = 0.0;

// Enforcer hold
bool g_bFrozenHold = false;
float g_fFrozenAt = 0.0;

// Anti-bounce grace
float g_fCollectiveRearmAt = 0.0;
float g_fRearmGrace = 2.0;

// Auto-relax retry counter
int g_iRelaxTries = 0;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("L4D2Direct_GetFlowDistance");
	MarkNativeAsOptional("L4D2_GetScriptValueFloat");
	MarkNativeAsOptional("L4D2_ExecVScriptCode");
	MarkNativeAsOptional("HD_SetHordesTime");
	MarkNativeAsOptional("HD_GetHordesTime");
	return APLRes_Success;
}
void SafeKillTimer(Handle &h)
{
	if (h == null)
		return;

	if (IsValidHandle(h))
		KillTimer(h);

	h = null;
}

public void OnPluginStart()
{
	// Policy CVARs
	gC_Enable         = CreateConVar("hdf_enable", "1", "Enable freeze controller (0/1)", FCVAR_NOTIFY);
	gC_CollectiveNeed = CreateConVar("hdf_collective_need", "3", "Base count at survivor_max to freeze", FCVAR_NOTIFY);
	gC_ScaleByMax     = CreateConVar("hdf_collective_scale", "1", "Scale by alive vs survivor_max using FLOOR (0/1)", FCVAR_NOTIFY);

	gC_IncapFreeze    = CreateConVar("hdf_incap_freeze", "1", "Freeze on non-FF incaps (0/1)", FCVAR_NOTIFY);
	gC_ResumeDelay    = CreateConVar("hdf_resume_delay", "30.0", "Seconds after last incap cleared before a SURVIVOR kill can resume", FCVAR_NOTIFY);
	gC_ResumeFlow     = CreateConVar("hdf_resume_flow", "-1.0", "Flow to resume by travel (-1: auto RelaxMaxFlowTravel)", FCVAR_NOTIFY);

	gC_Spread         = CreateConVar("hdf_spread_flow", "1750.0", "Flow spread to unfreeze (no reset) while frozen", FCVAR_NOTIFY);
	gC_FFGrace        = CreateConVar("hdf_ff_limp_grace_secs", "8.0", "Seconds after FF-caused limp where freeze is suppressed", FCVAR_NOTIFY);

	// Debugger CVARs
	gC_Debug          = CreateConVar("hdf_debug", "0", "Master debug prints", FCVAR_NONE);
	gC_DbgTrace       = CreateConVar("hdf_dbg_trace", "0", "Per-frame trace (rate-limited)", FCVAR_NONE);
	gC_DbgRate        = CreateConVar("hdf_dbg_rate", "0.5", "Seconds between trace lines", FCVAR_NONE);
	gC_DbgHud         = CreateConVar("hdf_dbg_hud", "0", "HUD status to survivors (0/1)", FCVAR_NONE);
	gC_DbgFile        = CreateConVar("hdf_dbg_file", "0", "Write data/hdf_debug.log (0/1)", FCVAR_NONE);
	gC_DbgTraceTarget = CreateConVar("hdf_dbg_trace_target", "-1", "Trace target userid (-1=all)", FCVAR_NONE);
	gC_DbgVerbose     = CreateConVar("hdf_dbg_verbose", "0", "Verbose per-player dump (0/1)", FCVAR_NONE);

	AutoExecConfig(true, "l4d2_horde_director_freeze_ext");
	BuildPath(Path_SM, g_sCfgPath, sizeof(g_sCfgPath), "../../cfg/%s", g_sCfgExec);
	CreateTimer(0.05, T_EnsureCfg, _, TIMER_FLAG_NO_MAPCHANGE);

	HookCvarChanges();
	HookGameplayEvents();

	// Round lifecycle hooks
	HookEvent("round_start",            E_RoundStart, EventHookMode_Post);
	HookEvent("map_transition",         E_RoundEnd,   EventHookMode_Post);
	HookEvent("finale_vehicle_leaving", E_RoundEnd,   EventHookMode_Post);
	HookEvent("mission_lost",           E_RoundEnd,   EventHookMode_Post);
	HookEvent("round_end",              E_RoundEnd,   EventHookMode_Post);

	g_hSurvivorLimit = FindConVar("survivor_limit");
	if (g_hSurvivorLimit != null) g_hSurvivorLimit.AddChangeHook(CvarChanged);

	BuildPath(Path_SM, g_sDbgPath, sizeof(g_sDbgPath), "data/hdf_debug.log");

	RegConsoleCmd("hdf_dump",           CmdDump);
	RegConsoleCmd("hdf_trace",          CmdTrace);
	RegConsoleCmd("hdf_fflist",         CmdFFList);
	RegConsoleCmd("hdf_ping",           CmdPing);
	RegConsoleCmd("hdf_relax_refresh",  CmdRelaxRefresh);

	ApplyCvars();
	StartOrStopHud();
	StartOrStopEnforcer();

	if (g_hRelaxTimer == null)
	g_hRelaxTimer = CreateTimer(1.0, T_UpdateRelaxSafe, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_hInitTimer == null)
	g_hInitTimer = CreateTimer(0.25, T_InitKickoff, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action T_InitKickoff(Handle t, any d)
{
	g_hInitTimer = null;
	ApplyCvars();
	StartOrStopHud();
	StartOrStopEnforcer();
	if (g_hRelaxTimer == null)
	g_hRelaxTimer = CreateTimer(0.75, T_UpdateRelaxSafe, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action T_UpdateRelaxSafe(Handle t, any d)
{
	g_hRelaxTimer = null;

	// Attempt to update; schedule retries if not yet available
	UpdateAutoRelax();
	if (g_fRelaxAuto <= 0.0 && g_iRelaxTries < RELAX_MAX_RETRY)
	{
		g_iRelaxTries++;
		g_hRelaxTimer = CreateTimer(RELAX_RETRY_SECS, T_UpdateRelaxSafe, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	return Plugin_Stop;
}

// cfg with descriptions
Action T_EnsureCfg(Handle t, any d)
{
	if (!FileExists(g_sCfgPath))
	{
		File f = OpenFile(g_sCfgPath, "w");
		if (f != null)
		{
			WriteFileLine(f, "// l4d2_horde_director_freeze_ext - defaults");
			WriteFileLine(f, "hdf_enable \"1\"");
			WriteFileLine(f, "hdf_collective_need \"3\"");
			WriteFileLine(f, "hdf_collective_scale \"1\"");
			WriteFileLine(f, "hdf_incap_freeze \"1\"");
			WriteFileLine(f, "hdf_resume_delay \"30.0\"");
			WriteFileLine(f, "hdf_resume_flow \"-1.0\"");
			WriteFileLine(f, "hdf_ff_limp_grace_secs \"8.0\"");
			WriteFileLine(f, "hdf_spread_flow \"1750.0\"");
			WriteFileLine(f, "hdf_debug \"0\"");
			WriteFileLine(f, "hdf_dbg_trace \"0\"");
			WriteFileLine(f, "hdf_dbg_rate \"0.5\"");
			WriteFileLine(f, "hdf_dbg_hud \"0\"");
			WriteFileLine(f, "hdf_dbg_file \"0\"");
			WriteFileLine(f, "hdf_dbg_trace_target \"-1\"");
			WriteFileLine(f, "hdf_dbg_verbose \"0\"");
			CloseHandle(f);
			PrintToServer("[HDF] Wrote cfg: %s", g_sCfgPath);
		}
	}
	ServerCommand("exec %s", g_sCfgExec);
	return Plugin_Stop;
}

void HookCvarChanges()
{
	gC_Enable.AddChangeHook(CvarChanged);
	gC_CollectiveNeed.AddChangeHook(CvarChanged);
	gC_ScaleByMax.AddChangeHook(CvarChanged);
	gC_FFGrace.AddChangeHook(CvarChanged);
	gC_Spread.AddChangeHook(CvarChanged);
	gC_ResumeFlow.AddChangeHook(CvarChanged);
	gC_ResumeDelay.AddChangeHook(CvarChanged);
	gC_IncapFreeze.AddChangeHook(CvarChanged);
	gC_Debug.AddChangeHook(CvarChanged);
	gC_DbgTrace.AddChangeHook(CvarChanged);
	gC_DbgRate.AddChangeHook(CvarChanged);
	gC_DbgHud.AddChangeHook(CvarChanged);
	gC_DbgFile.AddChangeHook(CvarChanged);
	gC_DbgTraceTarget.AddChangeHook(CvarChanged);
	gC_DbgVerbose.AddChangeHook(CvarChanged);
}

void HookGameplayEvents()
{
	HookEvent("player_hurt",            E_PlayerHurt,    EventHookMode_Post);
	HookEvent("player_incapacitated",   E_PlayerIncap,   EventHookMode_Post);
	HookEvent("revive_begin",           E_ReviveBegin,   EventHookMode_Post);
	HookEvent("revive_success",         E_ReviveSuccess, EventHookMode_Post);
	HookEvent("player_death",           E_PlayerDeath,   EventHookMode_Post);
	HookEvent("infected_death",         E_InfectedDeath, EventHookMode_Post);
	HookEvent("player_spawn",           E_PlayerSpawn,   EventHookMode_Post);
	HookEvent("survivor_rescued",       E_PlayerRescued, EventHookMode_Post);
	HookEvent("defibrillator_used",     E_DefibUsed,     EventHookMode_Post);
	HookEvent("round_start",            E_RoundStart, EventHookMode_Post);
	HookEvent("map_transition",         E_RoundEnd,   EventHookMode_Post);
	HookEvent("finale_vehicle_leaving", E_RoundEnd,   EventHookMode_Post);
	HookEvent("mission_lost",           E_RoundEnd,   EventHookMode_Post);
	HookEvent("round_end",              E_RoundEnd,   EventHookMode_Post);
}

void CvarChanged(ConVar c, const char[] o, const char[] n)
{
	ApplyCvars();
	if (c == gC_DbgHud) StartOrStopHud();
	if (c == gC_ResumeFlow) UpdateAutoRelax();
}

void ApplyCvars()
{
	g_bEnable         = gC_Enable.BoolValue;
	g_iCollectiveNeed = gC_CollectiveNeed.IntValue;
	g_bScaleByMax     = gC_ScaleByMax.BoolValue;
	g_fFFGrace        = gC_FFGrace.FloatValue;
	g_fSpread         = gC_Spread.FloatValue;
	g_fResumeFlow     = gC_ResumeFlow.FloatValue;
	g_fResumeDelay    = gC_ResumeDelay.FloatValue;
	g_bIncapFreeze    = gC_IncapFreeze.BoolValue;

	g_bDbg            = gC_Debug.BoolValue;
	g_bDbgTrace       = gC_DbgTrace.BoolValue;
	g_fDbgRate        = gC_DbgRate.FloatValue;
	g_bDbgHud         = gC_DbgHud.BoolValue;
	g_bDbgFile        = gC_DbgFile.BoolValue;
	g_iDbgTraceTarget = gC_DbgTraceTarget.IntValue;
	g_bDbgVerbose     = gC_DbgVerbose.BoolValue;

	if (g_fDbgRate < 0.1) g_fDbgRate = 0.1;
}

void StartOrStopHud()
{
	if (g_hHudTimer != null && !IsValidHandle(g_hHudTimer))
		g_hHudTimer = null;

	if (g_bDbgHud)
	{
		if (g_hHudTimer != null)
		{
			SafeKillTimer(g_hHudTimer);
			g_hHudTimer = null;
		}

		g_hHudTimer = CreateTimer(1.0, T_Hud, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		if (g_hHudTimer != null)
		{
			SafeKillTimer(g_hHudTimer);
			g_hHudTimer = null;
		}
	}
}

void StartOrStopEnforcer()
{
	if (g_hEnforceTimer != null && !IsValidHandle(g_hEnforceTimer))
		g_hEnforceTimer = null;

	if (g_hEnforceTimer != null)
	{
		SafeKillTimer(g_hEnforceTimer);
		g_hEnforceTimer = null;
	}

	g_hEnforceTimer = CreateTimer(0.2, T_Enforce, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// Utilities, core, events, lifecycle, HUD/debug

public bool IsClientSurvivor(int c)
{
	return (c>0 && c<=MaxClients && IsClientInGame(c) && GetClientTeam(c)==TEAM_SURVIVOR);
}
public bool IsAlive(int c)
{
	return (IsClientSurvivor(c) && IsPlayerAlive(c));
}

bool HasHeals(int c)
{
	if (!IsClientSurvivor(c)) return false;
	int ent = GetPlayerWeaponSlot(c,3);
	if (ent>MaxClients && IsValidEntity(ent)){
		char cls[64];
		GetEdictClassname(ent,cls,sizeof(cls));
		if (StrEqual(cls,"weapon_first_aid_kit",false)) return true;
	}
	ent=GetPlayerWeaponSlot(c,4);
	if (ent>MaxClients && IsValidEntity(ent)){
		char cls2[64];
		GetEdictClassname(ent,cls2,sizeof(cls2));
		if (StrEqual(cls2,"weapon_pain_pills",false) || StrEqual(cls2,"weapon_adrenaline",false)) return true;
	}
	return false;
}
bool IsLimpingNow(int c)
{
	if (!IsAlive(c)) return false;
	int hp = GetClientHealth(c);
	float temp = GetEntPropFloat(c,Prop_Send,"m_healthBuffer");
	if (temp<0.0) temp=0.0;
	bool adr = HasEntProp(c,Prop_Send,"m_bAdrenalineActive")&&(GetEntProp(c,Prop_Send,"m_bAdrenalineActive")!=0);
	return ((float(hp)+temp)<=40.0 && !adr);
}
public float GetFlow(int c)
{
	if (!IsClientSurvivor(c)) return 0.0;
	if (GetFeatureStatus(FeatureType_Native,"L4D2Direct_GetFlowDistance")==FeatureStatus_Available) return L4D2Direct_GetFlowDistance(c);
	return 0.0;
}
public float GetFarthestFlowSurvivor(int &farId)
{
	float maxf = 0.0;
	farId=0;
	for(int i = 1;i<=MaxClients;i++) if (IsAlive(i)){
		float f = GetFlow(i);
		if (f>maxf){
			maxf=f;
			farId=i;
		}
	}
	return maxf;
}
public float GetSlowestIncapFlow()
{
	float minf = -1.0;
	bool found = false;
	for(int i = 1;i<=MaxClients;i++){
		if(!IsClientSurvivor(i)) continue;
		if (GetEntProp(i,Prop_Send,"m_isIncapacitated")==0) continue;
		float f = GetFlow(i);
		if(!found||f<minf){
			minf=f;
			found=true;
		}
	}
	return found?minf:-1.0;
}
public float GetSlowestLimpFlow()
{
	float minf = -1.0;
	bool found = false;
	for(int i = 1;i<=MaxClients;i++){
		if(!IsAlive(i)) continue;
		if(!IsLimpingNow(i)) continue;
		if(HasHeals(i)) continue;
		float f = GetFlow(i);
		if(!found||f<minf){
			minf=f;
			found=true;
		}
	}
	return found?minf:-1.0;
}

void EnsureVSBuf()
{
	if (g_hVSBuf == null)
	{
		g_hVSBuf = FindConVar("l4d2_vscript_return");
		if (g_hVSBuf == null)
		g_hVSBuf = CreateConVar("l4d2_vscript_return","", "VScript return buffer", FCVAR_DONTRECORD);
	}
}

public void UpdateAutoRelax()
{
	g_fRelaxAuto = 0.0;

	// 1) Native read (Left4DHooks)
	if (GetFeatureStatus(FeatureType_Native,"L4D2_GetScriptValueFloat")==FeatureStatus_Available)
	{
		float v = L4D2_GetScriptValueFloat("RelaxMaxFlowTravel", 0.0);
		if (v <= 0.0) v = L4D2_GetScriptValueFloat("relaxmaxflowtravel", 0.0);
		if (v > 0.0){ g_fRelaxAuto = v; if (g_bDbg) DbgPrint("AutoRelax(native)=%.0f", v); return; }
	}

	// 2) VScript probe: SessionOptions -> DirectorOptions -> DirectorScript
	if (GetFeatureStatus(FeatureType_Native,"L4D2_ExecVScriptCode")==FeatureStatus_Available)
	{
		EnsureVSBuf();

		// Clear buffer to avoid stale carryover
		g_hVSBuf.SetString("0");

		char vs[512];
		vs[0] = '\0';
		StrCat(vs, sizeof(vs), "try{");
		StrCat(vs, sizeof(vs), " local v=0;");
		StrCat(vs, sizeof(vs), " if ((\"SessionOptions\" in getroottable()) && (::SessionOptions!=null) && (\"RelaxMaxFlowTravel\" in ::SessionOptions)) v=::SessionOptions.RelaxMaxFlowTravel;");
		StrCat(vs, sizeof(vs), " else if ((\"DirectorOptions\" in getroottable()) && (::DirectorOptions!=null) && (\"RelaxMaxFlowTravel\" in ::DirectorOptions)) v=::DirectorOptions.RelaxMaxFlowTravel;");
		StrCat(vs, sizeof(vs), " else if ((\"DirectorScript\" in getroottable()) && (::DirectorScript!=null) && (\"RelaxMaxFlowTravel\" in ::DirectorScript)) v=::DirectorScript.RelaxMaxFlowTravel;");
		StrCat(vs, sizeof(vs), " Convars.SetValue(\"l4d2_vscript_return\",\"\"+v);");
		StrCat(vs, sizeof(vs), "}catch(e){ Convars.SetValue(\"l4d2_vscript_return\",\"0\"); }");

		L4D2_ExecVScriptCode(vs);

		char s[32];
		g_hVSBuf.GetString(s, sizeof(s));
		float v2 = StringToFloat(s);
		if (v2 > 0.0) { g_fRelaxAuto = v2; if (g_bDbg) DbgPrint("AutoRelax(vscript)=%.0f", v2); return; }
	}

	// 3) Fallback (caller may retry via timer)
	if (g_bDbg) DbgPrint("AutoRelax(pending/fallback)=3000");
}

public float GetRelaxDistance()
{
	float explicitResume = gC_ResumeFlow.FloatValue;
	if (explicitResume > 0.0) return explicitResume; // explicit override via cfg
	if (g_fRelaxAuto > 0.0) return g_fRelaxAuto;     // auto from map scripts
	return 3000.0;                                   // Valve default
}

int CountCollectiveMembers()
{
	int count = 0;
	for(int i = 1;i<=MaxClients;i++){
		if(!IsClientSurvivor(i)||!IsPlayerAlive(i)) continue;
		bool incapped = (GetEntProp(i,Prop_Send,"m_isIncapacitated")!=0);
		bool limping = (!incapped && IsLimpingNow(i));
		bool hasHeals = HasHeals(i);
		if ((incapped && !hasHeals) || (limping && !hasHeals)) count++;
	}
	return count;
}
public int CountIncapSurvivors()
{
	int count = 0;
	for(int i = 1;i<=MaxClients;i++){
		if(!IsClientSurvivor(i)||!IsPlayerAlive(i)) continue;
		if(GetEntProp(i,Prop_Send,"m_isIncapacitated")!=0) count++;
	}
	return count;
}
public int GetCollectiveNeedTarget()
{
	int base = g_iCollectiveNeed;
	int limit = (g_hSurvivorLimit!=null)?g_hSurvivorLimit.IntValue:4;
	int alive = 0;
	for(int i = 1;i<=MaxClients;i++) if(IsAlive(i)) alive++;
	if (alive<=0) return 1;
	if(!g_bScaleByMax||limit<=0){
		if(base<1) base=1;
		if(base>alive) base=alive;
		return base;
	}
	float f = (float(base)*float(alive))/float(limit);
	int need = RoundToFloor(f+0.000001);
	if(need<1) need=1;
	if(need>alive) need=alive;
	return need;
}
bool IsAnyFFWindowActiveGlobal()
{
	float now = GetEngineTime();
	for(int v = 1; v<=MaxClients; v++) if(g_bFFWindowActive[v] && now<g_fFFWindowEnd[v]) return true;
	return false;
}
bool HasPermanentIgnoreFreezeFF()
{
	for(int v = 1; v<=MaxClients; v++) if(g_bFFWindowCausedIncap[v] && !g_bFFForgiven[v]) return true;
	return false;
}

void ArmKillResumeIfNoneIncap()
{
	if(g_Freeze!=FREEZE_POST_INCAP) return;
	if(CountIncapSurvivors()>0) return;
	g_fKillResumeEarliest=GetEngineTime()+g_fResumeDelay;
	if(g_bDbg) DbgPrint("Post-incap kill-to-resume armed until=%.1f", g_fKillResumeEarliest);
}

public Action OnHordeDirectorContinuing(float &timePast, float timeCap)
{
	g_bForwardSeen = true;
	g_fLastForward = GetEngineTime();

	if (!g_bEnable)
		return Plugin_Continue;

	if (IsAnyFFWindowActiveGlobal())
	{
		g_bFrozenHold = false;
		return Plugin_Continue;
	}

	// Post-incap
	if (g_Freeze == FREEZE_POST_INCAP)
	{
		int incaps = CountIncapSurvivors();

		int farId;
		float far = GetFarthestFlowSurvivor(farId);

		float slowI = GetSlowestIncapFlow();
		if (slowI < 0.0) slowI = 0.0;

		if (incaps == 0)
		{
			// Post-incap cleared - check IMMEDIATELY if collective should take over.
			if (GetEngineTime() >= g_fCollectiveRearmAt)
			{
				int have = CountCollectiveMembers();
				int needC = GetCollectiveNeedTarget();

				if (have >= needC)
				{
					// Transition directly to collective WITHOUT any unfrozen gap.
					g_Freeze = FREEZE_COLLECTIVE;
					g_bFrozenHold = true;
					g_fFrozenAt = timePast; // Keep frozen time, no jump.

					int dummy;
					g_fGateStartFlow = GetFarthestFlowSurvivor(dummy);
					return Plugin_Stop; // Stay frozen.
				}
			}

			// No collective freeze needed, check travel resume.
			if ((far - g_fGateStartFlow) >= GetRelaxDistance())
			{
				HD_SetHordesTime(0.0);

				g_Freeze = FREEZE_NONE;
				g_bFrozenHold = false;
				g_bUnfrozenBySpread = false;
				g_iSpreadHelper = 0;
				g_fKillResumeEarliest = 0.0;

				int d;
				g_fGateStartFlow = GetFarthestFlowSurvivor(d);
				g_fCollectiveRearmAt = GetEngineTime() + g_fRearmGrace;
				return Plugin_Continue;
			}
		}
		else
		{
			if (slowI > 0.0 && (far - slowI) >= g_fSpread)
			{
				g_bUnfrozenBySpread = true;
				g_iSpreadHelper = farId;
				g_Freeze = FREEZE_NONE;
				g_bFrozenHold = false;

				int d;
				g_fGateStartFlow = GetFarthestFlowSurvivor(d);
				g_fCollectiveRearmAt = GetEngineTime() + g_fRearmGrace;
				return Plugin_Continue;
			}

			if ((far - g_fGateStartFlow) >= GetRelaxDistance())
			{
				HD_SetHordesTime(0.0);

				g_Freeze = FREEZE_NONE;
				g_bFrozenHold = false;
				g_bUnfrozenBySpread = false;
				g_iSpreadHelper = 0;

				int d;
				g_fGateStartFlow = GetFarthestFlowSurvivor(d);
				g_fCollectiveRearmAt = GetEngineTime() + g_fRearmGrace;
				return Plugin_Continue;
			}
		}

		g_bFrozenHold = true;
		g_fFrozenAt = timePast;
		return Plugin_Stop;
	}

	// Collective
	if (g_Freeze == FREEZE_COLLECTIVE)
	{
		if (g_bFFDeathOccurred)
		{
			// FF death: stay unfrozen permanently.
			int have = CountCollectiveMembers();
			int needC = GetCollectiveNeedTarget();

			// Only clear flag when collective no longer needed.
			if (have < needC)
			{
				g_bFFDeathOccurred = false;
				g_Freeze = FREEZE_NONE;
				g_bFrozenHold = false;
			}

			return Plugin_Continue;
		}

		int farId;
		float far = GetFarthestFlowSurvivor(farId);

		float slowI = GetSlowestIncapFlow();
		float slowL = GetSlowestLimpFlow();

		float anchor = -1.0;
		if (slowI >= 0.0 && slowL >= 0.0) anchor = (slowI < slowL) ? slowI : slowL;
		else if (slowI >= 0.0) anchor = slowI;
		else if (slowL >= 0.0) anchor = slowL;

		if (anchor >= 0.0 && (far - anchor) >= g_fSpread)
		{
			g_bUnfrozenBySpread = true;
			g_iSpreadHelper = farId;
			g_Freeze = FREEZE_NONE;
			g_bFrozenHold = false;

			int d;
			g_fGateStartFlow = GetFarthestFlowSurvivor(d);
			g_fCollectiveRearmAt = GetEngineTime() + g_fRearmGrace;
			return Plugin_Continue;
		}

		if ((far - g_fGateStartFlow) >= GetRelaxDistance())
		{
			HD_SetHordesTime(0.0);

			g_Freeze = FREEZE_NONE;
			g_bFrozenHold = false;
			g_bUnfrozenBySpread = false;
			g_iSpreadHelper = 0;

			int d;
			g_fGateStartFlow = GetFarthestFlowSurvivor(d);
			g_fCollectiveRearmAt = GetEngineTime() + g_fRearmGrace;
			return Plugin_Continue;
		}

		g_bFrozenHold = true;
		g_fFrozenAt = timePast;
		return Plugin_Stop;
	}

	// After-return and pure relax gating both use GetRelaxDistance().
	if (g_Freeze == FREEZE_GATING_RELAX || g_Freeze == FREEZE_GATING_AFTER_RETURN)
	{
		float need = GetRelaxDistance();

		int dummy;
		float nowF = GetFarthestFlowSurvivor(dummy);

		if ((nowF - g_fGateStartFlow) >= need)
		{
			HD_SetHordesTime(0.0);

			g_Freeze = FREEZE_NONE;
			g_bFrozenHold = false;
			g_bUnfrozenBySpread = false;
			g_iSpreadHelper = 0;

			int d;
			g_fGateStartFlow = GetFarthestFlowSurvivor(d);
			g_fCollectiveRearmAt = GetEngineTime() + g_fRearmGrace;
			return Plugin_Continue;
		}

		g_bFrozenHold = true;
		g_fFrozenAt = timePast;
		return Plugin_Stop;
	}

	if (HasPermanentIgnoreFreezeFF())
	{
		g_bFrozenHold = false;
		return Plugin_Continue;
	}

	if (GetEngineTime() < g_fCollectiveRearmAt)
	{
		g_bFrozenHold = false;
		return Plugin_Continue;
	}

	int have = CountCollectiveMembers();
	int needC = GetCollectiveNeedTarget();
	if (have >= needC)
	{
		g_Freeze = FREEZE_COLLECTIVE;
		g_bFrozenHold = true;
		g_fFrozenAt = timePast;

		int dummy;
		g_fGateStartFlow = GetFarthestFlowSurvivor(dummy);
		return Plugin_Stop;
	}

	g_bFrozenHold = false;
	return Plugin_Continue;
}


// Events (includes grace short-circuit)
public void E_PlayerHurt(Event e, const char[] n, bool db)
{
	int v = GetClientOfUserId(e.GetInt("userid"));
	int a = GetClientOfUserId(e.GetInt("attacker"));
	if(!IsClientSurvivor(v)||!IsClientSurvivor(a)||v==a) return;
	int dmg = e.GetInt("dmg_health");
	int hp_after = GetClientHealth(v);
	int hp_before = hp_after+dmg;
	float temp = GetEntPropFloat(v,Prop_Send,"m_healthBuffer");
	if(temp<0.0) temp=0.0;
	bool adr = HasEntProp(v,Prop_Send,"m_bAdrenalineActive")&&(GetEntProp(v,Prop_Send,"m_bAdrenalineActive")!=0);
	bool before = ((float(hp_before)+temp)<=40.0 && !adr);
	bool after = IsLimpingNow(v);
	if(!before && after){
		g_bFFWindowActive[v]=true;
		g_fFFWindowEnd[v]=GetEngineTime()+g_fFFGrace;
		g_iFFWindowShooter[v]=a;
		g_bFFForgiven[v]=false;
		if(g_Freeze==FREEZE_COLLECTIVE||g_Freeze==FREEZE_POST_INCAP){
			g_Freeze=FREEZE_NONE;
			g_bFrozenHold=false;
			g_fKillResumeEarliest=0.0;
		}
	}
}

public void E_PlayerIncap(Event e, const char[] n, bool db)
{
	if (!g_bIncapFreeze) return;

	int vic = GetClientOfUserId(e.GetInt("userid"));
	int atk = GetClientOfUserId(e.GetInt("attacker"));
	bool ff = (atk > 0 && IsClientInGame(atk) && GetClientTeam(atk) == TEAM_SURVIVOR && atk != vic);

	if (IsClientSurvivor(vic) && g_bFFWindowActive[vic] && GetEngineTime() < g_fFFWindowEnd[vic])
	{
		g_bFFWindowCausedIncap[vic] = true;
		g_Freeze = FREEZE_NONE;
		g_bFrozenHold = false;
		return;
	}

	if (ff) return;

	g_Freeze = FREEZE_POST_INCAP;
	int dummy;
	g_fGateStartFlow = GetFarthestFlowSurvivor(dummy);
	g_bFrozenHold = true;
	g_fFrozenAt = view_as<float>(HD_GetHordesTime());
	g_fKillResumeEarliest = 0.0;
}

public void E_ReviveBegin(Event e, const char[] n, bool db)
{
	int h = GetClientOfUserId(e.GetInt("userid"));
	int t = GetClientOfUserId(e.GetInt("subject"));
	if(IsClientSurvivor(h)&&IsClientSurvivor(t)) g_iReviveTargetOfHelper[h]=t;
}
public void E_ReviveSuccess(Event e, const char[] n, bool db)
{
	int h = GetClientOfUserId(e.GetInt("userid"));
	int t = GetClientOfUserId(e.GetInt("subject"));
	if(!IsClientSurvivor(h)||!IsClientSurvivor(t)) return;
	if(g_iReviveTargetOfHelper[h]==t) g_iReviveTargetOfHelper[h]=0;
	if(g_iFFWindowShooter[t]==h&&g_bFFWindowCausedIncap[t]){
		g_bFFForgiven[t]=true;
		g_bFFWindowCausedIncap[t]=false;
		int have = CountCollectiveMembers();
		int needC = GetCollectiveNeedTarget();
		if(have>=needC) g_Freeze=FREEZE_COLLECTIVE;
	}
	ArmKillResumeIfNoneIncap();
}

public void E_PlayerDeath(Event e, const char[] n, bool db)
{
	int vic = GetClientOfUserId(e.GetInt("userid"));
	if (!IsClientSurvivor(vic)) return;

	int atk = GetClientOfUserId(e.GetInt("attacker"));
	bool isFF = (atk > 0 && IsClientInGame(atk) && GetClientTeam(atk) == TEAM_SURVIVOR && atk != vic);

	if (isFF)
	{
		// FF death: permanently unfreeze
		g_bFFDeathOccurred = true;
		g_Freeze = FREEZE_NONE;
		g_bFrozenHold = false;
		g_fKillResumeEarliest = 0.0;
		if (g_bDbg) DbgPrint("FF Death: permanent unfreeze");
		return;
	}

	// Non-FF death: check collective
	if (g_Freeze == FREEZE_POST_INCAP || g_Freeze == FREEZE_COLLECTIVE)
	{
		int have = CountCollectiveMembers();
		int needC = GetCollectiveNeedTarget();

		if (have >= needC)
		{
			if (g_Freeze == FREEZE_POST_INCAP)
			{
				g_Freeze = FREEZE_COLLECTIVE;
				g_bFrozenHold = true;
				g_fFrozenAt = view_as<float>(HD_GetHordesTime());
				int d;
				g_fGateStartFlow = GetFarthestFlowSurvivor(d);
				g_fKillResumeEarliest = 0.0;
				if (g_bDbg) DbgPrint("Death: transitioned POST_INCAP -> COLLECTIVE");
			}
			return;
		}
	}

	ArmKillResumeIfNoneIncap();
}

public void E_PlayerSpawn(Event e, const char[] n, bool b)
{
	int c = GetClientOfUserId(e.GetInt("userid"));
	if(c>0){
		g_bFFWindowActive[c]=false;
		g_fFFWindowEnd[c]=0.0;
		g_iFFWindowShooter[c]=0;
		g_bFFWindowCausedIncap[c]=false;
		g_bFFForgiven[c]=false;
		g_iReviveTargetOfHelper[c]=0;
	}
}
public void E_PlayerRescued(Event e, const char[] n, bool b)
{
	ArmKillResumeIfNoneIncap();
}
public void E_DefibUsed(Event e, const char[] n, bool b)
{
	ArmKillResumeIfNoneIncap();
}

// Round lifecycle
public void E_RoundStart(Event e, const char[] n, bool b)
{
	ResetAllState(true);
}
public void E_RoundEnd(Event e, const char[] n, bool b)
{
	ResetAllState(false);
}
public void ResetAllState(bool onStart)
{
	g_Freeze = FREEZE_NONE;

	g_bFrozenHold = false;
	g_fFrozenAt = 0.0;
	g_fKillResumeEarliest = 0.0;
	g_fCollectiveRearmAt = 0.0;

	g_bFFDeathOccurred = false;
	g_bUnfrozenBySpread = false;
	g_iSpreadHelper = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_bFFWindowActive[i] = false;
		g_fFFWindowEnd[i] = 0.0;
		g_iFFWindowShooter[i] = 0;
		g_bFFWindowCausedIncap[i] = false;
		g_bFFForgiven[i] = false;
		g_iReviveTargetOfHelper[i] = 0;
	}

	int dummy;
	g_fGateStartFlow = GetFarthestFlowSurvivor(dummy);

	if (GetFeatureStatus(FeatureType_Native, "HD_SetHordesTime") == FeatureStatus_Available)
		HD_SetHordesTime(0.0);

	g_fRelaxAuto = 0.0;
	g_iRelaxTries = 0;

	if (g_hRelaxTimer != null)
	{
		SafeKillTimer(g_hRelaxTimer);
		g_hRelaxTimer = null;
	}

	g_hRelaxTimer = CreateTimer(1.0, T_UpdateRelaxSafe, _, TIMER_FLAG_NO_MAPCHANGE);

	EnsureVSBuf();
	g_hVSBuf.SetString("0");
}

public void E_InfectedDeath(Event e, const char[] n, bool db)
{
	int attacker = GetClientOfUserId(e.GetInt("attacker"));
	if (attacker <= 0 || !IsClientInGame(attacker) || GetClientTeam(attacker) != TEAM_SURVIVOR) return;

	if (g_Freeze == FREEZE_POST_INCAP && g_fKillResumeEarliest > 0.0 && GetEngineTime() >= g_fKillResumeEarliest)
	{
		if (GetEngineTime() >= g_fCollectiveRearmAt)
		{
			int have = CountCollectiveMembers();
			int needC = GetCollectiveNeedTarget();
			if (have >= needC)
			{
				HD_SetHordesTime(0.0);
				g_Freeze = FREEZE_COLLECTIVE;
				g_bFrozenHold = true;
				g_fFrozenAt = 0.0;
				int d;
				g_fGateStartFlow = GetFarthestFlowSurvivor(d);
				g_fKillResumeEarliest = 0.0;
				if (g_bDbg) DbgPrint("Post-incap kill: transitioned to COLLECTIVE (timer=0)");
				return;
			}
		}
		g_Freeze = FREEZE_NONE;
		g_bFrozenHold = false;
		g_bUnfrozenBySpread = false;
		g_iSpreadHelper = 0;
		g_fKillResumeEarliest = 0.0;
		int d;
		g_fGateStartFlow = GetFarthestFlowSurvivor(d);
		g_fCollectiveRearmAt = GetEngineTime() + g_fRearmGrace;
		if (g_bDbg) DbgPrint("Post-incap kill: resumed");
		return;
	}

	if (g_Freeze == FREEZE_COLLECTIVE && g_fKillResumeEarliest > 0.0 && GetEngineTime() >= g_fKillResumeEarliest)
	{
		HD_SetHordesTime(0.0);
		g_fFrozenAt = 0.0;
		g_bFrozenHold = true;
		g_fKillResumeEarliest = 0.0;
		if (g_bDbg) DbgPrint("Collective kill: reset timer to 0");
	}
}

public void OnMapStart()
{
	ResetAllState(true);
	StartOrStopHud();
	StartOrStopEnforcer();
	if(g_hRelaxTimer==null) g_hRelaxTimer=CreateTimer(1.0, T_UpdateRelaxSafe, _, TIMER_FLAG_NO_MAPCHANGE);
}
public void OnConfigsExecuted()
{
	ApplyCvars();
	StartOrStopHud();
	StartOrStopEnforcer();
	if(g_hRelaxTimer==null) g_hRelaxTimer=CreateTimer(0.75, T_UpdateRelaxSafe, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action T_Enforce(Handle t, any d)
{
	if (!g_bEnable)
		return Plugin_Continue;

	bool policyHold =
	(
		g_Freeze == FREEZE_COLLECTIVE
		|| g_Freeze == FREEZE_GATING_RELAX
		|| g_Freeze == FREEZE_GATING_AFTER_RETURN
		|| g_Freeze == FREEZE_POST_INCAP
	);

	if (!policyHold && g_bFrozenHold)
		g_bFrozenHold = false;

	if (policyHold && g_bFrozenHold)
		HD_SetHordesTime(g_fFrozenAt);

	if (g_bDbgTrace)
	{
		float now = GetEngineTime();
		if (now >= g_fNextTrace)
		{
			g_fNextTrace = now + g_fDbgRate;

			int farId;
			float far = GetFarthestFlowSurvivor(farId);

			float slowI = GetSlowestIncapFlow();
			float slowL = GetSlowestLimpFlow();

			int have = CountCollectiveMembers();
			int need = GetCollectiveNeedTarget();

			float tp = view_as<float>(HD_GetHordesTime());

			DbgPrint("TRACE(enf): time=%.1f freeze=%d hold=%d have=%d/%d relax=%.0f spread=%.0f far=%.0f slowI=%.0f slowL=%.0f helper=%d arm=%.1f rearm=%.1f",
				tp, g_Freeze, g_bFrozenHold ? 1 : 0, have, need, GetRelaxDistance(), g_fSpread, far,
				(slowI < 0.0) ? 0.0 : slowI, (slowL < 0.0) ? 0.0 : slowL, farId, g_fKillResumeEarliest, g_fCollectiveRearmAt);
		}
	}

	return Plugin_Continue;
}

public Action T_Hud(Handle t, any d)
{
	if (!g_bDbgHud) return Plugin_Stop;

	char line[256];
	int dummy;
	float far = GetFarthestFlowSurvivor(dummy);
	float slowI = GetSlowestIncapFlow();
	float slowL = GetSlowestLimpFlow();
	if (slowI < 0.0) slowI = 0.0;
	if (slowL < 0.0) slowL = 0.0;
	int have = CountCollectiveMembers();
	int need = GetCollectiveNeedTarget();
	float tp = view_as<float>(HD_GetHordesTime());
	Format(line, sizeof(line), "[HDF] freeze=%d hold=%d time=%.1f have=%d/%d relax=%.0f spread=%.0f far=%.0f slowI=%.0f slowL=%.0f arm=%.1f rearm=%.1f",
	g_Freeze, g_bFrozenHold?1:0, tp, have, need, GetRelaxDistance(), g_fSpread, far, slowI, slowL, g_fKillResumeEarliest, g_fCollectiveRearmAt);

	// Admin-only HUD: show to clients who pass CheckCommandAccess("hdf_dbg_hud", ADMFLAG_GENERIC)
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (CheckCommandAccess(i, "hdf_dbg_hud", ADMFLAG_GENERIC, true))
		PrintHintText(i, "%s", line);
	}
	return Plugin_Continue;
}

void DbgPrint(const char[] fmt, any ...)
{
	char msg[256];
	VFormat(msg, sizeof(msg), fmt, 2);
	PrintToServer("[HDF] %s", msg);
	if (g_bDbgFile) LogToFileEx(g_sDbgPath, "%s", msg);

	if (g_bDbgTrace)
	{
		// Admin-only chat + hint spam for trace mode
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i)) continue;
			if (!CheckCommandAccess(i, "hdf_dbg_hud", ADMFLAG_GENERIC, true)) continue;
			PrintToChat(i, "[HDF] %s", msg);
			PrintHintText(i, "[HDF] %s", msg);
		}
	}
}

public Action CmdPing(int client, int args)
{
	PrintToServer("[HDF] ping: plugin alive, freeze=%d, trace=%d", g_Freeze, g_bDbgTrace?1:0);

	// Admin-only chat + hint for ping
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (!CheckCommandAccess(i, "hdf_dbg_hud", ADMFLAG_GENERIC, true)) continue;
		PrintToChat(i, "[HDF] ping alive freeze=%d trace=%d", g_Freeze, g_bDbgTrace?1:0);
		PrintHintText(i, "[HDF] ping alive freeze=%d trace=%d", g_Freeze, g_bDbgTrace?1:0);
	}
	return Plugin_Handled;
}

public Action CmdTrace(int client, int args)
{
	if (args >= 1)
	{
		char a0[16];
		GetCmdArg(1, a0, sizeof(a0));
		g_bDbgTrace = (StringToInt(a0) != 0);
		gC_DbgTrace.SetInt(g_bDbgTrace ? 1 : 0);
	}
	if (args >= 2)
	{
		char a1[16];
		GetCmdArg(2, a1, sizeof(a1));
		g_iDbgTraceTarget = StringToInt(a1);
		gC_DbgTraceTarget.SetInt(g_iDbgTraceTarget);
	}

	PrintToServer("[HDF] trace=%d rate=%.2f hud=%d file=%d", g_bDbgTrace?1:0, g_fDbgRate, g_bDbgHud?1:0, g_bDbgFile?1:0);

	// Admin-only chat notice
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (!CheckCommandAccess(i, "hdf_dbg_hud", ADMFLAG_GENERIC, true)) continue;
		PrintToChat(i, "[HDF] trace=%d rate=%.2f hud=%d file=%d", g_bDbgTrace?1:0, g_fDbgRate, g_bDbgHud?1:0, g_bDbgFile?1:0);
	}
	return Plugin_Handled;
}

public Action CmdFFList(int client, int args)
{
	float now = GetEngineTime();
	PrintToServer("[HDF] FF windows:");
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bFFWindowActive[i] && now < g_fFFWindowEnd[i])
		PrintToServer("  victim=%d shooter=%d until=%.1f permIncap=%d forgiven=%d",
		i, g_iFFWindowShooter[i], g_fFFWindowEnd[i], g_bFFWindowCausedIncap[i]?1:0, g_bFFForgiven[i]?1:0);
	}
	return Plugin_Handled;
}

public Action CmdRelaxRefresh(int client, int args)
{
	g_iRelaxTries = 0;

	if (g_hRelaxTimer != null)
	{
		SafeKillTimer(g_hRelaxTimer);
		g_hRelaxTimer = null;
	}

	EnsureVSBuf();
	g_hVSBuf.SetString("0");

	UpdateAutoRelax();

	if (g_fRelaxAuto <= 0.0)
		g_hRelaxTimer = CreateTimer(RELAX_RETRY_SECS, T_UpdateRelaxSafe, _, TIMER_FLAG_NO_MAPCHANGE);

	PrintToServer("[HDF] relax refreshed: now=%.0f (explicit=%.0f)", GetRelaxDistance(), gC_ResumeFlow.FloatValue);
	return Plugin_Handled;
}

public Action CmdDump(int client, int args)
{
	int have = CountCollectiveMembers();
	int need = GetCollectiveNeedTarget();

	int farId;
	float far = GetFarthestFlowSurvivor(farId);

	float slowI = GetSlowestIncapFlow();
	float slowL = GetSlowestLimpFlow();
	if (slowI < 0.0) slowI = 0.0;
	if (slowL < 0.0) slowL = 0.0;

	float tp = view_as<float>(HD_GetHordesTime());
	int survivor_limit = (g_hSurvivorLimit != null) ? g_hSurvivorLimit.IntValue : 4;

	PrintToServer("[HDF] DUMP ----");

	PrintToServer("time=%.1f freeze=%d hold=%d have=%d/%d relax=%.0f spread=%.0f gateStart=%.0f unfreezeBySpread=%d spreadHelper=%d killArm=%.1f rearm=%.1f slowI=%.0f slowL=%.0f",
		tp, g_Freeze, g_bFrozenHold ? 1 : 0, have, need, GetRelaxDistance(), g_fSpread, g_fGateStartFlow,
		g_bUnfrozenBySpread ? 1 : 0, g_iSpreadHelper, g_fKillResumeEarliest, g_fCollectiveRearmAt, slowI, slowL);

	PrintToServer("flows: far=%.0f farId=%d survivor_limit=%d forwardSeen=%d",
		far, farId, survivor_limit, g_bForwardSeen ? 1 : 0);

	PrintToServer("FF: anyGrace=%d permIgnore=%d",
		IsAnyFFWindowActiveGlobal() ? 1 : 0, HasPermanentIgnoreFreezeFF() ? 1 : 0);

	// Admin-only chat summary
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (!CheckCommandAccess(i, "hdf_dbg_hud", ADMFLAG_GENERIC, true)) continue;

		PrintToChat(i, "[HDF] dump: freeze=%d hold=%d time=%.1f have=%d/%d relax=%.0f spread=%.0f",
			g_Freeze, g_bFrozenHold ? 1 : 0, tp, have, need, GetRelaxDistance(), g_fSpread);
	}

	return Plugin_Handled;
}
