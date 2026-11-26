# AFK Bomb

A SourceMod plugin for Counter-Strike: Source. When the terrorist carrying the bomb is AFK, the plugin gives
the bomb to an active teammate or drops it, so one absent player cannot stall a whole round.

This is a maintained fork of **[CS:S+GO] Afk Bomb** by RedSword / Bob Le Ponge
([AlliedModders thread](https://forums.alliedmods.net/showthread.php?p=1429371), last original version 1.5.0,
2012). Version 1.5.1 was checked against the current CS:S build with SourceMod 1.12 and fixes the problems found.
1.5.2 rewrites the source in current SourcePawn syntax without changing behaviour. 1.5.3 relicenses it
under GPL v3, as SourceMod requires. 1.5.4 removes two square roots from choosing the bomb receiver, without
changing behaviour.

In the original author's words, the point is "short-afking": a player who alt-tabs for a few seconds, or spends
the whole freezetime in the buy menu, should not leave the team without its bomb. It is not an AFK kicker; use
it next to one if you also want to deal with long-term AFK players.

## Requirements

- Counter-Strike: Source dedicated server.
- MetaMod:Source and SourceMod 1.12 or newer. The plugin uses the `sdktools`, `sdkhooks` and `cstrike`
  extensions, which ship with SourceMod.
- No gamedata file. Dropping the bomb uses SourceMod's built-in `CS_DropWeapon`.

The original thread reports 1.5.0 working on CS:GO. 1.5.1 to 1.5.4 have only been tested on CS:S.

## Installation

1. Download `afkbomb-1.5.4.zip` from the [Releases](https://github.com/Ballganda/SourceMod-AFKbomb/releases)
   page.
2. Extract it into the server's `cstrike` folder. The zip already contains the `addons/sourcemod/...` folders,
   so the files land here:

   | File | Path | Needed |
   | --- | --- | --- |
   | Plugin | `cstrike/addons/sourcemod/plugins/afkbomb.smx` | yes |
   | Translations | `cstrike/addons/sourcemod/translations/afkbomb.phrases.txt` | **yes**: without it the drop and give messages fail with a missing-phrase error |
   | Source | `cstrike/addons/sourcemod/scripting/afkbomb.sp` | no, only to recompile |
   | Include | `cstrike/addons/sourcemod/scripting/include/instance_config.inc` | no, only to recompile |
   | License | `cstrike/addons/sourcemod/scripting/afkbomb-LICENSE.txt` | no, the GPL v3 text |

3. Restart the server, or change the map, or run `sm plugins load afkbomb` in the server console.
4. Check it loaded: `sm plugins list` shows `Afk Bomb (1.5.4)`, and `afkbombversion` prints `1.5.4`.
5. On first load the plugin writes its settings file, `cstrike/addons/sourcemod/configs/afkbomb.cfg`, with every
   cvar at its default. Edit that file to change settings; it is applied on every map.

### Upgrading from 1.5.0 or older

- Replace `afkbomb.smx` and `afkbomb.phrases.txt`.
- 1.5.0 had no settings file of its own, so its cvars were usually set in `server.cfg`. 1.5.1 applies
  `addons/sourcemod/configs/afkbomb.cfg` after `server.cfg` on every map, so that file wins: move your values
  into it and remove the `afkbomb*` lines from `server.cfg`.
- `afkbomb_freezetime` is still accepted but has no effect; see [Changes in 1.5.1](#changes-in-151).

### Several servers on one installation

The settings file is under the SourceMod path, not the shared game `cfg` folder. Servers that share one game
install but start with their own `+sm_basepath` each get, and keep, their own `afkbomb.cfg`.

## How it works

1. When freezetime ends, the plugin records the state of every living terrorist: position, angles, eye angles,
   velocity, pressed buttons, money, armour and weapons.
2. `afkbomb` seconds later it compares each terrorist with that record. A player whose state has not changed at
   all is AFK.
3. If the bomb carrier is AFK, the plugin applies `afkbomb_action`:
   - **give** (0): the bomb goes to the best active teammate. Humans come before bots, moving players before
     still ones, then the nearest to the AFK carrier. If no teammate is active, the bomb is dropped instead.
   - **drop** (1): the bomb is dropped on the ground and the carrier says so in team chat.
4. A player judged AFK cannot pick the bomb up again until they do something.
5. If the carrier was active, late checks follow: every `afkbomb_latecheckdelay` seconds the plugin takes a new
   record and compares again. After `afkbomb_latecheck` intervals in a row with the carrier unchanged, it applies
   `afkbomb_latecheckaction`. Late checks also follow the bomb to whoever picks it up next.
6. Checks stop when the bomb is planted and restart every round.

If the bomb was in the carrier's hands, they switch to their primary, secondary or knife, so their hands are never
empty.

## Cvars

| Cvar | Default | Description |
| --- | --- | --- |
| `afkbomb` | `2` | Seconds after freezetime ends before the first AFK check. `0` disables the plugin; setting it to `0` mid-round also cancels the checks already running. |
| `afkbomb_action` | `0` | Carrier AFK at the first check: `0` give to an active teammate (dropped if there is none), `1` drop. |
| `afkbomb_msg` | `1` | `1` announces the action: team chat from the carrier on a drop, chat to everyone on a give. `0` is silent. |
| `afkbomb_latecheck` | `2` | Number of late-check intervals the carrier must stay unchanged before the late action. `0` disables late checks. |
| `afkbomb_latecheckdelay` | `5.0` | Seconds per late-check interval. Minimum `1.0`. |
| `afkbomb_latecheckaction` | `1` | Carrier AFK at a late check: `0` give, `1` drop. Giving is not recommended here, since a player can fake being AFK to send the bomb across the map. |
| `afkbomb_freezetime` | `0` | **Deprecated** since 1.5.1, ignored. Checks always start when freezetime ends. |
| `afkbombversion` | `1.5.4` | Plugin version (read-only). |

Example `addons/sourcemod/configs/afkbomb.cfg` lines: `afkbomb 3` or `afkbomb_action "1"`. Lines starting with
`//` are comments.

## Translations

Messages come from `translations/afkbomb.phrases.txt`, in the **server's** language (`sv_language` /
SourceMod's `ServerLang`), so every player sees the same text.

Languages: English, French, Russian (drop message only), Brazilian Portuguese, Polish, Dutch, German, Lithuanian,
Korean, Slovak and Czech. Translators credited in the original thread: noPASARAN (ru), away000 (pt), sajmon83 (pl),
Groger (nl), Dr. Greg House (de), hleV (lt), Blowst (ko), musosoft (sk, cze), RedSword (fr).

## Changes in 1.5.4

Performance only, no behaviour change. No cvar, phrase or config entry was added, renamed or removed.

- Choosing the bomb receiver compares squared distances and checks the velocity components for zero, so it
  computes no square roots. The receiver order is the same.

## Changes in 1.5.3

License and source only, no behaviour change. No cvar, phrase or config entry was added, renamed or removed.

- The plugin is licensed under GPL v3, as SourceMod requires of plugins; 1.5.1 and 1.5.2 were published as CC0.
  The release zip includes the license text and `afkbomb.sp` carries the GPL notice.
- The `instance_config.inc` registration function takes a typed `ConVar` instead of a `Handle`.

## Changes in 1.5.2

Source rewrite, no behaviour change. No cvar, phrase or config entry was added, renamed or removed.

- `afkbomb.sp` uses the SourcePawn 1.7+ transitional syntax (`#pragma newdecls required`) and compiles with no
  warnings on SourceMod 1.12.
- Money is read through the named `m_iAccount` property instead of a raw `FindSendPropOffs` offset.
- The removed `FCVAR_PLUGIN` flag is dropped from every cvar.
- Weapon slots are named with the `CS_SLOT_*` constants instead of numbers.
- The per-player AFK snapshot is one `enum struct` instead of nine parallel arrays.

## Changes in 1.5.1

Behaviour fixes. No cvar or phrase was renamed or removed.

- AFK detection starts when freezetime ends, instead of one second after round start plus an optional freezetime.
  A player buying during freezetime is no longer judged AFK, and the timing no longer depends on `mp_freezetime`.
- The bomb goes only to an active teammate, never to another AFK player; with nobody active it is dropped.
- An AFK player cannot pick the dropped bomb straight back up, which ended the old drop loop on some spawns.
- The carrier's hands switch to a weapon when a held bomb is taken.
- `afkbomb 0` cancels checks already running, not only future rounds.
- Late checks stop when the bomb is planted, and each interval is judged on a fresh record.
- Drop and give messages are sent once per bomb movement, in the server language, keeping the chat colours.
- Settings live in `addons/sourcemod/configs/afkbomb.cfg`, one file per SourceMod path.
- `afkbomb_freezetime` is deprecated and ignored.

<details>
<summary>Original changelog, 1.0.0 to 1.5.0 (RedSword)</summary>

- **1.0.0** (2011-03-07) Initial release.
- **1.0.1** Checks money too; timers no longer survive a map change.
- **1.1.0** The AFK carrier says in team chat that they are dropping the bomb; translation file (en, fr).
- **1.2.0** `afkbomb_msg` makes that message optional.
- **1.2.1** First check moved from 0.5 s to 1.0 s after round start (some de_dust2 spawns drop the player for
  longer than 0.5 s).
- **1.2.2** Fixed a carrier leaving between the two checks.
- **1.2.3** Fixed two checks running at once after a round restart; CS:S DM support.
- **1.3.0** Late (mid-round) checks.
- **1.3.1** Bomb is thrown further when dropped.
- **1.3.2** Fixed a timer memory leak; approved on AlliedModders.
- **1.4.0** `afkbomb_action`: give the bomb to a random terrorist instead of dropping it.
- **1.4.1** Checks restart at once after a give.
- **1.4.2** No more gamedata file: uses SourceMod 1.4's `CS_DropWeapon`.
- **1.5.0** (2012-04-21) `afkbomb_latecheckaction`; moving players get the bomb before still ones; default is
  give at round start, drop mid-round.

</details>

## Building from source

The `instance_config` include is maintained in [SourceMod-Incs](https://github.com/Ballganda/SourceMod-Incs) and
pulled in as the `incs` git submodule, pinned to a commit. Clone with it:

```
git clone --recurse-submodules https://github.com/Ballganda/SourceMod-AFKbomb.git
```

In an existing clone run `git submodule update --init`.

`build.ps1` compiles `scripting/afkbomb.sp` with the `spcomp` of a local SourceMod install (`-SourceModDir`, or the
`SOURCEMOD_DIR` environment variable) into `plugins/afkbomb.smx`. `-Deploy` also copies the plugin and
translations to that install. `-Package` also writes the release zip, `plugins/afkbomb-<version>.zip`, with the
include copied in from the submodule. To compile by hand:

```
spcomp scripting/afkbomb.sp -iincs/scripting/include -o plugins/afkbomb.smx
```

To move to a newer include: `git -C incs pull origin main`, run the tests, commit the new `incs` pointer.

## Tests

`tests/afkbomb_tests.sp` is a regression suite plugin (`afkbomb_test` in the server console). `test.ps1` builds,
deploys, runs it on a fresh local srcds and scans the server and SourceMod logs; exit code 0 means clean.
`-WithClient` also starts the CS:S client for the cases that need a real player (chat, view model, idling).

## Credits

- **RedSword / Bob Le Ponge**: original author, versions 1.0.0 to 1.5.0.
- dalto (botdropbomb drop code), AltPluzF4, AtomicStryker, Dr!fter, TnTSCS (drop-weapon signatures), psychonic
  (memory leak report, approval), sinblaster (testing), and the SourceMod team (`CS_DropWeapon`), as credited in
  the original.
- **BallGanda**: 1.5.1 to 1.5.4.

## License

GNU General Public License, version 3: see [LICENSE](LICENSE). SourceMod requires plugins to be released
under GPL v3 ([SourceMod license](https://www.sourcemod.net/license.php)). The release zip includes the license as
`addons/sourcemod/scripting/afkbomb-LICENSE.txt`.
