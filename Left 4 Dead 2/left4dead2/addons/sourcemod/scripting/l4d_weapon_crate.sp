/*
*	Weapon Crate
*	Copyright (C) 2025 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/



#define PLUGIN_VERSION 		"1.9"

/*======================================================================================
	Plugin Info:

*	Name	:	[L4D & L4D2] Weapon Crate
*	Author	:	SilverShot
*	Descrp	:	Spawns a weapon in a weapon crate/locker, these can be temporary or saved for auto-spawning.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=222932
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

1.9 (01-Apr-2025)
	- Items and weapons are now spawned frozen in place to prevent them from moving or rolling. Requested by "Tighty-Whitey".

1.8 (11-Dec-2022)
	- Changes to fix compile warnings on SourceMod 1.11.

1.7 (10-May-2020)
	- Blocked glow command from L4D1 which does not support glows.
	- Extra checks to prevent "IsAllowedGameMode" throwing errors.
	- Various changes to tidy up code.
	- Various optimizations and fixes.

1.6 (01-Apr-2020)
	- Fixed "IsAllowedGameMode" from throwing errors when the "_tog" cvar was changed before MapStart.

1.5 (05-May-2018)
	- Converted plugin source to the latest syntax utilizing methodmaps. Requires SourceMod 1.8 or newer.
	- Changed cvar "l4d_weapon_crate_modes_tog" now supports L4D1.

1.4.1 (20-Nov-2015)
	- Fixed the Sniper Scout not spawning when "l4d_weapon_spawn_count" cvar was set to 0.

1.4 (19-Nov-2015)
	- Fixed Auto Shotgun ammo in L4D1 not filling.
	- Fixed some guns not spawning when "l4d_weapon_crate_count" cvar was set to 0.

1.3 (29-Mar-2015)
	- Fixed the plugin not loading in L4D1 due to an Invalid Convar Handle.

1.2 (18-Aug-2013)
	- Added cvar "l4d_weapon_crate_count" to set how many times a spawner gives items/weapons before disappearing.
	- Added cvar "l4d_weapon_crate_randomise" to randomise the spawns based on a chance out of 100.

1.1 (11-Aug-2013)
	- Fixed the "sm_weapon_crate_del" command to work.

1.0 (09-Aug-2013)
	- Initial release.

========================================================================================
	Thanks:

	This plugin was made using source code from the following plugins.
	If I have used your code and not credited you, please let me know.

*	"Zuko & McFlurry" for "[L4D2] Weapon/Zombie Spawner" - Modified SetTeleportEndPoint function.
	https://forums.alliedmods.net/showthread.php?t=109659

*	Thanks to "Boikinov" for "[L4D] Left FORT Dead builder" - RotateYaw function to rotate ground flares
	https://forums.alliedmods.net/showthread.php?t=93716

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define CVAR_FLAGS			FCVAR_NOTIFY
#define CHAT_TAG			"\x04[\x05Weapon Crate\x04] \x01"
#define CONFIG_SPAWNS		"data/l4d_weapon_crate.cfg"
#define MAX_SPAWNS			32
#define	MAX_WEAPONS			10
#define	MAX_WEAPONS2		29
#define	NEAR_TO_TARGET		50.0
#define	MODEL_LOCKER		"models/props/cs_militia/footlocker01_open.mdl"
#define	MODEL_LOCKER_LARGE	"models/props_crates/supply_crate02_gib1.mdl"
#define	MODEL_LOCKER_SMALL	"models/props_crates/supply_crate01_gib1.mdl"


ConVar g_hCvarAllow, g_hCvarCount, g_hCvarMPGameMode, g_hCvarModes, g_hCvarModesOff, g_hCvarModesTog, g_hCvarRandom, g_hCvarRandomise;
int g_iCvarCount, g_iCvarRandom, g_iCvarRandomise, g_iPlayerSpawn, g_iRoundStart, g_iSave[MAXPLAYERS+1], g_iSpawnCount, g_iSpawns[MAX_SPAWNS][3], g_iType[MAXPLAYERS+1];
bool g_bCvarAllow, g_bMapStarted, g_bLeft4Dead2, g_bLoaded;
Menu g_hMenuAng, g_hMenuList, g_hMenuPos, g_hMenuType;

ConVar g_hAmmoAutoShot, g_hAmmoChainsaw, g_hAmmoGL, g_hAmmoHunting, g_hAmmoM60, g_hAmmoRifle, g_hAmmoShotgun, g_hAmmoSmg, g_hAmmoSniper;
int g_iAmmoAutoShot, g_iAmmoChainsaw, g_iAmmoGL, g_iAmmoHunting, g_iAmmoM60, g_iAmmoRifle, g_iAmmoShotgun, g_iAmmoSmg, g_iAmmoSniper;

static char g_sWeaponNames[MAX_WEAPONS][] =
{
	"Rifle",
	"Auto Shotgun",
	"Hunting Rifle",
	"SMG",
	"Pump Shotgun",
	"Pistol",
	"Molotov",
	"Pipe Bomb",
	"First Aid Kit",
	"Pain Pills"
};
static char g_sWeapons[MAX_WEAPONS][] =
{
	"weapon_rifle",
	"weapon_autoshotgun",
	"weapon_hunting_rifle",
	"weapon_smg",
	"weapon_pumpshotgun",
	"weapon_pistol",
	"weapon_molotov",
	"weapon_pipe_bomb",
	"weapon_first_aid_kit",
	"weapon_pain_pills"
};
static char g_sWeaponModels[MAX_WEAPONS][] =
{
	"models/w_models/weapons/w_rifle_m16a2.mdl",
	"models/w_models/weapons/w_autoshot_m4super.mdl",
	"models/w_models/weapons/w_sniper_mini14.mdl",
	"models/w_models/weapons/w_smg_uzi.mdl",
	"models/w_models/weapons/w_pumpshotgun_A.mdl",
	"models/w_models/weapons/w_pistol_a.mdl",
	"models/w_models/weapons/w_eq_molotov.mdl",
	"models/w_models/weapons/w_eq_pipebomb.mdl",
	"models/w_models/weapons/w_eq_medkit.mdl",
	"models/w_models/weapons/w_eq_painpills.mdl"
};
static char g_sWeaponNames2[MAX_WEAPONS2][] =
{
	"Rifle",
	"Auto Shotgun",
	"Hunting Rifle",
	"SMG",
	"Pump Shotgun",
	"Pistol",
	"Molotov",
	"Pipe Bomb",
	"First Aid Kit",
	"Pain Pills",

	"Shotgun Chrome",
	"Rifle Desert",
	"Grenade Launcher",
	"M60",
	"AK47",
	"SG552",
	"Shotgun Spas",
	"SMG Silenced",
	"SMG MP5",
	"Sniper AWP",
	"Sniper Military",
	"Sniper Scout",
	"Chainsaw",
	"Pistol Magnum",
	"VomitJar",
	"Defibrillator",
	"Upgradepack Explosive",
	"Upgradepack Incendiary",
	"Adrenaline"
};
static char g_sWeapons2[MAX_WEAPONS2][] =
{
	"weapon_rifle",
	"weapon_autoshotgun",
	"weapon_hunting_rifle",
	"weapon_smg",
	"weapon_pumpshotgun",
	"weapon_pistol",
	"weapon_molotov",
	"weapon_pipe_bomb",
	"weapon_first_aid_kit",
	"weapon_pain_pills",

	"weapon_shotgun_chrome",
	"weapon_rifle_desert",
	"weapon_grenade_launcher",
	"weapon_rifle_m60",
	"weapon_rifle_ak47",
	"weapon_rifle_sg552",
	"weapon_shotgun_spas",
	"weapon_smg_silenced",
	"weapon_smg_mp5",
	"weapon_sniper_awp",
	"weapon_sniper_military",
	"weapon_sniper_scout",
	"weapon_chainsaw",
	"weapon_pistol_magnum",
	"weapon_vomitjar",
	"weapon_defibrillator",
	"weapon_upgradepack_explosive",
	"weapon_upgradepack_incendiary",
	"weapon_adrenaline"
};
static char g_sWeaponModels2[MAX_WEAPONS2][] =
{
	"models/w_models/weapons/w_rifle_m16a2.mdl",
	"models/w_models/weapons/w_autoshot_m4super.mdl",
	"models/w_models/weapons/w_sniper_mini14.mdl",
	"models/w_models/weapons/w_smg_uzi.mdl",
	"models/w_models/weapons/w_pumpshotgun_A.mdl",
	"models/w_models/weapons/w_pistol_a.mdl",
	"models/w_models/weapons/w_eq_molotov.mdl",
	"models/w_models/weapons/w_eq_pipebomb.mdl",
	"models/w_models/weapons/w_eq_medkit.mdl",
	"models/w_models/weapons/w_eq_painpills.mdl",

	"models/w_models/weapons/w_shotgun.mdl",
	"models/w_models/weapons/w_desert_rifle.mdl",
	"models/w_models/weapons/w_grenade_launcher.mdl",
	"models/w_models/weapons/w_m60.mdl",
	"models/w_models/weapons/w_rifle_ak47.mdl",
	"models/w_models/weapons/w_rifle_sg552.mdl",
	"models/w_models/weapons/w_shotgun_spas.mdl",
	"models/w_models/weapons/w_smg_a.mdl",
	"models/w_models/weapons/w_smg_mp5.mdl",
	"models/w_models/weapons/w_sniper_awp.mdl",
	"models/w_models/weapons/w_sniper_military.mdl",
	"models/w_models/weapons/w_sniper_scout.mdl",
	"models/weapons/melee/w_chainsaw.mdl",
	"models/w_models/weapons/w_desert_eagle.mdl",
	"models/w_models/weapons/w_eq_bile_flask.mdl",
	"models/w_models/weapons/w_eq_defibrillator.mdl",
	"models/w_models/weapons/w_eq_explosive_ammopack.mdl",
	"models/w_models/weapons/w_eq_incendiary_ammopack.mdl",
	"models/w_models/weapons/w_eq_adrenaline.mdl"
};



// ====================================================================================================
//					PLUGIN INFO / START / END
// ====================================================================================================
public Plugin myinfo =
{
	name = "[L4D & L4D2] Weapon Crate",
	author = "SilverShot",
	description = "Spawns a weapon in a weapon crate/locker, these can be temporary or saved for auto-spawning.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=222932"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if( test == Engine_Left4Dead ) g_bLeft4Dead2 = false;
	else if( test == Engine_Left4Dead2 ) g_bLeft4Dead2 = true;
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hCvarAllow =		CreateConVar(	"l4d_weapon_crate_allow",			"1",			"0=Plugin off, 1=Plugin on.", CVAR_FLAGS );
	g_hCvarModes =		CreateConVar(	"l4d_weapon_crate_modes",			"",				"Turn on the plugin in these game modes, separate by commas (no spaces). (Empty = all).", CVAR_FLAGS );
	g_hCvarModesOff =	CreateConVar(	"l4d_weapon_crate_modes_off",		"",				"Turn off the plugin in these game modes, separate by commas (no spaces). (Empty = none).", CVAR_FLAGS );
	g_hCvarModesTog =	CreateConVar(	"l4d_weapon_crate_modes_tog",		"0",			"Turn on the plugin in these game modes. 0=All, 1=Coop, 2=Survival, 4=Versus, 8=Scavenge. Add numbers together.", CVAR_FLAGS );
	g_hCvarCount =		CreateConVar(	"l4d_weapon_crate_count",			"1",			"0=Infinite. How many items/weapons to give from 1 spawner.", CVAR_FLAGS );
	g_hCvarRandom =		CreateConVar(	"l4d_weapon_crate_random",			"-1",			"-1=All, 0=None. Otherwise randomly select this many weapons to spawn from the maps config.", CVAR_FLAGS );
	g_hCvarRandomise =	CreateConVar(	"l4d_weapon_crate_randomise",		"25",			"0=Off. Chance out of 100 to randomise the type of item/weapon regardless of what it's set to.", CVAR_FLAGS );
	CreateConVar(						"l4d_weapon_crate_version",			PLUGIN_VERSION, "Weapon Crate plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig(true,				"l4d_weapon_crate");

	g_hCvarMPGameMode = FindConVar("mp_gamemode");
	g_hCvarMPGameMode.AddChangeHook(ConVarChanged_Allow);
	g_hCvarAllow.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModes.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesOff.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesTog.AddChangeHook(ConVarChanged_Allow);
	g_hCvarCount.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarRandom.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarRandomise.AddChangeHook(ConVarChanged_Cvars);


	g_hAmmoRifle =			FindConVar("ammo_assaultrifle_max");
	g_hAmmoSmg =			FindConVar("ammo_smg_max");
	g_hAmmoHunting =		FindConVar("ammo_huntingrifle_max");

	g_hAmmoRifle.AddChangeHook(ConVarChanged_Cvars);
	g_hAmmoSmg.AddChangeHook(ConVarChanged_Cvars);
	g_hAmmoHunting.AddChangeHook(ConVarChanged_Cvars);

	if( g_bLeft4Dead2 )
	{
		g_hAmmoShotgun =	FindConVar("ammo_shotgun_max");
		g_hAmmoGL =			FindConVar("ammo_grenadelauncher_max");
		g_hAmmoChainsaw =	FindConVar("ammo_chainsaw_max");
		g_hAmmoAutoShot =	FindConVar("ammo_autoshotgun_max");
		g_hAmmoM60 =		FindConVar("ammo_m60_max");
		g_hAmmoSniper =		FindConVar("ammo_sniperrifle_max");

		g_hAmmoGL.AddChangeHook(ConVarChanged_Cvars);
		g_hAmmoChainsaw.AddChangeHook(ConVarChanged_Cvars);
		g_hAmmoAutoShot.AddChangeHook(ConVarChanged_Cvars);
		g_hAmmoM60.AddChangeHook(ConVarChanged_Cvars);
		g_hAmmoSniper.AddChangeHook(ConVarChanged_Cvars);
	} else {
		g_hAmmoShotgun =	FindConVar("ammo_buckshot_max");
	}

	g_hAmmoShotgun.AddChangeHook(ConVarChanged_Cvars);

	RegAdminCmd("sm_weapon_crate",			CmdSpawnerTemp,		ADMFLAG_ROOT, 	"Spawns a temporary weapon at your crosshair. Usage: sm_weapon_crate [1=L4D model, 2=L4D2 model, 2=L4D2 Crate]");
	RegAdminCmd("sm_weapon_crate_save",		CmdSpawnerSave,		ADMFLAG_ROOT, 	"Spawns a weapon at your crosshair and saves to config. Usage: sm_weapon_crate_save [1=L4D model, 2=L4D2 model, 2=L4D2 Crate]");
	RegAdminCmd("sm_weapon_crate_del",		CmdSpawnerDel,		ADMFLAG_ROOT, 	"Removes the weapon you are pointing at and deletes from the config if saved.");
	RegAdminCmd("sm_weapon_crate_clear",	CmdSpawnerClear,	ADMFLAG_ROOT, 	"Removes all weapons spawned by this plugin from the current map.");
	RegAdminCmd("sm_weapon_crate_wipe",		CmdSpawnerWipe,		ADMFLAG_ROOT, 	"Removes all weapons from the current map and deletes them from the config.");
	if( g_bLeft4Dead2 )
		RegAdminCmd("sm_weapon_crate_glow",	CmdSpawnerGlow,		ADMFLAG_ROOT, 	"Toggle to enable glow on all weapons to see where they are placed.");
	RegAdminCmd("sm_weapon_crate_list",		CmdSpawnerList,		ADMFLAG_ROOT, 	"Display a list weapon positions and the total number of.");
	RegAdminCmd("sm_weapon_crate_tele",		CmdSpawnerTele,		ADMFLAG_ROOT, 	"Teleport to a weapon (Usage: sm_weapon_crate_tele <index: 1 to MAX_SPAWNS (32)>).");
	RegAdminCmd("sm_weapon_crate_ang",		CmdSpawnerAng,		ADMFLAG_ROOT, 	"Displays a menu to adjust the weapon angles your crosshair is over.");
	RegAdminCmd("sm_weapon_crate_pos",		CmdSpawnerPos,		ADMFLAG_ROOT, 	"Displays a menu to adjust the weapon origin your crosshair is over.");


	g_hMenuType = new Menu(TypeMenuHandler);
	g_hMenuType.AddItem("", "Locker");
	g_hMenuType.AddItem("", "Crate");
	g_hMenuType.SetTitle("Weapon Crate Model:");
	g_hMenuType.ExitButton = true;


	g_hMenuList = new Menu(ListMenuHandler);
	int max = MAX_WEAPONS;
	if( g_bLeft4Dead2 ) max = MAX_WEAPONS2;
	for( int i = 0; i < max; i++ )
	{
		g_hMenuList.AddItem("", g_bLeft4Dead2 ? g_sWeaponNames2[i] : g_sWeaponNames[i]);
	}
	g_hMenuList.SetTitle("Spawn Weapon");
	g_hMenuList.ExitBackButton = true;
}

public void OnPluginEnd()
{
	ResetPlugin();
}

public void OnMapStart()
{
	g_bMapStarted = true;

	PrecacheModel(MODEL_LOCKER);
	PrecacheModel(MODEL_LOCKER_LARGE);
	PrecacheModel(MODEL_LOCKER_SMALL);

	int max = MAX_WEAPONS;
	if( g_bLeft4Dead2 ) max = MAX_WEAPONS2;
	for( int i = 0; i < max; i++ )
	{
		PrecacheModel(g_bLeft4Dead2 ? g_sWeaponModels2[i] : g_sWeaponModels[i], true);
	}
}

public void OnMapEnd()
{
	g_bMapStarted = false;
	ResetPlugin(false);
}



// ====================================================================================================
//					CVARS
// ====================================================================================================
public void OnConfigsExecuted()
{
	IsAllowed();
}

void ConVarChanged_Allow(Handle convar, const char[] oldValue, const char[] newValue)
{
	IsAllowed();
}

void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_iCvarCount		= g_hCvarCount.IntValue;
	g_iCvarRandom		= g_hCvarRandom.IntValue;
	g_iCvarRandomise	= g_hCvarRandomise.IntValue;

	g_iAmmoRifle		= g_hAmmoRifle.IntValue;
	g_iAmmoShotgun		= g_hAmmoShotgun.IntValue;
	g_iAmmoSmg			= g_hAmmoSmg.IntValue;
	g_iAmmoHunting		= g_hAmmoHunting.IntValue;

	if( g_bLeft4Dead2 )
	{
		g_iAmmoGL			= g_hAmmoGL.IntValue;
		g_iAmmoChainsaw		= g_hAmmoChainsaw.IntValue;
		g_iAmmoAutoShot		= g_hAmmoAutoShot.IntValue;
		g_iAmmoM60			= g_hAmmoM60.IntValue;
		g_iAmmoSniper		= g_hAmmoSniper.IntValue;
	}
}

void IsAllowed()
{
	bool bCvarAllow = g_hCvarAllow.BoolValue;
	bool bAllowMode = IsAllowedGameMode();
	GetCvars();

	if( g_bCvarAllow == false && bCvarAllow == true && bAllowMode == true )
	{
		LoadSpawns();
		g_bCvarAllow = true;
		HookEvent("round_end",			Event_RoundEnd,		EventHookMode_PostNoCopy);
		HookEvent("round_start",		Event_RoundStart,	EventHookMode_PostNoCopy);
		HookEvent("player_spawn",		Event_PlayerSpawn,	EventHookMode_PostNoCopy);
	}

	else if( g_bCvarAllow == true && (bCvarAllow == false || bAllowMode == false) )
	{
		ResetPlugin();
		g_bCvarAllow = false;
		UnhookEvent("round_end",		Event_RoundEnd,		EventHookMode_PostNoCopy);
		UnhookEvent("round_start",		Event_RoundStart,	EventHookMode_PostNoCopy);
		UnhookEvent("player_spawn",		Event_PlayerSpawn,	EventHookMode_PostNoCopy);
	}
}

int g_iCurrentMode;
bool IsAllowedGameMode()
{
	if( g_hCvarMPGameMode == null )
		return false;

	int iCvarModesTog = g_hCvarModesTog.IntValue;
	if( iCvarModesTog != 0 )
	{
		if( g_bMapStarted == false )
			return false;

		g_iCurrentMode = 0;

		int entity = CreateEntityByName("info_gamemode");
		if( IsValidEntity(entity) )
		{
			DispatchSpawn(entity);
			HookSingleEntityOutput(entity, "OnCoop", OnGamemode, true);
			HookSingleEntityOutput(entity, "OnSurvival", OnGamemode, true);
			HookSingleEntityOutput(entity, "OnVersus", OnGamemode, true);
			HookSingleEntityOutput(entity, "OnScavenge", OnGamemode, true);
			ActivateEntity(entity);
			AcceptEntityInput(entity, "PostSpawnActivate");
			if( IsValidEntity(entity) ) // Because sometimes "PostSpawnActivate" seems to kill the ent.
				RemoveEdict(entity); // Because multiple plugins creating at once, avoid too many duplicate ents in the same frame
		}

		if( g_iCurrentMode == 0 )
			return false;

		if( !(iCvarModesTog & g_iCurrentMode) )
			return false;
	}

	char sGameModes[64], sGameMode[64];
	g_hCvarMPGameMode.GetString(sGameMode, sizeof(sGameMode));
	Format(sGameMode, sizeof(sGameMode), ",%s,", sGameMode);

	g_hCvarModes.GetString(sGameModes, sizeof(sGameModes));
	if( sGameModes[0] )
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if( StrContains(sGameModes, sGameMode, false) == -1 )
			return false;
	}

	g_hCvarModesOff.GetString(sGameModes, sizeof(sGameModes));
	if( sGameModes[0] )
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if( StrContains(sGameModes, sGameMode, false) != -1 )
			return false;
	}

	return true;
}

void OnGamemode(const char[] output, int caller, int activator, float delay)
{
	if( strcmp(output, "OnCoop") == 0 )
		g_iCurrentMode = 1;
	else if( strcmp(output, "OnSurvival") == 0 )
		g_iCurrentMode = 2;
	else if( strcmp(output, "OnVersus") == 0 )
		g_iCurrentMode = 4;
	else if( strcmp(output, "OnScavenge") == 0 )
		g_iCurrentMode = 8;
}



// ====================================================================================================
//					EVENTS
// ====================================================================================================
void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetPlugin(false);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if( g_iPlayerSpawn == 1 && g_iRoundStart == 0 )
		CreateTimer(1.0, TimerStart, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iRoundStart = 1;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if( g_iPlayerSpawn == 0 && g_iRoundStart == 1 )
		CreateTimer(1.0, TimerStart, _, TIMER_FLAG_NO_MAPCHANGE);
	g_iPlayerSpawn = 1;
}

Action TimerStart(Handle timer)
{
	ResetPlugin();
	LoadSpawns();
	return Plugin_Continue;
}



// ====================================================================================================
//					LOAD SPAWNS
// ====================================================================================================
void LoadSpawns()
{
	if( g_bLoaded || g_iCvarRandom == 0 ) return;
	g_bLoaded = true;

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), CONFIG_SPAWNS);
	if( !FileExists(sPath) )
		return;

	// Load config
	KeyValues hFile = new KeyValues("spawns");
	if( !hFile.ImportFromFile(sPath) )
	{
		delete hFile;
		return;
	}

	// Check for current map in the config
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	if( !hFile.JumpToKey(sMap) )
	{
		delete hFile;
		return;
	}

	// Retrieve how many weapons to display
	int iCount = hFile.GetNum("num", 0);
	if( iCount == 0 )
	{
		delete hFile;
		return;
	}

	// Spawn only a select few weapons?
	int iIndexes[MAX_SPAWNS+1];
	if( iCount > MAX_SPAWNS )
		iCount = MAX_SPAWNS;


	// Spawn saved weapons or create random
	int iRandom = g_iCvarRandom;
	if( iRandom == -1 || iRandom > iCount)
		iRandom = iCount;
	if( iRandom != -1 )
	{
		for( int i = 1; i <= iCount; i++ )
			iIndexes[i-1] = i;

		SortIntegers(iIndexes, iCount, Sort_Random);
		iCount = iRandom;
	}

	// Get the weapon origins and spawn
	char sTemp[4];
	float vPos[3], vAng[3];
	int index, iMod, iType;
	for( int i = 1; i <= iCount; i++ )
	{
		if( iRandom != -1 ) index = iIndexes[i-1];
		else index = i;

		IntToString(index, sTemp, sizeof(sTemp));

		if( hFile.JumpToKey(sTemp) )
		{
			hFile.GetVector("ang", vAng);
			hFile.GetVector("pos", vPos);
			iMod = hFile.GetNum("mod");
			iType = hFile.GetNum("type");

			if( vPos[0] == 0.0 && vPos[1] == 0.0 && vPos[2] == 0.0 ) // Should never happen...
				LogError("Error: 0,0,0 origin. Iteration=%d. Index=%d. Random=%d. Count=%d.", i, index, iRandom, iCount);
			else
				CreateSpawn(vPos, vAng, index, iMod, iType, true);
			hFile.GoBack();
		}
	}

	delete hFile;
}



// ====================================================================================================
//					CREATE SPAWN
// ====================================================================================================
void CreateSpawn(const float vOrigin[3], const float vAngles[3], int index = 0, int model = 0, int type = 0, int autospawn = false)
{
	if( g_iSpawnCount >= MAX_SPAWNS )
		return;

	int iSpawnIndex = -1;
	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		if( g_iSpawns[i][0] == 0 )
		{
			iSpawnIndex = i;
			break;
		}
	}

	if( iSpawnIndex == -1 )
		return;

	if( autospawn && g_iCvarRandomise && GetRandomInt(0, 100) <= g_iCvarRandomise )
	{
		if( g_bLeft4Dead2 )
		{
			model = GetRandomInt(0, MAX_WEAPONS2-1);

			if( model == 15 || model == 18 )		model = GetRandomInt(0, 14); // CS weapons replace
			else if( model == 19 || model == 21 )	model = GetRandomInt(22, 28);
		} else {
			model = GetRandomInt(0, MAX_WEAPONS-1);
		}
	}

	float vPos[3], vAng[3];
	int entity = CreateEntityByName("prop_dynamic_override");
	DispatchKeyValue(entity, "solid", "0");
	vPos = vOrigin;

	char classname[64];
	strcopy(classname, sizeof(classname), g_bLeft4Dead2 ? g_sWeapons2[model] : g_sWeapons[model]);

	int size = 1;
	if( type == 0 )	SetEntityModel(entity, MODEL_LOCKER);
	else
	{
		if( strcmp(classname[7], "smg") == 0 ) size = 0;
		if( strcmp(classname[7], "pistol") == 0 ) size = 0;
		if( strcmp(classname[7], "molotov") == 0 ) size = 0;
		if( strcmp(classname[7], "pipe_bomb") == 0 ) size = 0;
		if( strcmp(classname[7], "first_aid_kit") == 0 ) size = 0;
		if( strcmp(classname[7], "pain_pills") == 0 ) size = 0;

		if( g_bLeft4Dead2 )
		{
			if( strcmp(classname[7], "smg_mp5") == 0 ) size = 0;
			if( strcmp(classname[7], "pistol_magnum") == 0 ) size = 0;
			if( strcmp(classname[7], "vomitjar") == 0 ) size = 0;
			if( strcmp(classname[7], "defibrillator") == 0 ) size = 0;
			if( strcmp(classname[7], "adrenaline") == 0 ) size = 0;
			if( strcmp(classname[7], "upgradepack_explosive") == 0 ) size = 0;
			if( strcmp(classname[7], "upgradepack_incendiary") == 0 ) size = 0;
		}

		if( size == 0 )
		{
			SetEntityModel(entity, MODEL_LOCKER_SMALL);
			vPos[2] -= 5.5;
		} else {
			SetEntityModel(entity, MODEL_LOCKER_LARGE);
			vPos[2] -= 6.5;
		}
	}
	TeleportEntity(entity, vPos, vAngles, NULL_VECTOR);
	DispatchSpawn(entity);



	char sClass[64];
	strcopy(sClass, sizeof(sClass), classname);
	int iCount = g_iCvarCount;

	if( iCount != 1 )
	{
		if( model != 15 && model != 18 && model != 19 && model != 21 )
			StrCat(sClass, sizeof(sClass), "_spawn");
		else
			iCount = 1;
	}

	int entity_weapon = -1;
	entity_weapon = CreateEntityByName(sClass);
	if( entity_weapon == -1 )
		ThrowError("Failed to create entity '%s'", sClass);

	DispatchKeyValue(entity_weapon, "solid", "6");
	DispatchKeyValue(entity_weapon, "model", g_bLeft4Dead2 ? g_sWeaponModels2[model] : g_sWeaponModels[model]);
	DispatchKeyValue(entity_weapon, "rendermode", "3");
	DispatchKeyValue(entity_weapon, "disableshadows", "1");

	if( iCount <= 0 ) // Infinite
	{
		DispatchKeyValue(entity_weapon, "spawnflags", "8");
		DispatchKeyValue(entity_weapon, "count", "9999");
	}
	else if( iCount != 1 )
	{
		char sCount[5];
		IntToString(iCount, sCount, sizeof(sCount));
		DispatchKeyValue(entity_weapon, "count", sCount);
	}

	if( iCount == 1 )
		vPos = vOrigin;
	else
		vPos[2] -= 4.0;
	vAng = vAngles;
	vAng[1] += 90.0;
	vAng[2] -= 90.0;
	if( size == 1 )
		MoveSideway(vPos, vAng, vPos, -10.0);
	TeleportEntity(entity_weapon, vPos, vAng, NULL_VECTOR);
	DispatchSpawn(entity_weapon);
	CreateTimer(0.412, TimerFreeze, EntIndexToEntRef(entity_weapon));

	if( iCount == 1 )
	{
		int ammo;

		switch( model )
		{
			case 0:						ammo = g_iAmmoRifle;
			case 1:						ammo = g_iAmmoAutoShot;
			case 2:						ammo = g_iAmmoHunting;
			case 3:						ammo = g_iAmmoSmg;
			case 4:						ammo = g_iAmmoShotgun;
		}
		if( g_bLeft4Dead2 )
		{
			switch( model )
			{
				case 17, 18:			ammo = g_iAmmoSmg;
				case 11, 14, 15:		ammo = g_iAmmoRifle;
				case 10:				ammo = g_iAmmoShotgun;
				case 16:				ammo = g_iAmmoAutoShot;
				case 22:				ammo = g_iAmmoChainsaw;
				case 13:				ammo = g_iAmmoM60;
				case 12:				ammo = g_iAmmoGL;
				case 19, 20, 21:		ammo = g_iAmmoSniper;
			}
		}

		if( !g_bLeft4Dead2 && model == 1 ) ammo = g_iAmmoShotgun;

		SetEntProp(entity_weapon, Prop_Send, "m_iExtraPrimaryAmmo", ammo, 4);
	}
	// SetEntityMoveType(entity_weapon, MOVETYPE_NONE);

	g_iSpawns[iSpawnIndex][0] = EntIndexToEntRef(entity);
	g_iSpawns[iSpawnIndex][1] = EntIndexToEntRef(entity_weapon);
	g_iSpawns[iSpawnIndex][2] = index;

	g_iSpawnCount++;
}

void MoveSideway(const float vPos[3], const float vAng[3], float vReturn[3], float fDistance)
{
	float vDir[3];
	GetAngleVectors(vAng, vDir, NULL_VECTOR, NULL_VECTOR);
	vReturn = vPos;
	vReturn[0] += vDir[0] * fDistance;
	vReturn[1] += vDir[1] * fDistance;
	vReturn[2] += vDir[2] * fDistance;
}

Action TimerFreeze(Handle timer, int entity)
{
	entity = EntRefToEntIndex(entity);
	if( IsValidEntRef(entity) )
	{
		SetEntityMoveType(entity, MOVETYPE_NONE);
	}
}



// ====================================================================================================
//					COMMANDS
// ====================================================================================================
//					sm_weapon_crate
// ====================================================================================================
int ListMenuHandler(Menu menu, MenuAction action, int client, int index)
{
	if( action == MenuAction_Cancel )
	{
		if( index == MenuCancel_ExitBack )	g_hMenuType.Display(client, MENU_TIME_FOREVER);
	}
	else if( action == MenuAction_Select )
	{
		if( g_iSave[client] == 0 )
		{
			CmdSpawnerTempMenu(client, index);
		} else {
			CmdSpawnerSaveMenu(client, index);
		}

		g_hMenuList.Display(client, MENU_TIME_FOREVER);
	}

	return 0;
}

int TypeMenuHandler(Menu menu, MenuAction action, int client, int index)
{
	if( action == MenuAction_Select )
	{
		g_iType[client] = index;
		g_hMenuList.Display(client, MENU_TIME_FOREVER);
	}

	return 0;
}

Action CmdSpawnerTemp(int client, int args)
{
	if( !client )
	{
		ReplyToCommand(client, "[Weapon Crate] Command can only be used %s", IsDedicatedServer() ? "in game on a dedicated server." : "in chat on a Listen server.");
		return Plugin_Handled;
	}
	else if( g_iSpawnCount >= MAX_SPAWNS )
	{
		PrintToChat(client, "%sError: Cannot add anymore weapons. Used: (\x05%d/%d\x01).", CHAT_TAG, g_iSpawnCount, MAX_SPAWNS);
		return Plugin_Handled;
	}

	g_iSave[client] = 0;
	g_hMenuType.Display(client, MENU_TIME_FOREVER);

	return Plugin_Handled;
}

void CmdSpawnerTempMenu(int client, int weapon)
{
	if( !client )
	{
		ReplyToCommand(client, "[Weapon Crate] Command can only be used %s", IsDedicatedServer() ? "in game on a dedicated server." : "in chat on a Listen server.");
		return;
	}
	else if( g_iSpawnCount >= MAX_SPAWNS )
	{
		PrintToChat(client, "%sError: Cannot add anymore weapons. Used: (\x05%d/%d\x01).", CHAT_TAG, g_iSpawnCount, MAX_SPAWNS);
		return;
	}

	float vPos[3], vAng[3];
	if( !SetTeleportEndPoint(client, vPos, vAng) )
	{
		PrintToChat(client, "%sCannot place weapon, please try again.", CHAT_TAG);
		return;
	}

	int type = g_iType[client];
	CreateSpawn(vPos, vAng, 0, weapon, type);
	return;
}

// ====================================================================================================
//					sm_weapon_crate_save
// ====================================================================================================
Action CmdSpawnerSave(int client, int args)
{
	if( !client )
	{
		ReplyToCommand(client, "[Weapon Crate] Command can only be used %s", IsDedicatedServer() ? "in game on a dedicated server." : "in chat on a Listen server.");
		return Plugin_Handled;
	}
	else if( g_iSpawnCount >= MAX_SPAWNS )
	{
		PrintToChat(client, "%sError: Cannot add anymore weapons. Used: (\x05%d/%d\x01).", CHAT_TAG, g_iSpawnCount, MAX_SPAWNS);
		return Plugin_Handled;
	}

	g_iSave[client] = 1;
	g_hMenuType.Display(client, MENU_TIME_FOREVER);

	return Plugin_Handled;
}

void CmdSpawnerSaveMenu(int client, int weapon)
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), CONFIG_SPAWNS);
	if( !FileExists(sPath) )
	{
		File hCfg = OpenFile(sPath, "w");
		hCfg.WriteLine("");
		delete hCfg;
	}

	// Load config
	KeyValues hFile = new KeyValues("spawns");
	if( !hFile.ImportFromFile(sPath) )
	{
		PrintToChat(client, "%sError: Cannot read the weapon config, assuming empty file. (\x05%s\x01).", CHAT_TAG, sPath);
	}

	// Check for current map in the config
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	if( !hFile.JumpToKey(sMap, true) )
	{
		PrintToChat(client, "%sError: Failed to add map to weapon spawn config.", CHAT_TAG);
		delete hFile;
		return;
	}

	// Retrieve how many weapons are saved
	int iCount = hFile.GetNum("num", 0);
	if( iCount >= MAX_SPAWNS )
	{
		PrintToChat(client, "%sError: Cannot add anymore weapons. Used: (\x05%d/%d\x01).", CHAT_TAG, iCount, MAX_SPAWNS);
		delete hFile;
		return;
	}

	// Save count
	iCount++;
	hFile.SetNum("num", iCount);

	char sTemp[4];
	IntToString(iCount, sTemp, sizeof(sTemp));

	if( hFile.JumpToKey(sTemp, true) )
	{
		// Set player position as weapon spawn location
		float vPos[3], vAng[3];
		if( !SetTeleportEndPoint(client, vPos, vAng) )
		{
			PrintToChat(client, "%sCannot place weapon, please try again.", CHAT_TAG);
			delete hFile;
			return;
		}

		int type = g_iType[client];

		// Save angle / origin
		hFile.SetVector("ang", vAng);
		hFile.SetVector("pos", vPos);
		hFile.SetNum("mod", weapon);
		hFile.SetNum("type", type);

		CreateSpawn(vPos, vAng, iCount, weapon, type);

		// Save cfg
		hFile.Rewind();
		hFile.ExportToFile(sPath);

		PrintToChat(client, "%s(\x05%d/%d\x01) - Saved at pos:[\x05%f %f %f\x01] ang:[\x05%f %f %f\x01]", CHAT_TAG, iCount, MAX_SPAWNS, vPos[0], vPos[1], vPos[2], vAng[0], vAng[1], vAng[2]);
	}
	else
		PrintToChat(client, "%s(\x05%d/%d\x01) - Failed to save weapon.", CHAT_TAG, iCount, MAX_SPAWNS);

	delete hFile;
}

// ====================================================================================================
//					sm_weapon_crate_del
// ====================================================================================================
Action CmdSpawnerDel(int client, int args)
{
	if( !g_bCvarAllow )
	{
		ReplyToCommand(client, "[Weapon Crate] Plugin turned off.");
		return Plugin_Handled;
	}

	if( !client )
	{
		ReplyToCommand(client, "[Weapon Crate] Command can only be used %s", IsDedicatedServer() ? "in game on a dedicated server." : "in chat on a Listen server.");
		return Plugin_Handled;
	}

	float vAng[3]; float vPos[3]; int entity; int nearest; float dist; float near = NEAR_TO_TARGET;
	GetClientAbsOrigin(client, vPos);

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		entity = g_iSpawns[i][0];

		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vAng);
		dist = GetVectorDistance(vAng, vPos);
		if( dist < near )
		{
			near = dist;
			nearest = entity;
		}
	}

	if( nearest == 0 )
	{
		PrintToChat(client, "%sTo delete a weapon spawn you must be next to the weapon you want to delete.", CHAT_TAG);
		return Plugin_Handled;
	}

	int index = -1;

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		if( g_iSpawns[i][0] == nearest )
		{
			index = i;
			break;
		}
	}

	if( index == -1 )
	{
		PrintToChat(client, "%sCould not find the index to delete.", CHAT_TAG);
		return Plugin_Handled;
	}

	int cfgindex = g_iSpawns[index][2];
	if( cfgindex == 0 )
	{
		RemoveSpawn(index);
		PrintToChat(client, "%sRemoved a temporary Weapon Crate.", CHAT_TAG);
		return Plugin_Handled;
	}

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		if( g_iSpawns[i][2] > cfgindex )
			g_iSpawns[i][2]--;
	}

	g_iSpawnCount--;

	// Load config
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), CONFIG_SPAWNS);
	if( !FileExists(sPath) )
	{
		PrintToChat(client, "%sError: Cannot find the weapon config (\x05%s\x01).", CHAT_TAG, CONFIG_SPAWNS);
		return Plugin_Handled;
	}

	KeyValues hFile = new KeyValues("spawns");
	if( !hFile.ImportFromFile(sPath) )
	{
		PrintToChat(client, "%sError: Cannot load the weapon config (\x05%s\x01).", CHAT_TAG, sPath);
		delete hFile;
		return Plugin_Handled;
	}

	// Check for current map in the config
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	if( !hFile.JumpToKey(sMap) )
	{
		PrintToChat(client, "%sError: Current map not in the weapon config.", CHAT_TAG);
		delete hFile;
		return Plugin_Handled;
	}

	// Retrieve how many weapons
	int iCount = hFile.GetNum("num", 0);
	if( iCount == 0 )
	{
		delete hFile;
		return Plugin_Handled;
	}

	bool bMove;
	char sTemp[4];

	// Move the other entries down
	for( int i = cfgindex; i <= iCount; i++ )
	{
		IntToString(i, sTemp, sizeof(sTemp));

		if( hFile.JumpToKey(sTemp) )
		{
			if( !bMove )
			{
				bMove = true;
				hFile.DeleteThis();
				RemoveSpawn(index);
			}
			else
			{
				IntToString(i-1, sTemp, sizeof(sTemp));
				hFile.SetSectionName(sTemp);
			}
		}

		hFile.Rewind();
		hFile.JumpToKey(sMap);
	}

	if( bMove )
	{
		iCount--;
		hFile.SetNum("num", iCount);

		// Save to file
		hFile.Rewind();
		hFile.ExportToFile(sPath);

		PrintToChat(client, "%s(\x05%d/%d\x01) - weapon removed from config.", CHAT_TAG, iCount, MAX_SPAWNS);
	}
	else
		PrintToChat(client, "%s(\x05%d/%d\x01) - Failed to remove weapon from config.", CHAT_TAG, iCount, MAX_SPAWNS);

	delete hFile;
	return Plugin_Handled;
}

// ====================================================================================================
//					sm_weapon_crate_clear
// ====================================================================================================
Action CmdSpawnerClear(int client, int args)
{
	if( !client )
	{
		ReplyToCommand(client, "[Weapon Crate] Command can only be used %s", IsDedicatedServer() ? "in game on a dedicated server." : "in chat on a Listen server.");
		return Plugin_Handled;
	}

	ResetPlugin();

	PrintToChat(client, "%s(0/%d) - All weapons removed from the map.", CHAT_TAG, MAX_SPAWNS);
	return Plugin_Handled;
}

// ====================================================================================================
//					sm_weapon_crate_wipe
// ====================================================================================================
Action CmdSpawnerWipe(int client, int args)
{
	if( !client )
	{
		ReplyToCommand(client, "[Weapon Crate] Command can only be used %s", IsDedicatedServer() ? "in game on a dedicated server." : "in chat on a Listen server.");
		return Plugin_Handled;
	}

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), CONFIG_SPAWNS);
	if( !FileExists(sPath) )
	{
		PrintToChat(client, "%sError: Cannot find the weapon config (\x05%s\x01).", CHAT_TAG, sPath);
		return Plugin_Handled;
	}

	// Load config
	KeyValues hFile = new KeyValues("spawns");
	if( !hFile.ImportFromFile(sPath) )
	{
		PrintToChat(client, "%sError: Cannot load the weapon config (\x05%s\x01).", CHAT_TAG, sPath);
		delete hFile;
		return Plugin_Handled;
	}

	// Check for current map in the config
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	if( !hFile.JumpToKey(sMap, false) )
	{
		PrintToChat(client, "%sError: Current map not in the weapon config.", CHAT_TAG);
		delete hFile;
		return Plugin_Handled;
	}

	hFile.DeleteThis();
	ResetPlugin();

	// Save to file
	hFile.Rewind();
	hFile.ExportToFile(sPath);
	delete hFile;

	PrintToChat(client, "%s(0/%d) - All weapons removed from config, add with \x05sm_weapon_crate_save\x01.", CHAT_TAG, MAX_SPAWNS);
	return Plugin_Handled;
}

// ====================================================================================================
//					sm_weapon_crate_glow
// ====================================================================================================
Action CmdSpawnerGlow(int client, int args)
{
	static bool glow;
	glow = !glow;
	PrintToChat(client, "%sGlow has been turned %s", CHAT_TAG, glow ? "on" : "off");

	VendorGlow(glow);
	return Plugin_Handled;
}

void VendorGlow(int glow)
{
	int ent;

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		ent = g_iSpawns[i][0];
		if( IsValidEntRef(ent) )
		{
			SetEntProp(ent, Prop_Send, "m_iGlowType", glow ? 3 : 0);
			if( glow )
			{
				SetEntProp(ent, Prop_Send, "m_glowColorOverride", 255);
				SetEntProp(ent, Prop_Send, "m_nGlowRange", glow ? 0 : 50);
			}
		}
	}
}

// ====================================================================================================
//					sm_weapon_crate_list
// ====================================================================================================
Action CmdSpawnerList(int client, int args)
{
	float vPos[3];
	int count;
	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		if( IsValidEntRef(g_iSpawns[i][0]) )
		{
			count++;
			GetEntPropVector(g_iSpawns[i][0], Prop_Data, "m_vecOrigin", vPos);
			PrintToChat(client, "%s%d) %f %f %f", CHAT_TAG, i+1, vPos[0], vPos[1], vPos[2]);
		}
	}
	PrintToChat(client, "%sTotal: %d.", CHAT_TAG, count);
	return Plugin_Handled;
}

// ====================================================================================================
//					sm_weapon_crate_tele
// ====================================================================================================
Action CmdSpawnerTele(int client, int args)
{
	if( args == 1 )
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));
		int index = StringToInt(arg) - 1;
		if( index > -1 && index < MAX_SPAWNS && IsValidEntRef(g_iSpawns[index][0]) )
		{
			float vPos[3];
			GetEntPropVector(g_iSpawns[index][0], Prop_Data, "m_vecOrigin", vPos);
			vPos[2] += 20.0;
			TeleportEntity(client, vPos, NULL_VECTOR, NULL_VECTOR);
			PrintToChat(client, "%sTeleported to %d.", CHAT_TAG, index + 1);
			return Plugin_Handled;
		}

		PrintToChat(client, "%sCould not find index for teleportation.", CHAT_TAG);
	}
	else
		PrintToChat(client, "%sUsage: sm_weapon_crate_tele <index 1-%d>.", CHAT_TAG, MAX_SPAWNS);
	return Plugin_Handled;
}

// ====================================================================================================
//					MENU ANGLE
// ====================================================================================================
Action CmdSpawnerAng(int client, int args)
{
	ShowMenuAng(client);
	return Plugin_Handled;
}

void ShowMenuAng(int client)
{
	CreateMenus();
	g_hMenuAng.Display(client, MENU_TIME_FOREVER);
}

int AngMenuHandler(Menu menu, MenuAction action, int client, int index)
{
	if( action == MenuAction_Select )
	{
		if( index == 6 )
			SaveData(client);
		else
			SetAngle(client, index);
		ShowMenuAng(client);
	}

	return 0;
}

void SetAngle(int client, int index)
{
	// new aim = GetClientAimTarget(client, false);
	// if( aim != -1 )
	// {
		// new Float:vAng[3], entity;
		// aim = EntIndexToEntRef(aim);

	float vAng[3]; float vPos[3]; int entity; int nearest; float dist; float near = NEAR_TO_TARGET;
	GetClientAbsOrigin(client, vPos);

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		entity = g_iSpawns[i][0];

		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vAng);
		dist = GetVectorDistance(vAng, vPos);
		if( dist < near )
		{
			near = dist;
			nearest = entity;
		}
	}

	if( nearest == 0 )
	{
		PrintToChat(client, "%sTo change the weapon spawn angle you must be next to the weapon you want to affect.", CHAT_TAG);
		return;
	}

	GetEntPropVector(nearest, Prop_Send, "m_angRotation", vAng);

	switch( index )
	{
		case 0: vAng[0] += 5.0;
		case 1: vAng[1] += 5.0;
		case 2: vAng[2] += 5.0;
		case 3: vAng[0] -= 5.0;
		case 4: vAng[1] -= 5.0;
		case 5: vAng[2] -= 5.0;
	}

	TeleportEntity(nearest, NULL_VECTOR, vAng, NULL_VECTOR);

	PrintToChat(client, "%sNew angles: %f %f %f", CHAT_TAG, vAng[0], vAng[1], vAng[2]);
}

// ====================================================================================================
//					MENU ORIGIN
// ====================================================================================================
Action CmdSpawnerPos(int client, int args)
{
	ShowMenuPos(client);
	return Plugin_Handled;
}

void ShowMenuPos(int client)
{
	CreateMenus();
	g_hMenuPos.Display(client, MENU_TIME_FOREVER);
}

int PosMenuHandler(Menu menu, MenuAction action, int client, int index)
{
	if( action == MenuAction_Select )
	{
		if( index == 6 )
			SaveData(client);
		else
			SetOrigin(client, index);
		ShowMenuPos(client);
	}

	return 0;
}

void SetOrigin(int client, int index)
{
	// new aim = GetClientAimTarget(client, false);
	// if( aim != -1 )
	// {
		// new Float:vPos[3], entity;
		// aim = EntIndexToEntRef(aim);

		// for( new i = 0; i < MAX_SPAWNS; i++ )
		// {
			// entity = g_iSpawns[i][0];

			// if( entity == aim  )

	float vAng[3]; float vPos[3]; int entity; int nearest; float dist; float near = NEAR_TO_TARGET;
	GetClientAbsOrigin(client, vPos);

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		entity = g_iSpawns[i][0];

		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vAng);
		dist = GetVectorDistance(vAng, vPos);
		if( dist < near )
		{
			near = dist;
			nearest = entity;
		}
	}

	if( nearest == 0 )
	{
		PrintToChat(client, "%sTo change the weapon spawn origin you must be next to the weapon you want to affect.", CHAT_TAG);
		return;
	}

	GetEntPropVector(nearest, Prop_Send, "m_vecOrigin", vPos);

	switch( index )
	{
		case 0: vPos[0] += 0.5;
		case 1: vPos[1] += 0.5;
		case 2: vPos[2] += 0.5;
		case 3: vPos[0] -= 0.5;
		case 4: vPos[1] -= 0.5;
		case 5: vPos[2] -= 0.5;
	}

	TeleportEntity(nearest, vPos, NULL_VECTOR, NULL_VECTOR);

	PrintToChat(client, "%sNew origin: %f %f %f", CHAT_TAG, vPos[0], vPos[1], vPos[2]);
}

void SaveData(int client)
{
	// new entity, index;
	// new aim = GetClientAimTarget(client, false);
	// if( aim == -1 )
		// return;

	// aim = EntIndexToEntRef(aim);

	float vAng[3]; float vPos[3]; int entity; int nearest; float dist; float near = NEAR_TO_TARGET;
	GetClientAbsOrigin(client, vPos);

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		entity = g_iSpawns[i][0];

		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vAng);
		dist = GetVectorDistance(vAng, vPos);
		if( dist < near )
		{
			near = dist;
			nearest = entity;
		}
	}

	if( nearest == 0 )
	{
		PrintToChat(client, "%sTo delete a weapon spawn you must be next to the weapon you want to delete.", CHAT_TAG);
		return;
	}
	int index = -1;

	for( int i = 0; i < MAX_SPAWNS; i++ )
	{
		entity = g_iSpawns[i][0];

		if( entity == nearest  )
		{
			index = g_iSpawns[i][2];
			break;
		}
	}

	if( index == 0 )
		return;

	// Load config
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), CONFIG_SPAWNS);
	if( !FileExists(sPath) )
	{
		PrintToChat(client, "%sError: Cannot find the Weapon Crate config (\x05%s\x01).", CHAT_TAG, CONFIG_SPAWNS);
		return;
	}

	KeyValues hFile = new KeyValues("spawns");
	if( !hFile.ImportFromFile(sPath) )
	{
		PrintToChat(client, "%sError: Cannot load the Weapon Crate config (\x05%s\x01).", CHAT_TAG, sPath);
		delete hFile;
		return;
	}

	// Check for current map in the config
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));

	if( !hFile.JumpToKey(sMap) )
	{
		PrintToChat(client, "%sError: Current map not in the Weapon Crate config.", CHAT_TAG);
		delete hFile;
		return;
	}

	char sTemp[4];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vPos);
	GetEntPropVector(entity, Prop_Send, "m_angRotation", vAng);

	IntToString(index, sTemp, sizeof(sTemp));
	if( hFile.JumpToKey(sTemp) )
	{
		vPos[2] += 6.5;
		hFile.SetVector("ang", vAng);
		hFile.SetVector("pos", vPos);

		// Save cfg
		hFile.Rewind();
		hFile.ExportToFile(sPath);

		PrintToChat(client, "%sSaved origin and angles to the data config", CHAT_TAG);
	}
}

void CreateMenus()
{
	if( g_hMenuAng == null )
	{
		g_hMenuAng = new Menu(AngMenuHandler);
		g_hMenuAng.AddItem("", "X + 5.0");
		g_hMenuAng.AddItem("", "Y + 5.0");
		g_hMenuAng.AddItem("", "Z + 5.0");
		g_hMenuAng.AddItem("", "X - 5.0");
		g_hMenuAng.AddItem("", "Y - 5.0");
		g_hMenuAng.AddItem("", "Z - 5.0");
		g_hMenuAng.AddItem("", "SAVE");
		g_hMenuAng.SetTitle("Set Angle");
		g_hMenuAng.ExitButton = true;
	}

	if( g_hMenuPos == null )
	{
		g_hMenuPos = new Menu(PosMenuHandler);
		g_hMenuPos.AddItem("", "X + 0.5");
		g_hMenuPos.AddItem("", "Y + 0.5");
		g_hMenuPos.AddItem("", "Z + 0.5");
		g_hMenuPos.AddItem("", "X - 0.5");
		g_hMenuPos.AddItem("", "Y - 0.5");
		g_hMenuPos.AddItem("", "Z - 0.5");
		g_hMenuPos.AddItem("", "SAVE");
		g_hMenuPos.SetTitle("Set Position");
		g_hMenuPos.ExitButton = true;
	}
}



// ====================================================================================================
//					STUFF
// ====================================================================================================
bool IsValidEntRef(int entity)
{
	if( entity && EntRefToEntIndex(entity) != INVALID_ENT_REFERENCE )
		return true;
	return false;
}

void ResetPlugin(bool all = true)
{
	g_bLoaded = false;
	g_iSpawnCount = 0;
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;

	if( all )
		for( int i = 0; i < MAX_SPAWNS; i++ )
			RemoveSpawn(i);
}

void RemoveSpawn(int index)
{
	int entity, client;

	entity = g_iSpawns[index][0];
	g_iSpawns[index][0] = 0;
	if( IsValidEntRef(entity) )	RemoveEntity(entity);

	entity = g_iSpawns[index][1];
	g_iSpawns[index][1] = 0;

	if( IsValidEntRef(entity) )
	{
		client = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
		if( client < 0 || client > MaxClients || !IsClientInGame(client) )
		{
			RemoveEntity(entity);
		}
	}
}



// ====================================================================================================
//					POSITION
// ====================================================================================================
float GetGroundHeight(float vPos[3])
{
	float vAng[3];

	Handle trace = TR_TraceRayFilterEx(vPos, view_as<float>({ 90.0, 0.0, 0.0 }), MASK_ALL, RayType_Infinite, _TraceFilter);
	if( TR_DidHit(trace) )
		TR_GetEndPosition(vAng, trace);

	delete trace;
	return vAng[2];
}

// Taken from "[L4D2] Weapon/Zombie Spawner"
// By "Zuko & McFlurry"
bool SetTeleportEndPoint(int client, float vPos[3], float vAng[3])
{
	GetClientEyePosition(client, vPos);
	GetClientEyeAngles(client, vAng);

	Handle trace = TR_TraceRayFilterEx(vPos, vAng, MASK_SHOT, RayType_Infinite, _TraceFilter);

	if( TR_DidHit(trace) )
	{
		float vNorm[3];
		float degrees = vAng[1];
		TR_GetEndPosition(vPos, trace);
		GetGroundHeight(vPos);
		vPos[2] += 12.0;
		TR_GetPlaneNormal(trace, vNorm);
		GetVectorAngles(vNorm, vAng);
		if( vNorm[2] == 1.0 )
		{
			vAng[0] = 0.0;
			vAng[1] = degrees + 180;
		}
		else
		{
			if( degrees > vAng[1] )
				degrees = vAng[1] - degrees;
			else
				degrees = degrees - vAng[1];
			vAng[0] += 90.0;
			RotateYaw(vAng, degrees + 180);
		}
	}
	else
	{
		delete trace;
		return false;
	}

	delete trace;
	return true;
}

bool _TraceFilter(int entity, int contentsMask)
{
	return entity > MaxClients || !entity;
}



//---------------------------------------------------------
// do a specific rotation on the given angles
//---------------------------------------------------------
void RotateYaw(float angles[3], float degree)
{
	float direction[3], normal[3];
	GetAngleVectors( angles, direction, NULL_VECTOR, normal );

	float sin = Sine( degree * 0.01745328 );	 // Pi/180
	float cos = Cosine( degree * 0.01745328 );
	float a = normal[0] * sin;
	float b = normal[1] * sin;
	float c = normal[2] * sin;
	float x = direction[2] * b + direction[0] * cos - direction[1] * c;
	float y = direction[0] * c + direction[1] * cos - direction[2] * a;
	float z = direction[1] * a + direction[2] * cos - direction[0] * b;
	direction[0] = x;
	direction[1] = y;
	direction[2] = z;

	GetVectorAngles( direction, angles );

	float up[3];
	GetVectorVectors( direction, NULL_VECTOR, up );

	float roll = GetAngleBetweenVectors( up, normal, direction );
	angles[2] += roll;
}

//---------------------------------------------------------
// calculate the angle between 2 vectors
// the direction will be used to determine the sign of angle (right hand rule)
// all of the 3 vectors have to be normalized
//---------------------------------------------------------
float GetAngleBetweenVectors(const float vector1[3], const float vector2[3], const float direction[3])
{
	float vector1_n[3], vector2_n[3], direction_n[3], cross[3];
	NormalizeVector( direction, direction_n );
	NormalizeVector( vector1, vector1_n );
	NormalizeVector( vector2, vector2_n );
	float degree = ArcCosine( GetVectorDotProduct( vector1_n, vector2_n ) ) * 57.29577951;   // 180/Pi
	GetVectorCrossProduct( vector1_n, vector2_n, cross );

	if( GetVectorDotProduct( cross, direction_n ) < 0.0 )
		degree *= -1.0;

	return degree;
}