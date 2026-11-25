# SourceMod-AFKbomb

Fork of the AFK Bomb SourceMod plugin (https://forums.alliedmods.net/showthread.php?p=1429371)
for Counter-Strike: Source. Goal: verify it still works on the current game build and fix it if not.

## Layout

- `scripting/*.sp` — plugin source; `scripting/include/` — project-local includes (currently none)
- `incs/` — git submodule of https://github.com/Ballganda/SourceMod-Incs, pinned to a commit; shared includes
  (`instance_config.inc`) live in `incs/scripting/include/`. Never edit them here: change them in SourceMod-Incs,
  then bump the pointer (`git -C incs pull origin main`, test, commit `incs`). Fresh clone: `git submodule update --init`.
- `plugins/*.smx`, `plugins/*.zip` — build output (git-ignored)
- `build.ps1` — compile; `-Deploy` also copies the `.smx` to the test server; `-Package` also writes the release
  zip `plugins/afkbomb-<version>.zip` (plugin, translations, source, the includes `afkbomb.sp` uses, and the GPL v3 `LICENSE` as
  `scripting/afkbomb-LICENSE.txt`)
- `tests/afkbomb_tests.sp` — regression suite plugin (`afkbomb_test` on the server console)
- `test.ps1` — build, deploy, run the suite on a fresh srcds, then scan `afkbomb_tests.log`, SourceMod
  `L*.log`/`errors_*.log` and `console.log` for errors; exit code 0 = clean. `-WithClient` also launches the
  CS:S client so the five real-client cases run; `-InjectError` proves the error detection (must fail);
  `-ScanOnly` scans the current logs without running anything. `-ServerDir` and `-Port` run it on a test slot
  (set `SOURCEMOD_DIR` to the slot's `addons\sourcemod` so the build deploys there).

## Test server

- Operating the server and the CS:S client for tests: the `srcds-testing` skill
  (`~/.claude/skills/srcds-testing/SKILL.md`, personal to this PC, not in this repo). Read it before starting
  srcds or the client, running `test.ps1`, or writing a test case.
- Install: `C:\Users\user\cssds`; SourceMod in `cstrike\addons\sourcemod` (`build.ps1` uses its `spcomp.exe`).
- Per-instance config: `incs/scripting/include/instance_config.inc` writes `configs/<plugin>.cfg` under the SourceMod
  path (never game `cfg`). Under a second SourceMod base path (see the skill) the file and the `L*.log` appear
  only under that path.

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

- Issue tracker: GitHub Issues on `Ballganda/SourceMod-AFKbomb` via `gh`. See `docs/agents/issue-tracker.md`.
- Triage labels: see `docs/agents/triage-labels.md`.
- Domain docs: see `docs/agents/domain.md`.
- Models: see `docs/agents/models.md`.
- Replies: to the user in chat. First line, when the message gave an instruction, decision or correction beyond a bare "yes": "Understood: <your interpretation>". Next line: the outcome, in one sentence. Then bullets, each a short clause holding exactly one fact; a reason, example or consequence gets its own bullet. Number them when the user answers per item. Each offer of further work is its own numbered item with a recommendation that "yes" accepts, as is each of two or more decisions. Use a table to compare items across attributes, a code block for code. Write prose when the user asks for an explanation. A subagent's Report follows its caller's format.
