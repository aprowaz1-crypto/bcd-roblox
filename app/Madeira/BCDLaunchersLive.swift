// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// Modified for BCD-RobloxDev on 2026-11-17: generated Studio/Dev Mode batches, Studio settings and the auth bridge.

import Foundation

/// PC launchers on the engine (BCDLaunchers.swift; docs/BCD-UI-ARCHITECTURE.md): the files in drive_c, the library
/// entries and the session. Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).
///
/// - Installed: one of the launcher's programs exists in the prefix (BCDLauncherFiles). Dev Mode is different: it is
///   ready when Roblox Studio or VS Code is installed, and its batch is written when it opens.
/// - Install: the company's installer is downloaded into drive_c/bcd-launchers (BCDLauncherInstaller: the company's
///   own HTTPS host, every redirect checked, the file looked at) and started as the session's first program through
///   the same Play every game uses. A library entry made for the run is not kept in the library (see isSetup).
///   Roblox Studio's install runs through `bcd-dev/studio-setup.bat`: it starts Roblox's own installer, then writes
///   Studio's ClientSettings and opens Studio again with BCD's sign-in bridge.
/// - Open: the installed launcher's program is started the same way, from a library entry of its own (BCDLauncherSpec.entryID),
///   which holds its per-game settings and takes the recommended list and auto-tune by its program's name like any
///   other program. Studio starts through `bcd-dev/studio.bat` and Dev Mode through `bcd-dev/dev.bat`; both batches
///   are written here just before the session, and both carry `studio-auth.bat`, the polling loop that hands a
///   Roblox OAuth callback to the running Studio (RobloxAuth.swift).
/// - Both start directly: Wine's first process is the program, with no explorer desktop behind it
///   (BCDLauncherStart); the launcher's own session lines (BCDLauncherSpec.sessionConfig) go into the entry's config.
///
/// Log tag: [launcher] (the launcher's id, host names, byte counts and short reasons; never a login or an address with a path).
@objc(BCDLaunchersLive)
@MainActor final class BCDLaunchersLive: NSObject, BCDLauncherEngine {
    private var control: BCDLauncherDownloadControl?

    nonisolated override init() { super.init() }

    // MARK: - Files

    func installedProgram(_ spec: BCDLauncherSpec) -> String? {
        if spec.isComposed {
            // Dev Mode builds itself from what is there. Its batch is written at Open, so the file need not exist yet.
            let studio = BCDLauncherFiles.installedProgram(.robloxStudio, in: LibraryModel.drive)
            let code = BCDLauncherFiles.installedProgram(.vscode, in: LibraryModel.drive)
            guard studio != nil || code != nil else { return nil }
            return spec.programs[0]
        }
        return BCDLauncherFiles.installedProgram(spec, in: LibraryModel.drive)
    }

    // MARK: - Can a session start?

    func sessionBlocker() -> String? {
        let library = LibraryModel.shared
        if library.current != nil || wine_process_is_running() != 0 || wineserver_is_running() != 0 {
            return "Another session is still running."
        }
        // One Wine session per run of BCD (ContentView.launchLibraryEntry): ask for the restart now, before anything is downloaded.
        if LibraryModel.sessionsThisRun > 0, MadeiraConfig.flag("MADEIRA_ONE_SESSION_PER_RUN") {
            LogStore.shared.log("[launcher] held: \(LibraryModel.sessionsThisRun) session(s) already ran in this run of BCD")
            library.restartNotice = LibraryModel.restartMessage
            return LibraryModel.restartMessage
        }
        return nil
    }

    // MARK: - The installer

    func downloadInstaller(_ spec: BCDLauncherSpec, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard spec.installerURL != nil else { throw BCDLauncherError.nothingToDownload(title: spec.title) }
        let wanted = Int64(spec.spaceGigabytes) << 30
        if let free = Self.freeBytes(), free < wanted {
            LogStore.shared.log("[launcher] \(spec.id) refused: free=\(free / (1 << 20))MB needs=\(wanted / (1 << 20))MB")
            throw BCDLauncherError.notEnoughSpace(title: spec.title, gigabytes: spec.spaceGigabytes)
        }
        let control = BCDLauncherDownloadControl()
        self.control = control
        defer { self.control = nil }
        let folder = LibraryModel.drive.appendingPathComponent(spec.installerFolder, isDirectory: true)
        do {
            _ = try await BCDLauncherInstaller.fetch(spec, into: folder, control: control,
                                                     log: { LogStore.shared.log($0) }, progress: progress)
        } catch {
            LogStore.shared.log("[launcher] \(spec.id) download failed reason=\((error as? BCDLauncherError)?.logReason ?? "other")")
            throw error
        }
    }

    func cancelDownload() {
        control?.cancel()
        BCDGeckoModel.shared.cancel()
    }

    // MARK: - Wine Gecko for installers that show a web page

    func missingComponent(_ spec: BCDLauncherSpec) -> String? {
        spec.needsGecko && !BCDGeckoModel.shared.isReady ? "the HTML engine" : nil
    }

    func downloadComponent(_ spec: BCDLauncherSpec, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let gecko = BCDGeckoModel.shared
        gecko.log = { LogStore.shared.log($0) }
        LogStore.shared.log("[launcher] \(spec.id) needs the HTML engine (Wine Gecko)")
        try await gecko.ensure(progress: progress)
    }

    func startInstaller(_ spec: BCDLauncherSpec) {
        var relative = spec.installerRelativePath
        var start = BCDLauncherStart.installer(spec)
        if spec.kind == .studio {
            BCDRobloxAuth.clearCallback(in: LibraryModel.drive)
            _ = Self.writeStudioAuthWatcher()
            if Self.writeStudioSetup() {
                relative = "bcd-dev/studio-setup.bat"
                start = .script(spec, relative: relative, installer: true)
            } else {
                LogStore.shared.log("[launcher] robloxstudio setup batch could not be written; starting its installer directly")
            }
        }
        let entry = Self.entry(spec, relative: relative, title: spec.title + " setup",
                               id: UUID(uuidString: spec.setupEntryID)!, stored: nil, start: start)
        LogStore.shared.log("[launcher] \(spec.id) installer start bits=\(entry.bits) desktop=\(entry.runsInDesktop ? 1 : 0) "
                            + "services=\(entry.startServices == true ? 1 : 0) args=\(entry.arguments.isEmpty ? 0 : 1) script=\(start.isScript ? 1 : 0)")
        BCDLiveStore.shared.startLauncherEntry(entry, game: BCDLauncherSpec.gameID(spec.id))
    }

    // MARK: - The launcher

    func startLauncher(_ spec: BCDLauncherSpec, program: String) {
        let library = LibraryModel.shared
        let ours = UUID(uuidString: spec.entryID)!
        // Our own entry, else a program the player added by hand under the same path (it keeps its own settings and id).
        let stored = library.entries.first { $0.id == ours }
            ?? library.entries.first { entry in
                entry.steamAppID == nil && entry.desktop != true
                    && spec.programs.contains { $0.caseInsensitiveCompare(entry.relativePath) == .orderedSame }
            }
        var relative = program
        var start = BCDLauncherStart.program(spec, relative: program)
        let hasStudio = BCDLauncherFiles.installedProgram(.robloxStudio, in: LibraryModel.drive) != nil
        if spec.kind == .studio || spec.kind == .devMode {
            BCDRobloxAuth.clearCallback(in: LibraryModel.drive)
            if hasStudio {
                _ = Self.prepareStudioSettings()
                _ = Self.writeStudioAuthWatcher()
            }
        }
        switch spec.kind {
        case .studio:
            if Self.writeStudioRun() {
                relative = "bcd-dev/studio.bat"
                start = .script(spec, relative: relative)
            }
        case .devMode:
            if Self.writeDevMode() {
                relative = "bcd-dev/dev.bat"
                start = .script(spec, relative: relative)
            }
        case .store, .editor:
            break
        }
        let entry = Self.entry(spec, relative: relative, title: spec.title, id: ours, stored: stored, start: start)
        LogStore.shared.log("[launcher] \(spec.id) open bits=\(entry.bits) own-entry=\(stored == nil || stored?.id == ours ? 1 : 0) "
                            + "desktop=\(entry.runsInDesktop ? 1 : 0) services=\(entry.startServices == true ? 1 : 0) script=\(start.isScript ? 1 : 0)")
        BCDLiveStore.shared.startLauncherEntry(entry, game: BCDLauncherSpec.gameID(spec.id))
    }

    // MARK: - BCD-RobloxDev first run

    /// Both installers are fetched before any Wine session starts, so BCD's one-session-per-run rule
    /// cannot stop the second download. The report names the launcher, not an address with a path.
    func downloadSetupInstallers(progress: @escaping @Sendable (String, Int64, Int64) -> Void) async throws {
        if let why = sessionBlocker() { throw BCDLauncherError.setupBlocked(reason: why) }
        for spec in [BCDLauncherSpec.robloxStudio, .vscode] {
            try Task.checkCancellation()
            try await downloadInstaller(spec) { received, total in progress(spec.title, received, total) }
        }
    }

    /// One batch installs VS Code without questions, runs Roblox's installer, writes Studio's settings
    /// and then calls `dev.bat`, whose Command Prompt holds the only session of this run open.
    func startFirstRun() {
        if let why = sessionBlocker() {
            LogStore.shared.log("[launcher] first-run held: \(why)")
            return
        }
        BCDRobloxAuth.clearCallback(in: LibraryModel.drive)
        guard Self.writeStudioAuthWatcher(), Self.writeDevMode(), Self.writeFirstRun() else {
            LogStore.shared.log("[launcher] first-run batch could not be written")
            return
        }
        let spec = BCDLauncherSpec.devMode
        let relative = "bcd-dev/first-run.bat"
        let start = BCDLauncherStart.script(spec, relative: relative, installer: true)
        let entry = Self.entry(spec, relative: relative, title: "BCD Dev Mode setup",
                               id: UUID(uuidString: spec.setupEntryID)!, stored: nil, start: start)
        LogStore.shared.log("[launcher] first-run start bits=\(entry.bits) script=1")
        BCDLiveStore.shared.startLauncherEntry(entry, game: BCDLauncherSpec.gameID(spec.id))
    }

    // MARK: - The library entry of a start

    /// Whether `entry` is the one made for an installer run: it is started like any program but not kept in the library
    /// (ContentView.startLibraryEntry hands LibraryModel.begin `remember: false`).
    static func isSetup(_ entry: LibraryEntry) -> Bool {
        BCDLauncherSpec.all.contains { $0.setupEntryID.caseInsensitiveCompare(entry.id.uuidString) == .orderedSame }
    }

    /// The entry a start hands to Play: in a Wine desktop with Windows services first (BCDLauncherStart, build 594). A
    /// stored entry keeps everything the player set; BCD's own entry whose start options were never set (build 593 made
    /// such entries "on its own") gets the launcher's start options. What BCD owns besides is the program's path of its
    /// own entry, the table's arguments when it has any, and the table's block of config lines. A generated batch
    /// carries its own arguments: none of the entry's may land after `cmd /c "<batch>"`.
    static func entry(_ spec: BCDLauncherSpec, relative: String, title: String, id: UUID, stored: LibraryEntry?,
                      start: BCDLauncherStart) -> LibraryEntry {
        var entry: LibraryEntry
        if let stored {
            entry = stored
            if stored.id == id { entry.relativePath = relative }
        } else {
            let url = LibraryModel.drive.appendingPathComponent(relative)
            entry = (try? LibraryModel.inspect(url)) ?? LibraryEntry(title: title, relativePath: relative, bits: 0)
            entry.title = title
            entry.relativePath = relative
            entry.id = id
        }
        if stored == nil || (stored?.id == id && stored?.launchMode == nil && stored?.startServices == nil) {
            entry.launchMode = start.inWineDesktop ? "desktop" : nil
            entry.startServices = start.startServices ? true : nil
        }
        if start.isScript {
            entry.arguments = ""
        } else {
            entry.arguments = BCDLauncherArguments.merged(entry.arguments, table: start.arguments)
        }
        entry.config = BCDLauncherConfig.merged(entry.config, lines: start.sessionConfig, id: spec.id)
        entry.demandStartServices = start.demandStartServices.isEmpty ? nil : start.demandStartServices   // round 625: BCD's, at every start
        return entry
    }

    private static func freeBytes() -> Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Generated files in drive_c

    /// A batch BCD writes beside the launcher's own files. CRLF, like the services batch, and a directory made on demand.
    private static func write(_ relative: String, lines: [String]) -> Bool {
        let file = LibraryModel.drive.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\r\n") + "\r\n").write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            LogStore.shared.log("[launcher] could not write \(relative): \(error.localizedDescription)")
            return false
        }
    }

    /// Studio's sign-in flags, written before every Studio start. A Roblox update brings a new version folder; this
    /// finds the one that actually holds Studio, as spelled on disk.
    private static func prepareStudioSettings() -> Bool {
        guard let program = BCDLauncherFiles.installedProgram(.robloxStudio, in: LibraryModel.drive) else { return false }
        let folder = LibraryModel.drive.appendingPathComponent(program).deletingLastPathComponent()
        let file = folder.appendingPathComponent("ClientSettings/ClientAppSettings.json")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try BCDRobloxAuth.studioSettingsJSON.write(to: file, atomically: true, encoding: .utf8)
            LogStore.shared.log("[launcher] robloxstudio ClientSettings written")
            return true
        } catch {
            LogStore.shared.log("[launcher] robloxstudio ClientSettings failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The small loop that waits for `auth.url` and runs RobloxStudioBeta.exe with it. Roblox's single instance
    /// forwards that command to the Studio window the player already has, so Studio can finish the browser sign-in.
    private static func writeStudioAuthWatcher() -> Bool {
        let lines = [
            "@echo off",
            "rem Generated by BCD-RobloxDev: hands Roblox's browser callback to the running Studio.",
            "setlocal",
            "set \"BCD=C:\\ProgramData\\BCD\\DevMode\"",
            "if not exist \"%BCD%\" mkdir \"%BCD%\"",
            ":wait",
            "if not exist \"%BCD%\\auth.url\" (",
            "  ping -n 3 127.0.0.1 >nul",
            "  goto wait",
            ")",
            "set \"AUTH=\"",
            "set /p AUTH=<\"%BCD%\\auth.url\"",
            "del \"%BCD%\\auth.url\" >nul 2>&1",
            "if not defined AUTH goto wait",
            "for /f \"delims=\" %%D in ('dir /b /ad /o-n \"%LOCALAPPDATA%\\Roblox\\Versions\\version-*\" 2^>nul') do (",
            "  if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\" (",
            "    start \"\" \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\" \"%AUTH%\"",
            "    goto handed",
            "  )",
            "  if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\" (",
            "    start \"\" \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\" \"%AUTH%\"",
            "    goto handed",
            "  )",
            ")",
            ":handed",
            "ping -n 2 127.0.0.1 >nul",
            "goto wait",
        ]
        return write("bcd-dev/studio-auth.bat", lines: lines)
    }

    /// Open Studio alone: one hidden sign-in loop, then Studio. `start /wait` keeps cmd.exe (the session's first
    /// process) alive until Studio closes.
    private static func writeStudioRun() -> Bool {
        let lines = [
            "@echo off",
            "title Roblox Studio",
            "rem Generated by BCD-RobloxDev; rewritten at every open.",
            "setlocal",
            "set \"BCD=C:\\ProgramData\\BCD\\DevMode\"",
            "if not exist \"%BCD%\" mkdir \"%BCD%\"",
            "del \"%BCD%\\auth.url\" >nul 2>&1",
            "start \"Studio sign-in\" /min cmd /c \"%BCD%\\studio-auth.bat\"",
            "for /f \"delims=\" %%D in ('dir /b /ad /o-n \"%LOCALAPPDATA%\\Roblox\\Versions\\version-*\" 2^>nul') do (",
            "  if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\" (",
            "    start /wait \"\" \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\"",
            "    goto done",
            "  )",
            "  if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\" (",
            "    start /wait \"\" \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\"",
            "    goto done",
            "  )",
            ")",
            "echo BCD could not find Roblox Studio in Roblox's Versions folder.",
            "ping -n 8 127.0.0.1 >nul",
            ":done",
        ]
        return write("bcd-dev/studio.bat", lines: lines)
    }

    /// Install Studio: run Roblox's own installer, close the first Studio window it opens, write BCD's ClientSettings
    /// and open Studio again with the sign-in loop. All of it is one Wine session, so BCD's one-session-per-run rule
    /// only asks for a restart after the setup has finished.
    private static func writeStudioSetup() -> Bool {
        var lines = [
            "@echo off",
            "title Roblox Studio setup",
            "rem Generated by BCD-RobloxDev; rewritten at every install.",
            "setlocal",
            "set \"BCD=C:\\ProgramData\\BCD\\DevMode\"",
            "if not exist \"%BCD%\" mkdir \"%BCD%\"",
            "echo Installing Roblox Studio. This can take a while.",
            "\"C:\\bcd-launchers\\RobloxStudioInstaller.exe\"",
            "rem Roblox's installer may open Studio itself. Close that first window: BCD's settings need a fresh start.",
            "ping -n 5 127.0.0.1 >nul",
            "taskkill /IM RobloxStudioBeta.exe /F >nul 2>&1",
            "ping -n 3 127.0.0.1 >nul",
            "for /d %%D in (\"%LOCALAPPDATA%\\Roblox\\Versions\\version-*\") do (",
            "  if exist \"%%~D\\RobloxStudioBeta.exe\" (",
            "    if not exist \"%%~D\\ClientSettings\" mkdir \"%%~D\\ClientSettings\"",
            "    (",
        ]
        lines += BCDRobloxAuth.studioSettingsBatchLines.map { "      " + $0 }
        lines += [
            "    ) > \"%%~D\\ClientSettings\\ClientAppSettings.json\"",
            "  )",
            ")",
            "start \"Studio sign-in\" /min cmd /c \"%BCD%\\studio-auth.bat\"",
            "for /f \"delims=\" %%D in ('dir /b /ad /o-n \"%LOCALAPPDATA%\\Roblox\\Versions\\version-*\" 2^>nul') do (",
            "  if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\" (",
            "    start /wait \"\" \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\"",
            "    goto done",
            "  )",
            "  if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\" (",
            "    start /wait \"\" \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\"",
            "    goto done",
            "  )",
            ")",
            "echo Roblox Studio was installed but its program was not found.",
            "ping -n 8 127.0.0.1 >nul",
            ":done",
        ]
        return write("bcd-dev/studio-setup.bat", lines: lines)
    }

    /// Dev Mode: start whichever of VS Code and Studio are installed, the sign-in loop when Studio is there, then an
    /// interactive Command Prompt in the Windows user's folder. The prompt is the last command in this batch, so it
    /// holds the session open; closing it ends the session, as BCD's one program per run expects.
    private static func writeDevMode() -> Bool {
        let code = " " + BCDLauncherSpec.vscodeArguments
        let lines = [
            "@echo off",
            "title BCD Dev Mode",
            "rem Generated by BCD-RobloxDev; rewritten at every start.",
            "setlocal",
            "set \"BCD=C:\\ProgramData\\BCD\\DevMode\"",
            "if not exist \"%BCD%\" mkdir \"%BCD%\"",
            "del \"%BCD%\\auth.url\" >nul 2>&1",
            "echo BCD Dev Mode: starting the programs you have installed.",
            "if exist \"%LOCALAPPDATA%\\Programs\\Microsoft VS Code\\Code.exe\" (",
            "  start \"\" \"%LOCALAPPDATA%\\Programs\\Microsoft VS Code\\Code.exe\"" + code,
            ") else if exist \"%ProgramFiles%\\Microsoft VS Code\\Code.exe\" (",
            "  start \"\" \"%ProgramFiles%\\Microsoft VS Code\\Code.exe\"" + code,
            ")",
            "set \"STUDIO=\"",
            "for /f \"delims=\" %%D in ('dir /b /ad /o-n \"%LOCALAPPDATA%\\Roblox\\Versions\\version-*\" 2^>nul') do (",
            "  if not defined STUDIO if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\" set \"STUDIO=%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioBeta.exe\"",
            "  if not defined STUDIO if exist \"%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\" set \"STUDIO=%LOCALAPPDATA%\\Roblox\\Versions\\%%~D\\RobloxStudioLauncherBeta.exe\"",
            ")",
            "if defined STUDIO (",
            "  start \"Studio sign-in\" /min cmd /c \"%BCD%\\studio-auth.bat\"",
            "  start \"\" \"%STUDIO%\"",
            ") else (",
            "  echo Roblox Studio is not installed. Add it from BCD's Library to use it here.",
            ")",
            "cd /d \"%USERPROFILE%\"",
            "echo.",
            "echo Close this Command Prompt to leave BCD Dev Mode.",
            "cmd /k",
        ]
        return write("bcd-dev/dev.bat", lines: lines)
    }

    /// The first-run batch: both installers were already downloaded, so this one session installs
    /// VS Code quietly, runs Roblox's installer, writes Studio's settings and hands over to Dev Mode.
    private static func writeFirstRun() -> Bool {
        let vscode = BCDLauncherSpec.vscode
        let studio = BCDLauncherSpec.robloxStudio
        var lines = [
            "@echo off",
            "title BCD Dev Mode setup",
            "rem Generated by BCD-RobloxDev for the first run; rewritten if setup is repeated.",
            "setlocal",
            "set \"BCD=C:\\ProgramData\\BCD\\DevMode\"",
            "if not exist \"%BCD%\" mkdir \"%BCD%\"",
            "del \"%BCD%\\auth.url\" >nul 2>&1",
            "echo Installing Visual Studio Code...",
            "\"" + vscode.installerWindowsPath + "\" " + vscode.installerArguments,
            "echo Installing Roblox Studio...",
            "\"" + studio.installerWindowsPath + "\"",
            "rem The installer may open Studio itself; close that first window so BCD's settings are read.",
            "ping -n 5 127.0.0.1 >nul",
            "taskkill /IM RobloxStudioBeta.exe /F >nul 2>&1",
            "ping -n 3 127.0.0.1 >nul",
            "for /d %%D in (\"%LOCALAPPDATA%\\Roblox\\Versions\\version-*\") do (",
            "  if exist \"%%~D\\RobloxStudioBeta.exe\" (",
            "    if not exist \"%%~D\\ClientSettings\" mkdir \"%%~D\\ClientSettings\"",
            "    (",
        ]
        lines += BCDRobloxAuth.studioSettingsBatchLines.map { "      " + $0 }
        lines += [
            "    ) > \"%%~D\\ClientSettings\\ClientAppSettings.json\"",
            "  )",
            ")",
            "echo BCD Dev Mode is starting...",
            "call \"C:\\bcd-dev\\dev.bat\"",
        ]
        return write("bcd-dev/first-run.bat", lines: lines)
    }
}
