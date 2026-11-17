# SourceMod-AFKbomb

Fork of the AFK Bomb SourceMod plugin (https://forums.alliedmods.net/showthread.php?p=1429371)
for Counter-Strike: Source. Goal: verify it still works on the current game build and fix it if not.

## Layout

- `scripting/*.sp` — plugin source; `scripting/include/` — project-local includes
- `plugins/*.smx` — build output (git-ignored)
- `build.ps1` — compile; `build.ps1 -Deploy` also copies the `.smx` to the test server
- `tests/afkbomb_tests.sp` — regression suite plugin (`afkbomb_test` on the server console)
- `test.ps1` — build, deploy, run the suite on a fresh srcds, then scan `afkbomb_tests.log`, SourceMod
  `L*.log`/`errors_*.log` and `console.log` for errors; exit code 0 = clean. `-WithClient` also launches the
  CS:S client so the two real-client cases run; `-InjectError` proves the error detection (must fail);
  `-ScanOnly` scans the current logs without running anything.

## Test server

- Install: `C:\Users\user\cssds` (CS:S dedicated server, **32-bit** `srcds.exe`, tickrate enabler VSP at 100 tick)
- MetaMod:Source 1.12 and SourceMod 1.12 (stable branch) in `cstrike\addons\`
- Compiler: `cstrike\addons\sourcemod\scripting\spcomp.exe`; stock includes in `scripting\include`
- Start: `srcds.exe -console -game cstrike -condebug -tickrate 100 +sv_lan 1 +maxplayers 10 +map de_dust2`
- Logs: `cstrike\console.log` (needs `-condebug`), `cstrike\addons\sourcemod\logs\L*.log` and `errors_*.log`
- Console checks: `meta list`, `sm plugins list`, `sm exts list`, `sm plugins reload <name>`
- RCON listens on the LAN IP, not 127.0.0.1
- `Unable to load plugin "addons/metamod/bin/win64/server"` at boot is expected (the x64 VDF on a 32-bit server)
- Testing without human clients: set `bot_join_after_player 0` or bots never join (`sv_hibernate_when_empty`
  does not exist in CS:S). AI bots are not a valid "AFK" player even with `bot_stop 1` — their eye angles keep
  swaying. Use an AI-less `CreateFakeClient` from a helper plugin; it stands perfectly still.
- `PrintToChat*` skips fake clients, so chat output can only be seen with a real client connected.
- Console output of a command run over RCON goes to the RCON reply, not to `console.log`.
- `translations/*.txt` deploy to `addons\sourcemod\translations`
- CS:S client on this PC: `C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source`
  (`cstrike_win64.exe`, launch with `steam.exe -applaunch 240 -condebug +connect <LAN IP>:27015`); chat it
  receives lands in its `cstrike\console.log`. A plugin can put it on a team with `ChangeClientTeam` +
  `CS_RespawnPlayer`, so no input is needed in the game window; left alone it is a genuine AFK player.
- Fake clients joining/leaving end the round ("Game will not start until both teams have players") and the
  game restarts it a few seconds later under whatever is running; set `mp_ignore_round_win_conditions 1`.
- Fake clients spawned on neighbouring spawn points nudge each other and pick up each other's dropped bombs;
  place them on far-apart spawn points for repeatable results.
- `LogToFileEx` paths are relative to the game dir; use `BuildPath(Path_SM, ...)` for `logs/`.

## SourcePawn notes

References: API https://sm.alliedmods.net/new-api/ · compiler https://github.com/alliedmodders/sourcepawn ·
syntax https://wiki.alliedmods.net/SourcePawn_Transitional_Syntax · stock plugin sources in the server's
`scripting\` folder are the best examples of current style.

- Write new code in the 1.7+ "transitional" syntax with `#pragma semicolon 1` and `#pragma newdecls required`:
  `int x; float f; bool b; char buf[64]; Handle h;` and `public void OnPluginStart()`.
- Old (pre-1.7) plugins use `new x`, `new String:buf[64]`, `Float:`, `Handle:`, `public Action:Cmd(client, args)`.
  spcomp 1.12 still compiles most of it, but mixing styles in a file with `newdecls required` is an error.
- Common breakage when rebuilding 2011-era plugins on 1.12:
  - `FCVAR_PLUGIN` removed — delete the flag
  - `GetClientAuthString` → `GetClientAuthId(client, AuthId_Steam2, ...)`
  - `FindSendPropOffs` → `FindSendPropInfo`; prefer `GetEntProp`/`SetEntProp` over raw offsets
  - `Handle` + `CloseHandle` still work; methodmaps (`ConVar`, `ArrayList`, `StringMap`, `Menu`, `Event`) are preferred
  - `FindConVar`/`CreateConVar` return `ConVar`; `HookEvent` callbacks take `Event event`
  - `funcenum`/`functag` replaced by `typeset`/`typedef`; `decl` is a no-op, use plain declarations
  - `INVALID_HANDLE` → `null`; `String:` format-class functions unchanged
- Client indexes are 1..MaxClients; always check `IsClientInGame` before touching a client.
  Pass `GetClientUserId` (not the index) into timers and resolve with `GetClientOfUserId`.
- Timers: `CreateTimer(interval, cb, data, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE)`; never keep a timer handle
  across map change without clearing it.
- CS:S specifics: `#include <cstrike>` and `<sdktools>`; teams are `CS_TEAM_T` (2) / `CS_TEAM_CT` (3);
  bomb is `weapon_c4`, `CS_SLOT_C4`; `CS_DropWeapon`, events `bomb_pickup`, `bomb_dropped`, `bomb_planted`, `round_start`.
- Plugins that rely on signatures/offsets (gamedata) are what game updates break; pure-API plugins rarely break.

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in `Ballganda/SourceMod-AFKbomb`, via `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
