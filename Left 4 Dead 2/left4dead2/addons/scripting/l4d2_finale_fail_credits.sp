// File: l4d2_finale_fail_ending.sp

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.6.1"

#define CVAR_FLAGS FCVAR_NOTIFY

#define PLUGIN_PREFIX "l4d2_"
#define PLUGIN_NAME   "finale_fail_credits"
#define CVARNAME(%1)  PLUGIN_PREFIX ... PLUGIN_NAME ... %1

public Plugin myinfo =
{
    name        = "[L4D2] Finale Fail Ending",
    author      = "Tighty-Whitey",
    description = "Converts finale failure into a stats outro.",
    version     = "1.0",
    url         = ""
};

// Timing cvar
ConVar gC_FinishToStatsDelay;

// Enable + gamemode filtering
ConVar gC_Enable;
ConVar gC_Modes;
ConVar gC_MPGameMode;
bool   g_bCvarAllow = true;

// State
bool   g_bFinaleActive = false;
bool   g_bAlreadyForced = false;
Handle g_hDelay = null, g_hStats = null;

// Death-check lock
ConVar gC_NoDeathCheck = null;
int    g_iNoDeathPrev  = 0;
bool   g_bDeathLocked  = false;

public void OnPluginStart()
{
    // CVARS
    gC_Enable = CreateConVar( CVARNAME("_enable"), "1", "Enable plugin (0/1).", CVAR_FLAGS );
    gC_Modes  = CreateConVar( CVARNAME("_modes"), "", "Allowed game modes (csv, empty = all).", CVAR_FLAGS );

    gC_FinishToStatsDelay = CreateConVar( CVARNAME("_finish_to_stats_delay"), "0.35", "Delay before stats crawl (sec).", CVAR_FLAGS );

    AutoExecConfig(true, PLUGIN_PREFIX ... PLUGIN_NAME);

    // ConVar hooks
    gC_MPGameMode = FindConVar("mp_gamemode");

    if( gC_MPGameMode != null )
        gC_MPGameMode.AddChangeHook(CvarChanged_Allow);

    gC_Enable.AddChangeHook(CvarChanged_Allow);
    gC_Modes.AddChangeHook(CvarChanged_Allow);

    IsAllowed();

    // Grab director_no_death_check (cheat cvar: 0 = normal, 1 = disable mission-lost death ending)
    gC_NoDeathCheck = FindConVar("director_no_death_check");

    if (gC_NoDeathCheck != null)
        g_iNoDeathPrev = gC_NoDeathCheck.IntValue;

    // Finale lifecycle
    HookEvent("finale_start", E_FinaleStart, EventHookMode_PostNoCopy);
    HookEvent("finale_radio_start", E_FinaleStart, EventHookMode_PostNoCopy);
    HookEvent("gauntlet_finale_start", E_FinaleStart, EventHookMode_PostNoCopy);

    HookEvent("finale_win", E_FinaleEnd, EventHookMode_PostNoCopy);
    HookEvent("map_transition", E_MapTransition, EventHookMode_PostNoCopy);
    HookEvent("round_end", E_RoundEnd, EventHookMode_PostNoCopy);

    // Normal escape path: when vehicle leaves, lock out death-check so late wipes can't roll mission_lost
    HookEvent("finale_vehicle_leaving", E_VehicleLeaving, EventHookMode_PostNoCopy);

    // Failure path (preempt + fallback)
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

// ---
// CVAR / GAMEMODE FILTER
// ---
void CvarChanged_Allow(ConVar convar, const char[] oldValue, const char[] newValue)
{
    IsAllowed();
}

void IsAllowed()
{
    bool allow = (gC_Enable != null) ? gC_Enable.BoolValue : true;
    bool mode  = IsAllowedGameMode();

    g_bCvarAllow = (allow && mode);
}

bool IsAllowedGameMode()
{
    if( gC_MPGameMode == null )
        gC_MPGameMode = FindConVar("mp_gamemode");

    if( gC_MPGameMode == null )
        return false;

    char mode[64];
    gC_MPGameMode.GetString(mode, sizeof(mode));
    Format(mode, sizeof(mode), ",%s,", mode);

    char modes[256];
    if( gC_Modes != null )
        gC_Modes.GetString(modes, sizeof(modes));
    else
        modes[0] = '\0';

    // Empty = all.
    if( !modes[0] )
        return true;

    Format(modes, sizeof(modes), ",%s,", modes);

    if( StrContains(modes, mode, false) == -1 )
        return false;

    return true;
}

// --- death-check lock helpers ---

void LockDeathCheck()
{
    if (gC_NoDeathCheck == null || g_bDeathLocked)
        return;

    g_iNoDeathPrev = gC_NoDeathCheck.IntValue;
    gC_NoDeathCheck.SetInt(1);   // disable death ending once outro is locked
    g_bDeathLocked = true;
}

void RestoreDeathCheck()
{
    if (gC_NoDeathCheck == null || !g_bDeathLocked)
        return;

    gC_NoDeathCheck.SetInt(g_iNoDeathPrev);
    g_bDeathLocked = false;
}

// Finale lifecycle

public void E_FinaleStart(Event e, const char[] n, bool b)
{
    if( !g_bCvarAllow ) return;
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

// Normal escape: once the vehicle leaves, lock death-check so late wipes can't cause mission_lost.
public void E_VehicleLeaving(Event e, const char[] n, bool b)
{
    if( !g_bCvarAllow ) return;
    if (!g_bFinaleActive) return;
    LockDeathCheck();
}

// Preempt when no one can stand
public void E_PlayerStateChange(Event e, const char[] n, bool b)
{
    if( !g_bCvarAllow ) return;
    if (!g_bFinaleActive || g_bAlreadyForced) return;

    if (AllSurvivorsUnableToStand())
    {
        g_bAlreadyForced = true;
        // We are about to force outro; lock death-check so later incaps/deaths don't restart the round.
        LockDeathCheck();
        ForceOutroNow();
    }
}

// mission_lost fallback
public Action E_MissionLost(Event e, const char[] n, bool b)
{
    if( !g_bCvarAllow ) return Plugin_Continue;
    // If outro is already locked (vehicle leaving or forced outro), ignore mission_lost entirely.
    if (g_bDeathLocked)
        return Plugin_Handled; // suppress as much as the event system allows

    if (!g_bFinaleActive || g_bAlreadyForced)
        return Plugin_Continue;

    g_bAlreadyForced = true;
    LockDeathCheck();
    // Run on next frame to outrun default mission-lost handling.
    RequestFrame(RF_ForceOutro);
    return Plugin_Handled;
}

public void RF_ForceOutro(any d)
{
    ForceOutroNow();
}

// Core: finish then stats (no kills, no teleports)
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

    AcceptEntityInput(finale, "FinaleEscapeFinished"); // consolidate stats and mark victory

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
        AcceptEntityInput(stats, "RollStatsCrawl"); // full stats crawl + lobby return
    return Plugin_Stop;
}

// Finale targeting
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

// Survivor-state helpers
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
