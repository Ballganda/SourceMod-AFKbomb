/**
	Credits :
	dalto - botdropbomb plugin for drop bomb code
	http://forums.alliedmods.net/showthread.php?p=523188

	AltPluzF4 - for sig-scanning thread which helped me correct the sdk-call crash problem in botdropbomb plugin
	http://forums.alliedmods.net/archive/index.php/t-78309.html

	AtomicStryker - for having in the past the same problem as me and posting in forums :
	http://forums.alliedmods.net/showthread.php?t=121145

	Dr!fter - for his 2nd sig-function that help me get this to work with CSS:DM
	http://forums.alliedmods.net/showthread.php?t=153765
	https://bugs.alliedmods.net/show_bug.cgi?id=4732 (his bug report)
	for 1.3.1 --> 4th & 5th argument to true --> drop bomb further (weapon restrict plugin)

	psychonic for telling me about my memory leak

	Testers : sinblaster (CSS:DM bug report)

	for 1.4.2 : Whole Sourcemod crew  --> no more need for SDKCall since SM 1.4.0; so no more gamedata needed
*/
#pragma semicolon 1
#pragma newdecls required

#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <instance_config> //settings file in this server's own SourceMod folder (not the shared game cfg folder)

#define PLUGIN_VERSION "1.5.1"

//Chat colour codes (control characters, written as escapes)
#define CHAT_DEFAULT "\x01"
#define CHAT_GREEN "\x04"

public Plugin myinfo =
{
	name = "Afk Bomb",
	author = "RedSword / Bob Le Ponge, BallGanda",
	description = "Drop the bomb if the player appears afk. Also possible to give to an active T since 1.4.0.",
	version = PLUGIN_VERSION,
	url = "http://www.sourcemod.net/"
};

//Cvars
ConVar g_afkBomb;
ConVar g_afkBomb_addFreeze;
ConVar g_afkBomb_action;

ConVar g_afkBomb_displayMsg;

ConVar g_afkBomb_lateCheckNumber; // 0 = late check disabled
ConVar g_afkBomb_lateCheckDelay; // 0 = late check disabled
ConVar g_afkBomb_lateCheckAction; //since 1.5; 1=drop, 0=give to an active T

//Check-generation token : advanced at round start and when the bomb is planted; a pending check that carries an older value is dropped
//Avoid a possible (rare) glitch where the same player would spawn with the bomb at the same place with a high CVar "afkbomb" value
static int g_checkGeneration = 0;

//State snapshot of every living terrorist, taken when freezetime ends (no per-tick hook)
//A later comparison with the current state tells whether the player did anything in between
int g_snapUserId[ MAXPLAYERS + 1 ]; //0 = no snapshot; userid prevents a new player taking a leaver's slot
int g_snapMoney[ MAXPLAYERS + 1 ];
int g_snapArmor[ MAXPLAYERS + 1 ];
int g_snapButtons[ MAXPLAYERS + 1 ];
int g_snapGuns[ MAXPLAYERS + 1 ][ CS_SLOT_C4 + 1 ]; // GetPlayerWeaponSlot(), slots 0 to CS_SLOT_C4
float g_snapEye[ MAXPLAYERS + 1 ][ 3 ]; // GetClientEyeAngles()
float g_snapAngle[ MAXPLAYERS + 1 ][ 3 ]; // GetClientAbsAngles()
float g_snapOrigin[ MAXPLAYERS + 1 ][ 3 ]; // GetClientAbsOrigin()
float g_snapVelocity[ MAXPLAYERS + 1 ][ 3 ]; // GetEntPropVector()

//Afk = result of the latest comparison : true = unchanged since the snapshot
//Every comparison re-judges every snapshotted terrorist. While afk : never a receiver, and cannot pick up the bomb
//(cleared at round start, at a comparison that finds the player changed, or when the player touches the bomb
//in a state different from the snapshot)
bool g_isAfk[ MAXPLAYERS + 1 ];

//Decided once at round start : is this round checked ? (a later change of afkbomb does not start a check)
//afkbomb 0 ends the round's checks for good (OnAfkBombChanged) : raising it again only counts from the next round
bool g_roundChecked;

//Only msg once for dropping bomb
bool g_shouldMsgBombDrop;

//If the first drop si the next one(to change delay things)
bool g_firstBombDrop;

//To count the number of check done for lateCheck
int g_lateCheckCount;

public void OnPluginStart()
{
	//CVARs
	CreateConVar( "afkbombversion", PLUGIN_VERSION, "Afk Bomb version", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_DONTRECORD );

	g_afkBomb = CreateConVar( "afkbomb", "2", "How long after freezetime ends before the afk drops the bomb, in seconds. 0 = disabled, 1+ = enabled. Def. 2.",
		FCVAR_NOTIFY, true, 0.0 );
	g_afkBomb_addFreeze = CreateConVar( "afkbomb_freezetime", "0", "DEPRECATED since 1.5.1, ignored : checks now always start when freezetime ends. Def. 0.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0 );
	g_afkBomb_action = CreateConVar( "afkbomb_action", "0",
	"What to do when someone is considered afk at the beginning of a round. 1=Drop. 0=Give to an active teammate (dropped if there is none). Def. 0.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0 );

	g_afkBomb_displayMsg = CreateConVar( "afkbomb_msg", "1",
		"Notify team when bomb is dropped (action or latecheckaction = 1) / Notify everyone when bomb is given to an active terrorist (action or latecheckaction = 0). 0 = no, 1 = yes. Def. 1.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0 );

	g_afkBomb_lateCheckNumber = CreateConVar( "afkbomb_latecheck", "2", "Number of latechecks to do before dropping the bomb. 0 = disabled. Def. 2.",
		FCVAR_NOTIFY, true, 0.0 );
	g_afkBomb_lateCheckDelay = CreateConVar( "afkbomb_latecheckdelay", "5.0", "Time between 2 latechecks to drop the bomb, in seconds. Min. 1. Def. 5.",
		FCVAR_NOTIFY, true, 1.0 );
	g_afkBomb_lateCheckAction = CreateConVar( "afkbomb_latecheckaction", "1",
	"What to do when someone is considered afk after the beginning of a round. 1=Drop. 0=Give to an active teammate, dropped if there is none (not recommended since it could be exploited). Def. 1.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0 );

	//Settings file : every cvar but the version one (applied in OnConfigsExecuted)
	InstCfg_Add( g_afkBomb );
	InstCfg_Add( g_afkBomb_addFreeze, true ); //deprecated
	InstCfg_Add( g_afkBomb_action );
	InstCfg_Add( g_afkBomb_displayMsg );
	InstCfg_Add( g_afkBomb_lateCheckNumber );
	InstCfg_Add( g_afkBomb_lateCheckDelay );
	InstCfg_Add( g_afkBomb_lateCheckAction );
	InstCfg_Ensure();

	//afkbomb 0 cancels the running checks at once, not only when their timer fires
	g_afkBomb.AddChangeHook( OnAfkBombChanged );

	//Hooks on events
	HookEvent( "round_start", Event_RoundStart );
	HookEvent( "round_freeze_end", Event_FreezeEnd ); //Players are judged only from here on
	HookEvent( "bomb_planted", Event_BombPlanted ); //Nothing left to guard : checks stop for the rest of the round

	//Translation file
	LoadTranslations( "afkbomb.phrases" );

	//Players already connected when the plugin loads late
	for ( int i = 1; i <= MaxClients; ++i )
		if ( IsClientInGame( i ) )
			SDKHook( i, SDKHook_WeaponCanUse, OnWeaponCanUse );
}

//Every map : the settings file wins over whatever was set before
public void OnConfigsExecuted()
{
	InstCfg_Apply();
}

//afkbomb set to 0 : every pending check of this round is dropped and the round stays unchecked,
//so setting it back to a positive value takes effect from the next round only
public void OnAfkBombChanged( ConVar convar, const char[] oldValue, const char[] newValue )
{
	if ( convar.IntValue < 1 )
	{
		++g_checkGeneration;
		g_roundChecked = false;
	}
}

public void OnClientPutInServer( int client )
{
	SDKHook( client, SDKHook_WeaponCanUse, OnWeaponCanUse );
}

public void OnClientDisconnect( int client )
{
	g_snapUserId[ client ] = 0;
	g_isAfk[ client ] = false;
}

//A player judged afk cannot collect the bomb; the state is compared again at the touch,
//so as soon as the player showed any activity the pickup goes through
public Action OnWeaponCanUse( int client, int weapon )
{
	if ( !g_isAfk[ client ] )
		return Plugin_Continue;

	char sClassName[ 32 ];
	GetEdictClassname( weapon, sClassName, sizeof(sClassName) );
	if ( !StrEqual( sClassName, "weapon_c4", false ) )
		return Plugin_Continue;

	//The bomb itself is not activity : the snapshot may hold it while it lies on the ground now
	if ( sameState( client, true ) )
		return Plugin_Handled;

	g_isAfk[ client ] = false;
	return Plugin_Continue;
}

public void Event_RoundStart( Event event, const char[] name, bool dontBroadcast )
{
	//Whatever afkbomb is : the previous round's checks end and the afk judgements (and so the pickup block) end with the round
	++g_checkGeneration; //Invalidates every check of the previous round
	g_firstBombDrop = true;
	ClearSnapshots();
	g_roundChecked = ( g_afkBomb.IntValue >= 1 );
}

//Bomb planted : advancing the check-generation token invalidates every pending check of this round (the next round_start advances it again)
public void Event_BombPlanted( Event event, const char[] name, bool dontBroadcast )
{
	++g_checkGeneration;
}

//Freezetime is over : players can act now, so this is where the judged period starts
public void Event_FreezeEnd( Event event, const char[] name, bool dontBroadcast )
{
	if ( g_roundChecked && g_afkBomb.IntValue >= 1 )
		CheckForBomber( null, g_checkGeneration );
}

//Check who has the bomb; Needs to be delayed to work
public Action CheckForBomber( Handle timer, any checkGeneration )
{
	//Avoid 2 timers identical
	if ( checkGeneration != g_checkGeneration )
		return Plugin_Continue;

	//afkbomb 0 cancels every scheduled check
	if ( g_afkBomb.IntValue < 1 )
		return Plugin_Continue;

	//If we're to look for the bomber, that means he's not found yet and that he won't repeat his speech
	g_shouldMsgBombDrop = true;
	g_lateCheckCount = 0;

	for ( int i = MaxClients; i >= 1; --i )
	{
		if ( IsClientInGame( i ) &&
				IsPlayerAlive( i ) &&
				GetPlayerWeaponSlot( i, CS_SLOT_C4 ) != -1 ) //if the player is carrying the bomb
		{
			FirstScan( i );
			return Plugin_Continue; //We found the bomber, no need to rerun the function
		}
	}

	//We rerun the function if not found
	ScheduleNextBomberSearch( checkGeneration );
	return Plugin_Continue;
}

//Schedule the next search for a bomber, one late-check delay from now (only if we want to lateCheck)
void ScheduleNextBomberSearch( int checkGeneration )
{
	if ( g_afkBomb_lateCheckNumber.IntValue > 0 )
	{
		g_firstBombDrop = false;
		CreateTimer( g_afkBomb_lateCheckDelay.FloatValue, CheckForBomber, checkGeneration, TIMER_FLAG_NO_MAPCHANGE );
	}
}

//Record bomber initial state
void FirstScan( int iBomber )
{
	if ( g_afkBomb.IntValue >= 1 )
	{
		//We consider that by default, we're late-checking
		float timeUntilScan = g_afkBomb_lateCheckDelay.FloatValue;

		if ( g_firstBombDrop ) //If we're not late-checking
			timeUntilScan = g_afkBomb.FloatValue;

		SnapshotAll(); //Save the state of every living terrorist

		DataPack bombUserIdAndCheckGenerationData; //CreateDataPack() not needed !!
		CreateDataTimer( timeUntilScan, SecondScan, bombUserIdAndCheckGenerationData, TIMER_FLAG_NO_MAPCHANGE );
		bombUserIdAndCheckGenerationData.WriteCell( GetClientUserId( iBomber ) );
		bombUserIdAndCheckGenerationData.WriteCell( g_checkGeneration );
	}
}

//Check if bomber's state changed
public Action SecondScan( Handle timer, DataPack bombUserIdAndCheckGenerationData ) //UserId used to prevent a possible problem if someone would leave and take bomber's "state" within 0.5 sec (lol)
{
	//Using the pack right now so it's cleaner to read the rest of the code
	bombUserIdAndCheckGenerationData.Reset();
	int bomberUserId = bombUserIdAndCheckGenerationData.ReadCell();
	int checkGeneration = bombUserIdAndCheckGenerationData.ReadCell();

	float lateCheckDelay = g_afkBomb_lateCheckDelay.FloatValue;

	int iBomber = GetClientOfUserId( bomberUserId );

	//afkbomb 0 cancels the check in progress : nothing is judged, dropped or rescheduled
	if ( g_checkGeneration == checkGeneration && //If no round start or bomb plant happened since the check was scheduled
			g_afkBomb.IntValue >= 1 )
	{
		CompareAll(); //Judge every snapshotted terrorist in one go

		if ( iBomber != 0 && //Prevent a disconnecting player between first & second scan
				IsClientInGame( iBomber ) &&
				IsPlayerAlive( iBomber ) &&
				g_isAfk[ iBomber ] ) //state unchanged ?
		{
			if ( g_firstBombDrop || ++g_lateCheckCount >= g_afkBomb_lateCheckNumber.IntValue )
			{
				//Give to the best active teammate if the action says so; otherwise (or if nobody qualifies) drop
				if ( ( ( g_firstBombDrop && g_afkBomb_action.IntValue == 0 ) ||
						( !g_firstBombDrop && g_afkBomb_lateCheckAction.IntValue == 0 ) ) &&
						stripAndGive2ActiveTBomb( iBomber ) ) //The function takes care of its own verbose
				{
					CheckForBomber( null, checkGeneration ); //lets start next check right now
					return Plugin_Continue; //no latecheck problem are possible so
				}

				TakeBomb( iBomber, true );

				if ( g_shouldMsgBombDrop ) //Do not repeat !
				{
					if ( g_afkBomb_displayMsg.IntValue == 1 )
					{
						//Server language, not the speaker's
						char sDropMsg[ 192 ];
						Format( sDropMsg, sizeof(sDropMsg), "%T", "Drop Bomb", LANG_SERVER );
						FakeClientCommand( iBomber, "say_team [Afk Bomb] %s", sDropMsg );
					}
					g_shouldMsgBombDrop = false;
				}

				//The afk player cannot pick the bomb up again (OnWeaponCanUse) : no re-drop needed, look for a new bomber if we want to lateCheck
				ScheduleNextBomberSearch( checkGeneration );
				return Plugin_Continue;
			}
			//If we're latechecking, we must relaunch timer if the bomber is in the same state
			//Every interval is judged on its own : a new snapshot of every living terrorist starts it
			SnapshotAll();
			//Reusing the datapack
			CreateDataTimer( lateCheckDelay, SecondScan, bombUserIdAndCheckGenerationData, TIMER_FLAG_NO_MAPCHANGE );
			bombUserIdAndCheckGenerationData.WriteCell( GetClientUserId( iBomber ) );
			bombUserIdAndCheckGenerationData.WriteCell( checkGeneration );
		}
		else //if bomber is lost, find him again (if we want to lateCheck)
		{
			ScheduleNextBomberSearch( checkGeneration );
		}
	}
	return Plugin_Continue;
}

//========== Privates ===========

//===== 1fct
//Give the bomb to the best receiver : alive T other than the old bomber, active in the latest comparison
//Order : humans before bots, then moving before stationary, then smallest distance to the old bomber
//return false (and leave the bomb alone) if nobody qualifies
bool stripAndGive2ActiveTBomb( int iOldBomber )
{
	int iEntIndex = GetPlayerWeaponSlot( iOldBomber, CS_SLOT_C4 );
	if ( iEntIndex == -1 )
		return false;

	//1- Find the best receiver
	float oldPos[ 3 ];
	GetClientAbsOrigin( iOldBomber, oldPos );

	int best = 0;
	bool bestHuman;
	bool bestMoving;
	float bestDist;

	for ( int i = 1; i <= MaxClients; ++i )
	{
		if ( i == iOldBomber ||
				!IsClientInGame( i ) ||
				GetClientTeam( i ) != CS_TEAM_T ||
				!IsPlayerAlive( i ) ||
				g_snapUserId[ i ] != GetClientUserId( i ) || //has to have been compared
				g_isAfk[ i ] )
			continue;

		float pos[ 3 ];
		float velocity[ 3 ];
		GetClientAbsOrigin( i, pos );
		GetEntPropVector( i, Prop_Data, "m_vecVelocity", velocity );

		bool human = !IsFakeClient( i );
		bool moving = GetVectorLength( velocity ) != 0.0;
		float dist = GetVectorDistance( oldPos, pos );

		if ( best == 0 ||
				( human != bestHuman ? human :
					( moving != bestMoving ? moving : dist < bestDist ) ) )
		{
			best = i;
			bestHuman = human;
			bestMoving = moving;
			bestDist = dist;
		}
	}

	if ( best == 0 )
		return false;

	//2- Strip c4
	TakeBomb( iOldBomber, false );

	//3- Give
	GivePlayerItem( best, "weapon_c4" );

	//4- Verbose
	if ( g_afkBomb_displayMsg.IntValue == 1 )
	{
		//Server language for everyone, one message
		char sGiveMsg[ 256 ];
		Format( sGiveMsg, sizeof(sGiveMsg), "%T", "StripNGive Bomb", LANG_SERVER, CHAT_GREEN, iOldBomber, CHAT_DEFAULT );
		PrintToChatAll( "%s[SM] %s%s", CHAT_GREEN, CHAT_DEFAULT, sGiveMsg );
	}

	return true;
}

//The one place the bomb is taken from a player : bDrop = true drops it to the ground, false removes it (to be given away)
//A bomb that was in hand is replaced by the best weapon, so the hands are never empty; otherwise the weapon in hand stays
void TakeBomb( int iClient, bool bDrop )
{
	int iBomb = GetPlayerWeaponSlot( iClient, CS_SLOT_C4 );
	if ( iBomb == -1 )
		return;

	bool bInHand = ( GetEntPropEnt( iClient, Prop_Send, "m_hActiveWeapon" ) == iBomb );

	if ( bDrop )
	{
		CS_DropWeapon( iClient, iBomb, true, true );
	}
	else
	{
		RemovePlayerItem( iClient, iBomb );
		AcceptEntityInput( iBomb, "kill" );
	}

	if ( bInHand )
		SwitchToBestWeapon( iClient );
}

//Put the first owned weapon of slot 0 (primary), 1 (secondary), 2 (knife) in hand
//Through the game's own weapon switch (the "use" client command, run by the server), so the client's view model follows
void SwitchToBestWeapon( int iClient )
{
	for ( int iSlot = CS_SLOT_PRIMARY; iSlot <= CS_SLOT_KNIFE; ++iSlot )
	{
		int iWeapon = GetPlayerWeaponSlot( iClient, iSlot );
		if ( iWeapon != -1 )
		{
			char sClassName[ 32 ];
			GetEdictClassname( iWeapon, sClassName, sizeof(sClassName) );
			FakeClientCommand( iClient, "use %s", sClassName );
			return;
		}
	}
}

//=====State-related

void ClearSnapshots()
{
	for ( int i = 1; i <= MaxClients; ++i )
	{
		g_snapUserId[ i ] = 0;
		g_isAfk[ i ] = false;
	}
}

//Record the state of every living terrorist (the afk judgement stays until the next comparison)
void SnapshotAll()
{
	for ( int i = 1; i <= MaxClients; ++i )
	{
		g_snapUserId[ i ] = 0;

		if ( IsClientInGame( i ) && GetClientTeam( i ) == CS_TEAM_T && IsPlayerAlive( i ) )
		{
			g_snapUserId[ i ] = GetClientUserId( i );
			g_snapMoney[ i ] = GetEntProp( i, Prop_Send, "m_iAccount" );
			g_snapArmor[ i ] = GetClientArmor( i );
			g_snapButtons[ i ] = GetClientButtons( i );

			for ( int j = CS_SLOT_C4; j >= CS_SLOT_PRIMARY; --j )
				g_snapGuns[ i ][ j ] = GetPlayerWeaponSlot( i, j );

			GetClientEyeAngles( i, g_snapEye[ i ] );
			GetClientAbsAngles( i, g_snapAngle[ i ] );
			GetClientAbsOrigin( i, g_snapOrigin[ i ] );
			GetEntPropVector( i, Prop_Data, "m_vecVelocity", g_snapVelocity[ i ] );
		}
	}
}

//Re-judge every snapshotted terrorist : afk if unchanged since its snapshot, otherwise active again
void CompareAll()
{
	for ( int i = 1; i <= MaxClients; ++i )
		g_isAfk[ i ] = ( g_snapUserId[ i ] != 0 && sameState( i ) );
}

//true if the client is exactly in the state of its snapshot (nothing done since)
bool sameState( int iClient, bool ignoreBomb = false )
{
	if ( !IsClientInGame( iClient ) || !IsPlayerAlive( iClient ) || g_snapUserId[ iClient ] != GetClientUserId( iClient ) )
		return false;

	if ( g_snapMoney[ iClient ] != GetEntProp( iClient, Prop_Send, "m_iAccount" ) ||
			g_snapArmor[ iClient ] != GetClientArmor( iClient ) ||
			g_snapButtons[ iClient ] != GetClientButtons( iClient ) )
		return false;

	//Guns
	for ( int i = ignoreBomb ? CS_SLOT_C4 - 1 : CS_SLOT_C4; i >= CS_SLOT_PRIMARY; --i )
		if ( g_snapGuns[ iClient ][ i ] != GetPlayerWeaponSlot( iClient, i ) )
			return false;

	//Vectors
	float eyeVec[ 3 ];
	float absAngVec[ 3 ];
	float absOriVec[ 3 ];
	float absVloVec[ 3 ];
	GetClientEyeAngles( iClient, eyeVec );
	GetClientAbsAngles( iClient, absAngVec );
	GetClientAbsOrigin( iClient, absOriVec );
	GetEntPropVector( iClient, Prop_Data, "m_vecVelocity", absVloVec );

	for ( int i = 2; i >= 0; --i )
		if ( eyeVec[ i ] != g_snapEye[ iClient ][ i ] ||
				absAngVec[ i ] != g_snapAngle[ iClient ][ i ] ||
				absOriVec[ i ] != g_snapOrigin[ iClient ][ i ] ||
				absVloVec[ i ] != g_snapVelocity[ iClient ][ i ] )
			return false;

	return true;
}
