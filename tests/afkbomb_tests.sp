/**
	AFK Bomb regression tests.

	Runs on the test server. Load it with afkbomb.smx, then run `afkbomb_test`
	from the server console (or RCON). Uses AI-less fake clients (CreateFakeClient),
	which stand still, so the AFK check sees an unchanged state.

	Each case fires a round_start event (CreateEvent/Fire) so the plugin's real
	round logic runs. Results go to the console and to
	addons/sourcemod/logs/afkbomb_tests.log.

	A case also fails if SourceMod's errors_*.log grew while it ran, and a
	[WARN] line is logged if the game fired its own round_start mid-case.
	Unattended: test.ps1 in the repo root (builds, runs the suite, scans all logs).
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <instance_config> // also exercised directly, through this plugin's own cvars (C_CFG_LONG_VALUE)

#define PLUGIN_VERSION "1.1.0"
#define MAX_FAKE 4
#define NAME_LEN 64
#define MAX_ATTEMPTS 3 // a case is rerun if the game restarted the round under it
#define MAX_STEP 99 // timer data = case * 100 + step

// Chat colour codes as a client receives them (control characters, written as escapes)
#define CHAT_DEFAULT "\x01"
#define CHAT_GREEN "\x04"

enum
{
	C_LOADED = 0,
	C_TRANSLATIONS,
	C_CLAMP,
	C_DROP_STILL,
	C_DROP_MOVING,
	C_EYE_MOVED,
	C_MONEY_CHANGED,
	C_SELF_DROP,
	C_ACTION_GIVE,
	C_GIVE_NO_BOUNCE,
	C_GIVE_PREFERS_MOVING,   // along Y only
	C_GIVE_PREFERS_MOVING_Z, // along Z only
	C_RECV_ACTIVE_OVER_AFK,
	C_RECV_CLOSEST,
	C_NO_CANDIDATE,
	C_LATE_NO_CANDIDATE,
	C_STRIP_ACTIVE,
	C_STRIP_SECONDARY,
	C_STRIP_KNIFE,
	C_STRIP_KEEPS,
	C_DROPW_ACTIVE,          // issue #22: the same weapon rules after a dropped held bomb
	C_DROPW_SECONDARY,
	C_DROPW_KNIFE,
	C_DROPW_KEEPS,
	C_ACTION_LONE,
	C_ACTION_CT_ONLY,
	C_DISABLED,
	C_DISABLE_MID,
	C_DISABLE_LATE,
	C_REENABLE,
	C_FREEZETIME_DELAY,
	C_FREEZE_PRE_ACTIVITY,
	C_FREEZE_CVAR_IGNORED,
	C_ACTIVE_BUTTON,
	C_ACTIVE_WEAPON,
	C_MSG_ON,
	C_MSG_OFF,
	C_MSG_SERVER_LANG,
	C_ROUND_RESTART,
	C_LATE_DROP,
	C_LATE_COUNT,
	C_LATE_GIVE,
	C_LATE_FRESH_IDLE,       // issue #23: every late interval compares with a fresh snapshot
	C_LATE_COUNT_RESET,
	C_LATE_GIVE_RULES,
	C_LATE_NONE,
	C_DEAD_CARRIER,
	C_DISCONNECT,
	C_PICKUP_BLOCKED,
	C_PICKUP_AFTER_ACTIVITY,
	C_PICKUP_NEVER_FLAGGED,
	C_PICKUP_BLOCK_ENDS,
	C_BLOCK_ENDS_DISABLED, // issue #21
	C_ENABLE_MID_FREEZE,
	C_PLANT_STOPS_LATE,
	C_PLANT_NEXT_ROUND,
	C_PLANT_PENDING,
	C_CFG_CREATED,      // per-instance config include (issue #12)
	C_CFG_ENTRIES,
	C_CFG_APPLIED,
	C_CFG_APPEND,
	C_CFG_FOREIGN,
	C_CFG_LONG_VALUE,
	C_CFG_SEMICOLON,
	C_CFG_DEPRECATED_REWORDED, // issue #29: deprecation is declared at registration, not read from the description
	C_CFG_DEPRECATED_WORD,
	C_HUMAN_DROP,     // the last two need a real client connected; skipped otherwise
	C_HUMAN_GIVE_MSG,
	C_HUMAN_FIRST,
	C_CFG_MAP_CHANGE, // changes the map, so it runs last
	NUM_CASES
};

char g_caseNames[NUM_CASES][NAME_LEN];

int g_curCase = -1;
bool g_caseActive;
bool g_running;
int g_pass;
int g_fail;
int g_skip;
int g_chatSeen;      // chat usermessages carrying the give message in the server language (English)
int g_chatOther;     // chat usermessages carrying the give message in another language (German)
int g_waited;        // seconds spent waiting for a real client

int g_fakeUids[MAX_FAKE];
int g_fakeCount;
int g_uidCarrier; // userid of the bomb carrier
int g_uidOther;   // userid of the second terrorist (action tests)
int g_uidExtra;   // userid of a third fake client (still T, or a CT)

int g_errSizeAtStart;  // size of SM's errors log when the case started
bool g_selfFire;       // true while we fire our own round_start
bool g_interfered;     // the game restarted the round during this attempt
int g_attempt;         // attempt number of the current case (1..MAX_ATTEMPTS)
int g_origIgnoreWin = -1;
int g_sayCount;        // say_team messages from the carrier during the case
char g_lastSay[192];

float g_origFreezetime;
bool g_mapChanging;    // C_CFG_MAP_CHANGE has issued its changelevel
bool g_forceButton;    // OnPlayerRunCmd presses IN_FORWARD for the carrier
ConVar g_cvAutorun;
char g_logPath[PLATFORM_MAX_PATH];
ConVar g_cvInjectError;
ConVar g_cvWaitClient;
ConVar g_cvClientLog; // path of the real client's console.log (set by test.ps1 -WithClient)
int g_clientLogPos;   // size of that log when the case started

char g_cfgA[16384];    // config file contents under inspection
char g_cfgB[16384];
char g_cfgOld[512];    // what a test wrote into the config
char g_cfgTypo[64];    // a cvar name that exists nowhere
ConVar g_cvTestLong;   // this plugin's own cvars for the include
ConVar g_cvTestSpaced;
ConVar g_cvTestBare;
ConVar g_cvTestRetired; // registered as deprecated; its description does not say so
ConVar g_cvTestWord;    // in use; its description merely contains the word

public Plugin myinfo =
{
	name = "AFK Bomb Tests",
	author = "BallGanda",
	description = "Regression tests for afkbomb.smx (run afkbomb_test on the test server)",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	BuildPath(Path_SM, g_logPath, sizeof(g_logPath), "logs/afkbomb_tests.log");

	strcopy(g_caseNames[C_LOADED], NAME_LEN, "plugin running, all cvars exist");
	strcopy(g_caseNames[C_TRANSLATIONS], NAME_LEN, "translation phrases load and format");
	strcopy(g_caseNames[C_EYE_MOVED], NAME_LEN, "carrier who looked around keeps bomb");
	strcopy(g_caseNames[C_MONEY_CHANGED], NAME_LEN, "carrier who spent money keeps bomb");
	strcopy(g_caseNames[C_SELF_DROP], NAME_LEN, "carrier drops bomb himself mid-check");
	strcopy(g_caseNames[C_GIVE_NO_BOUNCE], NAME_LEN, "action=0 never hands bomb back to the AFK");
	strcopy(g_caseNames[C_GIVE_PREFERS_MOVING], NAME_LEN, "action=0 prefers a T moving along Y over a closer still one");
	strcopy(g_caseNames[C_GIVE_PREFERS_MOVING_Z], NAME_LEN, "action=0 prefers a T moving along Z over a closer still one");
	strcopy(g_caseNames[C_RECV_ACTIVE_OVER_AFK], NAME_LEN, "action=0 gives to the active T, not a closer AFK one");
	strcopy(g_caseNames[C_RECV_CLOSEST], NAME_LEN, "action=0 gives to the closest of two active Ts");
	strcopy(g_caseNames[C_NO_CANDIDATE], NAME_LEN, "action=0 with only an AFK teammate drops once");
	strcopy(g_caseNames[C_LATE_NO_CANDIDATE], NAME_LEN, "latecheckaction=0 with only an AFK teammate drops once");
	strcopy(g_caseNames[C_HUMAN_FIRST], NAME_LEN, "real client: active human preferred over a closer bot");
	strcopy(g_caseNames[C_STRIP_ACTIVE], NAME_LEN, "action=0 strip while holding C4: primary in hand");
	strcopy(g_caseNames[C_STRIP_SECONDARY], NAME_LEN, "strip while holding C4, no primary: secondary in hand");
	strcopy(g_caseNames[C_STRIP_KNIFE], NAME_LEN, "strip while holding C4, no primary/secondary: knife in hand");
	strcopy(g_caseNames[C_STRIP_KEEPS], NAME_LEN, "strip while holding another weapon: it stays in hand");
	strcopy(g_caseNames[C_DROPW_ACTIVE], NAME_LEN, "drop while holding C4: primary in hand");
	strcopy(g_caseNames[C_DROPW_SECONDARY], NAME_LEN, "drop while holding C4, no primary: secondary in hand");
	strcopy(g_caseNames[C_DROPW_KNIFE], NAME_LEN, "drop while holding C4, no primary/secondary: knife in hand");
	strcopy(g_caseNames[C_DROPW_KEEPS], NAME_LEN, "drop while holding another weapon: it stays in hand");
	strcopy(g_caseNames[C_ACTION_CT_ONLY], NAME_LEN, "action=0 never gives bomb to an active CT, drops it");
	strcopy(g_caseNames[C_DISABLE_MID], NAME_LEN, "afkbomb=0 set mid-check cancels drop");
	strcopy(g_caseNames[C_DISABLE_LATE], NAME_LEN, "afkbomb=0 set during late checks stops them");
	strcopy(g_caseNames[C_REENABLE], NAME_LEN, "afkbomb back to 1 takes effect from the next round");
	strcopy(g_caseNames[C_MSG_ON], NAME_LEN, "afkbomb_msg=1 says once on drop");
	strcopy(g_caseNames[C_MSG_OFF], NAME_LEN, "afkbomb_msg=0 stays silent");
	strcopy(g_caseNames[C_MSG_SERVER_LANG], NAME_LEN, "drop message is server language, not the speaker's");
	strcopy(g_caseNames[C_ROUND_RESTART], NAME_LEN, "new round cancels old round's check");
	strcopy(g_caseNames[C_LATE_COUNT], NAME_LEN, "latecheck=3 waits for 3 checks");
	strcopy(g_caseNames[C_LATE_GIVE], NAME_LEN, "latecheckaction=0 gives late bomb away");
	strcopy(g_caseNames[C_LATE_FRESH_IDLE], NAME_LEN, "T who moved early but idles later is AFK in the next late check");
	strcopy(g_caseNames[C_LATE_COUNT_RESET], NAME_LEN, "carrier who moves between late checks restarts the count");
	strcopy(g_caseNames[C_LATE_GIVE_RULES], NAME_LEN, "bomb given in a late check is judged under late-check rules");
	strcopy(g_caseNames[C_HUMAN_DROP], NAME_LEN, "real client: AFK human loses bomb");
	strcopy(g_caseNames[C_HUMAN_GIVE_MSG], NAME_LEN, "real client: give message once, in server language");
	strcopy(g_caseNames[C_PICKUP_BLOCKED], NAME_LEN, "bomb put under the AFK player is not picked up");
	strcopy(g_caseNames[C_PICKUP_AFTER_ACTIVITY], NAME_LEN, "AFK-flagged player who acted picks the bomb up on touch");
	strcopy(g_caseNames[C_PICKUP_NEVER_FLAGGED], NAME_LEN, "never-flagged player picks the bomb up normally");
	strcopy(g_caseNames[C_PICKUP_BLOCK_ENDS], NAME_LEN, "pickup block ends with the round");
	strcopy(g_caseNames[C_BLOCK_ENDS_DISABLED], NAME_LEN, "pickup block ends with the round when the next round starts with afkbomb 0");
	strcopy(g_caseNames[C_ENABLE_MID_FREEZE], NAME_LEN, "afkbomb raised during freezetime starts no check that round");
	strcopy(g_caseNames[C_PLANT_STOPS_LATE], NAME_LEN, "no late check runs after the bomb is planted");
	strcopy(g_caseNames[C_PLANT_NEXT_ROUND], NAME_LEN, "checks resume in the round after a plant");
	strcopy(g_caseNames[C_PLANT_PENDING], NAME_LEN, "plant while a check is pending raises no error");
	strcopy(g_caseNames[C_CFG_CREATED], NAME_LEN, "config appears in SourceMod configs, nothing in game cfg");
	strcopy(g_caseNames[C_CFG_ENTRIES], NAME_LEN, "config has one commented entry per cvar, no version, deprecated marked");
	strcopy(g_caseNames[C_CFG_APPLIED], NAME_LEN, "config values applied: comments, blanks, quotes, CRLF handled");
	strcopy(g_caseNames[C_CFG_APPEND], NAME_LEN, "missing entries appended, existing lines unchanged");
	strcopy(g_caseNames[C_CFG_FOREIGN], NAME_LEN, "cvar the plugin does not own is not applied, reported once");
	strcopy(g_caseNames[C_CFG_LONG_VALUE], NAME_LEN, "long quoted value and quoted spaces are not truncated");
	strcopy(g_caseNames[C_CFG_SEMICOLON], NAME_LEN, "value ends at a trailing semicolon, quoted semicolon kept");
	strcopy(g_caseNames[C_CFG_DEPRECATED_REWORDED], NAME_LEN, "deprecated cvar keeps its comment whatever its description says");
	strcopy(g_caseNames[C_CFG_DEPRECATED_WORD], NAME_LEN, "description that merely says deprecated adds no comment");
	strcopy(g_caseNames[C_CFG_MAP_CHANGE], NAME_LEN, "edited value applied after map change, unknown reported once");
	strcopy(g_caseNames[C_CLAMP], NAME_LEN, "cvar bounds clamped");
	strcopy(g_caseNames[C_DROP_STILL], NAME_LEN, "stationary carrier loses bomb");
	strcopy(g_caseNames[C_DROP_MOVING], NAME_LEN, "moved carrier keeps bomb");
	strcopy(g_caseNames[C_ACTION_GIVE], NAME_LEN, "action=0 gives bomb to other T");
	strcopy(g_caseNames[C_ACTION_LONE], NAME_LEN, "action=0 with no other T drops bomb once");
	strcopy(g_caseNames[C_DISABLED], NAME_LEN, "afkbomb=0 never drops");
	strcopy(g_caseNames[C_FREEZETIME_DELAY], NAME_LEN, "idle carrier loses bomb afkbomb s after freeze ends");
	strcopy(g_caseNames[C_FREEZE_PRE_ACTIVITY], NAME_LEN, "activity during freezetime does not save carrier");
	strcopy(g_caseNames[C_FREEZE_CVAR_IGNORED], NAME_LEN, "afkbomb_freezetime=1 changes nothing, says deprecated");
	strcopy(g_caseNames[C_ACTIVE_BUTTON], NAME_LEN, "carrier who pressed a button keeps bomb");
	strcopy(g_caseNames[C_ACTIVE_WEAPON], NAME_LEN, "carrier who changed weapons keeps bomb");
	strcopy(g_caseNames[C_LATE_DROP], NAME_LEN, "late carrier dropped after latechecks");
	strcopy(g_caseNames[C_LATE_NONE], NAME_LEN, "latecheck=0 ignores late carrier");
	strcopy(g_caseNames[C_DEAD_CARRIER], NAME_LEN, "dead carrier not given to other T");
	strcopy(g_caseNames[C_DISCONNECT], NAME_LEN, "disconnect mid-check is safe");

	ConVar cv = FindConVar("mp_freezetime");
	g_origFreezetime = (cv != null) ? cv.FloatValue : 15.0;

	RegServerCmd("afkbomb_test", Cmd_RunTests, "Run the AFK Bomb regression tests");

	// Unattended mode: +afkbomb_test_autorun 1 runs the suite after the first map loads,
	// then quits the server. Results are in logs/afkbomb_tests.log.
	g_cvAutorun = CreateConVar("afkbomb_test_autorun", "0", "Run the suite on map start and quit when done (automation).", FCVAR_NONE, true, 0.0, true, 1.0);
	// Proves the error detection works: logs a deliberate SourceMod error in the first case.
	g_cvInjectError = CreateConVar("afkbomb_test_inject_error", "0", "Log a deliberate error (checks that error detection works).", FCVAR_NONE, true, 0.0, true, 1.0);

	// With +afkbomb_test_wait_client 1 the autorun waits (up to 3 minutes) for a real client to be in game.
	g_cvWaitClient = CreateConVar("afkbomb_test_wait_client", "0", "Autorun waits for a real client before starting.", FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvClientLog = CreateConVar("afkbomb_test_client_log", "", "Path of the real client's console.log; lets a case check the chat colour codes it received.");

	// PrintToChat* only reaches real clients; watch the chat usermessages to see what they are sent.
	static const char chatMsgs[][] = { "SayText", "SayText2", "TextMsg" };
	for (int i = 0; i < sizeof(chatMsgs); i++)
	{
		UserMsg id = GetUserMessageId(chatMsgs[i]);
		if (id != INVALID_MESSAGE_ID)
			HookUserMessage(id, OnChatMsg);
	}

	g_cvTestLong = CreateConVar("afkbomb_test_long", "short", "A string cvar for the config include test.");
	g_cvTestSpaced = CreateConVar("afkbomb_test_spaced", "a b", "A string cvar with spaces.");
	g_cvTestBare = CreateConVar("afkbomb_test_bare", "x", "A string cvar read from an unquoted value.");
	InstCfg_Add(g_cvTestLong);
	InstCfg_Add(g_cvTestSpaced);
	InstCfg_Add(g_cvTestBare);
	g_cvTestRetired = CreateConVar("afkbomb_test_retired", "0", "No longer used by the suite.");
	g_cvTestWord = CreateConVar("afkbomb_test_word", "1", "Whether deprecated settings are listed.");
	InstCfg_Add(g_cvTestRetired, true);
	InstCfg_Add(g_cvTestWord);
	InstCfg_Ensure(); // configs/afkbomb_tests.cfg; applied only by the case that tests it

	AddCommandListener(OnSayTeam, "say_team");
	HookEvent("round_start", OnRoundStartSeen, EventHookMode_PostNoCopy);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (g_forceButton && g_caseActive && client > 0 && GetClientUserId(client) == g_uidCarrier)
	{
		buttons |= IN_FORWARD;
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

public Action OnChatMsg(UserMsg id, BfRead bf, const int[] players, int playersNum, bool reliable, bool init)
{
	if (!g_caseActive)
		return Plugin_Continue;

	// The layout differs per message type, so scan the raw payload for the phrase.
	char raw[256];
	int n = 0;
	while (bf.BytesLeft > 0 && n < sizeof(raw) - 1)
	{
		int b = bf.ReadByte();
		raw[n++] = view_as<char>((b == 0) ? 32 : b);
	}
	raw[n] = '\0';
	// PrintToChatAll sends one usermessage per recipient; count only what a real client is sent.
	bool toHuman = false;
	for (int i = 0; i < playersNum; i++)
		if (!IsFakeClient(players[i]))
			toHuman = true;
	if (!toHuman)
		return Plugin_Continue;
	if (StrContains(raw, "seems to be afk with the bomb") != -1)
		g_chatSeen++;
	else if (StrContains(raw, "scheint abwesend zu sein") != -1)
		g_chatOther++;
	return Plugin_Continue;
}

int FindHuman()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i))
			return i;
	return 0;
}

// Puts the real client on T as the bomb carrier. It is not being played, so it is a genuine AFK player.
bool SetupHumanCarrier()
{
	int h = FindHuman();
	if (h == 0)
		return false;
	ChangeClientTeam(h, CS_TEAM_T);
	CS_RespawnPlayer(h);
	PlaceApart(h, CS_TEAM_T);
	GivePlayerItem(h, "weapon_c4");
	SetClientLanguage(h, GetLanguageByCode("de")); // server language stays English
	g_uidCarrier = GetClientUserId(h);
	return true;
}

public Action OnSayTeam(int client, const char[] command, int argc)
{
	if (g_caseActive && client > 0 && GetClientUserId(client) == g_uidCarrier)
	{
		g_sayCount++;
		GetCmdArgString(g_lastSay, sizeof(g_lastSay));
	}
	return Plugin_Continue;
}

// A round_start we did not fire means the game restarted the round under the case.
public void OnRoundStartSeen(Event event, const char[] name, bool dontBroadcast)
{
	if (g_running && g_caseActive && !g_selfFire)
		g_interfered = true;
}

public void OnMapStart()
{
	if (g_cvAutorun.BoolValue && !g_running)
		CreateTimer(15.0, Timer_Autorun, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted()
{
	if (g_mapChanging && g_caseActive && g_curCase == C_CFG_MAP_CHANGE)
	{
		g_mapChanging = false;
		Schedule(1.0, g_curCase, 3);
	}
}

public Action Timer_Autorun(Handle timer)
{
	if (g_cvWaitClient.BoolValue && FindHuman() == 0 && g_waited < 180)
	{
		if (g_waited == 0)
			PrintToServer("[afkbomb_test] waiting for a real client to join...");
		g_waited += 2;
		CreateTimer(2.0, Timer_Autorun, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Stop;
	}
	if (g_cvWaitClient.BoolValue && g_waited >= 0 && FindHuman() != 0)
	{
		g_waited = -1; // give the client a few seconds to finish loading in
		CreateTimer(8.0, Timer_Autorun, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Stop;
	}
	Cmd_RunTests(0);
	return Plugin_Stop;
}

public void OnPluginEnd()
{
	CleanupFakes();
	g_running = false;
	ResetCvars();
}

public Action Cmd_RunTests(int args)
{
	if (g_running)
	{
		PrintToServer("[afkbomb_test] already running");
		return Plugin_Handled;
	}
	if (FindPluginByFile("afkbomb.smx") == null)
	{
		PrintToServer("[afkbomb_test] afkbomb.smx is not loaded; aborting");
		return Plugin_Handled;
	}

	// Fake clients joining and leaving would otherwise end the round and restart it under a later case.
	ConVar ignore = FindConVar("mp_ignore_round_win_conditions");
	if (ignore != null)
	{
		g_origIgnoreWin = ignore.IntValue;
		ignore.IntValue = 1;
	}

	g_running = true;
	g_attempt = 1;
	g_pass = 0;
	g_fail = 0;
	g_skip = 0;
	ParkHuman();
	LogToFileEx(g_logPath, "=== AFK Bomb tests started (%d cases) ===", NUM_CASES);
	PrintToServer("[afkbomb_test] running %d cases (about 2 minutes)", NUM_CASES);
	StartCase(0);
	return Plugin_Handled;
}

//===== Case control =====

void StartCase(int c)
{
	g_curCase = c;
	g_caseActive = true;
	g_uidCarrier = 0;
	g_uidOther = 0;
	g_uidExtra = 0;
	g_sayCount = 0;
	g_chatSeen = 0;
	g_chatOther = 0;
	g_forceButton = false;
	g_interfered = false;
	g_lastSay[0] = '\0';
	g_errSizeAtStart = ErrorLogSize();
	ResetCvars();

	switch (c)
	{
		case C_LOADED:
		{
			if (g_cvInjectError.BoolValue)
				LogError("deliberate error injected by afkbomb_test_inject_error");

			static const char cvars[][] = { "afkbombversion", "afkbomb", "afkbomb_freezetime", "afkbomb_action",
				"afkbomb_msg", "afkbomb_latecheck", "afkbomb_latecheckdelay", "afkbomb_latecheckaction" };
			for (int i = 0; i < sizeof(cvars); i++)
			{
				if (FindConVar(cvars[i]) == null)
				{
					char why[96];
					Format(why, sizeof(why), "cvar %s does not exist", cvars[i]);
					EndCase(false, why);
					return;
				}
			}
			bool ok = GetPluginStatus(FindPluginByFile("afkbomb.smx")) == Plugin_Running;
			EndCase(ok, ok ? "running with 8 cvars" : "afkbomb.smx is not in the Running state");
		}

		case C_TRANSLATIONS:
		{
			char path[PLATFORM_MAX_PATH];
			BuildPath(Path_SM, path, sizeof(path), "translations/afkbomb.phrases.txt");
			if (!FileExists(path)) { EndCase(false, "translations/afkbomb.phrases.txt is not deployed"); return; }
			LoadTranslations("afkbomb.phrases");
			if (!TranslationPhraseExists("Drop Bomb") || !TranslationPhraseExists("StripNGive Bomb"))
				{ EndCase(false, "a phrase is missing"); return; }

			// PrintToChatAll skips fake clients, so format the give message here with a real client index.
			int dummy = SpawnFake("AFKTest Name", CS_TEAM_T, false);
			if (dummy == 0) { EndCase(false, "could not create fake client"); return; }
			char buf[256];
			Format(buf, sizeof(buf), "%T", "StripNGive Bomb", LANG_SERVER, "<", dummy, ">");
			bool ok = StrContains(buf, "<AFKTest Name >") == 0;
			if (ok)
			{
				Format(buf, sizeof(buf), "%T", "Drop Bomb", LANG_SERVER);
				ok = buf[0] != '\0';
			}
			EndCase(ok, ok ? "both phrases format" : "phrase did not format as expected");
		}

		case C_CLAMP:
		{
			SetCvarInt("afkbomb", -5);
			SetCvarInt("afkbomb_freezetime", 7);
			SetCvarInt("afkbomb_action", 5);
			SetCvarInt("afkbomb_msg", -1);
			SetCvarInt("afkbomb_latecheck", -3);
			SetCvarFloat("afkbomb_latecheckdelay", 0.1);
			SetCvarInt("afkbomb_latecheckaction", 9);

			bool ok = GetCvarInt("afkbomb") == 0
				&& GetCvarInt("afkbomb_freezetime") == 1
				&& GetCvarInt("afkbomb_action") == 1
				&& GetCvarInt("afkbomb_msg") == 0
				&& GetCvarInt("afkbomb_latecheck") == 0
				&& GetCvarFloat("afkbomb_latecheckdelay") == 1.0
				&& GetCvarInt("afkbomb_latecheckaction") == 1;
			EndCase(ok, ok ? "all out-of-range values clamped" : "a cvar was not clamped to its bounds");
		}

		case C_CFG_CREATED:
		{
			char path[PLATFORM_MAX_PATH];
			CfgPath("afkbomb", path, sizeof(path));
			DeleteFile(path);
			ServerCommand("sm plugins reload afkbomb");
			Schedule(1.5, c, 1);
		}

		case C_CFG_ENTRIES:
		{
			char path[PLATFORM_MAX_PATH];
			CfgPath("afkbomb", path, sizeof(path));
			DeleteFile(path);
			ServerCommand("sm plugins reload afkbomb");
			Schedule(1.5, c, 1);
		}

		case C_CFG_APPLIED:
		{
			char path[PLATFORM_MAX_PATH];
			CfgPath("afkbomb", path, sizeof(path));
			CfgWrite(path, "// custom settings\r\n; a semicolon comment\r\n\r\n   \r\nafkbomb \"3\"\r\n\tafkbomb_latecheck   4  \r\n//afkbomb_action 1\r\n;afkbomb_latecheckaction 0\r\nafkbomb_msg \"0\"\r\nafkbomb_latecheckdelay \"7.5\" // trailing\r\n");
			ServerCommand("sm plugins reload afkbomb");
			Schedule(1.5, c, 1);
		}

		case C_CFG_APPEND:
		{
			char path[PLATFORM_MAX_PATH];
			CfgPath("afkbomb", path, sizeof(path));
			strcopy(g_cfgOld, sizeof(g_cfgOld), "// my notes\nafkbomb \"5\"\nafkbomb_action \"1\"   \n// last line, no newline after it");
			CfgWrite(path, g_cfgOld);
			ServerCommand("sm plugins reload afkbomb");
			Schedule(1.5, c, 1);
		}

		case C_CFG_FOREIGN:
		{
			char path[PLATFORM_MAX_PATH], text[256];
			CfgPath("afkbomb", path, sizeof(path));
			Format(g_cfgTypo, sizeof(g_cfgTypo), "afkbomb_typo_%d", GetTime());
			Format(text, sizeof(text), "mp_freezetime 99\n%s 1\nafkbomb 4\n", g_cfgTypo);
			CfgWrite(path, text);
			ServerCommand("sm plugins reload afkbomb");
			Schedule(1.5, c, 1);
		}

		case C_CFG_LONG_VALUE:
		{
			// this plugin's own string cvars, read through the same include; 2000 characters is far beyond any chat message
			char path[PLATFORM_MAX_PATH], big[2100];
			CfgPath("afkbomb_tests", path, sizeof(path));
			for (int i = 0; i < 2000; i++)
				big[i] = view_as<char>('a' + (i % 26));
			big[2000] = '\0';
			File f = OpenFile(path, "wb");
			if (f == null) { EndCase(false, "cannot write the test plugin's config"); return; }
			f.WriteString("// long and spaced values\nafkbomb_test_long \"", false);
			f.WriteString(big, false);
			f.WriteString("\" // trailing\nafkbomb_test_spaced \"hello  big world\"\nafkbomb_test_bare unquoted\n", false);
			delete f;
			InstCfg_Apply();
			char got[2100];
			g_cvTestLong.GetString(got, sizeof(got));
			if (!StrEqual(got, big)) { EndCase(false, "the long quoted value was truncated or altered"); return; }
			g_cvTestSpaced.GetString(got, sizeof(got));
			if (!StrEqual(got, "hello  big world")) { EndCase(false, "quoted value with spaces was altered"); return; }
			g_cvTestBare.GetString(got, sizeof(got));
			EndCase(StrEqual(got, "unquoted"), StrEqual(got, "unquoted") ? "2000-character and spaced quoted values intact" : "bare value wrong");
		}

		case C_CFG_SEMICOLON:
		{
			// issue #26: `name 2;` sets 2, a ';' inside quotes stays, a quoted value may be followed by ';'
			char path[PLATFORM_MAX_PATH], got[64];
			CfgPath("afkbomb_tests", path, sizeof(path));
			File f = OpenFile(path, "wb");
			if (f == null) { EndCase(false, "cannot write the test plugin's config"); return; }
			f.WriteString("; full-line comment\nafkbomb_test_bare 2;\nafkbomb_test_long \"a;b\"\nafkbomb_test_spaced \"x y\"; note\n", false);
			delete f;
			g_cvTestBare.SetString("x");
			InstCfg_Apply();
			g_cvTestBare.GetString(got, sizeof(got));
			if (!StrEqual(got, "2")) { Format(got, sizeof(got), "bare value read as \"%s\", wanted 2", got); EndCase(false, got); return; }
			g_cvTestLong.GetString(got, sizeof(got));
			if (!StrEqual(got, "a;b")) { EndCase(false, "a semicolon inside quotes was cut"); return; }
			g_cvTestSpaced.GetString(got, sizeof(got));
			EndCase(StrEqual(got, "x y"), "semicolon ends a bare value, quoted semicolon kept");
		}

		case C_CFG_DEPRECATED_REWORDED, C_CFG_DEPRECATED_WORD:
		{
			// a freshly generated file for this plugin's own cvars
			bool retired = (c == C_CFG_DEPRECATED_REWORDED);
			char path[PLATFORM_MAX_PATH], block[512];
			CfgPath("afkbomb_tests", path, sizeof(path));
			DeleteFile(path);
			InstCfg_Ensure();
			if (!CfgRead(path, g_cfgA, sizeof(g_cfgA))) { EndCase(false, "the test plugin's config was not generated"); return; }
			int at = StrContains(g_cfgA, retired ? "\nafkbomb_test_retired \"0\"" : "\nafkbomb_test_word \"1\"");
			if (at == -1) { EndCase(false, "the cvar has no entry in the generated file"); return; }
			CfgBlockBefore(at, block, sizeof(block));
			if (StrContains(block, retired ? "// No longer used by the suite.\n" : "// Whether deprecated settings are listed.\n") == -1)
				{ EndCase(false, "description not in the entry's comments"); return; }
			bool marked = StrContains(block, "// DEPRECATED: kept so old configs still load; it has no effect.\n") != -1;
			if (retired)
				EndCase(marked, marked ? "comment present though the description does not say deprecated" : "no deprecation comment on a cvar registered as deprecated");
			else
				EndCase(!marked, !marked ? "no comment on a cvar that is not registered as deprecated" : "deprecation comment on a cvar that is not registered as deprecated");
		}

		case C_CFG_MAP_CHANGE:
		{
			char path[PLATFORM_MAX_PATH], text[256];
			CfgPath("afkbomb", path, sizeof(path));
			Format(g_cfgTypo, sizeof(g_cfgTypo), "afkbomb_typo_%d", GetTime() + 1);
				Format(text, sizeof(text), "%s 1\n", g_cfgTypo);
			CfgWrite(path, text);
			ServerCommand("sm plugins reload afkbomb"); // first apply: reports the typo
			Schedule(1.5, c, 1);
		}

		case C_HUMAN_DROP:
		{
			if (!SetupHumanCarrier()) { SkipCase("no real client connected"); return; }
			SetupCarrierRound(false, false, 1, 0, 1);
			Schedule(2.5, c, 1);
		}

		case C_HUMAN_GIVE_MSG:
		{
			if (!SetupHumanCarrier()) { SkipCase("no real client connected"); return; }
			char clog[PLATFORM_MAX_PATH];
			g_cvClientLog.GetString(clog, sizeof(clog));
			g_clientLogPos = -1;
			File lf = (clog[0] != '\0') ? OpenFile(clog, "rb") : null;
			if (lf != null)
			{
				lf.Seek(0, SEEK_END);
				g_clientLogPos = lf.Position;
				delete lf;
			}
			SetupCarrierRound(false, true, 1, 0, 0);
			Schedule(2.5, c, 1);
		}

		case C_HUMAN_FIRST:
		{
			int h = FindHuman();
			if (h == 0) { SkipCase("no real client connected"); return; }
			SetupCarrierRound(true, false, 1, 0, 0);
			ChangeClientTeam(h, CS_TEAM_T);
			CS_RespawnPlayer(h);
			PlaceApart(h, CS_TEAM_T);
			g_uidOther = GetClientUserId(h);
			int bot = SpawnFake("AFKTest Bot", CS_TEAM_T, false);
			if (bot == 0) { EndCase(false, "could not create fake client"); return; }
			g_uidExtra = GetClientUserId(bot);
			Schedule(1.5, c, 1); // human and bot both become active, the bot ends up closer
			Schedule(2.5, c, 2);
		}

		case C_DROP_STILL:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			Schedule(3.5, c, 1);
		}

		case C_PICKUP_BLOCKED, C_PICKUP_AFTER_ACTIVITY:
		{
			SetupCarrierRound(true, false, 1, 0, 1); // dropped at 2.0s
			Schedule(2.5, c, 1); // bomb goes under the carrier (after activity for the second case)
			Schedule(3.3, c, 2);
		}

		case C_PICKUP_NEVER_FLAGGED:
		{
			SetupCarrierRound(true, true, 1, 0, 1); // "other" is active at the check, so never flagged
			Schedule(2.5, c, 1);
			Schedule(3.3, c, 2);
		}

		case C_PICKUP_BLOCK_ENDS:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			Schedule(2.5, c, 1); // bomb under the carrier: blocked
			Schedule(3.2, c, 2); // still blocked; new round: the bomb lying under the carrier is collected at once
			Schedule(4.0, c, 4);
		}

		case C_BLOCK_ENDS_DISABLED:
		{
			SetupCarrierRound(true, false, 1, 0, 1); // carrier judged AFK, bomb dropped at 2.0s
			Schedule(2.5, c, 1); // bomb under the carrier: blocked
			Schedule(3.2, c, 2); // new round starts with afkbomb 0
			Schedule(4.0, c, 3);
		}

		case C_ENABLE_MID_FREEZE:
		{
			SetupCarrierRound(true, false, 0, 0, 1, 3.0); // disabled round, freezetime ends at 3.0s
			Schedule(1.5, c, 1); // raise afkbomb during freezetime
			Schedule(5.0, c, 2); // would have been dropped at 4.0s; start the next round
			Schedule(8.0, c, 3); // new round: freeze end 6.0s, check at 7.0s
		}

		case C_DROP_MOVING:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			Schedule(1.5, c, 1); // after first scan (1.0s), before second scan
			Schedule(2.5, c, 2);
		}

		case C_EYE_MOVED, C_MONEY_CHANGED, C_DISABLE_MID:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			Schedule(1.5, c, 1); // between first (1.0s) and second (2.0s) scan
			Schedule(2.5, c, 2);
		}

		case C_DISABLE_LATE:
		{
			SetupCarrierRound(false, false, 1, 3, 1);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			Schedule(1.2, c, 1); // carrier found at 2.0s; checks at 3.0, 4.0, 5.0s
			Schedule(3.5, c, 2); // after the first late check: disable
			Schedule(5.7, c, 3); // after the check that would have dropped
		}

		case C_REENABLE:
		{
			SetupCarrierRound(true, false, 0, 0, 1); // disabled: freeze end at 1.0s does nothing
			Schedule(1.5, c, 1); // enable mid-round
			Schedule(3.0, c, 2); // this round stays unchecked; start the next round
			Schedule(7.5, c, 3); // new round: freeze end 4.1s, snapshot, drop at 6.1s
		}

		case C_SELF_DROP:
		{
			SetupCarrierRound(true, false, 1, 2, 1);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			Schedule(1.5, c, 1);
			Schedule(3.5, c, 2);
		}

		case C_ACTION_GIVE:
		{
			SetupCarrierRound(true, true, 1, 0, 0);
			Schedule(2.5, c, 1); // scans at 1.0s and 2.0s
		}

		case C_GIVE_NO_BOUNCE:
		{
			SetupCarrierRound(true, true, 1, 0, 0);
			Schedule(2.6, c, 3); // the carrier judged AFK now moves: still never a receiver
			Schedule(3.5, c, 1); // the receiver is scanned at 2.0s and 3.0s
			Schedule(4.5, c, 2);
		}

		case C_GIVE_PREFERS_MOVING, C_GIVE_PREFERS_MOVING_Z:
		{
			// "other" is far and will be moving at the check, "extra" is close and active but stationary
			SetupCarrierRound(true, true, 1, 0, 0, 1.0, -1.0);
			int still = SpawnFake("AFKTest Still", CS_TEAM_T, false);
			if (still == 0) { EndCase(false, "could not create fake client"); return; }
			g_uidExtra = GetClientUserId(still);
			TeleportNear(still, GetClientOfUserId(g_uidCarrier)); // placed before the snapshot so it has settled (no fall velocity)
			Schedule(1.5, c, 1);  // the still one looks around: active, stationary
			Schedule(1.95, c, 2); // the far one gets velocity just before the check (2.0s)
			Schedule(2.5, c, 3);
		}

		case C_RECV_ACTIVE_OVER_AFK:
		{
			SetupCarrierRound(true, true, 1, 0, 0); // "other" becomes active at 1.5s
			int idle = SpawnFake("AFKTest Idle", CS_TEAM_T, false);
			if (idle == 0) { EndCase(false, "could not create fake client"); return; }
			g_uidExtra = GetClientUserId(idle);
			TeleportNear(idle, GetClientOfUserId(g_uidCarrier)); // closer than "other", but never does anything
			Schedule(2.5, c, 1);
		}

		case C_RECV_CLOSEST:
		{
			SetupCarrierRound(true, true, 1, 0, 0, 1.0, -1.0);
			int far = SpawnFake("AFKTest Far", CS_TEAM_T, false);
			if (far == 0) { EndCase(false, "could not create fake client"); return; }
			g_uidExtra = GetClientUserId(far);
			TeleportNear(GetClientOfUserId(g_uidOther), GetClientOfUserId(g_uidCarrier)); // before the snapshot, so it has settled
			Schedule(1.5, c, 1); // both look around: active
			Schedule(2.5, c, 2);
		}

		case C_NO_CANDIDATE:
		{
			SetupCarrierRound(true, true, 1, 0, 0, 1.0, -1.0); // the only other T never acts
			Schedule(3.5, c, 1);
		}

		case C_LATE_NO_CANDIDATE:
		{
			SetupCarrierRound(false, true, 1, 2, 1, 1.0, -1.0);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			SetCvarInt("afkbomb_latecheckaction", 0);
			Schedule(1.2, c, 1);
			Schedule(4.5, c, 2);
		}

		case C_STRIP_ACTIVE, C_STRIP_SECONDARY, C_STRIP_KNIFE, C_STRIP_KEEPS, C_DROPW_ACTIVE, C_DROPW_SECONDARY, C_DROPW_KNIFE, C_DROPW_KEEPS:
		{
			bool dropping = (c >= C_DROPW_ACTIVE && c <= C_DROPW_KEEPS);
			KillLooseGuns(); // an earlier case's dropped guns must not be picked up by this carrier
			if (dropping)
				SetupCarrierRound(true, false, 1, 0, 1); // action drop, nobody to give to
			else
				SetupCarrierRound(true, true, 1, 0, 0);
			int carrier = GetClientOfUserId(g_uidCarrier);
			if (carrier > 0)
			{
				int kind = dropping ? c - C_DROPW_ACTIVE + C_STRIP_ACTIVE : c; // same set-up as the matching strip case
				if (kind == C_STRIP_ACTIVE || kind == C_STRIP_KEEPS)
					GivePlayerItem(carrier, "weapon_ak47");
				if (kind == C_STRIP_SECONDARY || kind == C_STRIP_KNIFE)
					RemoveSlot(carrier, CS_SLOT_PRIMARY); // a primary dropped by an earlier case may have been picked up
				if (kind == C_STRIP_KNIFE)
					RemoveSlot(carrier, CS_SLOT_SECONDARY);
				int hold = GetPlayerWeaponSlot(carrier, kind == C_STRIP_KEEPS ? CS_SLOT_SECONDARY : CS_SLOT_C4);
				if (hold != -1)
					SetEntPropEnt(carrier, Prop_Send, "m_hActiveWeapon", hold);
			}
			Schedule(2.5, c, 1);
		}

		case C_ACTION_CT_ONLY:
		{
			int ct = SpawnFake("AFKTest CT", CS_TEAM_CT, false);
			if (ct == 0) { EndCase(false, "could not create CT fake client"); return; }
			g_uidExtra = GetClientUserId(ct);
			SetupCarrierRound(true, false, 1, 0, 0);
			Schedule(1.5, c, 97); // the CT is active, still not a receiver
			Schedule(3.5, c, 1);
		}

		case C_MSG_ON, C_MSG_OFF:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			SetCvarInt("afkbomb_msg", (c == C_MSG_ON) ? 1 : 0);
			Schedule(4.5, c, 1); // drop at 2.0s, re-scan at 3.5s must not repeat the message
		}

		case C_MSG_SERVER_LANG:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			int who = GetClientOfUserId(g_uidCarrier);
			if (who == 0) { EndCase(false, "carrier gone"); return; }
			SetClientLanguage(who, GetLanguageByCode("de")); // server language is English
			Schedule(4.5, c, 1);
		}

		case C_ROUND_RESTART:
		{
			SetupCarrierRound(true, false, 3, 0, 1); // scans at 1.0s and 4.0s
			Schedule(2.0, c, 1); // new round: scans move to 3.0s and 6.0s
			Schedule(4.5, c, 2);
			Schedule(6.5, c, 3);
		}

		case C_LATE_COUNT:
		{
			SetupCarrierRound(false, false, 1, 3, 1);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			Schedule(1.2, c, 1); // found at 2.0s; checks at 3.0, 4.0, 5.0s
			Schedule(4.5, c, 2);
			Schedule(5.5, c, 3);
		}

		case C_LATE_GIVE:
		{
			SetupCarrierRound(false, true, 1, 2, 1, 1.0, -1.0); // "other" is active in both late intervals (2.0-3.0s, 3.0-4.0s)
			Schedule(2.5, c, 96);
			Schedule(3.5, c, 96);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			SetCvarInt("afkbomb_latecheckaction", 0);
			Schedule(1.2, c, 1); // found at 2.0s; checks at 3.0, 4.0s
			Schedule(4.5, c, 2);
		}

		case C_LATE_FRESH_IDLE:
		{
			SetupCarrierRound(false, true, 1, 2, 1, 1.0, -1.0); // "other" acts once, between the late snapshot (2.0s) and check 1 (3.0s)
			Schedule(2.5, c, 96);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			SetCvarInt("afkbomb_latecheckaction", 0);
			Schedule(1.2, c, 1); // found at 2.0s; check 1 at 3.0s, check 2 at 4.0s against a snapshot of 3.0s
			Schedule(4.5, c, 2);
		}

		case C_LATE_COUNT_RESET:
		{
			SetupCarrierRound(false, false, 1, 3, 1);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			Schedule(1.2, c, 1); // found at 2.0s; check 1 at 3.0s (idle)
			Schedule(3.5, c, 4); // moves before check 2 (4.0s): the count restarts, a new search starts at 5.0s
			Schedule(5.7, c, 2); // an unbroken run would have dropped at 5.0s
			Schedule(9.5, c, 3); // restarted run: checks at about 6.1, 7.2, 8.3s (each hop adds a tick or so)
		}

		case C_LATE_GIVE_RULES:
		{
			SetupCarrierRound(false, true, 1, 2, 1, 1.0, -1.0); // "other" active in both intervals: gets the bomb at 4.0s
			Schedule(2.5, c, 96);
			Schedule(3.5, c, 96);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			SetCvarInt("afkbomb_latecheckaction", 0);
			Schedule(1.2, c, 1);
			Schedule(5.8, c, 2); // the receiver is idle; late rules need 2 checks (about 5.3s, 6.4s), first-check rules would drop at 5.3s
			Schedule(7.5, c, 3);
		}

		case C_ACTION_LONE:
		{
			SetupCarrierRound(true, false, 1, 0, 0);
			Schedule(3.5, c, 1);
		}

		case C_DISABLED:
		{
			SetupCarrierRound(true, false, 0, 0, 1);
			Schedule(3.5, c, 1);
		}

		case C_FREEZETIME_DELAY:
		{
			SetCvarFloat("mp_freezetime", 4.0);
			SetupCarrierRound(true, false, 1, 0, 1, 4.0); // freezetime ends at 4.0s, check at 5.0s
			Schedule(3.5, c, 1); // still frozen: nothing may have happened
			Schedule(4.7, c, 2); // freeze over, afkbomb window not yet: still held
			Schedule(5.8, c, 3);
		}

		case C_FREEZE_PRE_ACTIVITY:
		{
			SetupCarrierRound(true, false, 1, 0, 1, 3.0); // freezetime ends at 3.0s
			Schedule(1.5, c, 1); // moves during freezetime only
			Schedule(3.7, c, 2);
			Schedule(4.8, c, 3); // check at 4.0s
		}

		case C_FREEZE_CVAR_IGNORED:
		{
			SetCvarInt("afkbomb_freezetime", 1);
			SetupCarrierRound(true, false, 1, 0, 1, 3.0); // same timing as with 0: check at 4.0s
			Schedule(3.5, c, 1);
			Schedule(4.8, c, 2);
		}

		case C_ACTIVE_BUTTON, C_ACTIVE_WEAPON:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			Schedule(1.5, c, 1); // between the snapshot (1.0s) and the check (2.0s)
			Schedule(2.6, c, 2);
		}

		case C_LATE_DROP:
		{
			SetupCarrierRound(false, false, 1, 2, 1);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			Schedule(1.2, c, 1); // first check (1.0s) found nobody; carrier appears now
			Schedule(5.7, c, 2);
		}

		case C_LATE_NONE:
		{
			SetupCarrierRound(false, false, 1, 0, 1);
			Schedule(1.2, c, 1);
			Schedule(4.5, c, 2);
		}

		case C_DEAD_CARRIER:
		{
			SetupCarrierRound(true, true, 1, 0, 0);
			Schedule(1.2, c, 1); // dies between first (1.0s) and second (2.0s) scan
			Schedule(3.5, c, 2);
		}

		case C_PLANT_STOPS_LATE:
		{
			SetupCarrierRound(false, false, 1, 2, 1);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			Schedule(1.1, c, 1); // freeze end (1.0s) found nobody, next check due at 2.0s: plant now
			Schedule(1.2, c, 2); // carrier appears; without the plant it is found at 2.0s and dropped by 4.0s
			Schedule(5.7, c, 3);
		}

		case C_PLANT_NEXT_ROUND:
		{
			SetupCarrierRound(false, false, 1, 2, 1);
			SetCvarFloat("afkbomb_latecheckdelay", 1.0);
			Schedule(1.1, c, 1);
			Schedule(1.2, c, 2);
			Schedule(3.0, c, 3); // still held; new round: freeze end 4.0s, check 5.0s
			Schedule(6.0, c, 4);
		}

		case C_PLANT_PENDING:
		{
			SetupCarrierRound(true, false, 2, 2, 1); // snapshot at 1.0s, check pending until 3.0s
			Schedule(1.5, c, 1);
			Schedule(4.5, c, 2);
		}

		case C_DISCONNECT:
		{
			SetupCarrierRound(true, false, 1, 0, 1);
			Schedule(1.5, c, 1); // carrier leaves between scans
			Schedule(3.0, c, 2);
		}
	}
}

// Creates the carrier (optionally with a second idle T), sets cvars, and fires round_start.
// withCarrier=false: no bomb yet (late-check cases spawn the carrier later).
void SetupCarrierRound(bool withCarrier, bool withOther, int afkbomb, int latecheck, int action, float freeze = 1.0, float nudge = 1.5)
{
	SetCvarInt("afkbomb", afkbomb);
	SetCvarInt("afkbomb_latecheck", latecheck);
	SetCvarInt("afkbomb_action", action);

	if (withCarrier)
	{
		int carrier = SpawnFake("AFKTest Carrier", CS_TEAM_T, true);
		if (carrier == 0)
		{
			EndCase(false, "could not create carrier fake client");
			return;
		}
		g_uidCarrier = GetClientUserId(carrier);
	}
	if (withOther)
	{
		int other = SpawnFake("AFKTest Other", CS_TEAM_T, false);
		if (other == 0)
		{
			EndCase(false, "could not create second fake client");
			return;
		}
		g_uidOther = GetClientUserId(other);
		if (nudge >= 0.0)
			Schedule(nudge, g_curCase, 98); // "other" shows activity between snapshot and check
	}
	FireRoundStart(freeze);
}

void KillLooseGuns()
{
	char names[3][] = {"weapon_ak47", "weapon_glock", "weapon_usp"};
	for (int i = 0; i < 3; i++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, names[i])) != -1)
			if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") == -1)
				AcceptEntityInput(ent, "Kill");
	}
}

void RemoveSlot(int client, int slot)
{
	int w = GetPlayerWeaponSlot(client, slot);
	if (w != -1)
	{
		RemovePlayerItem(client, w);
		AcceptEntityInput(w, "Kill");
	}
}

char g_colourWhy[160];

// The client's console.log keeps the colour control bytes of the chat it received.
// 1.5.0 sent "\x04[SM] \x01" + "\x04<name> \x01seems to be afk with the bomb ..."
bool CheckGiveColours(int carrier)
{
	char clog[PLATFORM_MAX_PATH];
	g_cvClientLog.GetString(clog, sizeof(clog));
	if (g_clientLogPos < 0)
	{
		Format(g_colourWhy, sizeof(g_colourWhy), "client console.log not available (afkbomb_test_client_log = '%s')", clog);
		return false;
	}
	File f = OpenFile(clog, "rb");
	if (f == null)
	{
		strcopy(g_colourWhy, sizeof(g_colourWhy), "could not open the client console.log");
		return false;
	}
	f.Seek(g_clientLogPos, SEEK_SET);
	char name[MAX_NAME_LENGTH];
	GetClientName(carrier, name, sizeof(name));
	char want[192];
	Format(want, sizeof(want), "%s[SM] %s%s%s %sseems to be afk with the bomb", CHAT_GREEN, CHAT_DEFAULT, CHAT_GREEN, name, CHAT_DEFAULT);
	char line[512];
	int seen = 0, good = 0;
	while (!f.EndOfFile() && f.ReadLine(line, sizeof(line)))
	{
		if (StrContains(line, "seems to be afk with the bomb") == -1)
			continue;
		seen++;
		if (StrContains(line, want) != -1)
			good++;
	}
	delete f;
	if (seen != 1 || good != 1)
	{
		Format(g_colourWhy, sizeof(g_colourWhy), "client chat log: %d give line(s), %d with the 1.5.0 colour codes, expected 1 and 1", seen, good);
		return false;
	}
	strcopy(g_colourWhy, sizeof(g_colourWhy), "bomb given, one server-language message with the 1.5.0 colour codes in the client chat log");
	return true;
}

void Schedule(float delay, int c, int step)
{
	CreateTimer(delay, Timer_Step, c * 100 + step, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Step(Handle timer, any data)
{
	int code = view_as<int>(data);
	int c = code / 100;
	int step = code % 100;
	if (step > MAX_STEP || !g_caseActive || c != g_curCase)
		return Plugin_Stop; // stale timer from a finished case
	RunStep(c, step);
	return Plugin_Stop;
}

void RunStep(int c, int step)
{
	int carrier = GetClientOfUserId(g_uidCarrier);
	int other = GetClientOfUserId(g_uidOther);
	int extra = GetClientOfUserId(g_uidExtra);

	// generic steps: a client shows activity without changing where it stands
	if (step == 98) { if (other > 0) NudgeClient(other); return; }
	if (step == 97) { if (extra > 0) NudgeClient(extra); return; }
	// activity that leaves nothing moving afterwards (a nudged fake's body keeps turning for a second or so)
	if (step == 96) { if (other > 0) SetEntProp(other, Prop_Send, "m_iAccount", GetEntProp(other, Prop_Send, "m_iAccount") + 100); return; }

	switch (c)
	{
		case C_CFG_CREATED:
		{
			char path[PLATFORM_MAX_PATH];
			CfgPath("afkbomb", path, sizeof(path));
			if (!FileExists(path)) { EndCase(false, "no config file in the SourceMod configs folder after load"); return; }
			static const char stray[][] = { "cfg/sourcemod/plugin.afkbomb.cfg", "cfg/sourcemod/afkbomb.cfg", "cfg/afkbomb.cfg", "cfg/plugin.afkbomb.cfg" };
			for (int i = 0; i < sizeof(stray); i++)
			{
				if (FileExists(stray[i]))
				{
					char why[96];
					Format(why, sizeof(why), "a config was written to the game folder: %s", stray[i]);
					EndCase(false, why);
					return;
				}
			}
			EndCase(true, "configs/afkbomb.cfg created, game cfg folder untouched");
		}

		case C_CFG_ENTRIES:
		{
			char path[PLATFORM_MAX_PATH], why[160], needle[96], block[1024];
			CfgPath("afkbomb", path, sizeof(path));
			if (!CfgRead(path, g_cfgA, sizeof(g_cfgA))) { EndCase(false, "config file missing"); return; }
			if (StrContains(g_cfgA, "afkbombversion") != -1) { EndCase(false, "the version cvar is in the config"); return; }
			// independent expectations: literal defaults, description starts and bounds from the plugin source
			static const char names[][] = { "afkbomb", "afkbomb_freezetime", "afkbomb_action", "afkbomb_msg", "afkbomb_latecheck", "afkbomb_latecheckdelay", "afkbomb_latecheckaction" };
			static const char defs[][] = { "2", "0", "0", "1", "2", "5.0", "1" };
			static const char descs[][] = { "How long after freezetime ends", "DEPRECATED since 1.5.1", "What to do when someone is considered afk at the beginning",
				"Notify team when bomb is dropped", "Number of latechecks", "Time between 2 latechecks", "What to do when someone is considered afk after" };
			static const char mins[][] = { "0", "0", "0", "0", "0", "1", "0" };
			static const char maxs[][] = { "", "1", "1", "1", "", "", "1" };
			for (int i = 0; i < sizeof(names); i++)
			{
				Format(needle, sizeof(needle), "\n%s \"%s\"", names[i], defs[i]);
				int at = StrContains(g_cfgA, needle);
				if (at == -1) { Format(why, sizeof(why), "no entry %s \"%s\"", names[i], defs[i]); EndCase(false, why); return; }
				if (StrContains(g_cfgA[at + 1], needle) != -1) { Format(why, sizeof(why), "entry %s twice", names[i]); EndCase(false, why); return; }
				CfgBlockBefore(at, block, sizeof(block));
				if (StrContains(block, descs[i]) == -1) { Format(why, sizeof(why), "%s: description not in its comments", names[i]); EndCase(false, why); return; }
				Format(needle, sizeof(needle), "// Default: %s\n", defs[i]);
				if (StrContains(block, needle) == -1) { Format(why, sizeof(why), "%s: default not in its comments", names[i]); EndCase(false, why); return; }
				Format(needle, sizeof(needle), "// Min: %s\n", mins[i]);
				if (StrContains(block, needle) == -1) { Format(why, sizeof(why), "%s: min not in its comments", names[i]); EndCase(false, why); return; }
				if (maxs[i][0] != '\0')
				{
					Format(needle, sizeof(needle), "// Max: %s\n", maxs[i]);
					if (StrContains(block, needle) == -1) { Format(why, sizeof(why), "%s: max not in its comments", names[i]); EndCase(false, why); return; }
				}
				else if (StrContains(block, "// Max:") != -1) { Format(why, sizeof(why), "%s: a max that does not exist", names[i]); EndCase(false, why); return; }
				bool deprecated = StrContains(block, "// DEPRECATED") != -1;
				if (deprecated != (i == 1)) { Format(why, sizeof(why), "%s: deprecated marking wrong", names[i]); EndCase(false, why); return; }
			}
			EndCase(true, "7 entries with description, default, limits; deprecated one marked; no version");
		}

		case C_CFG_APPLIED:
		{
			bool ok = GetCvarInt("afkbomb") == 3 && GetCvarInt("afkbomb_latecheck") == 4 && GetCvarInt("afkbomb_msg") == 0
				&& GetCvarFloat("afkbomb_latecheckdelay") == 7.5
				&& GetCvarInt("afkbomb_action") == 0 && GetCvarInt("afkbomb_latecheckaction") == 1; // commented out: defaults
			char why[160];
			Format(why, sizeof(why), "afkbomb=%d latecheck=%d msg=%d delay=%.1f action=%d latecheckaction=%d", GetCvarInt("afkbomb"), GetCvarInt("afkbomb_latecheck"),
				GetCvarInt("afkbomb_msg"), GetCvarFloat("afkbomb_latecheckdelay"), GetCvarInt("afkbomb_action"), GetCvarInt("afkbomb_latecheckaction"));
			EndCase(ok, ok ? "edited values in effect, commented lines ignored" : why);
		}

		case C_CFG_APPEND:
		{
			char path[PLATFORM_MAX_PATH], why[160];
			CfgPath("afkbomb", path, sizeof(path));
			if (!CfgRead(path, g_cfgA, sizeof(g_cfgA))) { EndCase(false, "config file missing"); return; }
			if (step == 1)
			{
				if (StrContains(g_cfgA, g_cfgOld) != 0) { EndCase(false, "existing content was changed or reordered"); return; }
				static const char added[][] = { "\nafkbomb_freezetime \"0\"", "\nafkbomb_msg \"1\"", "\nafkbomb_latecheck \"2\"", "\nafkbomb_latecheckdelay \"5.0\"", "\nafkbomb_latecheckaction \"1\"" };
				for (int i = 0; i < sizeof(added); i++)
					if (StrContains(g_cfgA[strlen(g_cfgOld)], added[i]) == -1) { Format(why, sizeof(why), "entry not appended: %s", added[i][1]); EndCase(false, why); return; }
				if (StrContains(g_cfgA[strlen(g_cfgOld)], "\nafkbomb \"") != -1 || StrContains(g_cfgA[strlen(g_cfgOld)], "\nafkbomb_action \"") != -1)
					{ EndCase(false, "an entry that already existed was appended again"); return; }
				if (GetCvarInt("afkbomb") != 5 || GetCvarInt("afkbomb_action") != 1) { EndCase(false, "values already in the file were not applied"); return; }
				strcopy(g_cfgB, sizeof(g_cfgB), g_cfgA);
				ServerCommand("sm plugins reload afkbomb");
				Schedule(1.5, c, 2);
				return;
			}
			bool same = StrEqual(g_cfgA, g_cfgB);
			EndCase(same, same ? "missing entries appended after the old text; a complete file is left alone" : "a complete file was modified on the next load");
		}

		case C_CFG_FOREIGN:
		{
			char why[160];
			if (GetCvarInt("afkbomb") != 4) { EndCase(false, "the known line was not applied"); return; }
			if (FindConVar("mp_freezetime").FloatValue == 99.0) { EndCase(false, "a cvar the plugin does not own was changed"); return; }
			int n = CountInSmLog(g_cfgTypo);
			if (n != 1) { Format(why, sizeof(why), "unknown name logged %d times, expected once", n); EndCase(false, why); return; }
			EndCase(true, "foreign cvar untouched, unknown name logged once");
		}

		case C_CFG_MAP_CHANGE:
		{
			char path[PLATFORM_MAX_PATH], text[256];
			CfgPath("afkbomb", path, sizeof(path));
			if (step == 1)
			{
				if (CountInSmLog(g_cfgTypo) != 1) { EndCase(false, "setup: the unknown name was not logged at load"); return; }
				Format(text, sizeof(text), "%s 1\nafkbomb_msg \"0\"\n", g_cfgTypo);
				CfgWrite(path, text);
				Schedule(1.0, c, 2);
				return;
			}
			if (step == 2)
			{
				if (GetCvarInt("afkbomb_msg") != 1) { EndCase(false, "the edit took effect before the map changed"); return; }
				g_mapChanging = true;
				GetCurrentMap(text, sizeof(text));
				ServerCommand("changelevel %s", text);
				return;
			}
			// step 3: one second after the next map's configs ran
			g_interfered = false; // the map change fires the game's own round_start
			char why[160];
			if (GetCvarInt("afkbomb_msg") != 0) { EndCase(false, "edited value not in effect after the map change"); return; }
			int n = CountInSmLog(g_cfgTypo);
			if (n != 1) { Format(why, sizeof(why), "unknown name logged %d times over load + map change, expected once", n); EndCase(false, why); return; }
			EndCase(true, "value applied after the map change; unknown name still logged once");
		}

		case C_HUMAN_FIRST:
		{
			if (carrier == 0 || other == 0 || extra == 0) { EndCase(false, "a client is missing"); return; }
			if (step == 1)
			{
				NudgeClient(other);
				TeleportNear(extra, carrier);
				return;
			}
			if (HasC4(extra)) { EndCase(false, "bomb went to the bot although an active human was available"); return; }
			if (!HasC4(other)) { EndCase(false, "bomb not given to the active human"); return; }
			EndCase(true, "active human preferred over the closer bot");
		}

		case C_PICKUP_BLOCKED, C_PICKUP_AFTER_ACTIVITY, C_PICKUP_NEVER_FLAGGED, C_PICKUP_BLOCK_ENDS:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			int who = (c == C_PICKUP_NEVER_FLAGGED) ? other : carrier;
			if (who == 0) { EndCase(false, "a fake client is missing"); return; }
			if (c == C_PICKUP_BLOCK_ENDS && step == 2)
			{
				if (HasC4(carrier)) { EndCase(false, "setup: the AFK player picked the bomb up before the new round"); return; }
				FireNamedEvent("round_start");
				return;
			}
			if (step == 1)
			{
				if (c == C_PICKUP_AFTER_ACTIVITY)
					NudgeClient(carrier);
				if (!PutBombUnder(who)) { EndCase(false, "no bomb on the ground to put under the player"); return; }
				return;
			}
			if (c == C_PICKUP_BLOCK_ENDS && step == 4)
			{
				EndCase(HasC4(carrier), HasC4(carrier) ? "block gone in the new round, bomb picked up" : "AFK flag still blocked the pickup in the next round");
				return;
			}
			if (c == C_PICKUP_BLOCKED)
				EndCase(!HasC4(who) && BombOnGround(), !HasC4(who) && BombOnGround() ? "AFK player did not pick the bomb up" : "AFK player picked the bomb up (or it vanished)");
			else
				EndCase(HasC4(who), HasC4(who) ? "player picked the bomb up on touch" : "player could not pick the bomb up");
		}

		case C_BLOCK_ENDS_DISABLED:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1)
			{
				if (!PutBombUnder(carrier)) { EndCase(false, "no bomb on the ground to put under the player"); return; }
				return;
			}
			if (step == 2)
			{
				if (HasC4(carrier)) { EndCase(false, "setup: the AFK player picked the bomb up before the new round"); return; }
				SetCvarInt("afkbomb", 0);
				FireNamedEvent("round_start");
				return;
			}
			EndCase(HasC4(carrier), HasC4(carrier) ? "bomb picked up in the round that started disabled" : "AFK flag still blocked the pickup in a round that started with afkbomb 0");
		}

		case C_ENABLE_MID_FREEZE:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1) { SetCvarInt("afkbomb", 1); return; }
			if (step == 2)
			{
				if (!HasC4(carrier)) { EndCase(false, "afkbomb raised during freezetime started a check in that round"); return; }
				FireRoundStart();
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "next round did not check the carrier"); return; }
			EndCase(true, "no check in the round raised during freezetime, next round checked");
		}

		case C_HUMAN_DROP:
		{
			if (carrier == 0) { EndCase(false, "real client left"); return; }
			if (HasC4(carrier)) { EndCase(false, "idle real client kept the bomb (was the client being played?)"); return; }
			if (g_sayCount != 1) { EndCase(false, "bomb dropped but no say_team from the real client"); return; }
			bool okLang = StrContains(g_lastSay, "I appear to be afk") != -1;
			EndCase(okLang, okLang ? "idle real client dropped the bomb and said so in server language" : "drop message not in server language");
		}

		case C_HUMAN_GIVE_MSG:
		{
			if (step == 2) { EndCase(CheckGiveColours(carrier), g_colourWhy); return; } // the receiver is idle too and may drop it again by now
			if (carrier == 0 || other == 0) { EndCase(false, "a client is missing"); return; }
			if (HasC4(carrier)) { EndCase(false, "idle real client kept the bomb (was the client being played?)"); return; }
			if (!HasC4(other)) { EndCase(false, "bomb not given to the other T"); return; }
			if (g_chatOther != 0) { EndCase(false, "give message reached the client in the client's own language"); return; }
			if (g_chatSeen != 1)
			{
				char why[96];
				Format(why, sizeof(why), "%d server-language give message(s) sent to chat, expected exactly 1", g_chatSeen);
				EndCase(false, why);
				return;
			}
			Schedule(2.0, c, 2); // let the client write the line to its console.log
		}

		case C_EYE_MOVED, C_MONEY_CHANGED, C_DISABLE_MID:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1)
			{
				if (c == C_EYE_MOVED)
				{
					float ang[3];
					GetClientEyeAngles(carrier, ang);
					ang[1] += 45.0;
					TeleportEntity(carrier, NULL_VECTOR, ang, NULL_VECTOR);
				}
				else if (c == C_MONEY_CHANGED)
					SetEntProp(carrier, Prop_Send, "m_iAccount", GetEntProp(carrier, Prop_Send, "m_iAccount") + 100);
				else
					SetCvarInt("afkbomb", 0);
				return;
			}
			if (!HasC4(carrier)) { EndCase(false, "bomb was dropped anyway"); return; }
			EndCase(true, "bomb kept");
		}

		case C_DISABLE_LATE:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			if (carrier == 0) { EndCase(false, "late carrier gone"); return; }
			if (step == 2) { SetCvarInt("afkbomb", 0); return; }
			if (!HasC4(carrier)) { EndCase(false, "late check dropped the bomb after afkbomb=0"); return; }
			EndCase(true, "late checks stopped");
		}

		case C_REENABLE:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1) { SetCvarInt("afkbomb", 1); return; }
			if (step == 2)
			{
				if (!HasC4(carrier)) { EndCase(false, "bomb dropped in the round that started disabled"); return; }
				FireRoundStart();
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "next round did not check the carrier"); return; }
			EndCase(true, "disabled round untouched, next round checked");
		}

		case C_SELF_DROP:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1)
			{
				int c4 = GetPlayerWeaponSlot(carrier, CS_SLOT_C4);
				if (c4 == -1) { EndCase(false, "carrier had no bomb to drop"); return; }
				CS_DropWeapon(carrier, c4, true, true);
				return;
			}
			if (GetPluginStatus(FindPluginByFile("afkbomb.smx")) != Plugin_Running)
				{ EndCase(false, "afkbomb stopped running"); return; }
			EndCase(true, "plugin kept running with no carrier");
		}

		case C_GIVE_NO_BOUNCE:
		{
			if (carrier == 0 || other == 0) { EndCase(false, "a fake client is missing"); return; }
			if (step == 3) { NudgeClient(carrier); return; }
			if (HasC4(carrier)) { EndCase(false, "bomb bounced back to the original AFK carrier"); return; }
			if (step == 2) EndCase(true, "bomb stayed away from the AFK carrier");
		}

		case C_GIVE_PREFERS_MOVING, C_GIVE_PREFERS_MOVING_Z:
		{
			if (carrier == 0 || other == 0 || extra == 0) { EndCase(false, "a fake client is missing"); return; }
			if (step == 1)
			{
				NudgeClient(extra);
				return;
			}
			if (step == 2)
			{
				float vel[3];
				if (c == C_GIVE_PREFERS_MOVING) vel[1] = 200.0; else vel[2] = 300.0;
				TeleportEntity(other, NULL_VECTOR, NULL_VECTOR, vel);
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "carrier kept bomb"); return; }
			if (HasC4(extra)) { EndCase(false, "bomb went to the closer stationary T, not the moving one"); return; }
			if (!HasC4(other)) { EndCase(false, "bomb not given to the moving T"); return; }
			EndCase(true, "bomb given to the moving T");
		}

		case C_RECV_ACTIVE_OVER_AFK:
		{
			if (carrier == 0 || other == 0 || extra == 0) { EndCase(false, "a fake client is missing"); return; }
			if (HasC4(extra)) { EndCase(false, "bomb went to the AFK T"); return; }
			if (!HasC4(other)) { EndCase(false, "bomb not given to the active T"); return; }
			EndCase(true, "bomb given to the active T, not the AFK one");
		}

		case C_RECV_CLOSEST:
		{
			if (carrier == 0 || other == 0 || extra == 0) { EndCase(false, "a fake client is missing"); return; }
			if (step == 1)
			{
				NudgeClient(other);
				NudgeClient(extra);
				return;
			}
			float a[3], b[3];
			GetClientAbsOrigin(carrier, a);
			GetClientAbsOrigin(extra, b);
			if (GetVectorDistance(a, b) < 200.0) { EndCase(false, "setup: far T is not far from the carrier"); return; }
			if (HasC4(extra)) { EndCase(false, "bomb went to the farther active T"); return; }
			if (!HasC4(other)) { EndCase(false, "bomb not given to the closest active T"); return; }
			EndCase(true, "bomb given to the closest active T");
		}

		case C_NO_CANDIDATE:
		{
			if (carrier == 0 || other == 0) { EndCase(false, "a fake client is missing"); return; }
			if (HasC4(carrier)) { EndCase(false, "carrier kept bomb"); return; }
			if (HasC4(other)) { EndCase(false, "bomb given to an AFK T"); return; }
			if (!BombOnGround()) { EndCase(false, "bomb is not on the ground"); return; }
			char why[96];
			Format(why, sizeof(why), "%d say_team message(s), expected exactly 1", g_sayCount);
			EndCase(g_sayCount == 1, g_sayCount == 1 ? "bomb dropped with one drop message" : why);
		}

		case C_LATE_NO_CANDIDATE:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			if (carrier == 0 || other == 0) { EndCase(false, "a fake client is missing"); return; }
			if (HasC4(carrier)) { EndCase(false, "late carrier kept bomb"); return; }
			if (HasC4(other)) { EndCase(false, "late bomb given to an AFK T"); return; }
			if (!BombOnGround()) { EndCase(false, "bomb is not on the ground"); return; }
			char why[96];
			Format(why, sizeof(why), "%d say_team message(s), expected exactly 1", g_sayCount);
			EndCase(g_sayCount == 1, g_sayCount == 1 ? "late bomb dropped with one drop message" : why);
		}

		case C_STRIP_ACTIVE, C_STRIP_SECONDARY, C_STRIP_KNIFE, C_STRIP_KEEPS, C_DROPW_ACTIVE, C_DROPW_SECONDARY, C_DROPW_KNIFE, C_DROPW_KEEPS:
		{
			bool dropping = (c >= C_DROPW_ACTIVE && c <= C_DROPW_KEEPS);
			int kind = dropping ? c - C_DROPW_ACTIVE + C_STRIP_ACTIVE : c;
			if (carrier == 0) { EndCase(false, "a fake client is missing"); return; }
			if (dropping)
			{
				if (HasC4(carrier)) { EndCase(false, "bomb still held"); return; }
				if (!BombOnGround()) { EndCase(false, "bomb is not on the ground"); return; }
			}
			else
			{
				if (other == 0) { EndCase(false, "a fake client is missing"); return; }
				if (!HasC4(other)) { EndCase(false, "bomb not given to the other T"); return; }
			}
			int slot = (kind == C_STRIP_ACTIVE) ? CS_SLOT_PRIMARY : (kind == C_STRIP_SECONDARY || kind == C_STRIP_KEEPS) ? CS_SLOT_SECONDARY : CS_SLOT_KNIFE;
			int want = GetPlayerWeaponSlot(carrier, slot);
			int have = GetEntPropEnt(carrier, Prop_Send, "m_hActiveWeapon");
			if (have == -1) { EndCase(false, "old carrier left with no active weapon (empty hands)"); return; }
			if (want == -1 || have != want)
			{
				char hn[32], wn[32], why[96];
				GetEdictClassname(have, hn, sizeof(hn));
				if (want != -1) GetEdictClassname(want, wn, sizeof(wn)); else strcopy(wn, sizeof(wn), "(none in slot)");
				Format(why, sizeof(why), "old carrier holds %s, expected %s", hn, wn);
				EndCase(false, why);
				return;
			}
			// what the client draws: the view model must show the active weapon
			int vm = GetEntPropEnt(carrier, Prop_Send, "m_hViewModel", 0);
			if (vm != -1)
			{
				char why[128];
				int vmWeapon = GetEntPropEnt(vm, Prop_Send, "m_hWeapon");
				int vmModel = GetEntProp(vm, Prop_Send, "m_nModelIndex");
				int wModel = GetEntProp(have, Prop_Send, "m_iViewModelIndex");
				if (vmWeapon != have || vmModel != wModel)
				{
					Format(why, sizeof(why), "view model shows weapon %d model %d, active weapon %d expects model %d", vmWeapon, vmModel, have, wModel);
					EndCase(false, why);
					return;
				}
			}
			EndCase(true, "old carrier holds the expected weapon, view model shows it");
		}

		case C_ACTION_CT_ONLY:
		{
			if (carrier == 0 || extra == 0) { EndCase(false, "a fake client is missing"); return; }
			if (HasC4(extra)) { EndCase(false, "bomb given to a CT"); return; }
			if (HasC4(carrier)) { EndCase(false, "AFK carrier kept the bomb"); return; }
			if (!BombOnGround()) { EndCase(false, "bomb is not on the ground"); return; }
			EndCase(true, "bomb dropped, not given to the CT");
		}

		case C_MSG_ON, C_MSG_OFF:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (HasC4(carrier)) { EndCase(false, "bomb still held after afkbomb delay"); return; }
			char why[128];
			if (c == C_MSG_OFF)
			{
				Format(why, sizeof(why), "%d say_team message(s), expected 0", g_sayCount);
				EndCase(g_sayCount == 0, why);
				return;
			}
			if (g_sayCount != 1)
			{
				Format(why, sizeof(why), "%d say_team message(s), expected exactly 1", g_sayCount);
				EndCase(false, why);
				return;
			}
			bool ok = StrContains(g_lastSay, "[Afk Bomb] ") != -1 && StrContains(g_lastSay, "Drop Bomb") == -1;
			EndCase(ok, ok ? "one translated say_team message" : "message text is not the translated phrase");
		}

		case C_MSG_SERVER_LANG:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (HasC4(carrier)) { EndCase(false, "bomb still held after afkbomb delay"); return; }
			if (g_sayCount != 1)
			{
				char why[96];
				Format(why, sizeof(why), "%d say_team message(s), expected exactly 1", g_sayCount);
				EndCase(false, why);
				return;
			}
			bool ok = StrContains(g_lastSay, "I appear to be afk and I'm dropping the bomb.") != -1;
			EndCase(ok, ok ? "drop message in server language" : "drop message not in server language");
		}

		case C_ROUND_RESTART:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1) { FireRoundStart(); return; }
			if (step == 2)
			{
				if (!HasC4(carrier)) EndCase(false, "previous round's timer dropped the bomb");
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "new round's check never dropped the bomb"); return; }
			EndCase(true, "only the new round's check acted");
		}

		case C_LATE_FRESH_IDLE:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			if (carrier == 0 || other == 0) { EndCase(false, "a fake client is missing"); return; }
			if (HasC4(carrier)) { EndCase(false, "late carrier kept bomb"); return; }
			if (HasC4(other)) { EndCase(false, "bomb given to a T that was idle in the latest window"); return; }
			if (!BombOnGround()) { EndCase(false, "bomb is not on the ground"); return; }
			EndCase(true, "idle in the latest window: AFK, bomb dropped");
		}

		case C_LATE_COUNT_RESET:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			if (carrier == 0) { EndCase(false, "late carrier gone"); return; }
			if (step == 4) { NudgeClient(carrier); return; }
			if (step == 2)
			{
				if (!HasC4(carrier)) EndCase(false, "dropped although the carrier moved between checks");
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "not dropped after 3 fresh idle checks in a row"); return; }
			EndCase(true, "count restarted after the movement, dropped after 3 more idle checks");
		}

		case C_LATE_GIVE_RULES:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			if (carrier == 0 || other == 0) { EndCase(false, "a fake client is missing"); return; }
			if (step == 2)
			{
				if (!HasC4(other)) EndCase(false, "receiver of a late-check give lost the bomb before 2 late checks");
				return;
			}
			if (HasC4(other)) { EndCase(false, "receiver idle for 2 late checks kept the bomb"); return; }
			if (!BombOnGround()) { EndCase(false, "bomb is not on the ground"); return; }
			EndCase(true, "receiver judged under late-check rules");
		}

		case C_LATE_COUNT, C_LATE_GIVE:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			if (carrier == 0) { EndCase(false, "late carrier gone"); return; }
			if (c == C_LATE_GIVE)
			{
				if (other == 0) { EndCase(false, "other T gone"); return; }
				if (HasC4(carrier)) { EndCase(false, "late carrier kept bomb"); return; }
				if (!HasC4(other)) { EndCase(false, "bomb not given to the other T"); return; }
				EndCase(true, "late bomb moved to other T");
				return;
			}
			if (step == 2)
			{
				if (!HasC4(carrier)) EndCase(false, "dropped before 3 latechecks");
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "not dropped after 3 latechecks"); return; }
			EndCase(true, "dropped on the 3rd latecheck");
		}

		case C_DROP_STILL:
		{
			if (carrier == 0) { EndCase(false, "carrier gone before check"); return; }
			if (HasC4(carrier)) { EndCase(false, "bomb still held after afkbomb delay"); return; }
			EndCase(true, "bomb dropped");
		}

		case C_FREEZETIME_DELAY:
		{
			if (carrier == 0) { EndCase(false, "carrier gone before check"); return; }
			if (step < 3)
			{
				if (!HasC4(carrier)) EndCase(false, "bomb taken before freezetime + afkbomb elapsed");
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "bomb still held afkbomb seconds after freezetime ended"); return; }
			EndCase(true, "bomb taken afkbomb seconds after freezetime ended");
		}

		case C_FREEZE_PRE_ACTIVITY:
		{
			if (carrier == 0) { EndCase(false, "carrier gone before check"); return; }
			if (step == 1)
			{
				float pos[3];
				GetClientAbsOrigin(carrier, pos);
				pos[0] += 200.0;
				TeleportEntity(carrier, pos, NULL_VECTOR, NULL_VECTOR);
				return;
			}
			if (step == 2)
			{
				if (!HasC4(carrier)) EndCase(false, "bomb taken before the window after freezetime ended");
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "movement during freezetime saved the carrier"); return; }
			EndCase(true, "activity before freezetime ended did not count");
		}

		case C_FREEZE_CVAR_IGNORED:
		{
			if (carrier == 0) { EndCase(false, "carrier gone before check"); return; }
			if (step == 1)
			{
				if (!HasC4(carrier)) EndCase(false, "bomb taken before freezetime ended");
				return;
			}
			char desc[256];
			FindConVar("afkbomb_freezetime").GetDescription(desc, sizeof(desc));
			if (StrContains(desc, "deprecated", false) == -1) { EndCase(false, "description does not say deprecated"); return; }
			if (HasC4(carrier)) { EndCase(false, "afkbomb_freezetime=1 delayed the check"); return; }
			EndCase(true, "no effect on timing, described as deprecated");
		}

		case C_ACTIVE_BUTTON, C_ACTIVE_WEAPON:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1)
			{
				if (c == C_ACTIVE_BUTTON)
					g_forceButton = true;
				else
					GivePlayerItem(carrier, "weapon_ak47");
				return;
			}
			if (!HasC4(carrier)) { EndCase(false, "active carrier lost the bomb"); return; }
			EndCase(true, "bomb kept");
		}

		case C_DROP_MOVING:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1)
			{
				float pos[3];
				GetClientAbsOrigin(carrier, pos);
				pos[0] += 200.0;
				TeleportEntity(carrier, pos, NULL_VECTOR, NULL_VECTOR);
				return;
			}
			if (!HasC4(carrier)) { EndCase(false, "moved carrier lost bomb"); return; }
			EndCase(true, "bomb kept after movement");
		}

		case C_ACTION_GIVE:
		{
			if (carrier == 0 || other == 0) { EndCase(false, "a fake client is missing"); return; }
			if (HasC4(carrier)) { EndCase(false, "carrier kept bomb"); return; }
			if (!HasC4(other)) { EndCase(false, "bomb not given to the other T"); return; }
			EndCase(true, "bomb moved to other T");
		}

		case C_ACTION_LONE:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (HasC4(carrier)) { EndCase(false, "carrier kept the bomb"); return; }
			if (!BombOnGround()) { EndCase(false, "bomb is not on the ground"); return; }
			char why[96];
			Format(why, sizeof(why), "%d say_team message(s), expected exactly 1", g_sayCount);
			EndCase(g_sayCount == 1, g_sayCount == 1 ? "bomb dropped once with no other T" : why);
		}

		case C_DISABLED:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (!HasC4(carrier)) { EndCase(false, "bomb dropped while afkbomb=0"); return; }
			EndCase(true, "bomb kept while disabled");
		}

		case C_LATE_DROP:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			carrier = GetClientOfUserId(g_uidCarrier);
			if (carrier == 0) { EndCase(false, "late carrier gone"); return; }
			if (HasC4(carrier)) { EndCase(false, "late carrier not dropped after latechecks"); return; }
			EndCase(true, "late carrier dropped");
		}

		case C_LATE_NONE:
		{
			if (step == 1)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			carrier = GetClientOfUserId(g_uidCarrier);
			if (carrier == 0) { EndCase(false, "late carrier gone"); return; }
			if (!HasC4(carrier)) { EndCase(false, "latecheck=0 still dropped a late carrier"); return; }
			EndCase(true, "late carrier ignored");
		}

		case C_DEAD_CARRIER:
		{
			if (step == 1)
			{
				if (carrier == 0) { EndCase(false, "carrier gone"); return; }
				ForcePlayerSuicide(carrier);
				return;
			}
			if (other == 0) { EndCase(false, "other T gone"); return; }
			if (HasC4(other)) { EndCase(false, "dead carrier's bomb given to other T"); return; }
			EndCase(true, "bomb not given to other T");
		}

		case C_PLANT_STOPS_LATE, C_PLANT_NEXT_ROUND:
		{
			if (step == 1) { FireNamedEvent("bomb_planted"); return; }
			if (step == 2)
			{
				int late = SpawnFake("AFKTest Late", CS_TEAM_T, true);
				if (late == 0) { EndCase(false, "could not create late carrier"); return; }
				g_uidCarrier = GetClientUserId(late);
				return;
			}
			if (carrier == 0) { EndCase(false, "late carrier gone"); return; }
			if (c == C_PLANT_STOPS_LATE)
			{
				if (HasC4(carrier)) EndCase(true, "no late check ran after the plant");
				else EndCase(false, "late check dropped the bomb after the plant");
				return;
			}
			if (step == 3)
			{
				if (!HasC4(carrier)) { EndCase(false, "late check ran after the plant"); return; }
				FireRoundStart();
				return;
			}
			if (HasC4(carrier)) { EndCase(false, "next round's check never dropped the bomb"); return; }
			EndCase(true, "checks resumed in the next round");
		}

		case C_PLANT_PENDING:
		{
			if (carrier == 0) { EndCase(false, "carrier gone"); return; }
			if (step == 1) { FireNamedEvent("bomb_planted"); return; }
			if (GetPluginStatus(FindPluginByFile("afkbomb.smx")) != Plugin_Running)
				{ EndCase(false, "afkbomb stopped running"); return; }
			if (!HasC4(carrier)) { EndCase(false, "pending check acted after the plant"); return; }
			EndCase(true, "pending check ended quietly");
		}

		case C_DISCONNECT:
		{
			if (step == 1)
			{
				if (carrier == 0) { EndCase(false, "carrier gone"); return; }
				KickClient(carrier, "afkbomb test: disconnect");
				return;
			}
			if (GetPluginStatus(FindPluginByFile("afkbomb.smx")) != Plugin_Running)
				{ EndCase(false, "afkbomb stopped running after disconnect"); return; }
			EndCase(true, "plugin survived disconnect");
		}
	}
}

void SkipCase(const char[] why)
{
	LogToFileEx(g_logPath, "[SKIP] %s - %s", g_caseNames[g_curCase], why);
	PrintToServer("[SKIP] %s - %s", g_caseNames[g_curCase], why);
	g_skip++;
	g_attempt = 1;
	g_caseActive = false;
	CleanupFakes();
	CreateTimer(0.5, Timer_NextCase, g_curCase + 1, TIMER_FLAG_NO_MAPCHANGE);
}

void EndCase(bool ok, const char[] msg)
{
	if (!g_caseActive)
		return; // already ended (setup failure)

	char line[256];
	if (g_interfered && g_attempt < MAX_ATTEMPTS)
	{
		// The game restarted the round mid-case (respawns, bomb re-dealt): the result means nothing. Run it again.
		PrintToServer("[afkbomb_test] real round_start during \"%s\" (attempt %d); retrying", g_caseNames[g_curCase], g_attempt);
		g_attempt++;
		g_caseActive = false;
		CleanupFakes();
		CreateTimer(1.5, Timer_NextCase, g_curCase, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}
	if (g_interfered)
		LogToFileEx(g_logPath, "[WARN] game fired its own round_start during every attempt of \"%s\"; result may be unreliable", g_caseNames[g_curCase]);
	g_attempt = 1;

	if (ok && ErrorLogSize() > g_errSizeAtStart)
	{
		ok = false;
		Format(line, sizeof(line), "[FAIL] %s - SourceMod logged errors during this case (see logs/errors_*.log)", g_caseNames[g_curCase]);
	}
	else
		Format(line, sizeof(line), "[%s] %s - %s", ok ? "PASS" : "FAIL", g_caseNames[g_curCase], msg);
	LogToFileEx(g_logPath, "%s", line);
	PrintToServer("%s", line);

	if (ok) g_pass++; else { g_fail++; LogFakes("at failure"); }

	g_caseActive = false;
	CleanupFakes();
	CreateTimer(0.5, Timer_NextCase, g_curCase + 1, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_NextCase(Handle timer, any next)
{
	int n = view_as<int>(next);
	if (n >= NUM_CASES)
	{
		g_running = false;
		ResetCvars();
		char cfg[PLATFORM_MAX_PATH];
		CfgPath("afkbomb", cfg, sizeof(cfg)); // leave no edited config behind for the next run
		DeleteFile(cfg);
		CfgPath("afkbomb_tests", cfg, sizeof(cfg));
		DeleteFile(cfg);
		if (GetPluginStatus(FindPluginByFile("afkbomb.smx")) != Plugin_Running)
		{
			g_fail++;
			LogToFileEx(g_logPath, "[FAIL] afkbomb.smx is no longer running at the end of the suite");
		}
		char summary[128];
		Format(summary, sizeof(summary), "tests finished: %d passed, %d failed, %d skipped", g_pass, g_fail, g_skip);
		LogToFileEx(g_logPath, "%s", summary);
		PrintToServer("[afkbomb_test] %s", summary);
		g_running = false;
		if (g_cvAutorun.BoolValue)
		{
			// leave the plugin/extension state in console.log for test.ps1, then quit
			ServerCommand("sm plugins list");
			ServerCommand("sm exts list");
			CreateTimer(1.0, Timer_Quit);
		}
		return Plugin_Stop;
	}
	StartCase(n);
	return Plugin_Stop;
}

public Action Timer_Quit(Handle timer)
{
	ServerCommand("quit");
	return Plugin_Stop;
}

//===== Helpers =====

// Size of today's SourceMod error log; it grows whenever any plugin throws.
int ErrorLogSize()
{
	char date[16], path[PLATFORM_MAX_PATH];
	FormatTime(date, sizeof(date), "%Y%m%d");
	BuildPath(Path_SM, path, sizeof(path), "logs/errors_%s.log", date);
	return FileExists(path) ? FileSize(path) : 0;
}

int SpawnFake(const char[] name, int team, bool withBomb)
{
	if (g_fakeCount >= MAX_FAKE)
		return 0;

	int c = CreateFakeClient(name);
	if (c <= 0)
		return 0;

	g_fakeUids[g_fakeCount++] = GetClientUserId(c);
	ChangeClientTeam(c, team);
	CS_RespawnPlayer(c);
	PlaceApart(c, team);
	if (withBomb)
		GivePlayerItem(c, "weapon_c4");
	return c;
}

// Moves a fake client to the spawn point farthest from every other living player, so fakes never
// nudge each other and a dropped bomb never lands on a bystander (both made results random).
void PlaceApart(int client, int team)
{
	float best[3], pos[3], other[3];
	float bestDist = -1.0;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, (team == CS_TEAM_CT) ? "info_player_counterterrorist" : "info_player_terrorist")) != -1)
	{
		GetEntPropVector(ent, Prop_Data, "m_vecOrigin", pos);
		float nearest = 99999.0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i))
				continue;
			GetClientAbsOrigin(i, other);
			float d = GetVectorDistance(pos, other);
			if (d < nearest)
				nearest = d;
		}
		if (nearest > bestDist)
		{
			bestDist = nearest;
			best = pos;
		}
	}
	if (bestDist >= 0.0)
		TeleportEntity(client, best, NULL_VECTOR, NULL_VECTOR);
}

// One line per fake client: where it is and whether it holds the bomb (context for a failed case).
void LogFakes(const char[] when)
{
	float pos[3];
	for (int i = 0; i < g_fakeCount; i++)
	{
		int c = GetClientOfUserId(g_fakeUids[i]);
		if (c <= 0 || !IsClientInGame(c))
			continue;
		GetClientAbsOrigin(c, pos);
		LogToFileEx(g_logPath, "[INFO]   %s: %N alive=%d c4=%d pos=(%.0f %.0f %.0f)", when, c, IsPlayerAlive(c), HasC4(c), pos[0], pos[1], pos[2]);
	}
}

void CleanupFakes()
{
	for (int i = 0; i < g_fakeCount; i++)
	{
		int c = GetClientOfUserId(g_fakeUids[i]);
		if (c > 0 && IsClientConnected(c) && IsFakeClient(c))
			KickClient(c, "afkbomb test cleanup");
	}
	g_fakeCount = 0;
	ParkHuman();

	// Bombs dropped by a finished case must not be picked up in the next one.
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "weapon_c4")) != -1)
		AcceptEntityInput(ent, "Kill");
}

// The real client sits in spectator except during its own cases, so it is never "another T".
void ParkHuman()
{
	int h = FindHuman();
	if (h != 0 && GetClientTeam(h) != CS_TEAM_SPECTATOR)
		ChangeClientTeam(h, CS_TEAM_SPECTATOR);
}

// Shows activity without changing where the client stands (fakes look around; a real client's view is its own).
void NudgeClient(int client)
{
	if (IsFakeClient(client))
	{
		float ang[3];
		GetClientEyeAngles(client, ang);
		ang[1] += 30.0;
		TeleportEntity(client, NULL_VECTOR, ang, NULL_VECTOR);
	}
	else
	{
		float pos[3];
		GetClientAbsOrigin(client, pos);
		pos[0] += 30.0;
		TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);
	}
}

void TeleportNear(int client, int ref)
{
	float pos[3];
	GetClientAbsOrigin(ref, pos);
	pos[0] += 120.0;
	TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);
}

// Moves the bomb lying on the ground onto the client, so it touches them. false if there is none.
bool PutBombUnder(int client)
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "weapon_c4")) != -1)
	{
		if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") == -1)
		{
			float pos[3];
			GetClientAbsOrigin(client, pos);
			pos[2] += 8.0;
			TeleportEntity(ent, pos, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
			return true;
		}
	}
	return false;
}

bool BombOnGround()
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "weapon_c4")) != -1)
		if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") == -1)
			return true;
	return false;
}

bool HasC4(int client)
{
	return GetPlayerWeaponSlot(client, CS_SLOT_C4) != -1;
}

// round_start now; round_freeze_end `freeze` seconds later (the game fires both; the suite fires them itself).
// Checks begin at freeze end, so the default 1.0s also lets freshly spawned fakes settle.
void FireRoundStart(float freeze = 1.0)
{
	FireNamedEvent("round_start");
	CreateTimer(freeze, Timer_FreezeEnd, g_curCase, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_FreezeEnd(Handle timer, any data)
{
	if (g_caseActive && view_as<int>(data) == g_curCase)
		FireNamedEvent("round_freeze_end");
	return Plugin_Stop;
}

void FireNamedEvent(const char[] name)
{
	Event ev = CreateEvent(name);
	if (ev != null)
	{
		g_selfFire = true;
		ev.Fire(false);
		g_selfFire = false;
	}
}

void ResetCvars()
{
	SetCvarInt("afkbomb", 2);
	SetCvarInt("afkbomb_freezetime", 0);
	SetCvarInt("afkbomb_action", 0);
	SetCvarInt("afkbomb_msg", 1);
	SetCvarInt("afkbomb_latecheck", 2);
	SetCvarFloat("afkbomb_latecheckdelay", 5.0);
	SetCvarInt("afkbomb_latecheckaction", 1);
	SetCvarFloat("mp_freezetime", g_origFreezetime);
	int human = FindHuman();
	if (human != 0)
		SetClientLanguage(human, GetServerLanguage());
	if (!g_running && g_origIgnoreWin != -1)
	{
		SetCvarInt("mp_ignore_round_win_conditions", g_origIgnoreWin);
		g_origIgnoreWin = -1;
	}
}

void SetCvarInt(const char[] name, int value)
{
	ConVar cv = FindConVar(name);
	if (cv != null)
		cv.IntValue = value;
}

void SetCvarFloat(const char[] name, float value)
{
	ConVar cv = FindConVar(name);
	if (cv != null)
		cv.FloatValue = value;
}

int GetCvarInt(const char[] name)
{
	ConVar cv = FindConVar(name);
	return (cv != null) ? cv.IntValue : -999;
}

float GetCvarFloat(const char[] name)
{
	ConVar cv = FindConVar(name);
	return (cv != null) ? cv.FloatValue : -999.0;
}

//===== Config file helpers =====

void CfgPath(const char[] name, char[] out, int max)
{
	BuildPath(Path_SM, out, max, "configs/%s.cfg", name);
}

void CfgWrite(const char[] path, const char[] text)
{
	File f = OpenFile(path, "wb");
	if (f == null)
	{
		LogError("cannot write %s", path);
		return;
	}
	f.WriteString(text, false);
	delete f;
}

bool CfgRead(const char[] path, char[] out, int max)
{
	out[0] = '\0';
	File f = OpenFile(path, "rb");
	if (f == null)
		return false;
	int size = FileSize(path);
	if (size >= max)
		size = max - 1;
	int n = (size > 0) ? f.ReadString(out, max, size) : 0;
	delete f;
	out[(n > 0) ? n : 0] = '\0';
	return true;
}

// The comment lines directly above the entry that starts at g_cfgA[at] (back to the previous blank line).
void CfgBlockBefore(int at, char[] out, int max)
{
	int start = at;
	while (start > 0 && !(g_cfgA[start - 1] == '\n' && start >= 2 && g_cfgA[start - 2] == '\n'))
		start--;
	int len = at - start + 2; // includes the newline that ends the last comment line
	if (len > max) len = max;
	strcopy(out, len, g_cfgA[start]);
}

// Lines of today's SourceMod log that contain text.
int CountInSmLog(const char[] text)
{
	char date[16], path[PLATFORM_MAX_PATH], line[512];
	FormatTime(date, sizeof(date), "%Y%m%d");
	BuildPath(Path_SM, path, sizeof(path), "logs/L%s.log", date);
	File f = OpenFile(path, "r");
	if (f == null)
		return 0;
	int n = 0;
	while (f.ReadLine(line, sizeof(line)))
		if (StrContains(line, text) != -1)
			n++;
	delete f;
	return n;
}
