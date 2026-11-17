# BCD-RobloxDev

This checkout is a customization of [BCD](https://github.com/thebcd69/bcd-games) (base commit
`41e972b`, BCD 0.1.665). It keeps BCD's Wine/FEX/DXMT launch path and adds three cards to the
Library so that **Roblox Studio**, **VS Code** and a combined **Dev Mode** session run on an
iPad or iPhone with JIT. It is a fork of BCD, not of Henge, and it stays inside BCD's existing
launcher model rather than adding a second app.

Primary device: **iPad Air 5 (256 GB, M1)**. Secondary: **iPhone 14 Plus (A15)**. The iPad is
the one with the memory and thermal room for Studio plus an editor; the phone works for short
sessions but is much tighter.

> Not affiliated with Roblox Corporation or Microsoft. Roblox, Roblox Studio, Visual Studio Code
> and their download hosts belong to their owners. This project only downloads their public
> installers from those owners' own HTTPS hosts and starts them inside BCD's Wine prefix.

## What the cards do

All three live in the Library next to Battle.net and the EA app, in this order:

1. **Roblox Studio** — downloads `https://setup.rbxcdn.com/RobloxStudioInstaller.exe` (about
   14 MB) from Roblox's own host and runs it with a generated
   `drive_c/bcd-dev/studio-setup.bat`. The installer is interactive. The batch then writes
   `ClientSettings/ClientAppSettings.json` for the installed version and opens Studio again
   with BCD's sign-in bridge.
2. **VS Code** — downloads Microsoft's user installer from
   `https://update.code.visualstudio.com/latest/win32-x64-user/stable` (about 290 MB, redirect
   checked against Microsoft's own download host) and runs it silently with
   `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode`. Open starts `Code.exe` with
   `--disable-gpu --disable-workspace-trust`.
3. **Dev Mode** — nothing is downloaded. Once Studio *or* VS Code is installed, Open writes
   `drive_c/bcd-dev/dev.bat` and starts one session containing whichever programs are there, a
   hidden Studio sign-in loop and an interactive Command Prompt. Closing that Command Prompt
   ends the session.

## First run

On a fresh install (and once after updating to this version) BCD opens a short setup instead of the
Library: **Roblox Studio + VS Code**. It first checks the connection with a HEAD request to
`https://www.google.com/generate_204` — only a reachability check, no page is opened — then, once the
connection is up, downloads Roblox's installer (about 14 MB) and Microsoft's VS Code installer
(about 290 MB) **before starting any Wine session**. When both files are kept, one generated
`drive_c/bcd-dev/first-run.bat` runs VS Code's silent installer, Roblox's installer, writes Studio's
settings and calls `dev.bat`, whose Command Prompt holds the single session open. Setup closes as
soon as that batch is handed to Play. The usual BCD setup (JIT, sign-in, Wine Mono, VC++) remains
available under Settings › Accounts or JIT › Run setup again.

BCD starts **one Wine session per run of the app**. After an install or an Open, swipe BCD away
in the app switcher and reopen it before starting the next program. Dev Mode is the way to run
Studio and VS Code together without that restart between them.

## Studio sign-in

Studio's WebView2 sign-in cannot work in BCD's prefix (WebView2 needs a Windows service
manager). BCD avoids it instead of trying to repair it:

- `ClientSettings/ClientAppSettings.json` sets
  `FIntStudioEmbeddedAuthorizationDialogLoadingTimeoutMillis = 1` and
  `DFIntStudioEmbeddedAuthorizationDialogLoadingTimeoutMillis = 1`, so Studio's embedded
  authorization dialog gives up at once and offers its browser sign-in button.
- The same file sets `FFlagDebugGraphicsPreferD3D11 = true` and disables D3D12, Vulkan and
  OpenGL, keeping Studio on the renderer Wine can provide.
- When Studio asks to open `https://apis.roblox.com/oauth/v1/authorize?...`, BCD's
  `winebrowser.exe` leaves it in `drive_c/ProgramData/BCD/OpenURL/`. `Library.watchOpenURL`
  recognises that request, opens Roblox's page in `ASWebAuthenticationSession` (callback scheme
  `roblox-studio-auth`), and writes the exact callback
  (`roblox-studio-auth:/?code=...`) to `drive_c/ProgramData/BCD/DevMode/auth.url`.
- `bcd-dev/studio-auth.bat` polls for that one file, deletes it, and runs
  `RobloxStudioBeta.exe` with the callback. Studio's single instance forwards it to the window
  the player already has, exactly as a native Windows protocol handler would. Stale callbacks
  are removed at every session start and by the batches, so a code from an earlier run is never
  reused.

No password, cookie or token is kept by BCD. The only thing that crosses from iOS into the
prefix is the one-shot callback URL, and the batch removes it as soon as Studio has it.

## Known limits

- **Playtest from Studio starts the separate Windows Roblox client, which carries Hyperion
  anti-cheat. It is expected not to work under Wine.** Use Studio's Run mode or Device Emulator
  for editing tests, or publish the place and test it in the Roblox app on the iPad.
- WebView2's own installer still fails under Wine; the sign-in flow above bypasses it. Studio's
  installer may log a WebView2 error while it sets up, but Studio itself still installs.
- Studio is a large Qt/x64 program. Only iPad Air 5 / M1 and later are recommended; iPhone 14
  Plus is supported but small and hot. Free Apple ID limits sideloaded apps to three, so LiveContainer
  (see the main README) is usually needed alongside BCD and the JIT helper.
- Studio's installer is interactive: it downloads the versioned Studio files over the network,
  so the first install needs a good connection and several GB of free space.
- BCD's normal launcher rules still apply: each launcher's own library entry keeps the player's
  settings, and install runs are not added to the library.

## Build and check

A full iOS build still needs macOS, Xcode and BCD's submodules. From a checkout of this fork:

```sh
git submodule update --init --recursive
# open app/Madeira.xcodeproj, choose the Madeira target, build and sign an IPA, or
# push a branch and let .github/workflows/build-ipa.yml build it.
```

On a Mac with `swiftc`, the host check reads the launcher table, the resolver (including its
two wildcards for Roblox's `users/<user>/.../version-<hash>/` path), the download checks and the
model:

```sh
python3 tests/host/check-bcd-launchers.py --require-swift
```

The UI-only preview can be regenerated with `tools/ui-preview.py`; `RobloxAuth.swift` and
`BCDLaunchersLive.swift` are in that tool's `ENGINE_BOUND`, so the preview keeps compiling
without AuthenticationServices. New preview screens for the fork's cards are named
`-BCDSection launcher-robloxstudio`, `launcher-vscode` and `launcher-devmode` (with `+installed`,
`+downloading`, `+failed` or `+starting` as in BCD's existing sample).

This workspace has no Xcode, macOS or `swiftc`, so the source checks were run here and the
compiled and IPA builds are left to macOS or the GitHub Actions workflow.

## Licence and attribution

BCD is GPL-3.0-only with the additional terms in `LICENSE-BCD.md`. This fork keeps every BCD
header, marks every modified file with a `Modified for BCD-RobloxDev on <date>` line, and keeps
the notice **"Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games)"** in
the app's About/Credits. Madeira and the other projects BCD builds on keep their own notices in
`THIRD-PARTY-NOTICES.md` and `LICENSES/`.

The two sign-in FFlags and the D3D11 preference follow the public configuration used by
[Vinegar](https://github.com/vinegarhq/vinegar); no Vinegar code is copied into this fork.
