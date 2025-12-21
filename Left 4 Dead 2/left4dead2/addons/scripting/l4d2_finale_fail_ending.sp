#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define CVAR_FLAGS FCVAR_NOTIFY

public Plugin myinfo =
{
    name        = "[L4D2] Finale Fail Ending",
    author      = "Tighty-Whitey",
    description = "Converts finale failure into a stats outro.",
    version     = "1.0",
    url         = ""
};

ConVar gC_FinishToStatsDelay;

ConVar gC_Enable;
ConVar gC_Modes;
ConVar gC_MapsOff;
ConVar gC_MPGameMode;

bool g_bCvarAllow = true;

bool   g_bFinaleActive = false;
bool   g_bAlreadyForced = false;
Handle g_hDelay = null, g_hStats = null;

ConVar gC_NoDeathCheck = null;
int    g_iNoDeathPrev  = 0;
bool   g_bDeathLocked  = false;

public void OnPluginStart()
{
    gC_Enable = CreateConVar("l4d2_finale_fail_ending_enable", "1", "0=Plugin off, 1=Plugin on.", CVAR_FLAGS);
    gC_Modes = CreateConVar("l4d2_finale_fail_ending_modes", "coop,realism", "Turn on the plugin in these game modes, separate by commas (no spaces). Empty = all.", CVAR_FLAGS);
    gC_MapsOff = CreateConVar("l4d2_finale_fail_ending_maps_off", "", "Turn off the plugin on these maps, separate by commas (no spaces). Empty = none.", CVAR_FLAGS);
    gC_FinishToStatsDelay = CreateConVar("l4d2_finale_fail_ending_finish_to_stats_delay", "0.35", "Delay after FinaleEscapeFinished before env_outtro_stats.RollStatsCrawl (sec).", CVAR_FLAGS);

    AutoExecConfig(true, "l4d2_finale_fail_ending");

    gC_MPGameMode = FindConVar("mp_gamemode");

    if (gC_MPGameMode != null)
        gC_MPGameMode.AddChangeHook(CvarChanged_Allow);

    gC_Enable.AddChangeHook(CvarChanged_Allow);
    gC_Modes.AddChangeHook(CvarChanged_Allow);
    gC_MapsOff.AddChangeHook(CvarChanged_Allow);

    IsAllowed();

    gC_NoDeathCheck = FindConVar("director_no_death_check");

    if (gC_NoDeathCheck != null)
        g_iNoDeathPrev = gC_NoDeathCheck.IntValue;

    HookEvent("finale_start", E_FinaleStart, EventHookMode_PostNoCopy);
    HookEvent("finale_radio_start", E_FinaleStart, EventHookMode_PostNoCopy);
    HookEvent("gauntlet_finale_start", E_FinaleStart, EventHookMode_PostNoCopy);

    HookEvent("finale_win", E_FinaleEnd, EventHookMode_PostNoCopy);
    HookEvent("map_transition", E_MapTransition, EventHookMode_PostNoCopy);
    HookEvent("round_end", E_RoundEnd, EventHookMode_PostNoCopy);

    HookEvent("finale_vehicle_leaving", E_VehicleLeaving, EventHookMode_PostNoCopy);

    HookEvent("player_death", E_PlayerStateChange, EventHookMode_Post);
    HookEvent("player_incapacitated", E_PlayerStateChange, EventHookMode_Post);
    HookEvent("mission_lost", E_MissionLost, EventHookMode_Pre);
}

public void OnMapStart()
{
    ResetState();

    IsAllowed();
    if (gC_NoDeathCheck != null)
    {
        g_iNoDeathPrev = gC_NoDeathCheck.IntValue;
        g_bDeathLocked = false;
    }
}

public void OnConfigsExecuted()
{
    IsAllowed();
}

public void OnMapEnd()
{
    KillTimerSafe(g_hDelay);
    KillTimerSafe(g_hStats);
    RestoreDeathCheck();
    ResetState();
}

void ResetState()
{
    g_bFinaleActive = false;
    g_bAlreadyForced = false;
}

void KillTimerSafe(Handle &h)
{
    if (h != null) { CloseHandle(h); h = null; }
}

void CvarChanged_Allow(ConVar convar, const char[] oldValue, const char[] newValue)
{
    IsAllowed();
}

void IsAllowed()
{
    bool allow = (gC_Enable != null) ? gC_Enable.BoolValue : true;
    bool mode = IsAllowedGameMode();
    bool maps = !IsBlockedMap();

    g_bCvarAllow = (allow && mode && maps);
}

bool IsAllowedGameMode()
{
    if (gC_MPGameMode == null)
        gC_MPGameMode = FindConVar("mp_gamemode");

    if (gC_MPGameMode == null)
        return false;

    char mode[64];
    gC_MPGameMode.GetString(mode, sizeof(mode));
    Format(mode, sizeof(mode), ",%s,", mode);

    char modes[256];
    if (gC_Modes != null)
        gC_Modes.GetString(modes, sizeof(modes));
    else
        modes[0] = '\0';

    if (!modes[0])
        return true;

    Format(modes, sizeof(modes), ",%s,", modes);

    if (StrContains(modes, mode, false) == -1)
        return false;

    return true;
}

bool IsBlockedMap()
{
    if (gC_MapsOff == null)
        return false;

    char maps[512];
    gC_MapsOff.GetString(maps, sizeof(maps));

    if (!maps[0])
        return false;

    char map[64];
    GetCurrentMap(map, sizeof(map));

    Format(map, sizeof(map), ",%s,", map);
    Format(maps, sizeof(maps), ",%s,", maps);

    return (StrContains(maps, map, false) != -1);
}

void LockDeathCheck()
{
    if (gC_NoDeathCheck == null || g_bDeathLocked)
        return;

    g_iNoDeathPrev = gC_NoDeathCheck.IntValue;
    gC_NoDeathCheck.SetInt(1);
    g_bDeathLocked = true;
}

void RestoreDeathCheck()
{
    if (gC_NoDeathCheck == null || !g_bDeathLocked)
        return;

    gC_NoDeathCheck.SetInt(g_iNoDeathPrev);
    g_bDeathLocked = false;
}

public void E_FinaleStart(Event e, const char[] n, bool b)
{
    if (!g_bCvarAllow) return;
    g_bFinaleActive = true;
    g_bAlreadyForced = false;
}

public void E_FinaleEnd(Event e, const char[] n, bool b)
{
    g_bFinaleActive = false;
    g_bAlreadyForced = false;
    KillTimerSafe(g_hDelay);
    KillTimerSafe(g_hStats);
    RestoreDeathCheck();
}

public void E_MapTransition(Event e, const char[] n, bool b)
{
    g_bFinaleActive = false;
    g_bAlreadyForced = true;
    KillTimerSafe(g_hDelay);
    KillTimerSafe(g_hStats);
    RestoreDeathCheck();
}

public void E_RoundEnd(Event e, const char[] n, bool b)
{
    g_bFinaleActive = false;
    g_bAlreadyForced = false;
    KillTimerSafe(g_hDelay);
    KillTimerSafe(g_hStats);
    RestoreDeathCheck();
}

public void E_VehicleLeaving(Event e, const char[] n, bool b)
{
    if (!g_bCvarAllow) return;
    if (!g_bFinaleActive) return;
    LockDeathCheck();
}

public void E_PlayerStateChange(Event e, const char[] n, bool b)
{
    if (!g_bCvarAllow) return;
    if (!g_bFinaleActive || g_bAlreadyForced) return;

    if (AllSurvivorsUnableToStand())
    {
        g_bAlreadyForced = true;
        LockDeathCheck();
        ForceOutroNow();
    }
}

public Action E_MissionLost(Event e, const char[] n, bool b)
{
    if (!g_bCvarAllow) return Plugin_Continue;

    if (g_bDeathLocked)
        return Plugin_Handled;

    if (!g_bFinaleActive || g_bAlreadyForced)
        return Plugin_Continue;

    g_bAlreadyForced = true;
    LockDeathCheck();
    RequestFrame(RF_ForceOutro);
    return Plugin_Handled;
}

public void RF_ForceOutro(any d)
{
    ForceOutroNow();
}

void ForceOutroNow()
{
    int finale = GetActiveFinaleController();
    if (finale == -1) return;

    int stats = FindEntityByClassname(-1, "env_outtro_stats");
    if (stats == -1)
    {
        AcceptEntityInput(finale, "FinaleEscapeFinished");
        return;
    }

    AcceptEntityInput(finale, "FinaleEscapeFinished");

    float gap = gC_FinishToStatsDelay.FloatValue;
    if (gap < 0.0) gap = 0.0;

    KillTimerSafe(g_hStats);
    g_hStats = CreateTimer(gap, T_RollStats, EntIndexToEntRef(stats), TIMER_FLAG_NO_MAPCHANGE);
}

public Action T_RollStats(Handle t, any ref)
{
    g_hStats = null;

    int stats = EntRefToEntIndex(ref);
    if (stats != -1)
        AcceptEntityInput(stats, "RollStatsCrawl");

    return Plugin_Stop;
}

static bool IsEntDisabled(int ent)
{
    if (ent<=0 || !IsValidEntity(ent)) return true;
    if (HasEntProp(ent,Prop_Data,"m_bDisabled"))
        return GetEntProp(ent,Prop_Data,"m_bDisabled")!=0;
    return false;
}

static bool GetEntOriginSafe(int ent, float o[3])
{
    if (HasEntProp(ent,Prop_Send,"m_vecOrigin"))
    {
        GetEntPropVector(ent,Prop_Send,"m_vecOrigin",o);
        return true;
    }
    if (HasEntProp(ent,Prop_Data,"m_vecAbsOrigin"))
    {
        GetEntPropVector(ent,Prop_Data,"m_vecAbsOrigin",o);
        return true;
    }
    return false;
}

static bool GetSurvivorCentroid(float outPos[3])
{
    float s[3]={0.0,0.0,0.0}; int c=0;
    for(int i=1;i<=MaxClients;i++)
    {
        if(!IsClientInGame(i) || GetClientTeam(i)!=2) continue;
        float p[3]; GetClientAbsOrigin(i,p);
        s[0]+=p[0]; s[1]+=p[1]; s[2]+=p[2]; c++;
    }
    if(!c) return false;
    outPos[0]=s[0]/c; outPos[1]=s[1]/c; outPos[2]=s[2]/c; return true;
}

int FindActiveFinaleTrigger()
{
    int list[64]; int n=0; int ent=-1;
    while((ent=FindEntityByClassname(ent,"trigger_finale"))!=-1 && n<64)
        if(!IsEntDisabled(ent)) list[n++]=ent;
    ent=-1;
    while((ent=FindEntityByClassname(ent,"trigger_finale_dlc3"))!=-1 && n<64)
        if(!IsEntDisabled(ent)) list[n++]=ent;
    if(n==0) return -1;

    float team[3];
    if(!GetSurvivorCentroid(team))
        return list[0];

    float best = 1.0e12; int pick=list[0];
    for(int i=0;i<n;i++)
    {
        float o[3]; if(!GetEntOriginSafe(list[i],o)) continue;
        float dx=o[0]-team[0], dy=o[1]-team[1], dz=o[2]-team[2];
        float d=dx*dx+dy*dy+dz*dz;
        if(d<best){ best=d; pick=list[i]; }
    }
    return pick;
}

int GetActiveFinaleController()
{
    static int ref=INVALID_ENT_REFERENCE;
    int e=EntRefToEntIndex(ref);
    if(e!=-1 && !IsEntDisabled(e)) return e;
    e=FindActiveFinaleTrigger();
    ref=(e!=-1)?EntIndexToEntRef(e):INVALID_ENT_REFERENCE;
    return e;
}

bool AllSurvivorsUnableToStand()
{
    int aliveStanding=0;
    for(int i=1;i<=MaxClients;i++)
    {
        if(!IsClientInGame(i) || GetClientTeam(i)!=2) continue;
        bool standing = IsPlayerAlive(i) && (GetEntProp(i, Prop_Send, "m_isIncapacitated")==0);
        if (standing) aliveStanding++;
    }
    return (aliveStanding == 0);
}
