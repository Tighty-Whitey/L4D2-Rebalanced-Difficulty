// File: l4d2_boss_director.sp

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZCLASS_TANK 8
#define ZCLASS_WITCH 6

#define PZCLASS_WITCHSEARCH 7
#define PZCLASS_FALLBACK    8

#define WITCH_CLUSTER_TRIES 12
#define WITCH_MAX_CLUSTER   8

#define PLUGIN_PREFIX "l4d2_"
#define PLUGIN_NAME "boss_director"
#define CVARNAME(%1) PLUGIN_NAME ... %1

#define CRUMB_MAX 256
#define K_MAX_PLANS 64
#define K_BURST_MAX 4
#define K_MAX_CHECKS 16
#define K_FINAL_ALLOW 64
#define K_MAX_WITCH_PLANS 48

#define PHASE_1 1
#define PHASE_2 2
#define PHASE_3 3
#define PHASE_4 4
#define PHASE_5 5
#define PHASE_6 6
#define PHASE_7 7
#define PHASE_8 8
#define PHASE_FROZEN5 9

public Plugin myinfo =
{
    name = "[L4D2] Boss Director",
    author = "Tighty-Whitey",
    description = "Adaptive boss director.",
    version = "1.1",
    url = ""
};

/* ===== ConVars ===== */
ConVar gC_Enable, gC_Modes, gC_DirectorNoBosses, gC_MPGameMode;
ConVar gC_Tick, gC_Debug, gC_MaxAlive, gC_NoBosses;

// Score
ConVar gC_StartEasy, gC_StartNorm, gC_StartAdv, gC_StartExp, gC_ScoreMin;
ConVar gC_ResetScoreOnCampaign;
ConVar gC_VersusBaseline, gC_VersusForceReset;

// Damage -> score
ConVar gC_DmgMode, gC_DmgPerPt, gC_DmgMul;

// Checkpoints
ConVar gC_QHealthMode, gC_QHealthPer, gC_QHealthMul, gC_QDmgPenaltyMul, gC_IncludeTemp, gC_QCheckCSV;

// Tanks window
ConVar gC_MinPct, gC_MaxPct, gC_MinGapPct, gC_PlanMax;
ConVar gC_AllowFront, gC_AllowBehind;
ConVar gC_BurstChance, gC_BurstWeights, gC_BurstMax, gC_BurstMinPct;
ConVar gC_PlanAheadDelta, gC_ExecRetrySec;
ConVar gC_C1M1MinFlowPct;
ConVar gC_C1M1MinScore;
ConVar gC_C1M1TokenCap;

// Crumbs-only behind
ConVar gC_CrumbTick, gC_CrumbAgeMax;
ConVar gC_MinXY, gC_MaxZD, gC_MinDot;
ConVar gC_MinBackSlow, gC_MinBackFar;
ConVar gC_CrumbChance, gC_CrumbRadius, gC_MaxBackClamp;

// Finale + HUD
ConVar gC_FinaleNoGain, gC_FinaleNoTanks, gC_FinaleAllowCSV, gC_EndAwardMinPct;
ConVar gC_DbgHud, gC_DbgHudWitch, gC_DbgRate;

// Witches (moon phases)
ConVar gC_WitchEnable;
ConVar gC_Ph2Score, gC_Ph3Score, gC_Ph4Score, gC_Ph5Score;
ConVar gC_Ph2TotalCap, gC_Ph3ClusterCap;
ConVar gC_Ph4TotalCap, gC_Ph4NormalCap, gC_Ph4WanderCap;
ConVar gC_Ph5TotalCap, gC_Ph5NormalCap, gC_Ph5WanderCap;
ConVar gC_Ph4WanderPackChance, gC_Ph4WanderPackMax;
ConVar gC_Ph5WanderPackChance, gC_Ph5WanderPackMax;
ConVar gC_WitchSpawnCloseDist;
ConVar gC_WitchLog;
ConVar gC_Frozen5MapsCsv;
ConVar gC_WitchClusterMinMemberDist;
ConVar gC_P5LockEnable;
ConVar gC_Frozen5WrapMode;
ConVar gC_P5LockFloor;
ConVar gC_LockRatchetEnable;
ConVar gC_P5BlockTanks;
ConVar gC_Frozen5LockTanks;
ConVar gC_P5UnlockOnCampaign;
ConVar gC_P5UnlockOnMapStart;
ConVar gC_WanderPersistCsv;
ConVar gC_WitchBlockMapsCsv;
ConVar gC_TankBlockMapsCsv;

/* ===== State ===== */

bool g_bMapStarted = false;
bool g_bEnabled = true;
bool g_bDirectorNoBossesApplied = false;

Handle g_hTick = null, g_hCrumbTimer = null, g_hHudTimer = null;

float g_Score = 0.0;
char g_LastCampaign[32] = "";
float g_MapFlowMax = 0.0;
bool g_LeftStart = false, g_IsFinale = false;

// Checkpoints
float g_QDamage = 0.0;
float g_QPerc[K_MAX_CHECKS];
bool  g_QAwarded[K_MAX_CHECKS];
int   g_QCount = 0;
float g_QLastAwardedPct = 0.0;

// Tank tokens
int g_TokensAwarded = 0;
int g_TokensConsumed = 0;

// Tank plans
int   g_PlanCount = 0;
float g_PlanPct[K_MAX_PLANS];
bool  g_PlanExecuted[K_MAX_PLANS];
bool  g_PlanCanceled[K_MAX_PLANS];
int   g_PlanSide[K_MAX_PLANS];
int   g_PlanBurstTarget[K_MAX_PLANS];
int   g_PlanBurstSpawned[K_MAX_PLANS];
float g_PlanRetryUntil[K_MAX_PLANS];

// Crumbs
float g_vCrumbs[MAXPLAYERS + 1][CRUMB_MAX][3];
float g_tCrumbs[MAXPLAYERS + 1][CRUMB_MAX];
int   g_iCrumbHead[MAXPLAYERS + 1];
int   g_iCrumbCount[MAXPLAYERS + 1];

// Finale allow
char g_FinalAllow[K_FINAL_ALLOW][64];
int  g_FinalAllowCount = 0;

// Frozen-5 Maps
char g_Frozen5Allow[K_FINAL_ALLOW][64];
int  g_Frozen5AllowCount = 0;

// Wander-persist Maps
char g_WanderPersistAllow[K_FINAL_ALLOW][64];
int  g_WanderPersistCount = 0;

// Witch-block Maps (never spawn witches)
char g_WitchBlockAllow[K_FINAL_ALLOW][64];
int  g_WitchBlockCount = 0;

// Tank-block Maps (never spawn Tanks)
char g_TankBlockAllow[K_FINAL_ALLOW][64];
int  g_TankBlockCount = 0;

// Witches
int   g_WitchesKilledTotal = 0;
int   g_WitchesSpawnedTotal = 0;

int   g_WitchPlanCount = 0;
float g_WitchPlanPct[K_MAX_WITCH_PLANS];
bool  g_WitchPlanExecuted[K_MAX_WITCH_PLANS];
bool  g_WitchPlanCanceled[K_MAX_WITCH_PLANS];
int   g_WitchPlanType[K_MAX_WITCH_PLANS]; // 0 normal, 1 cluster, 2 wander
int   g_WitchPlanSize[K_MAX_WITCH_PLANS];
bool  g_bIsWanderModeLocked = false;
static int g_iLastWitchPhase = 0;

bool  g_OnMirror = false;
int   g_LastPhase = PHASE_1;
bool  g_Phase5Lock = false;
float g_Phase5Floor = 600.0; // deprecated: now controlled by gC_P5LockFloor cvar
float g_LockBaselineScore = 0.0;

float g_VecZero[3] = {0.0, 0.0, 0.0};

/* ===== Utils ===== */

static bool BD_IsAllowedGameMode()
{
    if (gC_MPGameMode == null) return true;

    char list[128];
    gC_Modes.GetString(list, sizeof list);
    if (!list[0])
    {
        // Empty list means allow all.
        return true;
    }

    char mode[64];
    gC_MPGameMode.GetString(mode, sizeof mode);

    // Wrap with commas to avoid partial matches.
    Format(mode, sizeof mode, ",%s,", mode);
    Format(list, sizeof list, ",%s,", list);

    return (StrContains(list, mode, false) != -1);
}

static bool BD_IsEnabledNow()
{
    if (!gC_Enable.BoolValue) return false;
    if (!BD_IsAllowedGameMode()) return false;
    return true;
}

static void BD_StopAllTimers()
{
    if (g_hTick != null) { CloseHandle(g_hTick); g_hTick = null; }
    if (g_hCrumbTimer != null) { CloseHandle(g_hCrumbTimer); g_hCrumbTimer = null; }
    if (g_hHudTimer != null) { CloseHandle(g_hHudTimer); g_hHudTimer = null; }
}

static void BD_ApplyDirectorNoBossesOnce()
{
    if (!g_bEnabled) return;
    if (!g_bMapStarted) return;
    if (g_bDirectorNoBossesApplied) return;

    if (gC_NoBosses == null) return;

    int v = gC_DirectorNoBosses.IntValue;
    if (v == 0)
        return; // Do not touch director_no_bosses at all.

    // Apply once per map.
    SetConVarInt(gC_NoBosses, 1);
    g_bDirectorNoBossesApplied = true;
}

static void BD_RefreshEnabled()
{
    bool allow = BD_IsEnabledNow();

    if (allow == g_bEnabled) return;

    g_bEnabled = allow;

    if (!g_bEnabled)
    {
        BD_StopAllTimers();
        return;
    }

    // If enabling mid-map, apply the base director_no_bosses value once.
    BD_ApplyDirectorNoBossesOnce();
}

public void OnBDEnableCvarChanged(ConVar cvar, const char[] oldv, const char[] newv)
{
    BD_RefreshEnabled();
    BD_ApplyDirectorNoBossesOnce();
}

static bool IsValidClient(int c) { return (c >= 1 && c <= MaxClients && IsClientInGame(c)); }
static bool IsValidSurvivor(int c) { return (IsValidClient(c) && GetClientTeam(c) == TEAM_SURVIVOR && IsPlayerAlive(c)); }
static bool IsDigit(char c) { return (c >= '0' && c <= '9'); }

static int CountAliveTanks()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;
        if (GetClientTeam(i) != TEAM_INFECTED) continue;
        if (!IsPlayerAlive(i)) continue;
        if (L4D2_GetPlayerZombieClass(i) != ZCLASS_TANK) continue;
        n++;
    }
    return n;
}

static bool IsCurrentMapName(const char[] want)
{
    char map[64]; GetCurrentMap(map, sizeof map);
    for (int i=0; map[i]; i++) map[i] = CharToLower(map[i]);
    return StrEqual(map, want, false);
}

static float GetEffectiveMinTankPct()
{
    float base = gC_MinPct.FloatValue;
    if (IsCurrentMapName("c1m1_hotel"))
    {
        float req = (gC_C1M1MinFlowPct != null) ? gC_C1M1MinFlowPct.FloatValue : 0.0;
        if (req < 0.0) req = 0.0;
        if (req > 100.0) req = 100.0;
        if (req > base) base = req;
    }
    return base;
}

static void EnforceWanderCvarForPhase(int phase)
{
    ConVar cv = FindConVar("witch_force_wander");
    if (cv == null) return;

    int flags = GetConVarFlags(cv);
    SetConVarFlags(cv, flags & ~FCVAR_NOTIFY);

    // Persistently force ON on CSV-marked maps
    if (IsMapWanderPersistCSV())
    {
        SetConVarInt(cv, 1);
    }
    else
    {
        if (phase == PHASE_5 || phase == PHASE_FROZEN5) SetConVarInt(cv, 1);
        else SetConVarInt(cv, 0);
    }

    SetConVarFlags(cv, flags);
}

static float GetMapFlowMax()
{
    float f = L4D2Direct_GetMapMaxFlowDistance();
    if (f <= 0.0) f = 10000.0;
    return f;
}

static float GetFarthestFlowPct()
{
    float maxFlow = (g_MapFlowMax > 0.0) ? g_MapFlowMax : GetMapFlowMax();
    float best = 0.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        float f = L4D2Direct_GetFlowDistance(i);
        if (f > best) best = f;
    }
    if (maxFlow <= 1.0) return 0.0;
    float pct = 100.0 * (best / maxFlow);
    if (pct < 0.0) pct = 0.0;
    if (pct > 100.0) pct = 100.0;
    return pct;
}

/* ===== Finale allowlist ===== */
static void ParseFinaleAllowCSV()
{
    g_FinalAllowCount = 0;
    char s[256]; gC_FinaleAllowCSV.GetString(s, sizeof s);
    if (!s[0]) return;
    char parts[K_FINAL_ALLOW][64];
    int count = ExplodeString(s, ",", parts, K_FINAL_ALLOW, 64, true);
    for (int i = 0; i < count; i++)
    {
        strcopy(g_FinalAllow[g_FinalAllowCount], 64, parts[i]);
        for (int k = 0; g_FinalAllow[g_FinalAllowCount][k]; k++)
            g_FinalAllow[g_FinalAllowCount][k] = CharToLower(g_FinalAllow[g_FinalAllowCount][k]);
        g_FinalAllowCount++;
    }
}

static bool IsMapAllowedByFinaleCSV()
{
    if (g_FinalAllowCount <= 0) return false;
    char map[64]; GetCurrentMap(map, sizeof map);
    for (int k = 0; map[k]; k++) map[k] = CharToLower(map[k]);
    for (int i = 0; i < g_FinalAllowCount; i++)
        if (StrEqual(map, g_FinalAllow[i], false)) return true;
    return false;
}

static void ParseFrozen5MapsCSV()
{
    g_Frozen5AllowCount = 0;
    if (gC_Frozen5MapsCsv == null) return;

    char s[512];
    gC_Frozen5MapsCsv.GetString(s, sizeof s);
    if (!s[0]) return;

    char parts[K_FINAL_ALLOW][64];
    int count = ExplodeString(s, ",", parts, K_FINAL_ALLOW, 64, true);
    for (int i = 0; i < count && g_Frozen5AllowCount < K_FINAL_ALLOW; i++)
    {
        char tok[64];
        strcopy(tok, sizeof tok, parts[i]);
        TrimString(tok);
        for (int k = 0; tok[k]; k++)
            tok[k] = CharToLower(tok[k]);
        if (!tok[0]) continue;
        strcopy(g_Frozen5Allow[g_Frozen5AllowCount++], 64, tok);
    }
}

static bool IsMapFrozen5CSV()
{
    if (g_Frozen5AllowCount <= 0) return false;
    char map[64];
    GetCurrentMap(map, sizeof map);
    for (int k = 0; map[k]; k++)
        map[k] = CharToLower(map[k]);
    for (int i = 0; i < g_Frozen5AllowCount; i++)
        if (StrEqual(map, g_Frozen5Allow[i], false))
            return true;
    return false;
}

static void ParseWanderPersistCSV()
{
    g_WanderPersistCount = 0;
    if (gC_WanderPersistCsv == null) return;

    char s[512];
    gC_WanderPersistCsv.GetString(s, sizeof s);
    if (!s[0]) return;

    char parts[K_FINAL_ALLOW][64];
    int count = ExplodeString(s, ",", parts, K_FINAL_ALLOW, 64, true);
    for (int i = 0; i < count && g_WanderPersistCount < K_FINAL_ALLOW; i++)
    {
        char tok[64];
        strcopy(tok, sizeof tok, parts[i]);
        TrimString(tok);
        for (int k = 0; tok[k]; k++) tok[k] = CharToLower(tok[k]);
        if (!tok[0]) continue;
        strcopy(g_WanderPersistAllow[g_WanderPersistCount++], 64, tok);
    }
}

static bool IsMapWanderPersistCSV()
{
    if (g_WanderPersistCount <= 0) return false;
    char map[64]; GetCurrentMap(map, sizeof map);
    for (int k = 0; map[k]; k++) map[k] = CharToLower(map[k]);
    for (int i = 0; i < g_WanderPersistCount; i++)
        if (StrEqual(map, g_WanderPersistAllow[i], false))
            return true;
    return false;
}

static void ParseWitchBlockCSV()
{
    g_WitchBlockCount = 0;
    if (gC_WitchBlockMapsCsv == null)
        return;

    char s[512];
    gC_WitchBlockMapsCsv.GetString(s, sizeof s);
    if (!s[0])
        return;

    char parts[K_FINAL_ALLOW][64];
    int count = ExplodeString(s, ",", parts, K_FINAL_ALLOW, 64, true);

    for (int i = 0; i < count && g_WitchBlockCount < K_FINAL_ALLOW; i++)
    {
        char tok[64];
        strcopy(tok, sizeof tok, parts[i]);
        TrimString(tok);

        for (int k = 0; tok[k]; k++)
            tok[k] = CharToLower(tok[k]);

        if (!tok[0])
            continue;

        strcopy(g_WitchBlockAllow[g_WitchBlockCount++], 64, tok);
    }
}

static bool IsMapWitchBlockedCSV()
{
    if (g_WitchBlockCount <= 0)
        return false;

    char map[64];
    GetCurrentMap(map, sizeof map);
    for (int k = 0; map[k]; k++)
        map[k] = CharToLower(map[k]);

    for (int i = 0; i < g_WitchBlockCount; i++)
    {
        if (StrEqual(map, g_WitchBlockAllow[i], false))
            return true;
    }
    return false;
}

static void ParseTankBlockCSV()
{
    g_TankBlockCount = 0;
    if (gC_TankBlockMapsCsv == null)
        return;

    char s[512];
    gC_TankBlockMapsCsv.GetString(s, sizeof s);
    if (!s[0])
        return;

    char parts[K_FINAL_ALLOW][64];
    int count = ExplodeString(s, ",", parts, K_FINAL_ALLOW, 64, true);

    for (int i = 0; i < count && g_TankBlockCount < K_FINAL_ALLOW; i++)
    {
        char tok[64];
        strcopy(tok, sizeof tok, parts[i]);
        TrimString(tok);

        for (int k = 0; tok[k]; k++)
            tok[k] = CharToLower(tok[k]);

        if (!tok[0])
            continue;

        strcopy(g_TankBlockAllow[g_TankBlockCount++], 64, tok);
    }
}

static bool IsMapTankBlockedCSV()
{
    if (g_TankBlockCount <= 0)
        return false;

    char map[64];
    GetCurrentMap(map, sizeof map);
    for (int k = 0; map[k]; k++)
        map[k] = CharToLower(map[k]);

    for (int i = 0; i < g_TankBlockCount; i++)
    {
        if (StrEqual(map, g_TankBlockAllow[i], false))
            return true;
    }
    return false;
}

static void UpdateFinaleState()
{
    g_IsFinale = false;

    // 1) Entity-based detection (robust for customs)
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "trigger_finale")) != -1) { g_IsFinale = true; return; }

    // 2) Name-based fallbacks (existing + extras)
    char map[64]; GetCurrentMap(map, sizeof map);
    char lower[64]; strcopy(lower, sizeof lower, map);
    for (int i=0; lower[i]; i++) lower[i] = CharToLower(lower[i]);

    if (StrContains(lower, "finale", false) != -1) { g_IsFinale = true; return; }
    if (StrContains(lower, "_final", false) != -1) { g_IsFinale = true; return; }
    if (StrContains(lower, "_end",   false) != -1) { g_IsFinale = true; return; }

    // Keep “m5” pattern as last fallback
    int len = strlen(lower);
    for (int i=0; i+1 < len; i++)
        if (lower[i] == 'm' && lower[i+1] == '5') { g_IsFinale = true; return; }
}

/* ===== Score init ===== */

static bool BDIsVersusMode()
{
    if (gC_MPGameMode == null) return false;
    char mode[64];
    gC_MPGameMode.GetString(mode, sizeof mode);
    return (StrContains(mode, "versus", false) != -1) || (StrContains(mode, "scavenge", false) != -1);
}

static void InitOrPersistScoreForCampaign()
{
    char mapname[64];
    GetCurrentMap(mapname, sizeof mapname);
    char campaign[32] = "";
    int len = strlen(mapname);
    for (int i = 0; i < len; i++)
    {
        if (mapname[i] == 'm' && i + 1 < len && IsDigit(mapname[i + 1]))
        {
            int copyLen = (i < (sizeof campaign - 1)) ? i : (sizeof campaign - 1);
            for (int j = 0; j < copyLen; j++) campaign[j] = mapname[j];
            campaign[copyLen] = '\0';
            break;
        }
    }
    if (!campaign[0]) strcopy(campaign, sizeof campaign, mapname);
    bool firstLoad = (g_LastCampaign[0] == '\0');
    bool changed = !firstLoad && !StrEqual(campaign, g_LastCampaign);
    bool doReset = (BDIsVersusMode() && gC_VersusForceReset.BoolValue) || firstLoad || (changed && gC_ResetScoreOnCampaign.BoolValue);

// Drop P5 lock on first load/campaign change only if enabled
if ((BDIsVersusMode() && gC_VersusForceReset.BoolValue) || ((firstLoad || changed) && gC_P5UnlockOnCampaign.BoolValue))
{
    g_Phase5Lock = false;
    g_LastPhase = PHASE_1;
    g_LockBaselineScore = 0.0;
}
if (doReset)
    {
        float startScore = 0.0;
        if (BDIsVersusMode())
        {
            startScore = gC_VersusBaseline.FloatValue;
        }
        else
        {
            char diff[32];
            FindConVar("z_difficulty").GetString(diff, sizeof diff);
            startScore = gC_StartExp.FloatValue;
            if (StrEqual(diff, "Easy", false)) startScore = gC_StartEasy.FloatValue;
            else if (StrEqual(diff, "Normal", false)) startScore = gC_StartNorm.FloatValue;
            else if (StrEqual(diff, "Advanced", false)) startScore = gC_StartAdv.FloatValue;
            else if (StrEqual(diff, "Expert", false) || StrEqual(diff, "Impossible", false)) startScore = gC_StartExp.FloatValue;
        }
        g_Score = startScore;
    }
strcopy(g_LastCampaign, sizeof g_LastCampaign, campaign);
float floorS = gC_ScoreMin.FloatValue;
if (g_Score < floorS) g_Score = floorS;
g_TokensAwarded = RoundToFloor(g_Score / 100.0);
if (g_TokensAwarded < 0) g_TokensAwarded = 0;
g_TokensConsumed = 0;
}


// HELPER FUNCTION
static void ResetCycleToPhase1()
{
    float startScore = 0.0;
    if (BDIsVersusMode())
    {
        startScore = gC_VersusBaseline.FloatValue;
    }
    else
    {
        char diff[32];
        FindConVar("z_difficulty").GetString(diff, sizeof diff);
        float startScore = gC_StartExp.FloatValue;
        if (StrEqual(diff, "Easy", false)) startScore = gC_StartEasy.FloatValue;
        else if (StrEqual(diff, "Normal", false)) startScore = gC_StartNorm.FloatValue;
        else if (StrEqual(diff, "Advanced", false)) startScore = gC_StartAdv.FloatValue;
        else if (StrEqual(diff, "Expert", false) || StrEqual(diff, "Impossible", false)) startScore = gC_StartExp.FloatValue;
    }
    g_Score = startScore;
    float floorS = gC_ScoreMin.FloatValue;
    if (g_Score < floorS) g_Score = floorS;

    g_TokensAwarded = RoundToFloor(g_Score / 100.0);
    if (g_TokensAwarded < 0) g_TokensAwarded = 0;
    g_TokensConsumed = 0;

    g_Phase5Lock = false;
    g_LastPhase = PHASE_1;
}

/* ===== Checkpoints ===== */
static void ResetCheckpointsState()
{
    for (int i = 0; i < K_MAX_CHECKS; i++) g_QAwarded[i] = false;
    g_QDamage = 0.0;
    g_QLastAwardedPct = 0.0;
}

static void BD_SortCheckpointsAsc()
{
    for (int i = 1; i < g_QCount; i++)
    {
        float key = g_QPerc[i];
        int j = i - 1;
        while (j >= 0 && g_QPerc[j] > key)
        {
            g_QPerc[j + 1] = g_QPerc[j];
            j--;
        }
        g_QPerc[j + 1] = key;
    }
}

static float GetLastAwardedPct()
{
    float last = 0.0;
    for (int i = 0; i < g_QCount; i++)
        if (g_QAwarded[i] && g_QPerc[i] > last)
            last = g_QPerc[i];
    return last;
}

static void PreMarkAwardedUpTo(float pct)
{
    for (int i = 0; i < g_QCount; i++)
        if (g_QPerc[i] <= pct)
            g_QAwarded[i] = true;
}

static void ParseCheckpointsCSV()
{
    g_QCount = 0;
    char s[128];
    gC_QCheckCSV.GetString(s, sizeof s);
    if (!s[0]) return;
    char parts[K_MAX_CHECKS][16];
    g_QCount = ExplodeString(s, ",", parts, K_MAX_CHECKS, 16, true);

    int w = 0;
    for (int i = 0; i < g_QCount; i++)
    {
        float v = StringToFloat(parts[i]);
        if (v >= 0.0 && v <= 100.0) g_QPerc[w++] = v;
    }
    g_QCount = w;

    if (g_QCount <= 0) return;
    BD_SortCheckpointsAsc();
    w = 0;
    for (int i = 0; i < g_QCount; i++)
        if (i == 0 || FloatAbs(g_QPerc[i] - g_QPerc[i - 1]) > 0.01)
            g_QPerc[w++] = g_QPerc[i];
    g_QCount = w;
    for (int i = 0; i < g_QCount; i++) g_QAwarded[i] = false;
}

static void AwardHealthToScore()
{
    float total = 0.0;
    bool includeTemp = gC_IncludeTemp.BoolValue;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        int hp = GetClientHealth(i);
        float eff = float(hp);
        if (includeTemp)
        {
            float buf = GetEntPropFloat(i, Prop_Send, "m_healthBuffer");
            if (buf > 0.0) eff += buf;
        }
        if (eff < 0.0) eff = 0.0;
        total += eff;
    }
    float baseGain = 0.0;
    if (gC_QHealthMode.IntValue == 1) baseGain = total * gC_QHealthMul.FloatValue;
    else
    {
        float per = gC_QHealthPer.FloatValue;
        if (per > 0.0) baseGain = total / per;
    }
    float penalty = g_QDamage * gC_QDmgPenaltyMul.FloatValue;
    float add = baseGain - penalty;
    if (add < 0.0) add = 0.0;
    g_Score += add;
    float floorS = gC_ScoreMin.FloatValue;
    if (g_Phase5Lock)
{
    float lockFloor = gC_LockRatchetEnable.BoolValue ? g_LockBaselineScore : gC_P5LockFloor.FloatValue;
    if (floorS < lockFloor) floorS = lockFloor;
}
if (g_Score < floorS) g_Score = floorS;
    g_QDamage = 0.0;
    g_QLastAwardedPct = GetLastAwardedPct();
}

static void AwardUpToPct(float curPct)
{
    if (g_QCount <= 0) return;
    if (g_IsFinale && gC_FinaleNoGain.BoolValue && !IsMapAllowedByFinaleCSV())
        return;

    bool any = false;
    for (int i = 0; i < g_QCount; i++)
    {
        if (g_QAwarded[i]) continue;
        float target = g_QPerc[i];
        if (curPct + 0.1 < target) continue;
        AwardHealthToScore();
        g_QAwarded[i] = true;
        any = true;
    }
    if (any) g_QLastAwardedPct = GetLastAwardedPct();
}

/* ===== Damage -> Score ===== */
public Action OnTakeDamageHook(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_bEnabled) return Plugin_Continue;
    if (damage <= 0.0) return Plugin_Continue;
    if (!IsValidClient(victim)) return Plugin_Continue;
    if (GetClientTeam(victim) != TEAM_SURVIVOR) return Plugin_Continue;

    bool incapped = (GetEntProp(victim, Prop_Send, "m_isIncapacitated") != 0);
    if (incapped) return Plugin_Continue;

    bool friendly = (IsValidClient(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR && attacker != victim);
    if (!friendly)
    {
        g_QDamage += damage;
        float delta = 0.0;
        if (gC_DmgMode.IntValue == 1) { float mul = gC_DmgMul.FloatValue; if (mul > 0.0) delta = damage * mul; }
        else { float div = gC_DmgPerPt.FloatValue; if (div > 0.0) delta = damage / div; }
if (delta > 0.0)
{
    g_Score -= delta;
    float floorS = gC_ScoreMin.FloatValue;
    if (g_Phase5Lock)
    {
        float lockFloor = gC_LockRatchetEnable.BoolValue ? g_LockBaselineScore : gC_P5LockFloor.FloatValue;
        if (floorS < lockFloor) floorS = lockFloor;
    }
    if (g_Score < floorS) g_Score = floorS;
}

    }
    return Plugin_Continue;
}

/* ===== Moon Phase engine ===== */
static int GetAscendingPhaseFromScore(float s)
{
    float p2 = gC_Ph2Score.FloatValue, p3 = gC_Ph3Score.FloatValue, p4 = gC_Ph4Score.FloatValue, p5 = gC_Ph5Score.FloatValue;
    if (s >= p5) return PHASE_5;
    if (s >= p4) return PHASE_4;
    if (s >= p3) return PHASE_3;
    if (s >= p2) return PHASE_2;
    return PHASE_1;
}

static int ResolveMoonPhase(float s)
{
    float p2 = gC_Ph2Score.FloatValue;
    float p3 = gC_Ph3Score.FloatValue;
    float p4 = gC_Ph4Score.FloatValue;
    float p5 = gC_Ph5Score.FloatValue;

    // Frozen-5 CSV maps
    if (IsMapFrozen5CSV())
    {
        float step = 150.0;

        if (!g_Phase5Lock && s >= p5)
        {
            // Only lock if _p5_lock_enable is 1
            if (!gC_P5LockEnable.BoolValue) return (g_LastPhase = GetAscendingPhaseFromScore(s));

            g_Phase5Lock = true;
            g_LockBaselineScore = p5;
            if (g_Score < g_LockBaselineScore) g_Score = g_LockBaselineScore;
            s = g_Score;
        }

        if (g_Phase5Lock && gC_LockRatchetEnable.BoolValue)
        {
            int extra = RoundToFloor((s - p5) / step);
            if (extra < 0) extra = 0;
            if (extra > 3) extra = 3;
            float newFloor = p5 + float(extra) * step;
            if (newFloor > g_LockBaselineScore) g_LockBaselineScore = newFloor;
            if (g_Score < g_LockBaselineScore) { g_Score = g_LockBaselineScore; s = g_Score; }
        }

        if (gC_Frozen5WrapMode.IntValue != 0)
        {
            int extra = RoundToFloor((s - p5) / step);
            if (extra >= 4)
            {
                if (gC_Frozen5WrapMode.IntValue == 1)
                {
                    ResetCycleToPhase1();
                }
                else
                {
                    g_Score = 0.0;
                    int ta = RoundToFloor(g_Score / 100.0);
                    if (ta < 0) ta = 0;
                    g_TokensAwarded = ta;
                    g_TokensConsumed = 0;
                    g_Phase5Lock = false;
                    g_LockBaselineScore = 0.0;
                }
                s = g_Score;
            }
        }

        if (g_Phase5Lock)
        {
            float minFloor = gC_LockRatchetEnable.BoolValue ? g_LockBaselineScore : p5;
            if (g_Score < minFloor) { g_Score = minFloor; s = g_Score; }
        }

        g_LastPhase = PHASE_FROZEN5;
        return PHASE_FROZEN5;
    }

    // Non-CSV maps
    if (!g_Phase5Lock)
    {
        if (s < p2)  return (g_LastPhase = PHASE_1);
        if (s < p3)  return (g_LastPhase = PHASE_2);
        if (s < p4)  return (g_LastPhase = PHASE_3);
        if (s < p5)  return (g_LastPhase = PHASE_4);

        // Only lock if _p5_lock_enable is 1
        if (!gC_P5LockEnable.BoolValue) return (g_LastPhase = GetAscendingPhaseFromScore(s));

        g_Phase5Lock = true;
        g_LockBaselineScore = p5;
        if (g_Score < gC_P5LockFloor.FloatValue) g_Score = gC_P5LockFloor.FloatValue;
        s = g_Score;
    }

    float step = 150.0;
    int extra = RoundToFloor((s - p5) / step);
    if (extra < 0) extra = 0;

    if (g_Phase5Lock && gC_LockRatchetEnable.BoolValue)
    {
        int clampedExtra = extra;
        if (clampedExtra > 3) clampedExtra = 3;
        float newFloor = p5 + float(clampedExtra) * step;
        if (newFloor > g_LockBaselineScore) g_LockBaselineScore = newFloor;
        if (g_Score < g_LockBaselineScore) { g_Score = g_LockBaselineScore; s = g_Score; }
    }

    static const int cycle[4] = { PHASE_5, PHASE_6, PHASE_7, PHASE_8 };

    if (extra >= 4)
    {
        ResetCycleToPhase1();
        return PHASE_1;
    }

    int phase = cycle[extra];
    g_LastPhase = phase;
    return phase;
}

/* ===== Witch placement and spawn ===== */
static bool FindWitchSpawnPosBoss(float pos[3])
{
    const int MAXC = 64;
    int refs[MAXC]; int rn = 0;

    int top = 0; float best = -1.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        float f = L4D2Direct_GetFlowDistance(i);
        if (f > best) { best = f; top = i; }
    }
    if (top > 0) refs[rn++] = top;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i) && i != top && rn < MAXC)
            refs[rn++] = i;

    for (int r = 0; r < rn; r++)
    {
        int s = refs[r];
        if (L4D_GetRandomPZSpawnPosition(s, ZCLASS_WITCH, 10, pos)) return true;
        if (L4D_GetRandomPZSpawnPosition(s, PZCLASS_WITCHSEARCH, 10, pos)) return true;
        if (L4D_GetRandomPZSpawnPosition(s, PZCLASS_FALLBACK, 10, pos)) return true;

        float base[3]; GetClientAbsOrigin(s, base);
        for (int k = 0; k < 12; k++)
        {
            float ang = GetRandomFloat(0.0, 6.2831853);
            float rad = GetRandomFloat(400.0, 900.0);
            float cand[3];
            cand[0] = base[0] + Cosine(ang) * rad;
            cand[1] = base[1] + Sine(ang) * rad;
            cand[2] = base[2] + 64.0;
            float ground[3];
            if (!TraceToGround(cand, ground)) continue;
            if (!HullClearAt(ground)) continue;
            pos[0] = ground[0]; pos[1] = ground[1]; pos[2] = ground[2];
            return true;
        }
    }
    return false;
}

static int SpawnOneWitchAt(const float pos[3])
{
    bool manageNoBosses = (gC_DirectorNoBosses != null && gC_DirectorNoBosses.BoolValue);
    bool savedNoBosses = false;
    if (manageNoBosses && gC_NoBosses != null)
    {
        savedNoBosses = gC_NoBosses.BoolValue;
        if (savedNoBosses) gC_NoBosses.SetBool(false);
    }
    int ent = L4D2_SpawnWitch(pos, NULL_VECTOR);
    if (manageNoBosses && gC_NoBosses != null && savedNoBosses)
        gC_NoBosses.SetBool(true);
    return ent;
}

/* ===== Witch planners ===== */
static void ResetWitchPlans()
{
    g_WitchPlanCount = 0;
    for (int i = 0; i < K_MAX_WITCH_PLANS; i++)
    {
        g_WitchPlanPct[i] = 0.0;
        g_WitchPlanExecuted[i] = false;
        g_WitchPlanCanceled[i] = false;
        g_WitchPlanType[i] = 0;
        g_WitchPlanSize[i] = 1;
    }
}

static void MakeRandomSlicesAhead(float curPct, int count, float minGap, float outPcts[12], int maxOut, float rangeLo, float rangeHi)
{
    if (count > maxOut) count = maxOut;
    int got = 0;
    int tries = 128;
    while (got < count && tries-- > 0)
    {
        float base = curPct + 0.8; if (base < rangeLo) base = rangeLo;
        float cand = base + GetRandomFloat(0.0, 1.0) * (rangeHi - base);
        bool ok = true;
        for (int i = 0; i < got; i++)
            if (FloatAbs(outPcts[i] - cand) < minGap) { ok = false; break; }
        if (!ok) continue;
        outPcts[got++] = cand;
    }
    for (int i = got; i < count; i++) outPcts[i] = (got > 0) ? outPcts[got - 1] : (curPct + 1.0);
}

static void CountActiveWitchPlans(int &nNormal, int &nWander, int &nCluster)
{
    nNormal = nWander = nCluster = 0;
    for (int i = 0; i < g_WitchPlanCount; i++)
    {
        if (g_WitchPlanExecuted[i] || g_WitchPlanCanceled[i]) continue;
        if (g_WitchPlanType[i] == 0) nNormal++;
        else if (g_WitchPlanType[i] == 2) nWander++;
        else if (g_WitchPlanType[i] == 1) nCluster++;
    }
}

static void ReconcileMoonPhaseWitchPlans(float curPct)
{
    if (!gC_WitchEnable.BoolValue)
    {
        ResetWitchPlans();
        return;
    }

    // Hard block: never plan witches on maps in _witch_block_maps_csv
    if (IsMapWitchBlockedCSV())
    {
        ResetWitchPlans();
        return;
    }

    int phase = ResolveMoonPhase(g_Score);

    // === Phase 4/3 Wanderer Logic ===
    ConVar cvWander = FindConVar("witch_force_wander");
    if (cvWander != null)
    {
        if (IsMapWanderPersistCSV())
        {
            // Always force ON and treat as locked for this map
            int flags = GetConVarFlags(cvWander);
            SetConVarFlags(cvWander, flags & ~FCVAR_NOTIFY);
            if (cvWander.IntValue != 1) SetConVarInt(cvWander, 1);
            SetConVarFlags(cvWander, flags);

            g_bIsWanderModeLocked = true;
        }
        else
        {
            // If we enter Phase 4 with 2+ witches, OR the 2nd witch spawns during phase 4, lock wander ON.
            if (phase == PHASE_4 && g_WitchesSpawnedTotal >= 2 && !g_bIsWanderModeLocked)
            {
                g_bIsWanderModeLocked = true;
                int flags = GetConVarFlags(cvWander);
                SetConVarFlags(cvWander, flags & ~FCVAR_NOTIFY);
                SetConVarInt(cvWander, 1);
                SetConVarFlags(cvWander, flags);
                if (gC_WitchLog.BoolValue)
                    LogAction(-1, -1, "[WITCH][PHASE-LOGIC] Wander mode locked ON (Phase 4, spawned=%d).", g_WitchesSpawnedTotal);
            }
            // If we drop down to Phase 3, unlock and turn wander OFF.
            else if (phase == PHASE_3 && g_iLastWitchPhase > phase && g_bIsWanderModeLocked)
            {
                g_bIsWanderModeLocked = false;
                int flags = GetConVarFlags(cvWander);
                SetConVarFlags(cvWander, flags & ~FCVAR_NOTIFY);
                SetConVarInt(cvWander, 0);
                SetConVarFlags(cvWander, flags);
                if (gC_WitchLog.BoolValue)
                    LogAction(-1, -1, "[WITCH][PHASE-LOGIC] Wander mode unlocked and reset (Phase 3).");
            }
        }
    }
    g_iLastWitchPhase = phase;
    // === End Phase Logic ===

    // GLOBAL BUDGET CHECK: if we've already met or exceeded the phase cap, cancel all pending plans
    int phaseCap = 0;
    if (phase == PHASE_2 || phase == PHASE_8) phaseCap = gC_Ph2TotalCap.IntValue;
    else if (phase == PHASE_3 || phase == PHASE_7) phaseCap = gC_Ph3ClusterCap.IntValue;
    else if (phase == PHASE_4 || phase == PHASE_6) phaseCap = gC_Ph4TotalCap.IntValue;
    else if (phase == PHASE_5 || phase == PHASE_FROZEN5) phaseCap = gC_Ph5TotalCap.IntValue;

    if (g_WitchesSpawnedTotal >= phaseCap)
    {
        for (int i = 0; i < g_WitchPlanCount; i++)
            if (!g_WitchPlanExecuted[i]) g_WitchPlanCanceled[i] = true;
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC] Early exit: phase=%d spawned=%d phaseCap=%d (budget_exceeded)", phase, g_WitchesSpawnedTotal, phaseCap);
        return;
    }

    int curN, curW, curC;
    CountActiveWitchPlans(curN, curW, curC);
    int remainingTotal = phaseCap - g_WitchesSpawnedTotal;
    if (remainingTotal <= 0)
    {
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC] Early exit: phase=%d remainingTotal=%d (no_budget)", phase, remainingTotal);
        return;
    }

    if (gC_WitchLog.BoolValue)
    {
        LogAction(-1, -1, "[WITCH][REC] phase=%d score=%.1f spawned=%d phaseCap=%d remaining=%d active(N/W/C)=%d/%d/%d",
            phase, g_Score, g_WitchesSpawnedTotal, phaseCap, remainingTotal, curN, curW, curC);
    }

    // Phase-specific allowed types: 0=normal, 1=cluster, 2=wander
    if (phase == PHASE_2 || phase == PHASE_8)
    {
        // Normal only: cancel cluster and wander
        for (int i = 0; i < g_WitchPlanCount; i++)
            if (!g_WitchPlanExecuted[i] && !g_WitchPlanCanceled[i] && g_WitchPlanType[i] != 0)
                g_WitchPlanCanceled[i] = true;
    }
    else if (phase == PHASE_3 || phase == PHASE_7)
    {
        // Cluster only: cancel normal and wander
        for (int i = 0; i < g_WitchPlanCount; i++)
            if (!g_WitchPlanExecuted[i] && !g_WitchPlanCanceled[i] && g_WitchPlanType[i] != 1)
                g_WitchPlanCanceled[i] = true;
    }
    else if (phase == PHASE_4 || phase == PHASE_6)
    {
        // Normal + Wander only: cancel cluster
        for (int i = 0; i < g_WitchPlanCount; i++)
            if (!g_WitchPlanExecuted[i] && !g_WitchPlanCanceled[i] && g_WitchPlanType[i] == 1)
                g_WitchPlanCanceled[i] = true;
    }
else if (phase == PHASE_5 || phase == PHASE_FROZEN5)
{
    // Wander only: cancel normal and cluster
    for (int i = 0; i < g_WitchPlanCount; i++)
        if (!g_WitchPlanExecuted[i] && !g_WitchPlanCanceled[i] && g_WitchPlanType[i] != 2)
            g_WitchPlanCanceled[i] = true;
}

    int planNormal = 0, planWander = 0, planCluster = 0, clusterSize = 0;
    float minGap = 6.0;

    if (phase == PHASE_1)
    {
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC-P1] no_witches");
        return;
    }
    else if (phase == PHASE_2 || phase == PHASE_8)
    {
        planNormal = remainingTotal - curN; if (planNormal < 0) planNormal = 0;
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC-P2] planNormal=%d (remaining=%d - active=%d)", planNormal, remainingTotal, curN);
    }
    else if (phase == PHASE_3 || phase == PHASE_7)
    {
        if (remainingTotal < 2)
        {
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][REC-P3] Skip: remainingTotal=%d (need_at_least_2)", remainingTotal);
            return;
        }
        planCluster = (curC >= 1) ? 0 : 1;
        clusterSize = remainingTotal;
        if (clusterSize > gC_Ph3ClusterCap.IntValue) clusterSize = gC_Ph3ClusterCap.IntValue;
        if (clusterSize < 2) clusterSize = 2;
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC-P3] planCluster=%d clusterSize=%d (active=%d)", planCluster, clusterSize, curC);
    }
    else if (phase == PHASE_4 || phase == PHASE_6)
    {
        int capNorm = gC_Ph4NormalCap.IntValue;
        int capWander = gC_Ph4WanderCap.IntValue;
        int normalsSoFar = (g_WitchesSpawnedTotal <= capNorm) ? g_WitchesSpawnedTotal : capNorm;
        int remainingNormals = capNorm - normalsSoFar; if (remainingNormals < 0) remainingNormals = 0;
        int remainingWanders = capWander;

        if (remainingNormals + remainingWanders > remainingTotal)
        {
            int over = (remainingNormals + remainingWanders) - remainingTotal;
            if (remainingWanders >= over) remainingWanders -= over;
            else { over -= remainingWanders; remainingWanders = 0; remainingNormals = (remainingNormals > over) ? (remainingNormals - over) : 0; }
        }

        planNormal = remainingNormals - curN; if (planNormal < 0) planNormal = 0;
        planWander = remainingWanders - curW; if (planWander < 0) planWander = 0;
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC-P4] remainN=%d remainW=%d planN=%d planW=%d (active_N=%d active_W=%d)",
                remainingNormals, remainingWanders, planNormal, planWander, curN, curW);
    }
else if (phase == PHASE_5 || phase == PHASE_FROZEN5)
{
    int capWander = gC_Ph5WanderCap.IntValue;
    int capNorm = gC_Ph5NormalCap.IntValue;
    int remainingWanders = capWander;
    int remainingNormals = capNorm;

    if (remainingWanders + remainingNormals > remainingTotal)
    {
        int over = (remainingWanders + remainingNormals) - remainingTotal;
        if (remainingNormals >= over) remainingNormals -= over;
        else { over -= remainingNormals; remainingNormals = 0; remainingWanders = (remainingWanders > over) ? (remainingWanders - over) : 0; }
    }

    planWander = remainingWanders - curW; if (planWander < 0) planWander = 0;
    planNormal = remainingNormals - curN; if (planNormal < 0) planNormal = 0;
    if (gC_WitchLog.BoolValue)
        LogAction(-1, -1, "[WITCH][REC-P5/F5] phase=%d remainN=%d remainW=%d planN=%d planW=%d (active_N=%d active_W=%d)",
            phase, remainingNormals, remainingWanders, planNormal, planWander, curN, curW);
}

    float cur = curPct;
    float maxRangeHi = 98.0;

    if (planNormal > 0)
    {
        float pcts[12];
        MakeRandomSlicesAhead(cur, planNormal, minGap, pcts, 12, cur + 0.8, maxRangeHi);
        for (int i = 0; i < planNormal && g_WitchPlanCount < K_MAX_WITCH_PLANS; i++)
        {
            int idx = g_WitchPlanCount++;
            g_WitchPlanPct[idx] = pcts[i];
            g_WitchPlanExecuted[idx] = false;
            g_WitchPlanCanceled[idx] = false;
            g_WitchPlanType[idx] = 0;
            g_WitchPlanSize[idx] = 1;
        }
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC] added_normal_plans=%d", planNormal);
    }

    if (planWander > 0)
    {
        float pcts[12];
        MakeRandomSlicesAhead(cur, planWander, minGap, pcts, 12, cur + 0.8, maxRangeHi);
        for (int i = 0; i < planWander && g_WitchPlanCount < K_MAX_WITCH_PLANS; i++)
        {
            int idx = g_WitchPlanCount++;
            g_WitchPlanPct[idx] = pcts[i];
            g_WitchPlanExecuted[idx] = false;
            g_WitchPlanCanceled[idx] = false;
            g_WitchPlanType[idx] = 2;
            g_WitchPlanSize[idx] = 1;
        }
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC] added_wander_plans=%d", planWander);
    }

    if (planCluster > 0 && clusterSize >= 2)
    {
        float pcts[12];
        MakeRandomSlicesAhead(cur, 1, minGap, pcts, 12, cur + 0.8, maxRangeHi);
        if (g_WitchPlanCount < K_MAX_WITCH_PLANS)
        {
            int idx = g_WitchPlanCount++;
            g_WitchPlanPct[idx] = pcts[0];
            g_WitchPlanExecuted[idx] = false;
            g_WitchPlanCanceled[idx] = false;
            g_WitchPlanType[idx] = 1;
            g_WitchPlanSize[idx] = clusterSize;
        }
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][REC] added_cluster_plan size=%d", clusterSize);
    }
}

/* ===== Execute witch plan ===== */
static bool TryExecuteWitchPlan(int idx)
{
    if (idx < 0 || idx >= g_WitchPlanCount) return false;
    if (g_WitchPlanExecuted[idx] || g_WitchPlanCanceled[idx]) return false;

    // Safety: if map is now blocked, cancel this plan instead of spawning
    if (IsMapWitchBlockedCSV())
    {
        g_WitchPlanCanceled[idx] = true;
        return false;
    }

    int phase = ResolveMoonPhase(g_Score);

    // Compute phase cap and remaining budget
    int phaseCap = 0;
    if (phase == PHASE_2 || phase == PHASE_8) phaseCap = gC_Ph2TotalCap.IntValue;
    else if (phase == PHASE_3 || phase == PHASE_7) phaseCap = gC_Ph3ClusterCap.IntValue;
    else if (phase == PHASE_4 || phase == PHASE_6) phaseCap = gC_Ph4TotalCap.IntValue;
    else if (phase == PHASE_5 || phase == PHASE_FROZEN5) phaseCap = gC_Ph5TotalCap.IntValue;

    int remaining = phaseCap - g_WitchesSpawnedTotal;
    if (gC_WitchLog.BoolValue)
    LogAction(-1, -1, "[WITCH][EXEC] phase=%d type=%d phaseCap=%d spawned=%d remaining=%d",
    phase, g_WitchPlanType[idx], phaseCap, g_WitchesSpawnedTotal, remaining);
    if (remaining <= 0) { g_WitchPlanCanceled[idx] = true; return false; }

    ConVar cvWander = FindConVar("witch_force_wander");
    bool persistentWander = IsMapWanderPersistCSV();
    int flagsSaved = (cvWander != null) ? GetConVarFlags(cvWander) : 0;
    int valSaved   = (cvWander != null) ? cvWander.IntValue : 0;
    bool forceRestorePrev = false;

    // If persistent, pre-force ON and never restore
    if (persistentWander && cvWander != null)
    {
        SetConVarFlags(cvWander, flagsSaved & ~FCVAR_NOTIFY);
        if (cvWander.IntValue != 1) SetConVarInt(cvWander, 1);
        SetConVarFlags(cvWander, flagsSaved);
    }

    if ((phase == PHASE_5 || phase == PHASE_FROZEN5) && cvWander != null)
    {
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][PHASE5-SETUP] cvWander_current=%d setting_to=1", valSaved);
        if (valSaved != 1)
        {
            SetConVarFlags(cvWander, flagsSaved & ~FCVAR_NOTIFY);
            SetConVarInt(cvWander, 1);
            SetConVarFlags(cvWander, flagsSaved);
        }
    }

    // Phase 3/7 must be cluster only
    if ((phase == PHASE_3 || phase == PHASE_7) && g_WitchPlanType[idx] != 1)
    {
        g_WitchPlanCanceled[idx] = true;
        return false;
    }

    // Block wrong types for current phase
    bool allow = false;
    if (phase == PHASE_2 || phase == PHASE_8) allow = (g_WitchPlanType[idx] == 0);
    else if (phase == PHASE_3 || phase == PHASE_7) allow = (g_WitchPlanType[idx] == 1);
    else if (phase == PHASE_4 || phase == PHASE_6) allow = (g_WitchPlanType[idx] == 0 || g_WitchPlanType[idx] == 2);
    else if (phase == PHASE_5 || phase == PHASE_FROZEN5) allow = (g_WitchPlanType[idx] == 2);

    if (!allow)
    {
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][EXEC-CANCEL] reason: wrong_type_for_phase");
        g_WitchPlanCanceled[idx] = true;
        return false;
    }

    int t = g_WitchPlanType[idx];
    int want = g_WitchPlanSize[idx];
    if (want < 1) want = 1;

    if (t == 1) // cluster
    {
        want = (want > remaining) ? remaining : want;
        if (want <= 0) { g_WitchPlanCanceled[idx] = true; return false; }
        if (want > WITCH_MAX_CLUSTER) want = WITCH_MAX_CLUSTER;
        float anchor[3], positions[WITCH_MAX_CLUSTER][3];
        bool success = false;

        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][CLUSTER-START] attempting_cluster want=%d tries=12", want);

        for (int attempt = 0; attempt < WITCH_CLUSTER_TRIES && !success; attempt++)
        {
            if (!FindWitchSpawnPosBoss(anchor)) continue;
            positions[0][0] = anchor[0]; positions[0][1] = anchor[1]; positions[0][2] = anchor[2];

            if (gC_WitchLog.BoolValue && attempt == 0)
                LogAction(-1, -1, "[WITCH][CLUSTER-ANCHOR] anchor_pos=(%.0f,%.0f,%.0f)", anchor[0], anchor[1], anchor[2]);

            int got = 1;
            float closeDist = gC_WitchSpawnCloseDist.FloatValue;
            float minMemberDist = gC_WitchClusterMinMemberDist.FloatValue;

            for (int k = 1; k < want; k++)
            {
                bool placed = false;
                for (int tries = 0; tries < WITCH_CLUSTER_TRIES; tries++)
                {
                    float pos[3];
                    if (!FindWitchSpawnPosBoss(pos)) break;

                    float dx = pos[0] - anchor[0], dy = pos[1] - anchor[1];
                    if (dx*dx + dy*dy > closeDist*closeDist) continue;

                   // Check distance to all previously-placed members
                    bool tooClose = false;
                    for (int prev = 0; prev < k; prev++)
                    {
                        float pdx = pos[0] - positions[prev][0];
                        float pdy = pos[1] - positions[prev][1];
                        if (pdx*pdx + pdy*pdy < minMemberDist*minMemberDist)
                        {
                            tooClose = true;
                            break;
                        }
                    }

                    if (tooClose) continue;

                    positions[k][0] = pos[0]; positions[k][1] = pos[1]; positions[k][2] = pos[2];
                    placed = true;
                    break;
                }
                if (!placed) { got = -1; break; }
                got++;
            }
            success = (got == want);
        }
        if (!success)
        {
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][CLUSTER-FAIL] geometry_failed want=%d", want);
            return false;
        }

        int spawned = 0;
        for (int i = 0; i < want; i++)
        {
            int e = SpawnOneWitchAt(positions[i]);
            if (e > 0) spawned++;
        }
        if (spawned > 0)
        {
            g_WitchPlanExecuted[idx] = true;
            g_WitchesSpawnedTotal += spawned;
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][CLUSTER-SPAWN] spawned=%d total_now=%d", spawned, g_WitchesSpawnedTotal);

            // If cap is now met, cancel all remaining pending plans
            if (g_WitchesSpawnedTotal >= phaseCap)
            {
                for (int j = 0; j < g_WitchPlanCount; j++)
                    if (!g_WitchPlanExecuted[j] && !g_WitchPlanCanceled[j])
                        g_WitchPlanCanceled[j] = true;
                if (gC_WitchLog.BoolValue)
                    LogAction(-1, -1, "[WITCH][CAP-MET] canceled_remaining phase_cap_reached");
            }
            return true;
        }
        return false;
    }
    else if (t == 2) // wander
    {
        int pack = 1;
        float chance = 0.0;
        int packMax = 1;
        if (phase == PHASE_4 || phase == PHASE_6) { chance = gC_Ph4WanderPackChance.FloatValue; packMax = gC_Ph4WanderPackMax.IntValue; }
        else if (phase == PHASE_5 || phase == PHASE_FROZEN5) { chance = gC_Ph5WanderPackChance.FloatValue; packMax = gC_Ph5WanderPackMax.IntValue; }
        else { chance = gC_Ph4WanderPackChance.FloatValue; packMax = gC_Ph4WanderPackMax.IntValue; }
        if (packMax < 1) packMax = 1;
        if (GetRandomFloat(0.0, 1.0) < chance) pack = GetRandomInt(2, packMax);

        // Clamp pack to remaining budget
        if (pack > remaining) pack = remaining;
        if (pack <= 0) { g_WitchPlanCanceled[idx] = true; return false; }

        if (phase != PHASE_5 && phase != PHASE_FROZEN5 && cvWander != null)
        {
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][WANDER-SETUP] phase=%d setting_witch_force_wander_to=1", phase);
            SetConVarFlags(cvWander, flagsSaved & ~FCVAR_NOTIFY);
            SetConVarInt(cvWander, 1);
            SetConVarFlags(cvWander, flagsSaved);
            // Only restore on non-CSV maps
            forceRestorePrev = !persistentWander;
        }

        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][WANDER-BEFORE-LOOP] phase=%d pack=%d cvWander=%d",
                phase, pack, (cvWander != null) ? cvWander.IntValue : -1);

        int spawned = 0;
        for (int i = 0; i < pack; i++)
        {
            float pos[3];
            if (!FindWitchSpawnPosBoss(pos)) continue;
            int e = SpawnOneWitchAt(pos);
            if (e > 0) spawned++;
            if (gC_WitchLog.BoolValue && i == 0)
                LogAction(-1, -1, "[WITCH][WANDER-SPAWN-1] spawned_first e=%d pos=(%.0f,%.0f,%.0f)",
                    e, pos[0], pos[1], pos[2]);
        }

        if (forceRestorePrev && cvWander != null)
        {
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][WANDER-RESTORE] restoring_witch_force_wander_to=%d", valSaved);
            SetConVarFlags(cvWander, flagsSaved & ~FCVAR_NOTIFY);
            SetConVarInt(cvWander, valSaved);
            SetConVarFlags(cvWander, flagsSaved);
        }

        if (spawned > 0)
        {
            g_WitchPlanExecuted[idx] = true;
            g_WitchesSpawnedTotal += spawned;
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][WANDER-SPAWN] spawned=%d total_now=%d", spawned, g_WitchesSpawnedTotal);

            // If cap is now met, cancel all remaining pending plans
            if (g_WitchesSpawnedTotal >= phaseCap)
            {
                for (int j = 0; j < g_WitchPlanCount; j++)
                    if (!g_WitchPlanExecuted[j] && !g_WitchPlanCanceled[j])
                        g_WitchPlanCanceled[j] = true;
                if (gC_WitchLog.BoolValue)
                    LogAction(-1, -1, "[WITCH][CAP-MET] canceled_remaining phase_cap_reached");
            }
            return true;
        }
        if (gC_WitchLog.BoolValue)
            LogAction(-1, -1, "[WITCH][WANDER-FAIL] pack=%d spawned=0", pack);
        return false;
    }
    else // normal
    {
        if (remaining <= 0)
        {
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][EXEC-CANCEL] reason: no_remaining_budget");
            g_WitchPlanCanceled[idx] = true;
            return false;
        }
        float pos[3];
        if (!FindWitchSpawnPosBoss(pos))
        {
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][NORMAL-FAIL] geometry_failed");
            return false;
        }
        int e = SpawnOneWitchAt(pos);
        if (e > 0)
        {
            g_WitchPlanExecuted[idx] = true;
            g_WitchesSpawnedTotal += 1;
            if (gC_WitchLog.BoolValue)
                LogAction(-1, -1, "[WITCH][NORMAL-SPAWN] e=%d pos=(%.0f,%.0f,%.0f) total_now=%d",
                    e, pos[0], pos[1], pos[2], g_WitchesSpawnedTotal);

            // If cap is now met, cancel all remaining pending plans
            if (g_WitchesSpawnedTotal >= phaseCap)
            {
                for (int j = 0; j < g_WitchPlanCount; j++)
                    if (!g_WitchPlanExecuted[j] && !g_WitchPlanCanceled[j])
                        g_WitchPlanCanceled[j] = true;
                if (gC_WitchLog.BoolValue)
                    LogAction(-1, -1, "[WITCH][CAP-MET] canceled_remaining phase_cap_reached");
            }
            return true;
        }
        return false;
    }
}

/* ===== Crumbs geometry (shared with Tanks behind) ===== */
public bool TraceFilter_NoPlayers(int ent, int contentsMask, any data)
{
    if (ent >= 1 && ent <= MaxClients) return false;
    return true;
}

static bool TraceToGround(const float start[3], float outGround[3])
{
    float end[3]; end[0]=start[0]; end[1]=start[1]; end[2]=start[2]-3000.0;
    TR_TraceRayFilter(start, end, MASK_PLAYERSOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_NoPlayers, 0);
    if (!TR_DidHit()) return false;
    TR_GetEndPosition(outGround);
    if (TR_PointOutsideWorld(outGround)) return false;
    return true;
}

static bool HullClearAt(const float pos[3])
{
    float mins[3] = {-16.0, -16.0, 0.0};
    float maxs[3] = {16.0, 16.0, 72.0};
    float from[3]; from[0]=pos[0]; from[1]=pos[1]; from[2]=pos[2]+1.0;
    float to[3]; to[0]=from[0]; to[1]=from[1]; to[2]=from[2];
    TR_TraceHullFilter(from, to, mins, maxs, MASK_PLAYERSOLID, TraceFilter_NoPlayers, 0);
    return !TR_DidHit();
}

static float Normalize2D(float v[3])
{
    v[2] = 0.0;
    float l = SquareRoot(v[0]*v[0] + v[1]*v[1]);
    if (l < 0.0001) { v[0]=0.0; v[1]=0.0; return 0.0; }
    v[0] /= l; v[1] /= l; return l;
}

static bool GetSlowAndFar(int &slow, float slowPos[3], int &far, float farPos[3], float teamDir2D[3])
{
    float bestFarFlow = -1.0;
    float bestSlowFlow = 99999999.0; slow = 0; far = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        float f = L4D2Direct_GetFlowDistance(i);
        if (f > bestFarFlow) { bestFarFlow = f; far = i; }
        if (f < bestSlowFlow) { bestSlowFlow = f; slow = i; }
    }
    if (slow <= 0 || far <= 0) return false;
    GetClientAbsOrigin(slow, slowPos);
    GetClientAbsOrigin(far, farPos);
    teamDir2D[0]=farPos[0]-slowPos[0]; teamDir2D[1]=farPos[1]-slowPos[1]; teamDir2D[2]=0.0;
    if (Normalize2D(teamDir2D) <= 0.0) return false;
    return true;
}

static bool IsValidCrumbBehind(const float slowPos[3], const float farPos[3], const float teamDir[3], const float ground[3], const float crumb[3])
{
    float minXY = gC_MinXY.FloatValue;
    float maxZD = gC_MaxZD.FloatValue;
    float minDot = gC_MinDot.FloatValue;
    float backS = gC_MinBackSlow.FloatValue;
    float backF = gC_MinBackFar.FloatValue;
    float radius = gC_CrumbRadius.FloatValue;
    float backMax = gC_MaxBackClamp.FloatValue;

    float zd = ground[2] - slowPos[2];
    if (FloatAbs(zd) > maxZD) return false;

    float rel[3]; rel[0]=ground[0]-slowPos[0]; rel[1]=ground[1]-slowPos[1]; rel[2]=0.0;
    float relLen = Normalize2D(rel);
    if (relLen < minXY) return false;

    float dot = rel[0]*teamDir[0] + rel[1]*teamDir[1];
    if (dot > minDot) return false;

    float projSlow = (ground[0]-slowPos[0])*teamDir[0] + (ground[1]-slowPos[1])*teamDir[1];
    if (projSlow > -backS) return false;

    float projFar = (ground[0]-farPos[0])*teamDir[0] + (ground[1]-farPos[1])*teamDir[1];
    if (projFar > -backF) return false;

    if (backMax > 10.0 && projSlow < -backMax) return false;

    float dx = ground[0]-crumb[0], dy = ground[1]-crumb[1];
    float distCr = SquareRoot(dx*dx + dy*dy);
    if (distCr > radius) return false;

    return true;
}

static bool FindBehindGroundPos(float outPos[3])
{
    int slow, far; float slowPos[3], farPos[3], dir[3];
    if (!GetSlowAndFar(slow, slowPos, far, farPos, dir)) return false;

    float now = GetEngineTime();
    float maxAge = gC_CrumbAgeMax.FloatValue;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsValidSurvivor(c)) continue;
        int count = g_iCrumbCount[c];
        if (count <= 0) continue;
        int idx = g_iCrumbHead[c];
        int iter = 0;
        while (iter < count)
        {
            float age = now - g_tCrumbs[c][idx];
            if (age > 0.0 && age <= maxAge)
            {
                float cand[3]; cand[0]=g_vCrumbs[c][idx][0]; cand[1]=g_vCrumbs[c][idx][1]; cand[2]=g_vCrumbs[c][idx][2];
                float ground[3];
                if (!TraceToGround(cand, ground)) { idx = (idx - 1 + CRUMB_MAX) % CRUMB_MAX; iter++; continue; }
                if (!HullClearAt(ground)) { idx = (idx - 1 + CRUMB_MAX) % CRUMB_MAX; iter++; continue; }

                if (IsValidCrumbBehind(slowPos, farPos, dir, ground, cand))
                {
                    outPos[0]=ground[0]; outPos[1]=ground[1]; outPos[2]=ground[2];
                    return true;
                }
            }
            idx = (idx - 1 + CRUMB_MAX) % CRUMB_MAX; iter++;
        }
    }
    return false;
}

/* ===== Tanks spawn helpers ===== */
static int SpawnTankAt(const float pos[3])
{
    float ang[3] = {0.0, 0.0, 0.0};
    bool manageNoBosses = (gC_DirectorNoBosses != null && gC_DirectorNoBosses.BoolValue);
bool savedNoBosses = false;
    if (manageNoBosses && gC_NoBosses != null)
    {
        savedNoBosses = gC_NoBosses.BoolValue;
        if (savedNoBosses) gC_NoBosses.SetBool(false);
    }
    int cl = L4D2_SpawnTank(pos, ang);
    if (cl > 0) TeleportEntity(cl, pos, ang, g_VecZero);
    if (manageNoBosses && gC_NoBosses != null && savedNoBosses)
        gC_NoBosses.SetBool(true);
    return cl;
}

static bool PickFrontPos(float outPos[3])
{
    int far = 0; float best = -1.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        float f = L4D2Direct_GetFlowDistance(i);
        if (f > best) { best = f; far = i; }
    }
    if (far > 0 && L4D_GetRandomPZSpawnPosition(far, ZCLASS_TANK, 10, outPos)) return true;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        if (L4D_GetRandomPZSpawnPosition(i, ZCLASS_TANK, 10, outPos)) return true;
    }
    return false;
}

static bool SpawnOneFront()
{
    float p[3]; if (!PickFrontPos(p)) return false;
    return (SpawnTankAt(p) > 0);
}

static bool SpawnOneBehindCrumb()
{
    float p[3]; if (!FindBehindGroundPos(p)) return false;
    return (SpawnTankAt(p) > 0);
}

static bool SpawnOneAccordingToSide(int side)
{
    float chance = gC_CrumbChance.FloatValue;
    if (side == 2)
    {
        if (GetRandomFloat(0.0, 1.0) < chance) return SpawnOneBehindCrumb();
        return SpawnOneFront();
    }
    else if (side == 1) return SpawnOneFront();
    else
    {
        if (SpawnOneFront()) return true;
        if (GetRandomFloat(0.0, 1.0) < chance) return SpawnOneBehindCrumb();
        return false;
    }
}

/* ===== Tanks plans ===== */
static void ResetPlans()
{
    g_PlanCount = 0;
    for (int i = 0; i < K_MAX_PLANS; i++)
    {
        g_PlanPct[i] = 0.0;
        g_PlanExecuted[i] = false;
        g_PlanCanceled[i] = false;
        g_PlanSide[i] = 0;
        g_PlanBurstTarget[i] = 0;
        g_PlanBurstSpawned[i] = 0;
        g_PlanRetryUntil[i] = 0.0;
    }
}

static bool IsPctFarEnough(float pct, float minGap)
{
    for (int i = 0; i < g_PlanCount; i++)
    {
        if (g_PlanExecuted[i] || g_PlanCanceled[i]) continue;
        float d = FloatAbs(g_PlanPct[i] - pct);
        if (d < minGap) return false;
    }
    return true;
}

static void DecidePlanSide(int idx)
{
    bool allowFront = gC_AllowFront.BoolValue;
    bool allowBehind = gC_AllowBehind.BoolValue;
    int side = 0;
    if (allowFront && allowBehind) side = (GetRandomInt(0, 1) == 0) ? 1 : 2;
    else if (allowBehind) side = 2;
    else side = 1;
    g_PlanSide[idx] = side;
}

static void AddRandomPlanAhead(float curPct)
{
    if (g_PlanCount >= gC_PlanMax.IntValue || g_PlanCount >= K_MAX_PLANS) return;
    float a = GetEffectiveMinTankPct();
    float b = gC_MaxPct.FloatValue;
    float delta = gC_PlanAheadDelta.FloatValue;
    float minGap = gC_MinGapPct.FloatValue;
    float lo = curPct + delta; if (lo < a) lo = a;
    float hi = b; if (hi <= lo + 0.01) return;

    int tries = 48;
    while (tries-- > 0)
    {
        float pct = lo + GetRandomFloat(0.0, 1.0) * (hi - lo);
        if (!IsPctFarEnough(pct, minGap)) continue;
        int idx = g_PlanCount++;
        g_PlanPct[idx] = pct;
        g_PlanExecuted[idx] = false;
        g_PlanCanceled[idx] = false;
        DecidePlanSide(idx);
        return;
    }
}

static int CountUnexecutedActivePlans()
{
    int u = 0;
    for (int i = 0; i < g_PlanCount; i++)
        if (!g_PlanExecuted[i] && !g_PlanCanceled[i]) u++;
    return u;
}

static int FindNearestUpcomingPlanIdx(float curPct, bool onlyActive)
{
    int best = -1;
    float bestDist = 9999.0;
    for (int i = 0; i < g_PlanCount; i++)
    {
        if (g_PlanExecuted[i]) continue;
        if (onlyActive && g_PlanCanceled[i]) continue;
        float p = g_PlanPct[i];
        float d = p - curPct;
        if (d < 0.0) d = 0.0;
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

static void ReconcilePlans(float curPct)
{
    // Hard block: on these maps, never keep or add Tank plans
    if (IsMapTankBlockedCSV())
    {
        for (int i = 0; i < g_PlanCount; i++)
        {
            if (!g_PlanExecuted[i])
                g_PlanCanceled[i] = true;
        }
        return;
    }

    int remainingTokens = g_TokensAwarded - g_TokensConsumed;
    if (remainingTokens < 0) remainingTokens = 0;

    // zero tokens during Phase 5–8 while locked (block Tanks completely)
    int phaseNow = ResolveMoonPhase(g_Score);
    if (gC_P5BlockTanks.BoolValue && g_Phase5Lock && phaseNow >= PHASE_5 && (!IsMapFrozen5CSV() || gC_Frozen5LockTanks.BoolValue)) remainingTokens = 0;

    int active = CountUnexecutedActivePlans();
    while (active > remainingTokens)
    {
        int idx = FindNearestUpcomingPlanIdx(curPct, true);
        if (idx < 0) break;
        g_PlanCanceled[idx] = true;
        active--;
    }
    while (active < remainingTokens && g_PlanCount < gC_PlanMax.IntValue && g_PlanCount < K_MAX_PLANS)
    {
        AddRandomPlanAhead(curPct);
        active++;
    }
}

static int WeightedPickBurst(int maxSize)
{
    char s[64];
    gC_BurstWeights.GetString(s, sizeof s);
    int w2=1,w3=1,w4=1;
    char parts[3][16];
    int n = ExplodeString(s, ",", parts, 3, 16, true);
    if (n >= 1) w2 = StringToInt(parts[0]);
    if (n >= 2) w3 = StringToInt(parts[1]);
    if (n >= 3) w4 = StringToInt(parts[2]);
    if (w2 < 0) w2 = 0; if (w3 < 0) w3 = 0; if (w4 < 0) w4 = 0;
    int sum = 0;
    if (maxSize >= 2) sum += w2;
    if (maxSize >= 3) sum += w3;
    if (maxSize >= 4) sum += w4;
    if (sum <= 0) return 1;
    int r = GetRandomInt(1, sum);
    if (maxSize >= 2) { if (r <= w2) return 2; r -= w2; }
    if (maxSize >= 3) { if (r <= w3) return 3; r -= w3; }
    return 4;
}

static bool TryExecutePlan(int idx)
{
    if (idx < 0 || idx >= g_PlanCount) return false;
    if (g_PlanExecuted[idx] || g_PlanCanceled[idx]) return false;

    // Hard block: do not spawn Tanks on maps in _tank_block_maps_csv
    if (IsMapTankBlockedCSV())
    {
        g_PlanCanceled[idx] = true;
        return false;
    }

    // Finale guard – respect finale_allow_csv
    if (g_IsFinale && gC_FinaleNoTanks.BoolValue && !IsMapAllowedByFinaleCSV())
    {
        g_PlanCanceled[idx] = true;
        return false;
    }

    // hard block during Phase 5–8 while locked
    int phaseNow = ResolveMoonPhase(g_Score);
    if (gC_P5BlockTanks.BoolValue && g_Phase5Lock && phaseNow >= PHASE_5 && (!IsMapFrozen5CSV() || gC_Frozen5LockTanks.BoolValue))
    {
        g_PlanCanceled[idx] = true;
        return false;
    }

    // c1m1 gates: require score and flow floor
    if (IsCurrentMapName("c1m1_hotel"))
    {
        float reqScore = (gC_C1M1MinScore != null) ? gC_C1M1MinScore.FloatValue : 0.0;
        if (reqScore > 0.0 && g_Score + 0.01 < reqScore)
            return false;

        float reqPct = (gC_C1M1MinFlowPct != null) ? gC_C1M1MinFlowPct.FloatValue : 0.0;
        if (reqPct > 0.0 && g_PlanPct[idx] + 0.001 < reqPct)
        {
            g_PlanPct[idx] = reqPct;
            return false;
        }
    }

    float now = GetEngineTime();

    if (g_PlanBurstTarget[idx] > 0)
    {
        if (g_PlanBurstSpawned[idx] >= g_PlanBurstTarget[idx])
        {
            g_PlanExecuted[idx] = true;
            return true;
        }
        if (now > g_PlanRetryUntil[idx])
        {
            g_PlanExecuted[idx] = true;
            return true;
        }

        int alive = CountAliveTanks();
        int cap = gC_MaxAlive.IntValue;
        if (alive >= cap) return false;

        int side = g_PlanSide[idx];
        if (SpawnOneAccordingToSide(side))
        {
            g_PlanBurstSpawned[idx]++;
            g_TokensConsumed++;
        }
        return false;
    }

    int alive = CountAliveTanks();
    int cap = gC_MaxAlive.IntValue;
    if (alive >= cap) return false;

    int remainingTokens = g_TokensAwarded - g_TokensConsumed;
    if (remainingTokens < 1)
    {
        g_PlanCanceled[idx] = true;
        return false;
    }

    int possibleMax = remainingTokens;
    int remainingCap = cap - alive;
    if (possibleMax > remainingCap) possibleMax = remainingCap;
    int burstMax = gC_BurstMax.IntValue;
    if (burstMax < 1) burstMax = 1;
    if (burstMax > K_BURST_MAX) burstMax = K_BURST_MAX;
    if (possibleMax > burstMax) possibleMax = burstMax;

    int burst = 1;
    float curPct = GetFarthestFlowPct();
    float minBurstPct = gC_BurstMinPct.FloatValue;
    float chance = gC_BurstChance.FloatValue;

    if (possibleMax >= 2 && curPct >= minBurstPct && GetRandomFloat(0.0, 1.0) < chance)
    {
        burst = WeightedPickBurst(possibleMax);
        if (burst < 1) burst = 1;
        if (burst > possibleMax) burst = possibleMax;
    }

    g_PlanBurstTarget[idx] = burst;
    g_PlanBurstSpawned[idx] = 0;
    float retrySec = gC_ExecRetrySec.FloatValue;
    g_PlanRetryUntil[idx] = now + retrySec;

    int side = g_PlanSide[idx];
    for (int i = 0; i < burst; i++)
    {
        if (CountAliveTanks() >= cap) break;
        if (SpawnOneAccordingToSide(side))
        {
            g_PlanBurstSpawned[idx]++;
            g_TokensConsumed++;
        }
    }

    if (g_PlanBurstSpawned[idx] >= g_PlanBurstTarget[idx])
    {
        g_PlanExecuted[idx] = true;
        return true;
    }
    return false;
}

/* ===== HUD ===== */
static bool IsAdminViewer(int client)
{
    if (!IsValidClient(client)) return false;
    int flags = GetUserFlagBits(client);
    if (flags & ADMFLAG_ROOT) return true;
    if (flags & ADMFLAG_GENERIC) return true;
    return false;
}

static void DisplayHudToAdmins()
{
    if (!(gC_DbgHud.BoolValue || gC_DbgHudWitch.BoolValue)) return;

    char msg[768] = "";

if (gC_DbgHud.BoolValue)
{
    int aliveTanks = CountAliveTanks();
    int cap = gC_MaxAlive.IntValue;
    int remTokens = g_TokensAwarded - g_TokensConsumed; if (remTokens < 0) remTokens = 0;

    char lockStatus[32] = "";
if (g_Phase5Lock)
{
    float showFloor = gC_LockRatchetEnable.BoolValue ? g_LockBaselineScore : gC_P5LockFloor.FloatValue;
    Format(lockStatus, sizeof lockStatus, " | P5LOCK ON (floor %.0f)", showFloor);
}
    else
        Format(lockStatus, sizeof lockStatus, "");

    Format(msg, sizeof msg, "BossDirector v1.0\nScore: %.1f | Tanks %d/%d | Tokens rem %d used %d%s",
        g_Score, aliveTanks, cap, remTokens, g_TokensConsumed, lockStatus);
}

    if (gC_DbgHudWitch.BoolValue)
    {
        int active=0, exec=0;
        for (int i = 0; i < g_WitchPlanCount; i++)
        {
            if (!g_WitchPlanExecuted[i] && !g_WitchPlanCanceled[i]) active++;
            if (g_WitchPlanExecuted[i]) exec++;
        }
int phase = ResolveMoonPhase(g_Score);
char phaseStr[8];
if (phase == PHASE_FROZEN5) strcopy(phaseStr, sizeof phaseStr, "5*");
else IntToString(phase, phaseStr, sizeof phaseStr);

char wmsg[512];
Format(wmsg, sizeof wmsg, "Witches Phase %s | Killed %d | Spawned %d | Plans %d active, %d exec",
    phaseStr, g_WitchesKilledTotal, g_WitchesSpawnedTotal, active, exec);

        if (msg[0]) Format(msg, sizeof msg, "%s\n%s", msg, wmsg);
        else strcopy(msg, sizeof msg, wmsg);
    }

    for (int i = 1; i <= MaxClients; i++)
        if (IsAdminViewer(i)) PrintHintText(i, "%s", msg);
}

/* ===== Timers ===== */
static void StartCrumbTimer()
{
	if (!g_bEnabled)
	return;

	delete g_hCrumbTimer;
	g_hCrumbTimer = null;

	float tick = gC_CrumbTick.FloatValue;
	if (tick < 0.05)
	tick = 0.05;

	g_hCrumbTimer = CreateTimer(tick, T_Crumb, 0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action T_Crumb(Handle t, any d)
{
    if (!g_bEnabled) return Plugin_Continue;
    float now = GetEngineTime();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        float pos[3]; GetClientAbsOrigin(i, pos);
        int head = g_iCrumbHead[i] + 1; if (head >= CRUMB_MAX) head = 0;
        g_iCrumbHead[i] = head;
        g_vCrumbs[i][head][0] = pos[0];
        g_vCrumbs[i][head][1] = pos[1];
        g_vCrumbs[i][head][2] = pos[2];
        g_tCrumbs[i][head] = now;
        if (g_iCrumbCount[i] < CRUMB_MAX) g_iCrumbCount[i]++;
    }
    return Plugin_Continue;
}

static void StartHudTimer()
{
    if (!g_bEnabled) return;
    if (!gC_DbgHud.BoolValue && !gC_DbgHudWitch.BoolValue)
    {
        if (g_hHudTimer != null) { CloseHandle(g_hHudTimer); g_hHudTimer = null; }
        return;
    }
    float dt = gC_DbgRate.FloatValue; if (dt < 0.1) dt = 0.1;
    if (g_hHudTimer != null) { CloseHandle(g_hHudTimer); g_hHudTimer = null; }
    g_hHudTimer = CreateTimer(dt, T_Hud, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action T_Hud(Handle timer, any data)
{
	DisplayHudToAdmins();
	return Plugin_Continue;
}

public Action T_ShowHudOnJoin(Handle t, any userid)
{
    int client = GetClientOfUserId(userid);
    if (IsAdminViewer(client)) DisplayHudToAdmins();
    return Plugin_Continue;
}

/* ===== Director tick ===== */
public Action T_Director(Handle h, any d)
{
    if (!g_bEnabled) return Plugin_Continue;
    if (!g_LeftStart) return Plugin_Continue;

    float pct = GetFarthestFlowPct();
    AwardUpToPct(pct);

    int current = RoundToFloor(g_Score / 100.0); if (current < 0) current = 0;
    g_TokensAwarded = current;

if (IsCurrentMapName("c1m1_hotel"))
{
    int capTok = (gC_C1M1TokenCap != null) ? gC_C1M1TokenCap.IntValue : 0;
    if (capTok > 0 && g_TokensAwarded > capTok) g_TokensAwarded = capTok;
}

    ReconcilePlans(pct);

if (IsCurrentMapName("c1m1_hotel"))
{
    float reqPct = (gC_C1M1MinFlowPct != null) ? gC_C1M1MinFlowPct.FloatValue : 0.0;
    if (reqPct > 0.0)
    {
        for (int i = 0; i < g_PlanCount; i++)
            if (!g_PlanExecuted[i] && !g_PlanCanceled[i] && g_PlanPct[i] + 0.001 < reqPct)
                g_PlanPct[i] = reqPct;
    }
}

    int phase = ResolveMoonPhase(g_Score);
    EnforceWanderCvarForPhase(phase);
    ReconcileMoonPhaseWitchPlans(pct);

    for (int i = 0; i < g_PlanCount; i++)
    {
        if (g_PlanExecuted[i] || g_PlanCanceled[i]) continue;
        if (pct + 0.1 < g_PlanPct[i]) continue;
        bool did = TryExecutePlan(i);
        if (did) ReconcilePlans(pct);
    }

    for (int i = 0; i < g_WitchPlanCount; i++)
    {
        if (g_WitchPlanExecuted[i] || g_WitchPlanCanceled[i]) continue;
        if (pct + 0.1 < g_WitchPlanPct[i]) continue;
        bool did = TryExecuteWitchPlan(i);
        if (did) ReconcileMoonPhaseWitchPlans(pct);
    }

    return Plugin_Continue;
}

/* ===== Lifecycle ===== */

public void OnConfigsExecuted()
{
    BD_RefreshEnabled();
    BD_ApplyDirectorNoBossesOnce();
}

public void OnMapStart()
{
    g_bMapStarted = true;
    g_bDirectorNoBossesApplied = false;

    g_MapFlowMax = GetMapFlowMax();
    InitOrPersistScoreForCampaign();
    ResetCheckpointsState();
    ParseCheckpointsCSV();
    UpdateFinaleState();
    ParseFinaleAllowCSV();
    ParseFrozen5MapsCSV();
    ParseWanderPersistCSV();
    ParseWitchBlockCSV();
    ParseTankBlockCSV();

    PrintToServer("[BD] MAP START: g_IsFinale=%d, finale_no_tanks=%d", g_IsFinale, gC_FinaleNoTanks.IntValue);

    g_LeftStart = false;
    g_WitchesKilledTotal = 0;
    g_WitchesSpawnedTotal = 0;
    g_bIsWanderModeLocked = false;
    g_iLastWitchPhase = 0;
    if (gC_P5UnlockOnMapStart.BoolValue)
    {
        g_Phase5Lock = false;
        g_LastPhase = PHASE_1;
        g_LockBaselineScore = 0.0;
    }
    ResetPlans();
    ResetWitchPlans();

    for (int i = 1; i <= MaxClients; i++) { g_iCrumbHead[i] = -1; g_iCrumbCount[i] = 0; }
    StartCrumbTimer();
    StartHudTimer();
    BD_ApplyDirectorNoBossesOnce();
    DisplayHudToAdmins();
}

public void OnMapEnd()
{
    g_bMapStarted = false;
    g_bDirectorNoBossesApplied = false;
    BD_StopAllTimers();

    if (g_hTick != null) { CloseHandle(g_hTick); g_hTick = null; }
    if (g_hCrumbTimer != null) { CloseHandle(g_hCrumbTimer); g_hCrumbTimer = null; }
    if (g_hHudTimer != null) { CloseHandle(g_hHudTimer); g_hHudTimer = null; }
    ResetPlans();
    ResetWitchPlans();
}

public void OnClientPutInServer(int c)
{
    SDKHook(c, SDKHook_OnTakeDamage, OnTakeDamageHook);
    CreateTimer(0.1, T_ShowHudOnJoin, GetClientUserId(c), TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int c)
{
    if (c >= 1 && c <= MaxClients) SDKUnhook(c, SDKHook_OnTakeDamage, OnTakeDamageHook);
}

public void E_RoundStart(Event e, const char[] name, bool dontBroadcast)
{
    if (!g_bEnabled) return;
    if (g_hTick != null) { CloseHandle(g_hTick); g_hTick = null; }
    g_MapFlowMax = GetMapFlowMax();
    InitOrPersistScoreForCampaign();
    ResetCheckpointsState();
    ParseCheckpointsCSV();
    UpdateFinaleState();
    ParseFinaleAllowCSV();
    ParseFrozen5MapsCSV();
    ParseWanderPersistCSV();
    ParseWitchBlockCSV();
    ParseTankBlockCSV();

    PrintToServer("[BD] ROUND START: g_IsFinale=%d, finale_no_tanks=%d", g_IsFinale, gC_FinaleNoTanks.IntValue);

    g_LeftStart = false;
    g_WitchesKilledTotal = 0;
    g_WitchesSpawnedTotal = 0;
    g_bIsWanderModeLocked = false;
    g_iLastWitchPhase = 0;

    g_LockBaselineScore = 0.0;

    ResetPlans();
    ResetWitchPlans();

    for (int i = 1; i <= MaxClients; i++) { g_iCrumbHead[i] = -1; g_iCrumbCount[i] = 0; }
    StartCrumbTimer();
    StartHudTimer();
    float dt = gC_Tick.FloatValue; if (dt < 0.05) dt = 0.05;
    g_hTick = CreateTimer(dt, T_Director, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    DisplayHudToAdmins();
}

public void E_RoundEnd(Event e, const char[] name, bool dontBroadcast)
{
    if (!g_bEnabled) return;
    AwardUpToPct(GetFarthestFlowPct());
    if (g_hTick != null) { CloseHandle(g_hTick); g_hTick = null; }
}

public void E_LeftStart(Event e, const char[] name, bool dontBroadcast)
{
    if (!g_bEnabled) return;
    if (g_LeftStart) return;
    if (!L4D_HasAnySurvivorLeftSafeArea()) return;

    g_LeftStart = true;

    float pct = GetFarthestFlowPct();
    AwardUpToPct(pct);
    ReconcilePlans(pct);

if (IsCurrentMapName("c1m1_hotel"))
{
    float reqPct = (gC_C1M1MinFlowPct != null) ? gC_C1M1MinFlowPct.FloatValue : 0.0;
    if (reqPct > 0.0)
    {
        for (int i = 0; i < g_PlanCount; i++)
            if (!g_PlanExecuted[i] && !g_PlanCanceled[i] && g_PlanPct[i] + 0.001 < reqPct)
                g_PlanPct[i] = reqPct;
    }
}

    ReconcileMoonPhaseWitchPlans(pct);

    float dt = gC_Tick.FloatValue; if (dt < 0.05) dt = 0.05;
    g_hTick = CreateTimer(dt, T_Director, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    DisplayHudToAdmins();
}

public void E_EnteredCheckpoint(Event e, const char[] name, bool dontBroadcast)
{
    if (!g_bEnabled) return;
    if (!g_LeftStart) return;
    float pct = GetFarthestFlowPct();
    float minEnd = gC_EndAwardMinPct.FloatValue;
    if (pct >= minEnd) AwardUpToPct(100.0);
}

public void E_WitchKilled(Event e, const char[] name, bool dontBroadcast)
{
    if (!g_bEnabled) return;
    g_WitchesKilledTotal++;
    DisplayHudToAdmins();
}

/* ===== OnPluginStart / CVARs / Admin cmds ===== */
public void OnPluginStart()
{
    AutoExecConfig(true, "l4d2_boss_director");

    gC_Enable = CreateConVar(CVARNAME("_enable"), "1", "Enable Boss Director (0/1)");
    gC_Modes = CreateConVar(CVARNAME("_modes"), "coop,realism", "Enable only in these mp_gamemode values (CSV). Empty=all.");
    gC_DirectorNoBosses = CreateConVar(CVARNAME("_director_no_bosses"), "1", "If 1, plugin forces game cvar director_no_bosses=1 (once per map) and may temporarily toggle it during plugin spawns; if 0, plugin does not touch director_no_bosses. (Some maps override this cvar and may still spawn a normal director tank.)");


    gC_Tick = CreateConVar(CVARNAME("_tick"), "0.5", "Director update interval (sec)");
    gC_Debug = CreateConVar(CVARNAME("_debug"), "0", "Debug logs (0/1)");
    gC_MaxAlive = CreateConVar(CVARNAME("_max_alive"), "4", "Max Tanks alive simultaneously");

    gC_StartEasy = CreateConVar(CVARNAME("_score_start_easy"), "50", "Starting score on Easy");
    gC_StartNorm = CreateConVar(CVARNAME("_score_start_normal"), "100", "Starting score on Normal");
    gC_StartAdv = CreateConVar(CVARNAME("_score_start_advanced"), "150", "Starting score on Advanced");
    gC_StartExp = CreateConVar(CVARNAME("_score_start_expert"), "200", "Starting score on Expert");
    gC_VersusBaseline = CreateConVar(CVARNAME("_versus_baseline_score"), "100", "Versus baseline starting score");
    gC_VersusForceReset = CreateConVar(CVARNAME("_versus_force_baseline_reset"), "1", "In Versus, always reset score to versus baseline");
    gC_ScoreMin = CreateConVar(CVARNAME("_score_min"), "0", "Minimum score floor");
    gC_ResetScoreOnCampaign = CreateConVar(CVARNAME("_reset_score_on_campaign"), "1", "Reset score on campaign change");

    gC_DmgMode = CreateConVar(CVARNAME("_damage_score_mode"), "1", "0=damage/val, 1=damage*val");
    gC_DmgPerPt = CreateConVar(CVARNAME("_damage_per_point"), "10.0", "Divider in mode 0");
    gC_DmgMul = CreateConVar(CVARNAME("_damage_score_mul"), "0.20", "Multiplier in mode 1");

    gC_QHealthMode = CreateConVar(CVARNAME("_quarter_health_mode"), "1", "0=health/val, 1=health*val");
    gC_QHealthPer = CreateConVar(CVARNAME("_quarter_health_per_point"), "30.0", "Divider when mode=0");
    gC_QHealthMul = CreateConVar(CVARNAME("_quarter_health_mul"), "0.25", "Multiplier when mode=1");
    gC_QDmgPenaltyMul = CreateConVar(CVARNAME("_quarter_damage_penalty_mul"), "0.05", "Penalty factor");
    gC_IncludeTemp = CreateConVar(CVARNAME("_include_temp"), "1", "Include temp health in health->score");
    gC_QCheckCSV = CreateConVar(CVARNAME("_quarter_checkpoints_csv"), "25,50,75,100", "CSV checkpoints");

    gC_MinPct = CreateConVar(CVARNAME("_range_min_percent"), "0.0", "Min percent for tank planning");
    gC_MaxPct = CreateConVar(CVARNAME("_range_max_percent"), "100.0", "Max percent for tank planning");
    gC_MinGapPct = CreateConVar(CVARNAME("_min_gap_percent"), "4.0", "Min gap between tank plans");
    gC_PlanMax = CreateConVar(CVARNAME("_plan_max"), "64", "Max planned tank points kept");
    gC_C1M1MinFlowPct = CreateConVar(CVARNAME("_c1m1_min_flow_percent"), "75.0", "On c1m1_hotel, minimum flow percent before any Tank can spawn; 0=disabled");
    gC_C1M1MinScore = CreateConVar(CVARNAME("_c1m1_min_score"), "300", "On c1m1_hotel, minimum score required to allow any Tank; 0=disabled");
    gC_C1M1TokenCap = CreateConVar(CVARNAME("_c1m1_token_cap"), "1", "On c1m1_hotel, clamp tokens awarded to this maximum; 0=disabled");

    gC_AllowFront = CreateConVar(CVARNAME("_allow_front"), "1", "Allow front tank spawns");
    gC_AllowBehind = CreateConVar(CVARNAME("_allow_behind"), "1", "Allow behind tank spawns");
    gC_BurstChance = CreateConVar(CVARNAME("_burst_chance"), "0.15", "Chance a due plan attempts a burst");
    gC_BurstWeights = CreateConVar(CVARNAME("_burst_weights"), "1,1,1", "Weights for burst sizes 2,3,4");
    gC_BurstMax = CreateConVar(CVARNAME("_burst_max"), "4", "Max simultaneous Tanks per plan");
    gC_BurstMinPct = CreateConVar(CVARNAME("_burst_min_percent"), "25.0", "Min percent before allowing bursts");

    gC_PlanAheadDelta = CreateConVar(CVARNAME("_plan_ahead_delta_percent"), "0.8", "Min percent ahead for new plans");
    gC_ExecRetrySec = CreateConVar(CVARNAME("_exec_retry_seconds"), "180.0", "Seconds to keep retrying burst");

    gC_CrumbTick = CreateConVar(CVARNAME("_behind_crumb_tick"), "0.20", "Seconds between breadcrumb samples");
    gC_CrumbAgeMax = CreateConVar(CVARNAME("_behind_crumb_age_max"), "180.0", "Max crumb age");
    gC_MinXY = CreateConVar(CVARNAME("_behind_mindistxy"), "260.0", "Min XY distance from slowest survivor");
    gC_MaxZD = CreateConVar(CVARNAME("_behind_maxzdelta"), "160.0", "Max |Z| delta");
    gC_MinDot = CreateConVar(CVARNAME("_behind_mindot"), "-0.90", "dot(candDir,teamDir) <= this");
    gC_MinBackSlow = CreateConVar(CVARNAME("_behind_flow_minback"), "1750.0", "Min flow behind slowest survivor");
    gC_MinBackFar = CreateConVar(CVARNAME("_behind_flow_minback_far"), "250.0", "Min flow behind farthest survivor");
    gC_CrumbChance = CreateConVar(CVARNAME("_behind_crumb_chance"), "0.35", "Chance to use crumb spawn when behind");
    gC_CrumbRadius = CreateConVar(CVARNAME("_behind_crumb_radius"), "1100.0", "Max distance from crumb to ground pick");
    gC_MaxBackClamp = CreateConVar(CVARNAME("_behind_flow_maxback"), "3000.0", "Reject if farther than this behind");

    gC_EndAwardMinPct = CreateConVar(CVARNAME("_end_award_min_percent"), "95.0", "Min pct to treat checkpoint as end");
    gC_FinaleNoGain = CreateConVar(CVARNAME("_finale_no_gain"), "1", "Block checkpoint awards on finales");
    gC_FinaleNoTanks = CreateConVar(CVARNAME("_finale_no_tanks"), "1", "Block token Tanks on finales");
    gC_FinaleAllowCSV = CreateConVar(CVARNAME("_finale_allow_csv"), "c5m5_bridge,c13m4_cutthroatcreek,c9m2_lots,c10m5_houseboat", "CSV of maps allowed on finales");

    gC_DbgHud = CreateConVar(CVARNAME("_dbg_hud"), "0", "Show main HUD");
    gC_DbgHudWitch = CreateConVar(CVARNAME("_dbg_hud_witch"), "0", "Show witch HUD");
    gC_DbgRate = CreateConVar(CVARNAME("_dbg_rate"), "0.5", "HUD refresh seconds");

    gC_WitchEnable = CreateConVar(CVARNAME("_witch_enable"), "1", "Enable moon-phase witches");
    gC_Ph2Score = CreateConVar(CVARNAME("_ph2_score"), "150.0", "Score to enter Phase 2");
    gC_Ph3Score = CreateConVar(CVARNAME("_ph3_score"), "300.0", "Score to enter Phase 3");
    gC_Ph4Score = CreateConVar(CVARNAME("_ph4_score"), "450.0", "Score to enter Phase 4");
    gC_Ph5Score = CreateConVar(CVARNAME("_ph5_score"), "600.0", "Score to enter Phase 5");

    gC_Ph2TotalCap = CreateConVar(CVARNAME("_ph2_total_cap"), "2", "Phase 2/8 total normal witches cap");
    gC_Ph3ClusterCap = CreateConVar(CVARNAME("_ph3_cluster_cap"), "4", "Phase 3/7 cluster total cap");
    gC_Ph4TotalCap = CreateConVar(CVARNAME("_ph4_total_cap"), "6", "Phase 4/6 total cap");
    gC_Ph4NormalCap = CreateConVar(CVARNAME("_ph4_normal_cap"), "3", "Phase 4/6 normal subcap");
    gC_Ph4WanderCap = CreateConVar(CVARNAME("_ph4_wander_cap"), "3", "Phase 4/6 wander subcap");
    gC_Ph5TotalCap = CreateConVar(CVARNAME("_ph5_total_cap"), "8", "Phase 5 total cap");
    gC_Ph5NormalCap = CreateConVar(CVARNAME("_ph5_normal_cap"), "0", "Phase 5 normal cap");
    gC_Ph5WanderCap = CreateConVar(CVARNAME("_ph5_wander_cap"), "8", "Phase 5 wander cap");

    gC_Ph4WanderPackChance = CreateConVar(CVARNAME("_ph4_wander_pack_chance"), "0.30", "Phase 4/6 wander pack chance");
    gC_Ph4WanderPackMax = CreateConVar(CVARNAME("_ph4_wander_pack_max"), "3", "Phase 4/6 wander pack max size");
    gC_Ph5WanderPackChance = CreateConVar(CVARNAME("_ph5_wander_pack_chance"), "0.15", "Phase 5 wander pack chance");
    gC_Ph5WanderPackMax = CreateConVar(CVARNAME("_ph5_wander_pack_max"), "4", "Phase 5 wander pack max size");

    gC_P5LockEnable = CreateConVar(CVARNAME("_p5_lock_enable"), "1", "Enable Phase-5 score lock + 5-8 no-fallback cycle (0/1)");
    gC_P5LockFloor = CreateConVar(CVARNAME("_p5_lock_floor"), "600.0", "Score floor enforced while Phase-5 lock is active");
    gC_LockRatchetEnable = CreateConVar(CVARNAME("_p5_lock_ratchet_enable"), "1", "1=enforce per-phase baseline floors at 600/750/900/1050 until wrap; 0=only 600 floor");
    gC_Frozen5WrapMode = CreateConVar(CVARNAME("_frozen5_wrap_mode"), "1", "Frozen-5 wrap when past Phase-8: 0=off, 1=reset to difficulty start, 2=reset to zero");
    gC_P5BlockTanks = CreateConVar(CVARNAME("_p5_block_tanks"), "1", "Block Tanks (zero tokens + cancel due plans) in Phases 5–8 while locked (0/1)");
    gC_P5UnlockOnCampaign = CreateConVar(CVARNAME("_p5_unlock_on_campaign"), "1", "Clear Phase-5 lock on campaign change/first load (0/1)");
    gC_P5UnlockOnMapStart = CreateConVar(CVARNAME("_p5_unlock_on_mapstart"), "0", "Clear Phase-5 lock on each map start (0/1)");
    gC_Frozen5MapsCsv = CreateConVar(CVARNAME("_frozen5_maps_csv"), "c4m1_milltown_a,c4m2_sugarmill_a,c12m1_hilltop,c12m3_bridge,c12m4_barn,c12m5_cornfield", "CSV of maps frozen at witch Phase 5");
    gC_Frozen5LockTanks = CreateConVar(CVARNAME("_frozen5_lock_tanks"), "1", "On Frozen-5 maps: 1=engage Phase-5 lock at 600 to cancel Tanks; 0=leave Tanks normal");
    gC_WanderPersistCsv = CreateConVar(CVARNAME("_wander_persist_maps_csv"), "c1m1_hotel,c1m2_streets,c3m2_swamp,c3m3_shantytown,c3m4_plantation,c4m1_milltown_a,c4m2_sugarmill_a,c5m1_waterfront,c5m2_park,c5m3_cemetery,c5m4_quarter,c5m5_bridge,c7m1_docks,c7m2_barge,c7m3_port,c13m1_alpinecreek,c13m2_southpinestream,c13m3_memorialbridge,c13m4_cutthroatcreek", "CSV of maps where witch_force_wander is periodically set to 1");

    gC_WitchBlockMapsCsv = CreateConVar(CVARNAME("_witch_block_maps_csv"), "c6m1_riverbank", "CSV of maps where Boss Director must not spawn witches");
    gC_TankBlockMapsCsv = CreateConVar(CVARNAME("_tank_block_maps_csv"), "", "CSV of maps where Boss Director must not spawn Tanks");

    gC_WitchSpawnCloseDist = CreateConVar(CVARNAME("_witch_cluster_distance"), "100.0", "Max cluster spread");
    gC_WitchClusterMinMemberDist = CreateConVar(CVARNAME("_witch_cluster_member_distance"), "50.0", "Min distance (units) between cluster members to prevent overlapping");
    gC_WitchLog = CreateConVar("l4d2_boss_director_witch_log", "0", "1=enable witch debug logging");

    gC_NoBosses = FindConVar("director_no_bosses");

    gC_MPGameMode = FindConVar("mp_gamemode");
    if (gC_MPGameMode != null) HookConVarChange(gC_MPGameMode, OnBDEnableCvarChanged);
    HookConVarChange(gC_Enable, OnBDEnableCvarChanged);
    HookConVarChange(gC_Modes, OnBDEnableCvarChanged);
    HookConVarChange(gC_DirectorNoBosses, OnBDEnableCvarChanged);

    BD_RefreshEnabled();


    HookConVarChange(gC_Frozen5MapsCsv, OnFrozen5CsvChanged);
    HookConVarChange(gC_WanderPersistCsv, OnWanderPersistCsvChanged);
    HookConVarChange(gC_WitchBlockMapsCsv, OnWitchBlockCsvChanged);
    HookConVarChange(gC_TankBlockMapsCsv, OnTankBlockCsvChanged);

    RegConsoleCmd("sm_bd_set_score", Cmd_SetScore, "Set BD score");
    RegConsoleCmd("sm_bd_add_score", Cmd_AddScore, "Add to BD score");
    RegConsoleCmd("sm_bd_sub_score", Cmd_SubScore, "Subtract from BD score");

    HookEvent("round_start", E_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", E_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("player_left_checkpoint", E_LeftStart, EventHookMode_PostNoCopy);
    HookEvent("player_left_start_area", E_LeftStart, EventHookMode_PostNoCopy);
    HookEvent("player_entered_checkpoint", E_EnteredCheckpoint, EventHookMode_PostNoCopy);
    HookEvent("witch_killed", E_WitchKilled, EventHookMode_PostNoCopy);

    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i)) SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamageHook);

    StartCrumbTimer();
    StartHudTimer();
    ParseWanderPersistCSV();
    ParseWitchBlockCSV();
    ParseTankBlockCSV();
}

public void OnFrozen5CsvChanged(ConVar cvar, const char[] oldv, const char[] newv)
{
    ParseFrozen5MapsCSV();
    LogMessage("[BD] Frozen5 CSV changed -> '%s'", newv);
}

public void OnWanderPersistCsvChanged(ConVar cvar, const char[] oldv, const char[] newv)
{
    ParseWanderPersistCSV();
    LogMessage("[BD] WanderPersist CSV changed -> '%s'", newv);
}

public void OnWitchBlockCsvChanged(ConVar cvar, const char[] oldv, const char[] newv)
{
    ParseWitchBlockCSV();
    LogMessage("[BD] WitchBlock CSV changed -> '%s'", newv);
}

public void OnTankBlockCsvChanged(ConVar cvar, const char[] oldv, const char[] newv)
{
    ParseTankBlockCSV();
    LogMessage("[BD] TankBlock CSV changed -> '%s'", newv);
}

/* ===== Admin Commands ===== */
static bool BD_CheckAccess(int client, const char[] overrideName)
{
	if (!CheckCommandAccess(client, overrideName, ADMFLAG_GENERIC))
	{
		ReplyToCommand(client, "[BD] No access.");
		return false;
	}
	return true;
}

static bool BD_ReadScoreArg(int client, int args, const char[] usage, float &value)
{
	if (args < 1)
	{
		ReplyToCommand(client, "%s", usage);
		return false;
	}

	if (!GetCmdArgFloatEx(1, value))
	{
		ReplyToCommand(client, "[BD] Invalid number.");
		return false;
	}

	return true;
}

static void BD_ClampScore()
{
	if (g_Score < 0.0)
		g_Score = 0.0;
}

public Action Cmd_SetScore(int client, int args)
{
	if (!BD_CheckAccess(client, "sm_bd_set_score"))
		return Plugin_Handled;

	float amount;
	if (!BD_ReadScoreArg(client, args, "Usage: sm_bd_set_score <amount>", amount))
		return Plugin_Handled;

	g_Score = amount;
	BD_ClampScore();

	DisplayHudToAdmins();
	ReplyToCommand(client, "[BD] Score set to %.1f.", g_Score);
	return Plugin_Handled;
}

public Action Cmd_AddScore(int client, int args)
{
	if (!BD_CheckAccess(client, "sm_bd_add_score"))
		return Plugin_Handled;

	float amount;
	if (!BD_ReadScoreArg(client, args, "Usage: sm_bd_add_score <amount>", amount))
		return Plugin_Handled;

	g_Score += amount;
	BD_ClampScore();

	DisplayHudToAdmins();
	ReplyToCommand(client, "[BD] Score now %.1f.", g_Score);
	return Plugin_Handled;
}

public Action Cmd_SubScore(int client, int args)
{
	if (!BD_CheckAccess(client, "sm_bd_sub_score"))
		return Plugin_Handled;

	float amount;
	if (!BD_ReadScoreArg(client, args, "Usage: sm_bd_sub_score <amount>", amount))
		return Plugin_Handled;

	g_Score -= amount;
	BD_ClampScore();

	DisplayHudToAdmins();
	ReplyToCommand(client, "[BD] Score now %.1f.", g_Score);
	return Plugin_Handled;
}

