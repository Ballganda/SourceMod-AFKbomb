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

#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <instance_config> //settings file in this server's own SourceMod folder (not the shared game cfg folder)

#define PLUGIN_VERSION "1.5.1"

//Chat colour codes (control characters, written as escapes)
#define CHAT_DEFAULT "\x01"
#define CHAT_GREEN "\x04"

public Plugin:myinfo =
{
	name = "Afk Bomb",
	author = "RedSword / Bob Le Ponge, BallGanda",
	description = "Drop the bomb if the player appears afk. Also possible to give to an active T since 1.4.0.",
	version = PLUGIN_VERSION,
	url = "http://www.sourcemod.net/"
};

//Cvars
new Handle:g_afkBomb;
new Handle:g_afkBomb_addFreeze;
new Handle:g_afkBomb_action;

new Handle:g_afkBomb_displayMsg;

new Handle:g_afkBomb_lateCheckNumber; // 0 = late check disabled
new Handle:g_afkBomb_lateCheckDelay; // 0 = late check disabled
new Handle:g_afkBomb_lateCheckAction; //since 1.5; 1=drop, 0=give to an active T

//Check-generation token : advanced at round start and when the bomb is planted; a pending check that carries an older value is dropped
//Avoid a possible (rare) glitch where the same player would spawn with the bomb at the same place with a high CVar "afkbomb" value
static g_checkGeneration = 0;

//State snapshot of every living terrorist, taken when freezetime ends (no per-tick hook)
//A later comparison with the current state tells whether the player did anything in between
new g_snapUserId[ MAXPLAYERS + 1 ]; //0 = no snapshot; userid prevents a new player taking a leaver's slot
new g_snapMoney[ MAXPLAYERS + 1 ];
new g_snapArmor[ MAXPLAYERS + 1 ];
new g_snapButtons[ MAXPLAYERS + 1 ];
new g_snapGuns[ MAXPLAYERS + 1 ][ CS_SLOT_C4 + 1 ]; // GetPlayerWeaponSlot(), slots 0 to CS_SLOT_C4
new Float:g_snapEye[ MAXPLAYERS + 1 ][ 3 ]; // GetClientEyeAngles()
new Float:g_snapAngle[ MAXPLAYERS + 1 ][ 3 ]; // GetClientAbsAngles()
new Float:g_snapOrigin[ MAXPLAYERS + 1 ][ 3 ]; // GetClientAbsOrigin()
new Float:g_snapVelocity[ MAXPLAYERS + 1 ][ 3 ]; // GetEntPropVector()

//Afk = result of the latest comparison : true = unchanged since the snapshot
//Every comparison re-judges every snapshotted terrorist. While afk : never a receiver, and cannot pick up the bomb
//(cleared at round start, at a comparison that finds the player changed, or when the player touches the bomb
//in a state different from the snapshot)
new bool:g_isAfk[ MAXPLAYERS + 1 ];

//Decided once at round start : is this round checked ? (a later change of afkbomb does not start a check)
//afkbomb 0 ends the round's checks for good (OnAfkBombChanged) : raising it again only counts from the next round
new bool:g_roundChecked;

//Prevent re-running a function
new g_iAccount;

//Only msg once for dropping bomb
new bool:g_shouldMsgBombDrop;

//If the first drop si the next one(to change delay things)
new bool:g_firstBombDrop;

//To count the number of check done for lateCheck
new g_lateCheckCount;

public OnPluginStart()
{
	//CVARs
	CreateConVar( "afkbombversion", PLUGIN_VERSION, "Afk Bomb version", FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_DONTRECORD );

	g_afkBomb = CreateConVar( "afkbomb", "2", "How long after freezetime ends before the afk drops the bomb, in seconds. 0 = disabled, 1+ = enabled. Def. 2.",
		FCVAR_PLUGIN | FCVAR_NOTIFY, true, 0.0 );
	g_afkBomb_addFreeze = CreateConVar( "afkbomb_freezetime", "0", "DEPRECATED since 1.5.1, ignored : checks now always start when freezetime ends. Def. 0.",
		FCVAR_PLUGIN | FCVAR_NOTIFY, true, 0.0, true, 1.0 );
	g_afkBomb_action = CreateConVar( "afkbomb_action", "0",
	"What to do when someone is considered afk at the beginning of a round. 1=Drop. 0=Give to an active teammate (dropped if there is none). Def. 0.",
		FCVAR_PLUGIN | FCVAR_NOTIFY, true, 0.0, true, 1.0 );

	g_afkBomb_displayMsg = CreateConVar( "afkbomb_msg", "1",
		"Notify team when bomb is dropped (action or latecheckaction = 1) / Notify everyone when bomb is given to an active terrorist (action or latecheckaction = 0). 0 = no, 1 = yes. Def. 1.",
		FCVAR_PLUGIN | FCVAR_NOTIFY, true, 0.0, true, 1.0 );

	g_afkBomb_lateCheckNumber = CreateConVar( "afkbomb_latecheck", "2", "Number of latechecks to do before dropping the bomb. 0 = disabled. Def. 2.",
		FCVAR_PLUGIN | FCVAR_NOTIFY, true, 0.0 );
	g_afkBomb_lateCheckDelay = CreateConVar( "afkbomb_latecheckdelay", "5.0", "Time between 2 latechecks to drop the bomb, in seconds. Min. 1. Def. 5.",
		FCVAR_PLUGIN | FCVAR_NOTIFY, true, 1.0 );
	g_afkBomb_lateCheckAction = CreateConVar( "afkbomb_latecheckaction", "1",
	"What to do when someone is considered afk after the beginning of a round. 1=Drop. 0=Give to an active teammate, dropped if there is none (not recommended since it could be exploited). Def. 1.",
		FCVAR_PLUGIN | FCVAR_NOTIFY, true, 0.0, true, 1.0 );

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
	HookConVarChange( g_afkBomb, OnAfkBombChanged );

	//Hooks on events
	HookEvent( "round_start", Event_RoundStart );
	HookEvent( "round_freeze_end", Event_FreezeEnd ); //Players are judged only from here on
	HookEvent( "bomb_planted", Event_BombPlanted ); //Nothing left to guard : checks stop for the rest of the round

	//Translation file
	LoadTranslations( "afkbomb.phrases" );

	//Prevent re-running a function
	g_iAccount = FindSendPropOffs( "CCSPlayer", "m_iAccount" );

	//Players already connected when the plugin loads late
	for ( new i = 1; i <= MaxClients; ++i )
		if ( IsClientInGame( i ) )
			SDKHook( i, SDKHook_WeaponCanUse, OnWeaponCanUse );
}

//Every map : the settings file wins over whatever was set before
public OnConfigsExecuted()
{
	InstCfg_Apply();
}

//afkbomb set to 0 : every pending check of this round is dropped and the round stays unchecked,
//so setting it back to a positive value takes effect from the next round only
public OnAfkBombChanged( Handle:convar, const String:oldValue[], const String:newValue[] )
{
	if ( GetConVarInt( convar ) < 1 )
	{
		++g_checkGeneration;
		g_roundChecked = false;
	}
}

public OnClientPutInServer( client )
{
	SDKHook( client, SDKHook_WeaponCanUse, OnWeaponCanUse );
}

public OnClientDisconnect( client )
{
	g_snapUserId[ client ] = 0;
	g_isAfk[ client ] = false;
}

//A player judged afk cannot collect the bomb; the state is compared again at the touch,
//so as soon as the player showed any activity the pickup goes through
public Action:OnWeaponCanUse( client, weapon )
{
	if ( !g_isAfk[ client ] )
		return Plugin_Continue;

	decl String:sClassName[ 32 ];
	GetEdictClassname( weapon, sClassName, sizeof(sClassName) );
	if ( !StrEqual( sClassName, "weapon_c4", false ) )
		return Plugin_Continue;

	//The bomb itself is not activity : the snapshot may hold it while it lies on the ground now
	if ( sameState( client, true ) )
		return Plugin_Handled;

	g_isAfk[ client ] = false;
	return Plugin_Continue;
}

public Event_RoundStart( Handle:event, const String:name[], bool:dontBroadcast )
{
	//Whatever afkbomb is : the previous round's checks end and the afk judgements (and so the pickup block) end with the round
	++g_checkGeneration; //Invalidates every check of the previous round
	g_firstBombDrop = true;
	ClearSnapshots();
	g_roundChecked = ( GetConVarInt( g_afkBomb ) >= 1 );

	return bool:Plugin_Handled;
}

//Bomb planted : advancing the check-generation token invalidates every pending check of this round (the next round_start advances it again)
public Event_BombPlanted( Handle:event, const String:name[], bool:dontBroadcast )
{
	++g_checkGeneration;
}

//Freezetime is over : players can act now, so this is where the judged period starts
public Event_FreezeEnd( Handle:event, const String:name[], bool:dontBroadcast )
{
	if ( g_roundChecked && GetConVarInt( g_afkBomb ) >= 1 )
		CheckForBomber( INVALID_HANDLE, g_checkGeneration );
}

//Check who has the bomb; Needs to be delayed to work
public Action:CheckForBomber( Handle:timer, any:checkGeneration )
{
	//Avoid 2 timers identical
	if ( checkGeneration != g_checkGeneration )
		return;

	//afkbomb 0 cancels every scheduled check
	if ( GetConVarInt( g_afkBomb ) < 1 )
		return;

	//If we're to look for the bomber, that means he's not found yet and that he won't repeat his speech
	g_shouldMsgBombDrop = true;
	g_lateCheckCount = 0;

	for ( new i = MaxClients; i >= 1; --i )
	{
		if ( IsClientInGame( i ) &&
				IsPlayerAlive( i ) &&
				GetPlayerWeaponSlot( i, CS_SLOT_C4 ) != -1 ) //if the player is carrying the bomb
		{
			FirstScan( i );
			return; //We found the bomber, no need to rerun the function
		}
	}

	//We rerun the function if not found
	ScheduleNextBomberSearch( checkGeneration );
}

//Schedule the next search for a bomber, one late-check delay from now (only if we want to lateCheck)
ScheduleNextBomberSearch( any:checkGeneration )
{
	if ( GetConVarInt( g_afkBomb_lateCheckNumber ) > 0 )
	{
		g_firstBombDrop = false;
		CreateTimer( GetConVarFloat( g_afkBomb_lateCheckDelay ), CheckForBomber, checkGeneration, TIMER_FLAG_NO_MAPCHANGE );
	}
}

//Record bomber initial state
Action:FirstScan( any:iBomber )
{
	if ( GetConVarInt( g_afkBomb ) >= 1 )
	{
		//We consider that by default, we're late-checking
		new Float:timeUntilScan = GetConVarFloat( g_afkBomb_lateCheckDelay );

		if ( g_firstBombDrop ) //If we're not late-checking
			timeUntilScan = GetConVarFloat( g_afkBomb );

		SnapshotAll(); //Save the state of every living terrorist

		new Handle:bombUserIdAndCheckGenerationData; //CreateDataPack() not needed !!
		CreateDataTimer( timeUntilScan, SecondScan, Handle:bombUserIdAndCheckGenerationData, TIMER_FLAG_NO_MAPCHANGE );
		WritePackCell( bombUserIdAndCheckGenerationData, GetClientUserId( iBomber ) );
		WritePackCell( bombUserIdAndCheckGenerationData, g_checkGeneration );
	}
}

//Check if bomber's state changed
public Action:SecondScan( Handle:timer, Handle:bombUserIdAndCheckGenerationData ) //UserId used to prevent a possible problem if someone would leave and take bomber's "state" within 0.5 sec (lol)
{
	//Using the pack right now so it's cleaner to read the rest of the code
	ResetPack( bombUserIdAndCheckGenerationData );
	new bomberUserId = ReadPackCell( bombUserIdAndCheckGenerationData );
	new checkGeneration = ReadPackCell( bombUserIdAndCheckGenerationData );

	new Float:lateCheckDelay = GetConVarFloat( g_afkBomb_lateCheckDelay );

	new iBomber = GetClientOfUserId( bomberUserId );

	//afkbomb 0 cancels the check in progress : nothing is judged, dropped or rescheduled
	if ( g_checkGeneration == checkGeneration && //If no round start or bomb plant happened since the check was scheduled
			GetConVarInt( g_afkBomb ) >= 1 )
	{
		CompareAll(); //Judge every snapshotted terrorist in one go

		if ( iBomber != 0 && //Prevent a disconnecting player between first & second scan
				IsClientInGame( iBomber ) &&
				IsPlayerAlive( iBomber ) &&
				g_isAfk[ iBomber ] ) //state unchanged ?
		{
			if ( g_firstBombDrop || ++g_lateCheckCount >= GetConVarInt( g_afkBomb_lateCheckNumber ) )
			{
				//Give to the best active teammate if the action says so; otherwise (or if nobody qualifies) drop
				if ( ( ( g_firstBombDrop && GetConVarInt( g_afkBomb_action ) == 0 ) ||
						( !g_firstBombDrop && GetConVarInt( g_afkBomb_lateCheckAction ) == 0 ) ) &&
						stripAndGive2ActiveTBomb( iBomber ) ) //The function takes care of its own verbose
				{
					CheckForBomber( INVALID_HANDLE, checkGeneration ); //lets start next check right now
					return; //no latecheck problem are possible so
				}

				TakeBomb( iBomber, true );

				if ( g_shouldMsgBombDrop ) //Do not repeat !
				{
					if ( GetConVarInt( g_afkBomb_displayMsg ) == 1 )
					{
						//Server language, not the speaker's
						decl String:sDropMsg[ 192 ];
						Format( sDropMsg, sizeof(sDropMsg), "%T", "Drop Bomb", LANG_SERVER );
						FakeClientCommand( iBomber, "say_team [Afk Bomb] %s", sDropMsg );
					}
					g_shouldMsgBombDrop = false;
				}

				//The afk player cannot pick the bomb up again (OnWeaponCanUse) : no re-drop needed, look for a new bomber if we want to lateCheck
				ScheduleNextBomberSearch( checkGeneration );
				return;
			}
			//If we're latechecking, we must relaunch timer if the bomber is in the same state
			//Every interval is judged on its own : a new snapshot of every living terrorist starts it
			SnapshotAll();
			//Reusing the datapack
			CreateDataTimer( lateCheckDelay, SecondScan, Handle:bombUserIdAndCheckGenerationData, TIMER_FLAG_NO_MAPCHANGE );
			WritePackCell( bombUserIdAndCheckGenerationData, GetClientUserId( iBomber ) );
			WritePackCell( bombUserIdAndCheckGenerationData, checkGeneration );
		}
		else //if bomber is lost, find him again (if we want to lateCheck)
		{
			ScheduleNextBomberSearch( checkGeneration );
		}
	}
}

//========== Privates ===========

//===== 1fct
//Give the bomb to the best receiver : alive T other than the old bomber, active in the latest comparison
//Order : humans before bots, then moving before stationary, then smallest distance to the old bomber
//return false (and leave the bomb alone) if nobody qualifies
bool:stripAndGive2ActiveTBomb( any:iOldBomber )
{
	new iEntIndex = GetPlayerWeaponSlot( iOldBomber, CS_SLOT_C4 );
	if ( iEntIndex == -1 )
		return false;

	//1- Find the best receiver
	decl Float:oldPos[ 3 ];
	GetClientAbsOrigin( iOldBomber, oldPos );

	new best = 0;
	new bool:bestHuman;
	new bool:bestMoving;
	new Float:bestDist;

	for ( new i = 1; i <= MaxClients; ++i )
	{
		if ( i == iOldBomber ||
				!IsClientInGame( i ) ||
				GetClientTeam( i ) != CS_TEAM_T ||
				!IsPlayerAlive( i ) ||
				g_snapUserId[ i ] != GetClientUserId( i ) || //has to have been compared
				g_isAfk[ i ] )
			continue;

		decl Float:pos[ 3 ];
		decl Float:velocity[ 3 ];
		GetClientAbsOrigin( i, pos );
		GetEntPropVector( i, Prop_Data, "m_vecVelocity", velocity );

		new bool:human = !IsFakeClient( i );
		new bool:moving = GetVectorLength( velocity ) != 0.0;
		new Float:dist = GetVectorDistance( oldPos, pos );

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
	if ( GetConVarInt( g_afkBomb_displayMsg ) == 1 )
	{
		//Server language for everyone, one message
		decl String:sGiveMsg[ 256 ];
		Format( sGiveMsg, sizeof(sGiveMsg), "%T", "StripNGive Bomb", LANG_SERVER, CHAT_GREEN, iOldBomber, CHAT_DEFAULT );
		PrintToChatAll( "%s[SM] %s%s", CHAT_GREEN, CHAT_DEFAULT, sGiveMsg );
	}

	return true;
}

//The one place the bomb is taken from a player : bDrop = true drops it to the ground, false removes it (to be given away)
//A bomb that was in hand is replaced by the best weapon, so the hands are never empty; otherwise the weapon in hand stays
TakeBomb( any:iClient, bool:bDrop )
{
	new iBomb = GetPlayerWeaponSlot( iClient, CS_SLOT_C4 );
	if ( iBomb == -1 )
		return;

	new bool:bInHand = ( GetEntPropEnt( iClient, Prop_Send, "m_hActiveWeapon" ) == iBomb );

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
SwitchToBestWeapon( any:iClient )
{
	for ( new iSlot = 0; iSlot <= 2; ++iSlot )
	{
		new iWeapon = GetPlayerWeaponSlot( iClient, iSlot );
		if ( iWeapon != -1 )
		{
			decl String:sClassName[ 32 ];
			GetEdictClassname( iWeapon, sClassName, sizeof(sClassName) );
			FakeClientCommand( iClient, "use %s", sClassName );
			return;
		}
	}
}

//=====State-related

ClearSnapshots()
{
	for ( new i = 1; i <= MaxClients; ++i )
	{
		g_snapUserId[ i ] = 0;
		g_isAfk[ i ] = false;
	}
}

//Record the state of every living terrorist (the afk judgement stays until the next comparison)
SnapshotAll()
{
	for ( new i = 1; i <= MaxClients; ++i )
	{
		g_snapUserId[ i ] = 0;

		if ( IsClientInGame( i ) && GetClientTeam( i ) == CS_TEAM_T && IsPlayerAlive( i ) )
		{
			g_snapUserId[ i ] = GetClientUserId( i );
			g_snapMoney[ i ] = GetEntData( i, g_iAccount );
			g_snapArmor[ i ] = GetClientArmor( i );
			g_snapButtons[ i ] = GetClientButtons( i );

			for ( new j = CS_SLOT_C4; j >= 0; --j )
				g_snapGuns[ i ][ j ] = GetPlayerWeaponSlot( i, j );

			GetClientEyeAngles( i, g_snapEye[ i ] );
			GetClientAbsAngles( i, g_snapAngle[ i ] );
			GetClientAbsOrigin( i, g_snapOrigin[ i ] );
			GetEntPropVector( i, Prop_Data, "m_vecVelocity", g_snapVelocity[ i ] );
		}
	}
}

//Re-judge every snapshotted terrorist : afk if unchanged since its snapshot, otherwise active again
CompareAll()
{
	for ( new i = 1; i <= MaxClients; ++i )
		g_isAfk[ i ] = ( g_snapUserId[ i ] != 0 && sameState( i ) );
}

//true if the client is exactly in the state of its snapshot (nothing done since)
bool:sameState( any:iClient, bool:ignoreBomb = false )
{
	if ( !IsClientInGame( iClient ) || !IsPlayerAlive( iClient ) || g_snapUserId[ iClient ] != GetClientUserId( iClient ) )
		return false;

	if ( g_snapMoney[ iClient ] != GetEntData( iClient, g_iAccount ) ||
			g_snapArmor[ iClient ] != GetClientArmor( iClient ) ||
			g_snapButtons[ iClient ] != GetClientButtons( iClient ) )
		return false;

	//Guns
	for ( new i = ignoreBomb ? CS_SLOT_C4 - 1 : CS_SLOT_C4; i >= 0; --i )
		if ( g_snapGuns[ iClient ][ i ] != GetPlayerWeaponSlot( iClient, i ) )
			return false;

	//Vectors
	decl Float:eyeVec[ 3 ];
	decl Float:absAngVec[ 3 ];
	decl Float:absOriVec[ 3 ];
	decl Float:absVloVec[ 3 ];
	GetClientEyeAngles( iClient, eyeVec );
	GetClientAbsAngles( iClient, absAngVec );
	GetClientAbsOrigin( iClient, absOriVec );
	GetEntPropVector( iClient, Prop_Data, "m_vecVelocity", absVloVec );

	for ( new i = 2; i >= 0; --i )
		if ( eyeVec[ i ] != g_snapEye[ iClient ][ i ] ||
				absAngVec[ i ] != g_snapAngle[ iClient ][ i ] ||
				absOriVec[ i ] != g_snapOrigin[ iClient ][ i ] ||
				absVloVec[ i ] != g_snapVelocity[ iClient ][ i ] )
			return false;

	return true;
}
