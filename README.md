# Xenia fixes & patches

Game patches, emulator source fixes, configuration templates and local verification tools for Xenia Canary and Edge.

**Find a game below.** Ready-to-copy game TOMLs live in [`patches/`](patches/); game-specific generators and tests live in [`games/`](games/). Emulator changes and pinned build recipes live in [`emulator/`](emulator/). The [patch manager](tools/patch-manager/) is a separate tool, not a requirement for manual installation.

## Install a game patch

1. Match the **Title ID and loaded module hash**, including the title update and disc/module variant. Read the patch description and its source documentation.
2. Close Xenia. Copy only the chosen `.patch.toml` into that fork's `patches` directory and enable `apply_patches` in its loaded configuration.
3. Restart the game and check the log for the matching module and applied option. Keep the requested output cap and readback settings; a 60 FPS cap alone does not unlock a game's internal limit.

Do **not** install or enable every file. Some files/options are alternative experiments for the same module; others depend on an emulator source fix. A matching hash and successful static verification do not establish stable FPS, correct simulation speed or campaign progression. Max Payne 3, Airborne and Warfighter are recent, unconfirmed changes, not advertised as verified 60 FPS fixes.

## Game patch index

| Game | Title ID | Module hash | Patch |
| --- | --- | --- | --- |
| Army of Two: The Devil's Cartel | `454109AB` | `9AFBA736404E53F5` | [454109AB - Army of Two The Devils Cartel Timing.patch.toml](<patches/454109AB - Army of Two The Devils Cartel Timing.patch.toml>) |
| Battlefield: Bad Company 2 | `454108A8` | `C1F8A2BE5BCF6B96` | [454108A8 - Battlefield Bad Company 2 Animation Timing.patch.toml](<patches/454108A8 - Battlefield Bad Company 2 Animation Timing.patch.toml>) |
| Battlefield: Bad Company 2 | `454108A8` | `C1F8A2BE5BCF6B96` | [454108A8 - Battlefield Bad Company 2 Timing.patch.toml](<patches/454108A8 - Battlefield Bad Company 2 Timing.patch.toml>) |
| BioShock GOTY / Ultimate Rapture Edition | `545407D8` | `DA62C7B0EA7405CF` | [545407D8 - BioShock Ultimate Rapture 60 FPS.patch.toml](<patches/545407D8 - BioShock Ultimate Rapture 60 FPS.patch.toml>) |
| Fable III | `4D5308D6` | `15A2B07FFF0A2754` | [4D5308D6 - Fable III 60FPS.patch.toml](<patches/4D5308D6 - Fable III 60FPS.patch.toml>) |
| Fallout: New Vegas Ultimate Edition (TU5) | `425307E0` | `BEC503E11EB9D8F9` | [425307E0 - Fallout New Vegas Ultimate 60FPS.patch.toml](<patches/425307E0 - Fallout New Vegas Ultimate 60FPS.patch.toml>) |
| Hitman 2: Silent Assassin HD | `5351081C` | `D5CC3670FA974441` | [5351081C - Hitman 2 Silent Assassin HD 60FPS.patch.toml](<patches/5351081C - Hitman 2 Silent Assassin HD 60FPS.patch.toml>) |
| Hitman: Blood Money HD | `534307DB` | `4B32E4CDC4BF4164` | [534307DB - Hitman Blood Money HD 60FPS.patch.toml](<patches/534307DB - Hitman Blood Money HD 60FPS.patch.toml>) |
| Hitman: Contracts HD | `5351081C` | `B9FAF12B253E03B3` | [5351081C - Hitman Contracts HD 60FPS.patch.toml](<patches/5351081C - Hitman Contracts HD 60FPS.patch.toml>) |
| Just Cause 2 | `534307E7` | `12134BD1769BFB2B` | [534307E7 - Just Cause 2 TU0 60FPS.patch.toml](<patches/534307E7 - Just Cause 2 TU0 60FPS.patch.toml>) |
| Just Cause 2 | `534307E7` | `12134BD1769BFB2B` | [534307E7 - Just Cause 2 TU0 Required Streaming.patch.toml](<patches/534307E7 - Just Cause 2 TU0 Required Streaming.patch.toml>) |
| Just Cause 2 | `534307E7` | `6CDA2880AB433BFF` | [534307E7 - Just Cause 2 TU1 60FPS.patch.toml](<patches/534307E7 - Just Cause 2 TU1 60FPS.patch.toml>) |
| L.A. Noire: The Complete Edition | `5454086C` | `60E4E421F4445C2B` | [5454086C - LA Noire Complete Edition 60FPS.patch.toml](<patches/5454086C - LA Noire Complete Edition 60FPS.patch.toml>) |
| Mafia II | `545407E6` | `D0F70B7B6332890A` | [545407E6 - Mafia II Frame Pacing 60FPS.patch.toml](<patches/545407E6 - Mafia II Frame Pacing 60FPS.patch.toml>) |
| Max Payne 3 | `5454086B` | `B203CBE51BCF3D72` | [5454086B - Max Payne 3 60FPS.patch.toml](<patches/5454086B - Max Payne 3 60FPS.patch.toml>) |
| Medal of Honor: Airborne | `454107F6` | `496DAFC9BE3E5A9D` | [454107F6 - Medal of Honor Airborne 60FPS.patch.toml](<patches/454107F6 - Medal of Honor Airborne 60FPS.patch.toml>) |
| Medal of Honor: Warfighter | `45410993` | `FC561A841E368F3D` | [45410993 - Medal of Honor Warfighter 60FPS.patch.toml](<patches/45410993 - Medal of Honor Warfighter 60FPS.patch.toml>) |
| Need for Speed: Rivals (TU2 render-only experiment) | `454109C6` | `3946E30942DCAF32` | [Rivals-render-test.patch.toml](<patches/Rivals-render-test.patch.toml>) |
| Need for Speed: Rivals (TU2) | `454109C6` | `3946E30942DCAF32` | [454109C6 - Need for Speed Rivals TU2 variable rendering.patch.toml](<patches/454109C6 - Need for Speed Rivals TU2 variable rendering.patch.toml>) |
| Need for Speed: Shift | `454108B4` | `8F8CCB15050567C3` | [454108B4 - Need for Speed Shift 60FPS.patch.toml](<patches/454108B4 - Need for Speed Shift 60FPS.patch.toml>) |
| Need for Speed: The Run (NFS.Main.xex) | `4541094A` | `B833F1869FAA9190` | [4541094A - The Run 60FPS.patch.toml](<patches/4541094A - The Run 60FPS.patch.toml>) |
| Red Dead Redemption GOTY TU1 (Disc 1) | `5454082B` | `D16175F24AF34798` | [5454082B - Red Dead Redemption GOTY TU1 Disc 1 60FPS.patch.toml](<patches/5454082B - Red Dead Redemption GOTY TU1 Disc 1 60FPS.patch.toml>) |
| Resident Evil 5 | `434307D4` | `EBE8DC47EB9402EC` | [434307D4 - Resident Evil 5 60FPS.patch.toml](<patches/434307D4 - Resident Evil 5 60FPS.patch.toml>) |
| Resident Evil 6 | `43430819` | `44A96367B5C19FB1` | [43430819 - Resident Evil 6 60FPS.patch.toml](<patches/43430819 - Resident Evil 6 60FPS.patch.toml>) |
| Resident Evil Revelations | `43430833` | `ADE9590DE9F292C9` | [43430833 - Resident Evil Revelations 60FPS.patch.toml](<patches/43430833 - Resident Evil Revelations 60FPS.patch.toml>) |
| Resident Evil Revelations 2 | `5841144C` | `9FBE98182B30938E` | [5841144C - Resident Evil Revelations 2 60FPS.patch.toml](<patches/5841144C - Resident Evil Revelations 2 60FPS.patch.toml>) |
| Rock Band 2 | `45410869` | `B94DA74D17CDF26F` | [45410869 - Rock Band 2 SEH Boot Fix.patch.toml](<patches/45410869 - Rock Band 2 SEH Boot Fix.patch.toml>) |
| Saints Row IV: Game of the Century Edition | `4B4D07F6` | `C875658006E4639C` | [4B4D07F6 - SR4 Single-sample Scene.patch.toml](<patches/4B4D07F6 - SR4 Single-sample Scene.patch.toml>) |
| Saints Row: Gat Out of Hell | `4B4D0800` | `DC470096D97A0450` | [4B4D0800 - Gat Single-sample Scene.patch.toml](<patches/4B4D0800 - Gat Single-sample Scene.patch.toml>) |
| Saints Row: The Third: The Full Package | `5451086D` | `F514A8ECF18C0E5A` | [5451086D - SR3 Single-sample Scene.patch.toml](<patches/5451086D - SR3 Single-sample Scene.patch.toml>) |
| Serious Sam - Double D XXL | `58411249` | `0F8C087D6FEA1BD4` | [58411249 - XXL RuntimeHost.patch.toml](<patches/58411249 - XXL RuntimeHost.patch.toml>) |
| Shift 2: Unleashed | `45410934` | `C4CD9F33611C5AFD` | [45410934 - Shift 2 Unleashed 60FPS.patch.toml](<patches/45410934 - Shift 2 Unleashed 60FPS.patch.toml>) |
| Silent Hill 2 HD | `4B4E0845` | `F3CA6A39460AF335` | [4B4E0845 - Silent Hill 2 HD New Voices.patch.toml](<patches/4B4E0845 - Silent Hill 2 HD New Voices.patch.toml>) |
| Silent Hill 2 HD | `4B4E0845` | `F3CA6A39460AF335` | [4B4E0845 - Silent Hill 2 HD Original Voices.patch.toml](<patches/4B4E0845 - Silent Hill 2 HD Original Voices.patch.toml>) |
| Silent Hill 3 HD | `4B4E0845` | `4DC9FF869FF55A1F` | [4B4E0845 - Silent Hill 3 HD 60FPS.patch.toml](<patches/4B4E0845 - Silent Hill 3 HD 60FPS.patch.toml>) |
| Silent Hill: Homecoming | `4B4E07E5` | `3DB72D7712F6ECD9` | [4B4E07E5 - Silent Hill Homecoming 60FPS.patch.toml](<patches/4B4E07E5 - Silent Hill Homecoming 60FPS.patch.toml>) |
| Spider-Man 3 | `415607E2` | `74EB693009B1AF55` | [415607E2 - Spider-Man 3 60FPS.patch.toml](<patches/415607E2 - Spider-Man 3 60FPS.patch.toml>) |
| Spider-Man: Edge of Time | `415608B2` | `26011A843A5386C6` | [415608B2 - Edge of Time 60FPS.patch.toml](<patches/415608B2 - Edge of Time 60FPS.patch.toml>) |
| Spider-Man: Shattered Dimensions | `41560881` | `B6F12EF2A529FDE4` | [41560881 - Shattered Dimensions 60FPS.patch.toml](<patches/41560881 - Shattered Dimensions 60FPS.patch.toml>) |
| Star Wars: The Force Unleashed | `4C4107D2` | `4C99AB5DF93A70F3` | [4C4107D2 - The Force Unleashed 60FPS.patch.toml](<patches/4C4107D2 - The Force Unleashed 60FPS.patch.toml>) |
| Star Wars: The Force Unleashed II | `4C4107F2` | `0C35DD8FCC1766CD` | [4C4107F2 - The Force Unleashed II 60FPS.patch.toml](<patches/4C4107F2 - The Force Unleashed II 60FPS.patch.toml>) |
| The Elder Scrolls IV: Oblivion GOTY (TU3) | `425307D1` | `B656ED4D389EEF2C` | [425307D1 - Oblivion GOTY TU3 60FPS.patch.toml](<patches/425307D1 - Oblivion GOTY TU3 60FPS.patch.toml>) |
| The Evil Within | `425307F4` | `08E87EF28DE9084B` | [425307F4 - The Evil Within 60FPS (base).patch.toml](<patches/425307F4 - The Evil Within 60FPS (base).patch.toml>) |
| The Lord of the Rings: Conquest | `45410852` | `FFA8A4695F7FC499` | [45410852 - The Lord of the Rings Conquest 60FPS.patch.toml](<patches/45410852 - The Lord of the Rings Conquest 60FPS.patch.toml>) |
| The Lord of the Rings: The Battle for Middle-earth II | `454107DF` | `64CA08FEDC8903CB` | [454107DF - BFME II 60FPS.patch.toml](<patches/454107DF - BFME II 60FPS.patch.toml>) |
| Wolfenstein | `415607DE` | `D4A77E183B2D6868` | [415607DE - Wolfenstein Singleplayer 60FPS.patch.toml](<patches/415607DE - Wolfenstein Singleplayer 60FPS.patch.toml>) |
| Worms Ultimate Mayhem | `58410AFD` | `D6BB8FBE542043A8` | [58410AFD - Worms Ultimate Mayhem 60FPS Timing.patch.toml](<patches/58410AFD - Worms Ultimate Mayhem 60FPS Timing.patch.toml>) |

## Source and tools

- [`games/`](games/): per-game generators, validators and specialist fixes, including Rock Band 3, Hitman water/depth and XXL runtime changes.
- [`emulator/`](emulator/): Canary/Edge source patches, version-pinned build inputs, config templates and their tests. The existing internal directory layout is retained so build recipes and tests keep their relative paths.
- [`emulator/pixel-fetch-residency/`](emulator/pixel-fetch-residency/): pixel-fetch residency and host-fence fixes, with version-pinned builders.
- [`tools/patch-manager/`](tools/patch-manager/): Windows patch-selection UI and optimized-settings import tools.
- [`catalog.json`](catalog.json): machine-readable game index. [`patch-sources.json`](patch-sources.json) connects installable copies to their maintained source projects.
- [`provenance.json`](provenance.json): source repository revisions used for this consolidation. Old repository names are provenance identifiers; maintain this repository going forward.

## What is included

Source patches, small game-memory patch definitions, generic configuration templates, builders and tests. You must provide any required original game image or emulator executable locally. No game media, decrypted game executables, title updates, profiles, saves, captures, credentials or cabinet inventories are distributed.

Existing component notices/licenses are preserved. Xenia-derived source changes remain subject to the applicable upstream Xenia license; this consolidation does not grant a new blanket license to third-party code or game material. See [NOTICE](NOTICE).

## Maintain the collection

Use Python 3.11+ and run `python tools/validate_collection.py` before committing. Keep each installable TOML identical to its source copy, update the JSON catalog when adding a game, and retain exact-version guards. Run the relevant component's tests separately; game-image checks need owner-supplied inputs and Windows tools need Windows. No hosted CI or workflow dispatch is configured.
