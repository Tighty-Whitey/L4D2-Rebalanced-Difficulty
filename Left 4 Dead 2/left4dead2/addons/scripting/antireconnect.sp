#include <sourcemod>

#define PLUGIN_VERSION "2.0.0"

public Plugin myinfo = 
{
	name = "Anti-Reconnect",
	author = "exvel (redesigned)",
	description = "Blocks survivors from reconnecting for a while after quitting while dead",
	version = PLUGIN_VERSION,
	url = "www.sourcemod.net"
}

bool g_bKickedByPlugin[MAXPLAYERS+1];
Handle g_kvDB = INVALID_HANDLE;

Handle cvar_ar_time = INVALID_HANDLE;
Handle cvar_ar_admin_immunity = INVALID_HANDLE;
Handle cvar_lan = INVALID_HANDLE;

bool isLAN = false;
int ar_time = 30;
bool ar_admin_immunity = false;

public void OnPluginStart()
{
	g_kvDB = CreateKeyValues("antireconnect");

	CreateConVar("sm_anti_reconnect_version", PLUGIN_VERSION, "Anti-Reconnect Version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	cvar_ar_time = CreateConVar("sm_anti_reconnect_time", "240", "Time in seconds survivors must wait before reconnecting after quitting while dead (0 = disabled)", FCVAR_PLUGIN, true, 0.0);
	cvar_ar_admin_immunity = CreateConVar("sm_anti_reconnect_admin_immunity", "0", "0 = disabled, 1 = admins are immune to the reconnect block", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	cvar_lan = FindConVar("sv_lan");

	HookConVarChange(cvar_ar_time, OnCVarChange);
	HookConVarChange(cvar_ar_admin_immunity, OnCVarChange);
	HookConVarChange(cvar_lan, OnCVarChange);

	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	AutoExecConfig(true, "plugin.antireconnect");
	LoadTranslations("antireconnect.phrases");
}

public void OnMapStart()
{
	if (g_kvDB != INVALID_HANDLE)
		CloseHandle(g_kvDB);
	g_kvDB = CreateKeyValues("antireconnect");
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_kvDB != INVALID_HANDLE)
		CloseHandle(g_kvDB);
	g_kvDB = CreateKeyValues("antireconnect");
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (g_bKickedByPlugin[client] || !client)
		return Plugin_Continue;

	if (GetClientTeam(client) != 2)
		return Plugin_Continue;

	if (IsPlayerAlive(client))
		return Plugin_Continue;

	char reason[128];
	event.GetString("reason", reason, sizeof(reason));

	if (!StrEqual(reason, "Disconnect by user."))
		return Plugin_Continue;

	if (isLAN || ar_time == 0 || IsFakeClient(client))
		return Plugin_Continue;

	if (GetUserFlagBits(client) && ar_admin_immunity)
		return Plugin_Continue;

	char steamId[30];
	GetClientAuthString(client, steamId, sizeof(steamId));

	KvSetNum(g_kvDB, steamId, GetTime());
	return Plugin_Continue;
}

public void OnClientPostAdminCheck(int client)
{
	g_bKickedByPlugin[client] = false;

	if (isLAN || ar_time == 0 || IsFakeClient(client) || !IsClientConnected(client))
		return;

	char steamId[30];
	GetClientAuthString(client, steamId, sizeof(steamId));

	int disconnect_time = KvGetNum(g_kvDB, steamId, -1);
	if (disconnect_time == -1)
		return;

	int wait_time = disconnect_time + ar_time - GetTime();
	if (wait_time <= 0)
	{
		KvDeleteKey(g_kvDB, steamId);
	}
	else
	{
		g_bKickedByPlugin[client] = true;
		KickClient(client, "%t", "You are not allowed to reconnect for X seconds", wait_time);
		LogAction(-1, client, "Kicked \"%L\". Survivor quit while dead and is blocked for %d seconds.", client, wait_time);
	}
}

public void OnCVarChange(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCVars();
}

public void OnConfigsExecuted()
{
	GetCVars();
}

void GetCVars()
{
	isLAN = GetConVarBool(cvar_lan);
	ar_time = GetConVarInt(cvar_ar_time);
	ar_admin_immunity = GetConVarBool(cvar_ar_admin_immunity);
}