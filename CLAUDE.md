# SourceMod-AFKbomb

Fork of the AFK Bomb SourceMod plugin (https://forums.alliedmods.net/showthread.php?p=1429371)
for Counter-Strike: Source. Goal: verify it still works on the current game build and fix it if not.

## Layout

- `scripting/*.sp` — plugin source; `scripting/include/` — project-local includes
- `plugins/*.smx` — build output (git-ignored)
- `build.ps1` — compile; `build.ps1 -Deploy` also copies the `.smx` to the test server

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
