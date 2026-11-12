# =========================
#   Watch2Print - BROWSER FRONT END
# =========================
#
#   Vibed by Dave - started January 2026
#   "...the less you know about a topic, the more AI makes you think you're an expert..."
#
#   This build replaces the WPF desktop window with a local browser
#   interface. It keeps its OWN data folder and config file, separate from
#   the production SimplyPrint-only build, so the two can be installed and
#   run side by side without touching each other.
#
# =========================

<#
  Watch2Print_Web.ps1

  Browser front end for watch2print. Serves a local page, edits the config,
  AND runs the engine, streaming its log live. Nothing is hosted: the
  listener binds localhost on this machine only.

  Runs on Windows PowerShell 5.1, PS7-Windows and PS7-Linux.

      pwsh -NoProfile -File ./Watch2Print_Web.ps1
      pwsh -NoProfile -File ./Watch2Print_Web.ps1 -Port 9000 -NoBrowser

  Stop it from the tray icon, the Quit button in the page, or Ctrl+C if a
  console is attached.
#>
[CmdletBinding()]
param(
    [int]$Port = 8787,
    [string]$Config,
    [string]$Engine,
    [string]$ColorMap,
    [switch]$NoBrowser,
    [switch]$AutoStart      # begin watching immediately - for headless/service use
)

$ErrorActionPreference = 'Stop'

# When compiled with ps2exe there is no $MyInvocation.MyCommand.Path, so fall
# back to the executable's own folder.
$here = $null
try { $here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
if ([string]::IsNullOrWhiteSpace($here)) {
    try { $here = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
}
if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }

# Running as a compiled exe? Then there are no loose .ps1 files beside us and
# the engine has to be unpacked from the payload below.
$script:IsPackaged = ($MyInvocation.MyCommand.Path -eq $null -or $MyInvocation.MyCommand.CommandType -eq 'Application')
$script:SelfPath = $null
try { $script:SelfPath = $MyInvocation.MyCommand.Path } catch { }

# --- console vs windowed ------------------------------------------------
# ps2exe -noConsole does NOT silence Write-Host: it routes it to a MessageBox,
# one popup per line, which for this app would be hundreds. So when there is
# no console attached, Write-Host is overridden to append to a log file in the
# data directory instead. That keeps the app silent AND keeps a bind failure
# or a crash diagnosable, which hiding the output would not.
$script:HasConsole = $true
try { $null = [Console]::WindowWidth } catch { $script:HasConsole = $false }
$script:StartupLog = $null

# Per-user data directory. Program Files needs admin to write, and a config
# next to the exe breaks the moment someone installs to a protected folder.
function Get-W2PDataDir {
    $d = if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
            Join-Path $env:LOCALAPPDATA 'Watch2Print'
         } elseif ($IsMacOS) {
            Join-Path $HOME 'Library/Application Support/Watch2Print'
         } else {
            $x = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
            Join-Path $x 'watch2print'
         }
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

if (-not $script:HasConsole) {
    $script:StartupLog = Join-Path (Get-W2PDataDir) 'watch2print.log'
    # Keep one previous run for comparison, then start fresh.
    try {
        if (Test-Path -LiteralPath $script:StartupLog) {
            Move-Item -LiteralPath $script:StartupLog -Destination ($script:StartupLog + '.prev') -Force
        }
    } catch { }
    function Write-Host {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline=$true, Position=0)] $Object,
            [System.ConsoleColor] $ForegroundColor,
            [System.ConsoleColor] $BackgroundColor,
            [switch] $NoNewline,
            $Separator
        )
        $line = if ($null -eq $Object) { '' } else { [string]$Object }
        try {
            [System.IO.File]::AppendAllText($script:StartupLog,
                ('{0}  {1}{2}' -f (Get-Date).ToString('HH:mm:ss'), $line, [Environment]::NewLine),
                (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
}

# --- version + update check ---------------------------------------------
# Bumped by hand at release time and stamped into the exe by build-exe.ps1.
$script:AppVersion = '1.1.6'

# Where to look for a newer build. Overridden by 'updateUrl' in the config, so
# it can be pointed somewhere new without a rebuild. Blank disables the check,
# which is the right default for a build nobody is distributing yet.
#
#   { "version": "3.1.0",
#     "url": "https://example.com/Watch2Print.exe",
#     "notes": "Fixes the thing that was broken." }
#
# There is deliberately no field for this in the UI: it is a deployment
# decision, not a per-operator setting. Set it here at build time, or add
# "updateUrl" to the config file - a farm can point every machine at a
# version.json on a shared drive that way.
#
# An http(s) URL or a filesystem path both work. A path matters more than it
# sounds: a farm with a shared drive can drop version.json on the share and
# every machine sees it, with no web host and no internet involved.
$script:UpdateUrl = 'github:Prevolve/prevolve-watcher'

$script:UpdateInfo = $null

function Compare-W2PVersion {
    # Numeric, part-by-part. A plain string compare calls 3.10.0 older than
    # 3.9.0, which is exactly the release where it would matter.
    param([string]$A, [string]$B)
    $pa = @(($A -split '[^\d]+') | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
    $pb = @(($B -split '[^\d]+') | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

function Get-W2PUpdateSource {
    # Config wins over the compiled-in default, so the source can change
    # without shipping a new exe.
    try {
        $c = Read-W2PConfig
        if ($c.PSObject.Properties.Name -contains 'updateUrl') {
            $u = [string]$c.updateUrl
            if (-not [string]::IsNullOrWhiteSpace($u)) { return $u.Trim() }
        }
    } catch { }
    return $script:UpdateUrl
}

function Test-W2PUpdate {
    # Returns a status object, never a bare $null. The previous version
    # returned null for BOTH "no newer version" and "the check failed", so a
    # typo in the source path displayed as a confident "Up to date" - the one
    # answer guaranteed to stop anyone investigating.
    #
    #   status = disabled | current | available | error
    $src = Get-W2PUpdateSource
    if ([string]::IsNullOrWhiteSpace($src)) {
        return @{ status = 'disabled'; source = '' }
    }
    try {
        if ($src -match '^(?i)github:(.+)$') {
            # GitHub Releases IS the version file: the tag is the version, the
            # release body is the notes, and the assets are the per-OS builds.
            # One source of truth, nothing to hand-edit on release day.
            $repo = $Matches[1].Trim().Trim('/')
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
            # /releases, not /releases/latest: internal builds are tagged with a
            # nonzero 4th segment (v1.1.5.3) and must never be offered as
            # updates. Walk the list for the newest PUBLIC one: 4th segment 0
            # or absent, not a draft, not marked pre-release.
            $list = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases?per_page=15" -f $repo) `
                     -Headers @{ 'User-Agent' = 'Watch2Print'; 'Accept' = 'application/vnd.github+json' } `
                     -TimeoutSec 15 -ErrorAction Stop
            $rel = $null
            foreach ($cand in @($list)) {
                if ($cand.draft -or $cand.prerelease) { continue }
                $tv = ([string]$cand.tag_name).TrimStart('v').TrimStart('V')
                $parts = @(($tv -split '[^\d]+') | Where-Object { $_ -ne '' })
                if ($parts.Count -ge 4 -and [int]$parts[3] -ne 0) { continue }
                $rel = $cand; break
            }
            if (-not $rel) { return @{ status = 'current'; source = $src; version = $script:AppVersion } }
            $latest = ([string]$rel.tag_name).TrimStart('v').TrimStart('V')
            if ([string]::IsNullOrWhiteSpace($latest)) { throw 'The latest release has no tag name.' }
            if ((Compare-W2PVersion $latest $script:AppVersion) -le 0) {
                return @{ status = 'current'; source = $src; version = $script:AppVersion }
            }
            # Pick the asset for THIS machine's OS, so every platform updates
            # itself rather than being handed a Windows installer.
            $os  = Get-OSKey
            # The RAW build files, not the installers: the app replaces its own
            # runtime copy, so the Setup exe / .deb / .app zip stay first-install
            # only.
            $pat = switch ($os) {
                'windows' { '^Watch2Print\.exe$' }
                default   { '^Watch2Print_Web\.ps1$' }
            }
            $asset = @($rel.assets) | Where-Object { $_.name -match $pat } | Select-Object -First 1
            if (-not $asset) {
                return @{ status = 'error'; source = $src;
                          message = ("Version {0} is out, but its release has no {1} build attached." -f $latest, $os) }
            }
            $gnotes = [string]$rel.body
            if ($gnotes.Length -gt 400) { $gnotes = $gnotes.Substring(0, 400) + '...' }
            return @{
                status  = 'available'
                source  = $src
                version = $latest
                url     = [string]$asset.browser_download_url
                notes   = $gnotes
                os      = $os
                asset   = [string]$asset.name
                self    = $true
            }
        }

        $r = $null
        if ($src -match '^(?i)https?://') {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
            $r = Invoke-RestMethod -Uri $src -TimeoutSec 10 -ErrorAction Stop
        } else {
            # Local file or UNC share.
            if (-not (Test-Path -LiteralPath $src)) { throw "File not found: $src" }
            $raw = [System.IO.File]::ReadAllText($src)
            $r = ($raw -replace '^\uFEFF','') | ConvertFrom-Json
        }

        $latest = [string]$r.version
        if ([string]::IsNullOrWhiteSpace($latest)) {
            throw "The file at that address has no 'version' field."
        }
        if ((Compare-W2PVersion $latest $script:AppVersion) -le 0) {
            return @{ status = 'current'; source = $src; version = $script:AppVersion }
        }
        return @{
            status  = 'available'
            source  = $src
            version = $latest
            url     = [string]$r.url
            notes   = [string]$r.notes
        }
    } catch {
        return @{ status = 'error'; source = $src; message = $_.Exception.Message }
    }
}

function Install-W2PUpdate {
    # Downloads the new build next to the current one and returns where it
    # landed. Deliberately does NOT replace the running exe: Windows locks it
    # while it runs, and swapping the binary under a live print-farm watcher
    # is a much bigger promise than this is ready to make.
    param([string]$Url, [switch]$ToTemp)

    if ([string]::IsNullOrWhiteSpace($Url)) { throw 'That version has no download link.' }

    $name = 'Watch2Print-update.exe'
    try {
        $leaf = [System.IO.Path]::GetFileName(([Uri]$Url).LocalPath)
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { $name = $leaf }
    } catch { }

    $dest = Join-Path ([Environment]::GetFolderPath('UserProfile')) (Join-Path 'Downloads' $name)
    $dir  = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) { $dest = Join-Path (Get-W2PDataDir) $name }
    if ($ToTemp) { $dest = Join-Path ([System.IO.Path]::GetTempPath()) ('w2p-update-' + $name) }

    if ($Url -match '^(?i)https?://') {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        Invoke-WebRequest -Uri $Url -OutFile $dest -TimeoutSec 300 -ErrorAction Stop
    } else {
        if (-not (Test-Path -LiteralPath $Url)) { throw "File not found: $Url" }
        Copy-Item -LiteralPath $Url -Destination $dest -Force
    }

    if (-not (Test-Path -LiteralPath $dest)) { throw 'The download did not produce a file.' }
    $size = (Get-Item -LiteralPath $dest).Length
    if ($size -lt 10000) { throw "The downloaded file is only $size bytes - that is not a build." }
    return $dest
}

# --- self-update --------------------------------------------------------
# The app replaces its own runtime and restarts. A detached helper does the
# swap (a running exe cannot replace itself), then watchdogs the new build:
# if the web server is not answering within ~20 seconds, the old build is
# restored and relaunched. The previous build waits as .bak until the new one
# proves healthy.

function Test-W2PDownloadValid {
    # Refuse to swap in anything that is not verifiably the expected build.
    param([string]$Path, [string]$Version)
    $v3 = (@(($Version -split '[^\d]+') | Where-Object { $_ -ne '' } | Select-Object -First 3) -join '.')
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $fv  = [string]$fvi.FileVersion
        if ([string]::IsNullOrWhiteSpace($fv)) { throw 'The downloaded file has no version metadata - not a Watch2Print build.' }
        if ((Compare-W2PVersion $fv $v3) -ne 0) { throw ("The downloaded file is version {0}, expected {1}." -f $fv, $v3) }
        return $true
    }
    $txt = [System.IO.File]::ReadAllText($Path)
    if ($txt -notmatch [regex]::Escape("`$script:AppVersion = '1.1.6'")) { throw ("The downloaded file does not declare version {0}." -f $v3) }
    if ($txt -notmatch "EnginePayloadB64\s*=\s*@'") { throw 'The downloaded file has no engine payload - not a packed build.' }
    return $true
}

function Get-W2PSelfMode {
    # How is this instance running, and what file IS this instance?
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        $t = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($t -notmatch '\.exe$' -or $t -match 'powershell|pwsh') {
            throw 'Self-update needs the installed exe build; this is running as a loose script.'
        }
        return @{ mode = 'exe'; target = $t }
    }
    if (-not $script:SelfPath) { throw 'Cannot locate my own script file.' }
    if ($IsMacOS) {
        $label = 'com.prevolve.watch2print'
        try {
            $st = & launchctl print ("gui/{0}/{1}" -f (& id -u), $label) 2>$null
            if ($st -match ('pid = {0}\b' -f $PID)) { return @{ mode = 'launchd'; target = $script:SelfPath; label = $label } }
        } catch { }
        return @{ mode = 'pwsh'; target = $script:SelfPath }
    }
    if ($env:INVOCATION_ID) { return @{ mode = 'systemd'; target = $script:SelfPath } }
    return @{ mode = 'pwsh'; target = $script:SelfPath }
}

$script:UpdateHelperSrc = @'
param($OldPid,$Target,$NewFile,$Bak,$Port,$Mode,$Label)
$ErrorActionPreference = 'SilentlyContinue'
function Start-It { param($t)
    switch ($Mode) {
        'exe'     { Start-Process -FilePath $t -ArgumentList '-NoBrowser' }
        'pwsh'    { Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile','-File',$t,'-Port',"$Port",'-NoBrowser') }
        'systemd' { & systemctl --user start watch2print }
        'launchd' { & launchctl bootstrap ("gui/{0}" -f (& id -u)) (Join-Path $HOME 'Library/LaunchAgents/com.prevolve.watch2print.plist') }
    }
}
# Wait for the old instance to be fully gone before touching its file.
if ($Mode -eq 'systemd')     { & systemctl --user stop watch2print }
elseif ($Mode -eq 'launchd') { & launchctl bootout ("gui/{0}/{1}" -f (& id -u), $Label) }
if ($OldPid) { Wait-Process -Id $OldPid -Timeout 90 -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 600
Move-Item -LiteralPath $Target -Destination $Bak -Force
Move-Item -LiteralPath $NewFile -Destination $Target -Force
Start-It $Target
# Watchdog: the new build must answer on its port, or it gets rolled back.
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 700
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', [int]$Port)
        if ($c.Connected) { $ok = $true; $c.Close(); break }
    } catch { }
}
if ($ok) { Remove-Item -LiteralPath $Bak -Force }
else {
    if ($Mode -eq 'systemd')     { & systemctl --user stop watch2print }
    elseif ($Mode -eq 'launchd') { & launchctl bootout ("gui/{0}/{1}" -f (& id -u), $Label) }
    Move-Item -LiteralPath $Target -Destination ($Target + '.bad') -Force
    Move-Item -LiteralPath $Bak -Destination $Target -Force
    if ($Mode -eq 'launchd') { & launchctl bootstrap ("gui/{0}" -f (& id -u)) (Join-Path $HOME 'Library/LaunchAgents/com.prevolve.watch2print.plist') }
    Start-It $Target
}
'@

function Invoke-W2PSelfUpdate {
    param([string]$NewFile, [string]$Version)
    $m = Get-W2PSelfMode
    $helper = Join-Path ([System.IO.Path]::GetTempPath()) 'w2p-update-helper.ps1'
    [System.IO.File]::WriteAllText($helper, $script:UpdateHelperSrc, (New-Object System.Text.UTF8Encoding($false)))
    # 'none' placeholder: Start-Process rejects empty elements in ArgumentList,
    # and only launchd mode has a real label. ($hargs, not $args - that name is
    # an automatic variable inside functions.)
    $lbl = [string]$m.label
    if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = 'none' }
    $hargs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper,
               '-OldPid',"$PID",'-Target',$m.target,'-NewFile',$NewFile,
               '-Bak',($m.target + '.bak'),'-Port',"$Port",'-Mode',$m.mode,'-Label',$lbl)
    if ($m.mode -eq 'systemd') {
        # A child of the service dies with the service's cgroup when systemd
        # stops it, taking the swap down mid-flight. systemd-run puts the
        # helper in its own transient unit, outside our fate.
        & systemd-run --user --collect -- pwsh @hargs | Out-Null
    } elseif ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList (@('-WindowStyle','Hidden') + $hargs) -WindowStyle Hidden
    } else {
        Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList $hargs
    }
    return $m.mode
}

# --- run at sign-in -----------------------------------------------------
# Windows: a shortcut in the user's Startup folder. Deliberately the SAME name
# the installer's "start at sign-in" task creates, so the two agree instead of
# leaving two shortcuts fighting over one app.
#
# Registry Run keys were the alternative. A Startup shortcut wins because the
# operator can see it, and because some endpoint-management tools quietly strip
# Run entries they did not create.
function Get-W2PStartupLinkPath {
    if (-not (Get-W2PIsWindows)) { return $null }
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Watch2Print.lnk')
}

function Get-W2PLaunchTarget {
    # Packaged: the exe launches itself. Running loose as a .ps1: point at the
    # host executable with the script as an argument, so a developer checkout
    # can still test this instead of silently doing nothing.
    $exe = $null
    try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if ($exe -and $exe -notmatch '(?i)\\(powershell|pwsh)\.exe$') {
        return @{ target = $exe; arguments = ''; dir = (Split-Path -Parent $exe) }
    }
    $script = $null
    try { $script = $MyInvocation.MyCommand.Path } catch { }
    if (-not $script) { $script = Join-Path $here 'Watch2Print_Web.ps1' }
    return @{
        target    = $exe
        arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoBrowser' -f $script)
        dir       = (Split-Path -Parent $script)
    }
}

function Get-W2PStartupEnabled {
    if (Get-W2PIsWindows) {
        $lnk = Get-W2PStartupLinkPath
        return ($lnk -and (Test-Path -LiteralPath $lnk))
    }
    if ($IsMacOS) {
        # The launchd agent is the mac equivalent. Its presence IS the setting:
        # RunAtLoad is written true, so plist on disk means starts at login.
        return (Test-Path -LiteralPath (Get-W2PLaunchAgentPath))
    }
    # Linux: the systemd user service is the equivalent, when one is installed.
    try {
        $out = & systemctl --user is-enabled watch2print 2>$null
        return ([string]$out).Trim() -eq 'enabled'
    } catch { return $false }
}

function Get-W2PLaunchAgentPath {
    return (Join-Path $HOME 'Library/LaunchAgents/com.prevolve.watch2print.plist')
}

function Set-W2PStartupEnabled {
    param([bool]$Enabled)

    if (Get-W2PIsWindows) {
        $lnk = Get-W2PStartupLinkPath
        if (-not $lnk) { throw 'No Startup folder on this system.' }
        if (-not $Enabled) {
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
            return $false
        }
        $t = Get-W2PLaunchTarget
        if (-not $t.target) { throw 'Could not work out what to launch at sign-in.' }
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath       = $t.target
        $sc.Arguments        = $t.arguments
        $sc.WorkingDirectory = $t.dir
        $sc.Description      = 'Watch2Print - print farm folder watcher'
        $sc.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sh) | Out-Null
        return (Test-Path -LiteralPath $lnk)
    }

    if ($IsMacOS) {
        # launchd, not systemd. The toggle owns the same agent the CLI's
        # --install-service writes, so the two stay in step.
        $plist = Get-W2PLaunchAgentPath
        $uid   = & id -u
        if (-not $Enabled) {
            & launchctl bootout "gui/$uid/com.prevolve.watch2print" 2>$null
            if (Test-Path -LiteralPath $plist) { Remove-Item -LiteralPath $plist -Force }
            return $false
        }
        $pwshBin = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $scriptPath = $null
        try { $scriptPath = $MyInvocation.MyCommand.Path } catch { }
        if (-not $scriptPath) { $scriptPath = Join-Path $here 'Watch2Print_Web.ps1' }
        $dir = Split-Path -Parent $scriptPath
        # -AutoStart so a reboot resumes watching unattended - same default the
        # service installer recommends. -NoBrowser: nobody is at a login screen.
        $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.prevolve.watch2print</string>
  <key>ProgramArguments</key>
  <array>
    <string>$pwshBin</string>
    <string>-NoProfile</string>
    <string>-NonInteractive</string>
    <string>-File</string>
    <string>$scriptPath</string>
    <string>-Port</string>
    <string>$Port</string>
    <string>-NoBrowser</string>
    <string>-AutoStart</string>
  </array>
  <key>WorkingDirectory</key><string>$dir</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
"@
        $lad = Split-Path -Parent $plist
        if (-not (Test-Path -LiteralPath $lad)) { New-Item -ItemType Directory -Path $lad -Force | Out-Null }
        [System.IO.File]::WriteAllText($plist, $xml, (New-Object System.Text.UTF8Encoding($false)))
        # Register now; RunAtLoad covers every later login. Bootout first so a
        # re-toggle refreshes rather than erroring on "already loaded".
        & launchctl bootout "gui/$uid/com.prevolve.watch2print" 2>$null
        & launchctl bootstrap "gui/$uid" $plist 2>$null
        return $true
    }

    # Linux
    $verb = if ($Enabled) { 'enable' } else { 'disable' }
    $null = & systemctl --user $verb watch2print 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'No systemd service installed. Run install-linux.sh to set one up.'
    }
    return $Enabled
}

# Favicon, base64 PNG. Embedded rather than fetched so the browser tab matches
# the tray icon even on a machine with no internet.
$script:FaviconB64 = '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'

# The engine, gzip+base64. Regenerated by repack_web.py - never hand-edit.
$script:EnginePayloadB64 = @'
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
'@

function Expand-W2PGz {
    param([string]$B64)
    $bytes = [System.Convert]::FromBase64String(($B64 -replace '\s',''))
    $inMs  = New-Object System.IO.MemoryStream (,$bytes)
    $gz    = New-Object System.IO.Compression.GzipStream($inMs, [System.IO.Compression.CompressionMode]::Decompress)
    $outMs = New-Object System.IO.MemoryStream
    $gz.CopyTo($outMs); $gz.Dispose(); $inMs.Dispose()
    $text = [System.Text.Encoding]::UTF8.GetString($outMs.ToArray()); $outMs.Dispose()
    return $text
}

function Install-W2PEngine {
    # Unpack only when the payload differs from what is already on disk, so a
    # normal start costs one hash comparison rather than a rewrite.
    param([string]$Dir)
    $path = Join-Path $Dir 'Watch2Print_Engine_MP.ps1'
    $ver  = Join-Path $Dir 'engine.version'
    $sig  = ($script:EnginePayloadB64 -replace '\s','')
    $hash = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($sig))
    ).Replace('-','')
    if ((Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $ver)) {
        if ((Get-Content -Raw -LiteralPath $ver).Trim() -eq $hash) { return $path }
    }
    [System.IO.File]::WriteAllText($path, (Expand-W2PGz $script:EnginePayloadB64), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($ver, $hash, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Find-First { param([string[]]$Candidates)
    foreach ($c in $Candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path } }
    return $null
}

$dataDir = Get-W2PDataDir

# Loose files beside the script win, so a developer checkout still behaves the
# way it always has; otherwise fall back to the per-user data directory.
# A relocated config leaves a pointer in the data dir; follow it first, and
# quietly drop it if it has gone stale (file deleted or drive unplugged).
if (-not $Config) {
    $ptr = Join-Path $dataDir 'config.location'
    if (Test-Path -LiteralPath $ptr) {
        try {
            $loc = (Get-Content -LiteralPath $ptr -Raw).Trim()
            if ($loc -and (Test-Path -LiteralPath $loc)) { $Config = $loc }
            else { Remove-Item -LiteralPath $ptr -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
}
if (-not $Config)   { $Config   = Find-First @((Join-Path $here 'Program_Files_MP/watch2print_config.json'), (Join-Path $here 'watch2print_config.json'), (Join-Path $dataDir 'watch2print_config.json')) }
if (-not $Engine)   { $Engine   = Find-First @((Join-Path $here 'Watch2Print_Engine_MP.ps1'), (Join-Path $here 'Watch2Print.EngineMP.ps1')) }
if (-not $ColorMap) { $ColorMap = Find-First @((Join-Path $here 'Program_Files_MP/colormap.json'), (Join-Path $here 'colormap.json'), (Join-Path $dataDir 'colormap.json')) }

# No engine beside us means we are the packaged build: unpack our own.
if (-not $Engine -and $script:EnginePayloadB64.Trim() -ne 'PLACEHOLDER_ENGINE_PAYLOAD') {
    $Engine = Install-W2PEngine -Dir $dataDir
}
if (-not $Engine) { throw "No engine found. Pass -Engine <path to Watch2Print_Engine_MP.ps1>." }

# First run with no config at all: write a minimal one rather than refusing to
# start. An empty Settings tab is a far better first impression than a crash.
if (-not $Config) {
    $Config = Join-Path $dataDir 'watch2print_config.json'
    $seed = [ordered]@{
        platform = 'simplyprint'; theme = 'dark'; dryRun = $true
        logToFile = $true; logRetentionMonths = 3; logFolder = ''
        watchFolder = ''; watchExtensions = '.gcode'
        historyFile = (Join-Path $dataDir 'watch2print_history.txt')
        colormapFile = (Join-Path $dataDir 'colormap.json')
        debounceSeconds = 300; safetyScanSeconds = 7200; scanOnStartup = $false
        amount = 1; group = 0
        bindMode = 'local'; remoteAccess = 'readonly'; accessPassHash = ''
        companyIdSimplyPrint = ''; apiKeySimplyPrint = ''
        apiBase = ''; filesBase = ''; u1MinMatchScore = 2
        storeIdPrintago = ''; apiKeyPrintago = ''; printerIdPrintago = ''
        modelMapPrintago = 'P1S=P1S, P1P=P1P, X1C=X1 Carbon, A1=A1, H2D=H2D, H2S=H2S, U1=U1'
        overrideModelPrintago = $true; sendMaterialTypesPrintago = $true
        usernamePrinterOS = ''; passwordPrinterOS = ''; hostPrinterOS = 'cloud'
        projectPrinterOS = ''; defaultPrinterIdPrinterOS = ''
    }
    [System.IO.File]::WriteAllText($Config, (($seed | ConvertTo-Json -Depth 10)), (New-Object System.Text.UTF8Encoding($true)))
}
if (-not $ColorMap) { $ColorMap = Join-Path $dataDir 'colormap.json' }

# Seed a starter colour map on first run. An empty Colors tab reads like the
# feature is broken; a short, generic list reads like a starting point. These
# are deliberately plain - no shop-specific shortcuts.
if (-not (Test-Path -LiteralPath $ColorMap)) {
    $seedColors = @(
        [pscustomobject]@{ key='black';       name='Black';       hex='#000000' }
        [pscustomobject]@{ key='white';       name='White';       hex='#FFFFFF' }
        [pscustomobject]@{ key='grey';        name='Grey';        hex='#9F9F9F' }
        [pscustomobject]@{ key='red';         name='Red';         hex='#D50000' }
        [pscustomobject]@{ key='orange';      name='Orange';      hex='#FF9800' }
        [pscustomobject]@{ key='yellow';      name='Yellow';      hex='#FFEB3B' }
        [pscustomobject]@{ key='green';       name='Green';       hex='#4CAF50' }
        [pscustomobject]@{ key='blue';        name='Blue';        hex='#2196F3' }
        [pscustomobject]@{ key='purple';      name='Purple';      hex='#800080' }
        [pscustomobject]@{ key='pink';        name='Pink';        hex='#E91E63' }
        [pscustomobject]@{ key='brown';       name='Brown';       hex='#795548' }
        [pscustomobject]@{ key='natural';     name='Natural';     hex='#E3E3E3' }
        [pscustomobject]@{ key='transparent'; name='Transparent'; hex='#D9DAD1' }
    )
    try {
        [System.IO.File]::WriteAllText($ColorMap, ($seedColors | ConvertTo-Json -Depth 4),
                                       (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

# =====================================================================
# PLATFORM CAPABILITIES
# Mirrors Get-PlatformCaps in the engine and $script:Platforms in the WPF
# app. The settings page shows only the fields the active platform can
# actually use, instead of every platform's fields at once.
# =====================================================================
$script:Platforms = @(
    [pscustomobject]@{
        Key='simplyprint'; Label='SimplyPrint'
        Fields=@('companyIdSimplyPrint','apiKeySimplyPrint','u1MinMatchScore')
        Amount=$true; Group=$true; MaterialTags=$true; U1=$true; Rush=$true; Colormap=$true
    }
    [pscustomobject]@{
        Key='printago'; Label='Printago'
        Fields=@('storeIdPrintago','apiKeyPrintago','printerIdPrintago','modelMapPrintago','overrideModelPrintago','sendMaterialTypesPrintago','extraTagsPrintago')
        Amount=$true; Group=$false; MaterialTags=$false; U1=$false; Rush=$false; Colormap=$false
    }
    [pscustomobject]@{
        Key='printeros'; Label='3DPrinterOS'
        Fields=@('usernamePrinterOS','passwordPrinterOS','hostPrinterOS','projectPrinterOS','defaultPrinterIdPrinterOS')
        Amount=$true; Group=$false; MaterialTags=$false; U1=$false; Rush=$false; Colormap=$false
    }
)

# =====================================================================
# PATH PORTABILITY
# A config authored on Windows holds "P:\..." which cannot resolve on
# Linux, and vice versa. Rather than force one canonical form, the config
# may carry a pathsByOS block; the flat keys stay as the fallback so old
# configs keep working untouched.
#
#   "pathsByOS": { "windows": {"watchFolder":"P:\\..."},
#                  "linux":   {"watchFolder":"/home/..."} }
# =====================================================================
$script:PathKeys = @('watchFolder','historyFile','colormapFile')

function Get-OSKey {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'windows' }
    if ($IsWindows) { return 'windows' } elseif ($IsMacOS) { return 'macos' } else { return 'linux' }
}

function Test-PathShape {
    # Does this string look like a path for a DIFFERENT platform than we are on?
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $looksWindows = ($Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\')
    $looksUnix    = ($Path -match '^/')
    $os = Get-OSKey
    if ($os -eq 'windows' -and $looksUnix)    { return 'This is a Unix path; this machine is Windows.' }
    if ($os -ne 'windows' -and $looksWindows) { return 'This is a Windows path; this machine is ' + $os + '.' }
    return $null
}

function Resolve-ConfigPaths {
    # Overlay this OS's saved paths onto the flat keys the engine reads.
    param([Parameter(Mandatory)]$Cfg)
    $os = Get-OSKey
    if ($Cfg.PSObject.Properties.Name -contains 'pathsByOS' -and $Cfg.pathsByOS) {
        $blk = $Cfg.pathsByOS.$os
        if ($blk) {
            foreach ($k in $script:PathKeys) {
                if ($blk.PSObject.Properties.Name -contains $k) {
                    $v = [string]$blk.$k
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $Cfg.$k = $v }
                }
            }
        }
    }
    return $Cfg
}

function Save-OSPaths {
    # Record the flat path values under this OS, so the other platform's
    # paths are preserved rather than overwritten.
    param([Parameter(Mandatory)]$Cfg)
    $os = Get-OSKey
    if (-not ($Cfg.PSObject.Properties.Name -contains 'pathsByOS') -or -not $Cfg.pathsByOS) {
        $Cfg | Add-Member -NotePropertyName 'pathsByOS' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not ($Cfg.pathsByOS.PSObject.Properties.Name -contains $os)) {
        $Cfg.pathsByOS | Add-Member -NotePropertyName $os -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    foreach ($k in $script:PathKeys) {
        $v = [string]$Cfg.$k
        $Cfg.pathsByOS.$os | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force
    }
    return $Cfg
}

# =====================================================================
# CONFIG IO
# =====================================================================
# The config was written by 5.1 and carries a BOM. Read and write it
# explicitly or a PS7 save silently changes the encoding under the GUI.
function Read-W2PConfig {
    $bytes = [System.IO.File]::ReadAllBytes($Config)
    $text  = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return (Resolve-ConfigPaths ($text | ConvertFrom-Json))
}
function Write-W2PConfig { param([Parameter(Mandatory)]$Obj)
    [System.IO.File]::WriteAllText($Config, ($Obj | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($true)))
}

$Secrets = @('apiKeySimplyPrint','apiKeyPrintago','passwordPrinterOS')

# =====================================================================
# NETWORK ACCESS
# =====================================================================
# Two modes:
#   local   - http://localhost:PORT, this machine only. The default, and the
#             only mode needing no privileges and no firewall change.
#   network - http://+:PORT, reachable from the LAN so the shop can pause the
#             watcher or read the log without walking to this PC.
#
# Network mode is gated behind a passphrase. Not user accounts - a shared
# secret, because the realistic risk on a shop network is a mistyped address
# or idle curiosity halting production mid-upload, not an attacker.
#
# WHAT THIS IS NOT: HTTP on a LAN is unencrypted. The passphrase and anything
# changed travel in the clear. Acceptable inside a trusted network; never
# acceptable port-forwarded to the internet.
$script:Sessions   = @{}      # token -> expiry. In memory: a restart signs everyone out.
$script:SessionTTL = 30       # days a browser stays signed in

# These two are consulted on EVERY request by the access gate. Re-reading and
# re-parsing the config file each time is pure overhead on a server that
# handles one request at a time, and it showed as sluggishness once a second
# machine started polling. Cache them, and re-read only when the file changes.
$script:ModeCache = @{ stamp = [datetime]::MinValue; bind = 'local'; remote = 'readonly' }

function Sync-W2PModeCache {
    try {
        $stamp = (Get-Item -LiteralPath $Config -ErrorAction Stop).LastWriteTimeUtc
        if ($stamp -eq $script:ModeCache.stamp) { return }
        $c = Read-W2PConfig
        $script:ModeCache = @{
            stamp  = $stamp
            bind   = $(if (([string]$c.bindMode).Trim().ToLowerInvariant() -eq 'network') { 'network' } else { 'local' })
            remote = $(if (([string]$c.remoteAccess).Trim().ToLowerInvariant() -eq 'full') { 'full' } else { 'readonly' })
        }
    } catch { }
}

function Get-W2PBindMode {
    Sync-W2PModeCache
    return $script:ModeCache.bind
}

function Get-W2PRemoteAccess {
    # 'readonly' lets the shop watch the log without being able to stop the
    # watcher. 'full' gives signed-in users the same controls as the host.
    Sync-W2PModeCache
    return $script:ModeCache.remote
}

function New-W2PPassphrase {
    # Words, not symbol soup. Something read aloud across a workshop should be
    # sayable, and length beats character classes anyway.
    $words = @('anchor','basalt','cobalt','dagger','ember','fathom','granite','harbor',
               'indigo','jasper','kelvin','lantern','marble','nickel','onyx','pewter',
               'quartz','ridge','saffron','timber','umber','velvet','walnut','zephyr')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $take = {
        $b = New-Object byte[] 4; $rng.GetBytes($b)
        $words[([BitConverter]::ToUInt32($b,0) % $words.Count)]
    }
    $n = New-Object byte[] 4; $rng.GetBytes($n)
    return ('{0}-{1}-{2}{3}' -f (& $take), (& $take), (& $take), ([BitConverter]::ToUInt32($n,0) % 90 + 10))
}

function Get-W2PHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()
}

function Test-W2PPassphrase {
    param([string]$Attempt)
    try {
        $stored = [string](Read-W2PConfig).accessPassHash
        if ([string]::IsNullOrWhiteSpace($stored)) { return $false }
        # Only the hash is written to disk, so a copied config file does not
        # hand over the passphrase itself.
        return ((Get-W2PHash $Attempt) -eq $stored)
    } catch { return $false }
}

function New-W2PSession {
    $b = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $tok = [BitConverter]::ToString($b).Replace('-','').ToLowerInvariant()
    $script:Sessions[$tok] = (Get-Date).AddDays($script:SessionTTL)
    return $tok
}

function Test-W2PSession {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    if (-not $script:Sessions.ContainsKey($Token)) { return $false }
    if ((Get-Date) -gt $script:Sessions[$Token]) { $script:Sessions.Remove($Token) | Out-Null; return $false }
    return $true
}

function Get-W2PRequestAuth {
    <#
      What this request may do:
        local    - from this machine. Always full control, so fumbling the
                   passphrase can never lock the host out of its own app.
        full     - signed in, remote access set to full
        readonly - signed in, may look but not touch
        none     - not signed in
    #>
    param($Context)
    if ($Context.Request.IsLocal) { return 'local' }
    $tok = $null
    try { $tok = $Context.Request.Cookies['w2p_session'].Value } catch { }
    if (-not (Test-W2PSession $tok)) { return 'none' }
    if ((Get-W2PRemoteAccess) -eq 'full') { return 'full' }
    return 'readonly'
}

function Grant-W2PNetworkAccess {
    <#
      Ask Windows, once, for the two things needed to serve on the LAN:
        1. a URL reservation, because binding http://+:PORT needs either
           administrator rights or a reservation for this account
        2. an inbound firewall rule for the port

      TWO RULES THIS FUNCTION FOLLOWS, BOTH LEARNED THE HARD WAY:

      It never DELETES anything. The previous version deleted the firewall
      rule and re-added it on every grant. Once a wrong port number got baked
      in - the listener had moved to 8788 while the reservation held 8787 -
      every subsequent toggle wiped the working rule and restored the broken
      one. A hand-repaired machine would work, then silently stop the next
      time somebody flipped the switch.

      It never touches what is already correct. If the reservation and the
      rule are both in place for this port there is nothing to do, so there is
      no UAC prompt at all. The app's job is to ask once, verify, and
      otherwise leave Windows firewall state alone.

      -Profile any on the rule is deliberate and load-bearing. A shop Ethernet
      is frequently classified Public rather than Private (confirmed on the
      first machine this ran on), and a Private-scoped rule silently does
      nothing there - the app binds, and nobody can reach it.
    #>
    param([int]$Port)

    if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) {
        # Linux/macOS: HttpListener binds a high port directly - there is no
        # URL reservation, no netsh, no UAC. Nothing to grant. A distro
        # firewall (ufw, firewalld) is the operator's to open, so just say so.
        Write-Host ("  Nothing to grant on this OS. If a firewall is enabled, allow the port once:") -ForegroundColor DarkGray
        Write-Host ("    sudo ufw allow {0}/tcp" -f $Port) -ForegroundColor DarkGray
        return @{ ok = $true; skipped = $true }
    }

    $needAcl = -not (Test-W2PUrlAcl   -Port $Port)
    $needFw  = -not (Test-W2PFirewall -Port $Port -Force)

    if (-not $needAcl -and -not $needFw) {
        # Already set up for this port. Say so and prompt for nothing.
        return @{ ok = $true; skipped = $true }
    }

    $who   = "$env:USERDOMAIN\$env:USERNAME"
    $steps = @()
    if ($needAcl) {
        $steps += "netsh http add urlacl url=http://+:$Port/ user=`"$who`""
    }
    if ($needFw) {
        # Named per port, so a rule left over from a different port can never
        # be mistaken for this one - and is obvious when reading the list.
        $steps += "netsh advfirewall firewall add rule name=`"Watch2Print $Port`" dir=in action=allow protocol=TCP localport=$Port profile=any"
    }

    try {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ($steps -join ' & ') `
                           -Verb RunAs -Wait -PassThru -WindowStyle Hidden
        # Re-check rather than trusting the exit code: netsh returns non-zero
        # for "already exists", which is a success as far as we are concerned.
        $aclOk = Test-W2PUrlAcl   -Port $Port
        $fwOk  = Test-W2PFirewall -Port $Port -Force
        return @{ ok = ($aclOk -and $fwOk); acl = $aclOk; firewall = $fwOk; code = $p.ExitCode }
    } catch {
        # Almost always the UAC prompt being declined.
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

# Get-NetFirewallRule enumerates every rule on the machine and regularly takes
# seconds. This server handles one request at a time, so calling it per request
# stalled everything - including other machines' polls, which is what made
# remote access feel intermittent. Answer from cache and refresh rarely.
$script:FwCache = @{ port = 0; ok = $false; at = [datetime]::MinValue }

function Test-W2PFirewall {
    <#
      Is ANY enabled inbound rule letting this port through?

      Deliberately not restricted to rules this app created. A perfectly good
      hand-made rule was already making the app insist Windows was not set up,
      and prompting for permission it did not need. What matters is whether
      the port is open, not who opened it.

      Checking needs no elevation, so the app can notice a mismatch quietly
      and only ask for a UAC prompt when there is something to fix.
    #>
    param([int]$Port, [switch]$Force)

    if (-not $Force -and $script:FwCache.port -eq $Port -and
        ((Get-Date) - $script:FwCache.at).TotalSeconds -lt 60) {
        return $script:FwCache.ok
    }

    $ok = $true      # if we cannot tell, do not claim it is broken
    try {
        $ok = $false
        $rules = Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop
        foreach ($r in $rules) {
            $f = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            if (-not $f) { continue }
            if ($f.Protocol -ne 'TCP' -and $f.Protocol -ne 'Any') { continue }
            foreach ($p in @($f.LocalPort)) {
                if ("$p" -eq "$Port" -or "$p" -eq 'Any') { $ok = $true; break }
                # Ranges, e.g. 8000-9000
                if ("$p" -match '^(\d+)-(\d+)$' -and
                    [int]$Matches[1] -le $Port -and $Port -le [int]$Matches[2]) { $ok = $true; break }
            }
            if ($ok) { break }
        }
    } catch { $ok = $true }

    $script:FwCache = @{ port = $Port; ok = $ok; at = (Get-Date) }
    return $ok
}

function Test-W2PUrlAcl {
    param([int]$Port)
    # URL reservations only exist on Windows http.sys; elsewhere the answer
    # is always "fine", otherwise the UI keeps insisting setup is needed.
    if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { return $true }
    try {
        $out = & netsh http show urlacl url=http://+:$Port/ 2>$null | Out-String
        return ($out -match [regex]::Escape("http://+:$Port/"))
    } catch { return $false }
}

# NOTE: there is deliberately no Revoke here.
#
# Turning sharing off does not remove the URL reservation or the firewall
# rule: it stops answering remote requests in software instead. Removing them
# would mean a UAC prompt every time sharing is switched off, and - worse -
# once the reservation is gone the app cannot bind the port again without
# another prompt. Every 503, 400 and "access denied" in this feature's history
# came from taking the reservation away and putting it back.
#
# To remove them for good, from an elevated prompt:
#   netsh http delete urlacl url=http://+:8787/
#   netsh advfirewall firewall delete rule name="Watch2Print 8787"

function Start-W2PListener {
    # http.sys does not always release a registration the instant Close()
    # returns, so a rebind that is correct can still fail if it is attempted
    # immediately. Retry briefly before treating it as a real failure.
    param([string]$HostPart, [int]$Port, [int]$Attempts = 8)
    $err = $null
    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://${HostPart}:$Port/")
            $l.Start()
            return @{ ok = $true; listener = $l }
        } catch {
            $err = $_.Exception.Message
            try { $l.Close() } catch { }
            Start-Sleep -Milliseconds 250
        }
    }
    return @{ ok = $false; error = $err }
}

function Get-W2PLanAddress {
    # NOTE: no Get-NetIPAddress here on purpose. It returned whichever
    # adapter sorted first - on any machine running WSL or Hyper-V that is
    # a virtual adapter (172.x), which is not where the LAN lives. The NIC
    # walk below is cross-platform and prefers the adapter with a default
    # gateway, which is the one other machines can actually reach.
    try {
        $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }
        # An adapter with a default gateway is the one the LAN actually lives
        # on. Without this preference, virtual adapters (vEthernet/WSL,
        # Hyper-V, VPN taps) can come first and get reported as 'the' address.
        foreach ($wantGateway in @($true, $false)) {
            foreach ($n in $nics) {
                $props = $n.GetIPProperties()
                $hasGw = @($props.GatewayAddresses | Where-Object { $_.Address -and "$($_.Address)" -ne '0.0.0.0' }).Count -gt 0
                if ($wantGateway -and -not $hasGw) { continue }
                if (-not $wantGateway -and ($n.Name -match 'WSL|vEthernet|Hyper-V|Virtual')) { continue }
                foreach ($ua in $props.UnicastAddresses) {
                    $a = $ua.Address
                    if ($a.AddressFamily -eq 'InterNetwork' -and
                        "$a" -notlike '127.*' -and "$a" -notlike '169.254.*') { return "$a" }
                }
            }
        }
    } catch { }
    try {
        return ([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '127.*' -and $_.ToString() -notlike '169.254.*' } |
                Select-Object -First 1).ToString()
    } catch { return 'this-machine' }
}

# Load the engine's helper functions into this process. The engine is all
# function definitions until Start-Watch2PrintEngine is called, so this is
# safe - the console harness does the same thing. It gives us exactly one
# implementation of the credential crypto instead of a copy that can drift.
try { . $Engine } catch { throw "Could not load the engine at $($Engine): $($_.Exception.Message)" }

# Belt and braces for the client fix: the display mask must never be able to
# reach disk, whatever the page sends. A credential that looks exactly like
# "set (N chars)" is the UI's own placeholder, not a key anyone typed.
$script:MaskPattern = '^set \(\d+ chars\)$'

function Test-IsMaskedSecret {
    param([string]$Value)
    return ($Value -match $script:MaskPattern)
}

function Repair-MaskedSecrets {
    # One-time cleanup for configs damaged by the mask round-trip bug: the UI
    # placeholder was written over the real credential and then encrypted.
    # Nothing can recover the original, so blank it and say so plainly - a
    # missing key produces an obvious error, a mask produces a baffling one.
    param([Parameter(Mandatory)]$Cfg)
    $fixed = @()
    foreach ($k in $Secrets) {
        if ($Cfg.PSObject.Properties.Name -notcontains $k) { continue }
        $v = [string]$Cfg.$k
        if ([string]::IsNullOrEmpty($v)) { continue }
        $plain = if (Test-W2PEncrypted $v) { Unprotect-W2PSecret $v } else { $v }
        if (Test-IsMaskedSecret $plain) { $Cfg.$k = ''; $fixed += $k }
    }
    return $fixed
}

function Protect-ConfigSecrets {
    # Encrypt any credential still sitting in plain text, in place.
    param([Parameter(Mandatory)]$Cfg)
    $changed = $false
    foreach ($k in $Secrets) {
        if ($Cfg.PSObject.Properties.Name -notcontains $k) { continue }
        $v = [string]$Cfg.$k
        if ([string]::IsNullOrEmpty($v)) { continue }
        if (Test-W2PEncrypted $v) { continue }
        if (Test-IsMaskedSecret $v) {
            # Encrypting the mask would silently destroy the real credential.
            Write-Host "  WARNING: '$k' holds the display placeholder, not a key. Re-enter it in Settings." -ForegroundColor Yellow
            continue
        }
        $Cfg.$k = Protect-W2PSecret $v
        $changed = $true
    }
    return $changed
}

function Get-SafeConfig {
    $c = Read-W2PConfig; $o = [ordered]@{}
    foreach ($p in $c.PSObject.Properties) {
        if ($Secrets -contains $p.Name) {
            $v = [string]$p.Value
            if (Test-W2PEncrypted $v) { $v = Unprotect-W2PSecret $v }
            # A stored value that IS the mask is corruption from the old
            # round-trip bug, not a credential. Reporting it as "set" would
            # tell the operator everything is fine while uploads fail.
            if (Test-IsMaskedSecret $v) { $v = '' }
            $o[$p.Name] = if ($v) { "set ($($v.Length) chars)" } else { '' }
        } else { $o[$p.Name] = $p.Value }
    }
    return $o
}

function Get-EngineColorMap {
    # WHY THE VARIABLE, AND NOT foreach ($row in @(... | ConvertFrom-Json)):
    #
    # Windows PowerShell 5.1 emits a JSON array from ConvertFrom-Json as ONE
    # non-enumerated object. Wrapping that pipeline in @() therefore produces a
    # single-element array holding the whole list, so $row became the entire
    # file and [string]$row.key flattened every key into one space-joined
    # string. The result was a map with exactly one nonsense key: every colour
    # missed, and every upload got the #D9DAD1 fallback.
    #
    # PowerShell 7 enumerates it, so the same line worked while testing under
    # pwsh and broke the moment it ran inside the compiled exe (5.1). Assigning
    # first sidesteps the difference entirely.
    $m = @{}

    # The config's own colormapFile wins over the path resolved at startup. It
    # was being shown in Settings, saved, and then never read - so pointing it
    # somewhere new changed nothing. Resolved here rather than at startup
    # because this runs after every function is defined, and it picks up a
    # change on the next Start without restarting the app.
    $path = $ColorMap
    try {
        $cfgNow = Read-W2PConfig
        $cfgMap = [string]$cfgNow.colormapFile
        if (-not [string]::IsNullOrWhiteSpace($cfgMap)) { $path = $cfgMap.Trim() }
    } catch { }

    if (-not $path) { return $m }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("  Colour map not found: {0} - using built-in colours." -f $path) -ForegroundColor Yellow
        return $m
    }
    try {
        $parsed = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        foreach ($row in @($parsed)) {
            if ($null -eq $row) { continue }
            $k = ([string]$row.key).Trim().ToLowerInvariant()
            # A key with whitespace inside it can only be the flattening bug
            # above, or a genuinely malformed file. Either way it is not a
            # colour token, and silently accepting it is what hid this.
            if (-not $k) { continue }
            $m[$k] = @{ name = [string]$row.name; hex = [string]$row.hex }
        }
    } catch {
        Write-Host ("  Could not read the colour map: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return @{}
    }
    Write-Host ("  Colour map: {0} entries from {1}" -f $m.Count, $path) -ForegroundColor DarkGray
    return $m
}

function Read-ColorMapRaw {
    if ($ColorMap -and (Test-Path -LiteralPath $ColorMap)) {
        try {
            $arr = Get-Content -Raw -LiteralPath $ColorMap | ConvertFrom-Json
            if ($arr) { return @($arr) }
        } catch { }
    }
    return @()
}

function Write-ColorMapRaw {
    param([Parameter(Mandatory)]$Rows)
    # Same encoding discipline as everything else this app writes.
    $clean = @()
    foreach ($r in $Rows) {
        $k = ([string]$r.key).Trim()
        if ([string]::IsNullOrWhiteSpace($k)) { continue }   # a blank key can never match
        $clean += [pscustomobject]@{ key = $k; name = [string]$r.name; hex = [string]$r.hex }
    }
    $json = if ($clean.Count) { $clean | ConvertTo-Json -Depth 4 } else { '[]' }
    if ($clean.Count -eq 1) { $json = "[`r`n$json`r`n]" }   # ConvertTo-Json unwraps single items
    [System.IO.File]::WriteAllText($ColorMap, $json, (New-Object System.Text.UTF8Encoding($true)))
    return $clean.Count
}

# =====================================================================
# ENGINE HOSTING
# =====================================================================
# Same mechanism the WPF app uses: the engine runs in its own runspace with
# Write-Host shadowed so every line it prints lands in a concurrent queue
# instead of a console. The web server drains that queue into a flat list
# the browser polls by index.
$script:sync    = $null
$script:rs      = $null
$script:ps      = $null
$script:handle  = $null
$script:Running = $false
$script:Log     = New-Object System.Collections.ArrayList
$script:LogCap  = 5000        # keep memory bounded on a long-running farm
# Lines dropped off the front of the buffer. The browser polls by absolute
# line number, so once trimming starts the buffer's own index stops matching
# what the browser is asking for. Without this counter the display silently
# froze at exactly $LogCap lines while the engine carried on working.
$script:LogDropped = 0

$script:Bootstrap = {
    function Write-Host {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline=$true, Position=0)] $Object,
            [System.ConsoleColor] $ForegroundColor,
            [System.ConsoleColor] $BackgroundColor,
            [switch] $NoNewline,
            $Separator
        )
        $text = if ($null -eq $Object) { '' } else { [string]$Object }
        $color = $null
        if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $color = $ForegroundColor.ToString() }
        $Sync.Queue.Enqueue([pscustomobject]@{ Time = (Get-Date); Color = $color; Text = $text })
    }
    try {
        . $EnginePath
        Start-Watch2PrintEngine -Config $Config -Sync $Sync -ColorMap $ColorMap
    } catch {
        $Sync.Queue.Enqueue([pscustomobject]@{ Time=(Get-Date); Color='Red'; Text=('ENGINE CRASH: ' + $_.Exception.Message) })
    } finally {
        $Sync.Running = $false
    }
}

function Get-W2PLogKind {
    # Split the single engine stream into "what happened" and "how it happened".
    #
    # The engine already signals intent through Write-Host colours: DarkGray is
    # its own chatter, everything else is something it wanted noticed. That is
    # most of the classification for free. The text rules below only handle the
    # cases colour cannot: uncoloured lines, which are a mix of headline facts
    # ("Watching: ...") and raw HTTP bodies.
    param([string]$Text, [string]$Color)

    $t = [string]$Text
    if ([string]::IsNullOrWhiteSpace($t)) { return 'd' }

    # Wire-level detail is always debug, whatever colour it arrived in.
    if ($t -match '^\s*(POST|GET|PUT|PATCH)\s+http') { return 'd' }
    if ($t -match '^\s*(Body|Payload being sent|signed-url entry|full part response)') { return 'd' }
    if ($t -match '^\s*[\{\}\[\]]') { return 'd' }          # bare JSON braces
    if ($t -match '^\s*"[A-Za-z_]+"\s*:') { return 'd' }       # JSON key lines
    if ($t -match '^\s*event\s+W2P_') { return 'd' }
    if ($t -match 'SimplyPrint Analysis found these slots') { return 'd' }

    # Things an operator must see even though the engine printed them plainly.
    if ($t -match '^\*\*\*') { return 'a' }                   # new file, rush job
    if ($t -match '(?i)^(ERROR|WARNING)') { return 'a' }
    if ($t -match '(?i)(error|failed|could not|timed out)') { return 'a' }
    if ($t -match '^===') { return 'a' }                         # start/stop banners
    if ($t -match '(?i)^(Uploading|Queue OK|Upload OK|Queued OK|Material Assign OK|Verified:|History reloaded|Engine (starting|stopped)|Waiting for new files|Existing files tracked|Watcher armed)') { return 'a' }
    if ($t -match '(?i)^(Watching|Extensions|History|Endpoint|Batch window|Platform|Resolved printer model)') { return 'a' }

    switch ([string]$Color) {
        'DarkGray'  { return 'd' }
        'Gray'      { return 'd' }
        'DarkCyan'  { return 'd' }
        ''          { return 'd' }
        $null       { return 'd' }
        default     { return 'a' }   # Red/Yellow/Green/Cyan/Magenta = noticed
    }
}

# =====================================================================
# FILE LOGGING
# =====================================================================
# Everything the Activity/Debug panes show is also appended to a rolling
# debug file, so evidence of a 2am failure survives the 5,000-line UI
# buffer, a browser refresh, and a restart. A file covers at most 30 days
# or 50 MB, whichever comes first, then rotates:
#     debug_20260824-current.txt  ->  debug_20260824-20260923.txt
# Old finished files are purged past the configured retention.
$script:FL = @{ enabled=$false; folder=''; path=''; start=$null; size=0L; retention=3; fellBack=$false }

function Get-W2PLogFolderDefault { return (Join-Path $dataDir 'logs') }

function Hide-W2PLogSecrets { param([string]$Text)
    # Belt and braces: the panes should never carry credentials, but the file
    # outlives the session, so mask anything that looks like one anyway.
    return ([regex]::Replace($Text,
        '(?i)((?:api[-_ ]?key|authorization|bearer|token|passphrase|password)[\s"'':=]+)(\S+)',
        '$1***'))
}

function Write-W2PFileLogRaw { param([string]$Line)
    try {
        [System.IO.File]::AppendAllText($script:FL.path, $Line + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false)))
        $script:FL.size += ($Line.Length + 2)
    } catch { }
}

function Clear-W2POldLogs {
    if ($script:FL.retention -le 0) { return }   # 0 = keep forever
    $cut = (Get-Date).AddMonths(-1 * $script:FL.retention)
    try {
        Get-ChildItem -LiteralPath $script:FL.folder -Filter 'debug_*.txt' -ErrorAction Stop | ForEach-Object {
            if ($_.Name -match '^debug_(\d{8})-(\d{8})\.txt$') {
                $end = [datetime]::ParseExact($Matches[2], 'yyyyMMdd', $null)
                if ($end -lt $cut) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
        }
    } catch { }
}

function Complete-W2PFileLogRotation {
    # Close the current file under its real span and open a fresh one.
    $stamp = (Get-Date).ToString('yyyyMMdd')
    $done  = Join-Path $script:FL.folder ('debug_{0}-{1}.txt' -f $script:FL.start.ToString('yyyyMMdd'), $stamp)
    if (Test-Path -LiteralPath $done) {
        $done = Join-Path $script:FL.folder ('debug_{0}-{1}_{2}.txt' -f $script:FL.start.ToString('yyyyMMdd'), $stamp, (Get-Date).ToString('HHmmss'))
    }
    try { Move-Item -LiteralPath $script:FL.path -Destination $done -Force } catch { }
    $script:FL.start = (Get-Date).Date
    $script:FL.path  = Join-Path $script:FL.folder ('debug_{0}-current.txt' -f $script:FL.start.ToString('yyyyMMdd'))
    $script:FL.size  = 0L
    Write-W2PFileLogRaw ('===== log rotated; continued from {0} =====' -f (Split-Path -Leaf $done))
    Clear-W2POldLogs
}

function Write-W2PFileLog { param([string]$Text)
    if (-not $script:FL.enabled -or [string]::IsNullOrEmpty($script:FL.path)) { return }
    if ($script:FL.start -and (((Get-Date).Date -ge $script:FL.start.AddDays(30)) -or ($script:FL.size -ge 50MB))) {
        Complete-W2PFileLogRotation
    }
    Write-W2PFileLogRaw ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + (Hide-W2PLogSecrets $Text))
}

function Initialize-W2PFileLog {
    # Called at startup and again after every settings save. Reads the config
    # itself so callers cannot pass stale state.
    $cfg = $null
    try { $cfg = Read-W2PConfig } catch { return }
    $names = $cfg.PSObject.Properties.Name
    $script:FL.enabled   = -not (($names -contains 'logToFile') -and ($cfg.logToFile -eq $false))
    $script:FL.retention = $(if ($names -contains 'logRetentionMonths') { [int]$cfg.logRetentionMonths } else { 3 })
    if (-not $script:FL.enabled) { $script:FL.path = ''; return }

    $want = [string]$(if ($names -contains 'logFolder') { $cfg.logFolder } else { '' })
    $script:FL.fellBack = $false
    $folder = $null
    if (-not [string]::IsNullOrWhiteSpace($want)) {
        try {
            if (-not (Test-Path -LiteralPath $want -PathType Container)) { throw 'missing' }
            $probe = Join-Path $want ('.w2p_probe_{0}' -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($probe, 'ok'); Remove-Item -LiteralPath $probe -Force
            $folder = $want
        } catch { $script:FL.fellBack = $true }
    }
    if (-not $folder) { $folder = Get-W2PLogFolderDefault }
    try { if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null } }
    catch { $script:FL.enabled = $false; return }

    $prevPath = $script:FL.path
    $script:FL.folder = $folder
    # Adopt an unfinished file from the last session so a nightly restart does
    # not fragment the record into per-run scraps.
    $cur = Get-ChildItem -LiteralPath $folder -Filter 'debug_*-current.txt' -ErrorAction SilentlyContinue |
           Sort-Object Name | Select-Object -Last 1
    if ($cur -and $cur.Name -match '^debug_(\d{8})-current\.txt$') {
        $script:FL.start = [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null)
        $script:FL.path  = $cur.FullName
        $script:FL.size  = $cur.Length
    } else {
        $script:FL.start = (Get-Date).Date
        $script:FL.path  = Join-Path $folder ('debug_{0}-current.txt' -f $script:FL.start.ToString('yyyyMMdd'))
        $script:FL.size  = $(if (Test-Path -LiteralPath $script:FL.path) { (Get-Item -LiteralPath $script:FL.path).Length } else { 0L })
    }
    if ($script:FL.path -ne $prevPath) {
        Write-W2PFileLog ('----- logging to {0}{1} -----' -f $script:FL.path, $(if ($script:FL.fellBack) { ' (fallback: chosen folder was not usable)' } else { '' }))
    }
    # Day-30 may have passed while the program was off; rotate on the way in.
    if ((Get-Date).Date -ge $script:FL.start.AddDays(30) -or $script:FL.size -ge 50MB) { Complete-W2PFileLogRotation }
    Clear-W2POldLogs
}

function Add-Log { param([string]$Text, [string]$Color = $null)
    Write-W2PFileLog -Text $Text
    [void]$script:Log.Add([pscustomobject]@{
        t = (Get-Date).ToString('HH:mm:ss'); c = $Color; x = $Text
        k = (Get-W2PLogKind -Text $Text -Color $Color)
    })
    if ($script:Log.Count -gt $script:LogCap) {
        $drop = $script:Log.Count - $script:LogCap
        $script:Log.RemoveRange(0, $drop)
        $script:LogDropped += $drop
    }
    # Running headless, the browser poll buffer is the ONLY place engine output
    # goes - journalctl shows nothing but the server's own banner. An operator
    # debugging a failed upload at 2am should not have to open a browser, so
    # mirror every line to stdout when this is running as a service.
    if ($AutoStart -and -not [string]::IsNullOrWhiteSpace($Text)) {
        try { [Console]::Out.WriteLine(('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text)) } catch { }
    }
}

function Sync-EngineLog {
    if (-not ($script:sync -and $script:sync.Queue)) { return }
    $item = $null
    while ($script:sync.Queue.TryDequeue([ref]$item)) {
        Add-Log -Text $item.Text -Color $item.Color
        $item = $null
    }
    # The engine sets Sync.Running false on exit; reflect that in our state.
    if ($script:Running -and $script:handle -and $script:handle.IsCompleted) { Stop-EngineHard }
}

function Start-Engine {
    if ($script:Running) { return @{ ok = $false; error = 'Already running' } }

    $cfg = Read-W2PConfig
    if ([string]::IsNullOrWhiteSpace([string]$cfg.watchFolder) -or -not (Test-Path -LiteralPath $cfg.watchFolder)) {
        return @{ ok = $false; error = "Watch folder is empty or does not exist: $($cfg.watchFolder)" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.watchExtensions)) {
        return @{ ok = $false; error = 'Set at least one file extension to watch for.' }
    }

    $script:Log.Clear()
    $script:LogDropped = 0
    $script:sync = [hashtable]::Synchronized(@{
        Running       = $true
        ReloadHistory = $false   # set by /api/history/reload; engine clears it
        Queue         = (New-Object System.Collections.Concurrent.ConcurrentQueue[object])
    })

    $script:rs = [runspacefactory]::CreateRunspace()
    # MTA matters: the engine's FileSystemWatcher callbacks must not be
    # serialised onto a single-threaded apartment.
    $script:rs.ApartmentState = 'MTA'
    $script:rs.ThreadOptions  = 'ReuseThread'
    $script:rs.Open()
    $script:rs.SessionStateProxy.SetVariable('Sync',       $script:sync)
    $script:rs.SessionStateProxy.SetVariable('Config',     ($cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json))
    $script:rs.SessionStateProxy.SetVariable('ColorMap',   (Get-EngineColorMap))
    $script:rs.SessionStateProxy.SetVariable('EnginePath', $Engine)

    $script:ps = [powershell]::Create()
    $script:ps.Runspace = $script:rs
    $null = $script:ps.AddScript($script:Bootstrap.ToString())
    $script:handle = $script:ps.BeginInvoke()
    $script:Running = $true

    Add-Log -Text 'Engine starting...' -Color 'Cyan'
    return @{ ok = $true }
}

function Stop-EngineHard {
    # Tear down the runspace after the engine has signalled it is done.
    try { if ($script:ps -and $script:handle) { $script:ps.EndInvoke($script:handle) } } catch {}
    try { if ($script:ps) { $script:ps.Dispose() } } catch {}
    try { if ($script:rs) { $script:rs.Close(); $script:rs.Dispose() } } catch {}
    $script:ps = $null; $script:rs = $null; $script:handle = $null
    $script:Running = $false
    Add-Log -Text 'Engine stopped.' -Color 'DarkYellow'
}

function Request-HistoryReload {
    # Only meaningful while the engine loop is alive to see the flag. Setting
    # it when stopped would leave it armed and fire confusingly on next start.
    if (-not $script:Running) {
        return @{ ok = $false; error = 'The watcher is not running. History is read fresh when you press Start.' }
    }
    if ($script:sync) { $script:sync.ReloadHistory = $true }
    # The merge happens on the loop's next pass, not synchronously, so say so.
    Add-Log -Text 'Reload History requested - merging on the next pass...' -Color 'Cyan'
    return @{ ok = $true }
}

function Request-Stop {
    if (-not $script:Running) { return @{ ok = $false; error = 'Not running' } }
    # Co-operative: the engine checks Sync.Running and finishes the file it
    # is on rather than being killed mid-upload.
    if ($script:sync) { $script:sync.Running = $false }
    Add-Log -Text 'Stop requested - finishing current file...' -Color 'DarkYellow'
    return @{ ok = $true }
}

# =====================================================================
# PAGE
# =====================================================================
function Get-Html {
@'

<!doctype html>
<html lang="en" data-theme="dark"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Watch2Print</title>
<link rel="icon" type="image/png" href="/favicon.png?v=3">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Manrope:wght@400;500;600&display=swap" rel="stylesheet">
<style>
/* Palette taken from the Prevolve mark: #A9E4A6 pastel green on #0A2D04
   deep green. Amber is the only other hue, reserved for "there is something
   you have not done yet" - so it never appears unless it means something. */
:root[data-theme="dark"]{
  --bg:#081007; --panel:#122016; --sunk:#050B05; --line:#2A3E2C; --line2:#1E3020;
  --ink:#D3E4D0; --muted:#9DB29A; --dim:#7E9280; --shadow:rgba(0,0,0,.5);
  --accent:#B7EDB3; --accent-glow:rgba(183,237,179,.16);
  --btn-bg:#174A12; --btn-ink:#E4F6E2; --btn-hi-bg:#B7EDB3; --btn-hi-ink:#0A2D04;
  --gold:#F2D07E; --gold-bg:#3E3210; --gold-line:#856E28; --gold-ink:#F7E0A4;
  --stop:#E88781; --stop-bg:#3A1A18; --stop-ink:#F5B3AF; --ts:#46603F;
  --lg-red:#EE9A94; --lg-green:#9CE398; --lg-cyan:#8ADCCE; --lg-mag:#D2ACE2; --lg-white:#EFF7EE;
}
:root[data-theme="light"]{
  --bg:#EEF6ED; --panel:#FFFFFF; --sunk:#F6FBF5; --line:#CBDFC7; --line2:#E3F0E1;
  --ink:#0A2D04; --muted:#4C6746; --dim:#89A583; --shadow:rgba(10,45,4,.07);
  --accent:#0F4A08; --accent-glow:rgba(15,74,8,.13);
  --btn-bg:#0F4A08; --btn-ink:#EAF7E8; --btn-hi-bg:#A9E4A6; --btn-hi-ink:#0A2D04;
  --gold:#8A6608; --gold-bg:#FBF0D2; --gold-line:#D9BC63; --gold-ink:#6B4F05;
  --stop:#A8322B; --stop-bg:#FAE8E7; --stop-ink:#8A2721; --ts:#A9C2A4;
  --lg-red:#A8322B; --lg-green:#1D6E33; --lg-cyan:#0F5E6B; --lg-mag:#6E3A80; --lg-white:#0A2D04;
}
:root{
  --mono:ui-monospace,"SF Mono","Cascadia Mono","JetBrains Mono",Menlo,Consolas,monospace;
  --sans:"Manrope",Helvetica,"Segoe UI",system-ui,-apple-system,sans-serif;
  --lbl:300px;
}
*{box-sizing:border-box}
/* One flex column filling the viewport: header, tabs, scrolling content,
   button bar. Every previous version computed the log pane's height in JS by
   adding up the parts above it, which was wrong whenever those wrapped - and
   the pane then overshot and scrolled under the sticky header. */
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);font-size:15px;line-height:1.5;
  height:100vh;display:flex;flex-direction:column;overflow:hidden}

.strip{display:flex;flex-wrap:wrap;border-bottom:1px solid var(--line);background:var(--panel);flex:none;z-index:20}
.cell{padding:9px 18px;border-right:1px solid var(--line2);min-width:118px}
.cell .k{font-family:var(--sans);font-size:11px;font-weight:600;letter-spacing:.13em;text-transform:uppercase;color:var(--dim)}
.cell .v{font-family:var(--sans);font-size:14px;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:32ch}
.v.on{color:var(--accent)} .v.off{color:var(--gold)} .v.idle{color:var(--muted)}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:7px;vertical-align:1px;background:var(--dim)}
.dot.live{background:var(--accent)}
@media (prefers-reduced-motion:no-preference){.dot.live{animation:p 1.8s ease-in-out infinite}}
@keyframes p{0%,100%{opacity:1}50%{opacity:.35}}
.striptail{margin-left:auto;display:flex;align-items:center;gap:12px;padding:0 14px}

/* A real switch rather than a bare checkbox: the strip is all monospace
   readouts, and an OS-default tick box in the middle of it looks pasted on. */
.tgl{display:flex;align-items:center;gap:8px;margin-top:3px;cursor:pointer}
.tgl input{position:absolute;opacity:0;width:0;height:0}
.tglui{position:relative;width:30px;height:16px;border-radius:9px;flex:none;
  background:var(--sunk);border:1px solid var(--line)}
.tglui::after{content:'';position:absolute;top:2px;left:2px;width:10px;height:10px;
  border-radius:50%;background:var(--dim)}
@media (prefers-reduced-motion:no-preference){.tglui::after{transition:left .14s,background .14s}}
.tgl input:checked + .tglui{border-color:var(--accent)}
.tgl input:checked + .tglui::after{left:16px;background:var(--accent)}
.tgl input:focus-visible + .tglui{outline:2px solid var(--accent);outline-offset:2px}
.tgltxt{font-family:var(--mono);font-size:14px;color:var(--muted)}
.tgl input:checked ~ .tgltxt{color:var(--accent)}
.mark{width:30px;height:30px;border-radius:6px;display:block;flex:none}
:root[data-theme="dark"]  .mark.light{display:none}
:root[data-theme="light"] .mark.dark{display:none}

/* Sticks below the status strip so section switching stays reachable
   however far down the settings list you have scrolled. */
nav{display:flex;padding:0 18px;border-bottom:1px solid var(--line);background:var(--panel);
    flex:none;z-index:19;box-shadow:0 2px 6px var(--shadow)}
nav button{background:none;border:0;border-bottom:3px solid transparent;color:var(--muted);
  font-family:var(--sans);font-size:16px;font-weight:500;padding:15px 22px;cursor:pointer}
nav button.sel{color:var(--ink);border-bottom-color:var(--accent)}
nav button:hover{color:var(--ink)}
nav button[hidden]{display:none}

/* min-height:0 is load-bearing: without it a flex child refuses to shrink
   below its content and the scrollbar never appears. */
.wrap{max-width:1000px;width:100%;margin:0 auto;padding:22px 22px 22px;
  flex:1 1 auto;min-height:0;overflow-y:auto}
.page{display:none} .page.sel{display:block}
/* The monitor fills the column; the other tabs scroll normally. */
#p-monitor.sel{height:100%}

/* The two panes divide one fixed column, so the monitor always reaches the
   bottom of the window whether or not debug is open. --monh is set in JS from
   the real header/footer heights, since those wrap on narrow screens. */
#monwrap{display:flex;flex-direction:column;height:100%;min-height:220px}
.wrap,#log,#dbg,.mlist{scrollbar-width:thin;scrollbar-color:var(--line) transparent}
.wrap::-webkit-scrollbar,#log::-webkit-scrollbar,#dbg::-webkit-scrollbar,.mlist::-webkit-scrollbar{width:10px;height:10px}
.wrap::-webkit-scrollbar-track,#log::-webkit-scrollbar-track,#dbg::-webkit-scrollbar-track,.mlist::-webkit-scrollbar-track{background:transparent}
.wrap::-webkit-scrollbar-thumb,#log::-webkit-scrollbar-thumb,#dbg::-webkit-scrollbar-thumb,.mlist::-webkit-scrollbar-thumb{
  background:var(--line);border-radius:5px;border:2px solid transparent;background-clip:content-box}
.wrap::-webkit-scrollbar-thumb:hover,#log::-webkit-scrollbar-thumb:hover,#dbg::-webkit-scrollbar-thumb:hover,.mlist::-webkit-scrollbar-thumb:hover{background:var(--dim);background-clip:content-box}

#log{background:var(--sunk);border:1px solid var(--line);border-radius:5px;padding:12px 14px;
  font-family:var(--mono);font-size:13px;line-height:1.65;flex:1 1 auto;min-height:70px;
  overflow-y:auto;white-space:pre-wrap;word-break:break-word}
#log .ln{display:flex;gap:12px}
#log .ts{color:var(--ts);flex:none}
.c-Red,.c-DarkRed{color:var(--lg-red)}.c-Yellow,.c-DarkYellow{color:var(--gold)}
.c-Green,.c-DarkGreen{color:var(--lg-green)}.c-Cyan,.c-DarkCyan{color:var(--lg-cyan)}
.c-Magenta,.c-DarkMagenta{color:var(--lg-mag)}.c-Gray,.c-DarkGray{color:var(--dim)}
.c-White{color:var(--lg-white)}
#empty{color:var(--dim);font-family:var(--mono);font-size:13px}

/* Two panes, one stream. The top shows what happened; the bottom, collapsed
   by default, shows how - every request, body and ignored event. */
.dbgbar{display:flex;align-items:center;gap:12px;padding:8px 0;flex:none;user-select:none}
/* Only a handle when there is something to resize. */
.dbgbar.grab{cursor:ns-resize}
/* A small centred grip, not a full-width rule: enough of a cue to say "this
   is draggable" without drawing a bright line across the whole pane. */
/* Centred both ways inside the bar, not pinned to its top edge, or it crowds
   the pane above it. */
.dbgbar.grab::before{content:'';position:absolute;left:50%;top:50%;
  transform:translate(-50%,-50%);
  width:34px;height:8px;pointer-events:none;opacity:.45;
  background-image:repeating-linear-gradient(to bottom,var(--dim) 0 1px,transparent 1px 3px);
  background-size:34px 8px;background-repeat:no-repeat}
.dbgbar.grab:hover::before{opacity:.85}
.dbgbar.dragging::before{opacity:1;background-image:repeating-linear-gradient(to bottom,var(--accent) 0 1px,transparent 1px 3px)}
.dbgbar{position:relative}
.dbgbtn{background:none;border:1px solid var(--line);color:var(--muted);border-radius:3px;
  padding:5px 12px;font-family:var(--sans);font-size:12.5px;cursor:pointer}
.dbgbtn:hover{color:var(--ink);border-color:var(--muted)}
#dbgcaret{display:inline-block;font-size:11px}
@media (prefers-reduced-motion:no-preference){#dbgcaret{transition:transform .15s}}
#dbgcaret.open{transform:rotate(90deg)}
.dbghint{color:var(--dim);font-family:var(--mono);font-size:12px}
#dbg{background:var(--sunk);border:1px solid var(--line);border-radius:5px;padding:10px 14px;
  font-family:var(--mono);font-size:12px;line-height:1.6;flex:0 0 auto;height:220px;min-height:70px;
  overflow-y:auto;white-space:pre-wrap;word-break:break-word;color:var(--muted)}
#dbg .ln{display:flex;gap:12px}
#dbg .ts{color:var(--ts);flex:none}

fieldset{border:1px solid var(--line);border-radius:5px;padding:0;margin:0 0 18px;background:var(--panel);box-shadow:0 1px 2px var(--shadow)}
legend{font-family:var(--mono);font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:var(--accent);padding:0 9px;margin-left:13px}
.rows{padding:5px 18px 16px}
.row{display:grid;grid-template-columns:var(--lbl) minmax(0,1fr);gap:16px;align-items:start;padding:11px 0;border-bottom:1px solid var(--line2)}
.row:last-child{border-bottom:0}
label{color:var(--muted);font-size:14px;padding-top:7px}
label .hint{display:block;color:var(--dim);font-size:12px;margin-top:3px;line-height:1.45}
label .def{color:var(--dim);opacity:.85}
input[type=text],select{width:100%;background:var(--sunk);border:1px solid var(--line);color:var(--ink);
  font-family:var(--mono);font-size:13.5px;padding:8px 10px;border-radius:3px}
select{font-family:var(--sans)}
input[type=text]:focus,select:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-glow)}
input:disabled,select:disabled{opacity:.5}
input::placeholder{color:var(--dim)}
input[type=checkbox]{width:16px;height:16px;accent-color:var(--accent)}
.pathwarn{display:block;color:var(--gold);font-size:12.5px;margin-top:5px;font-family:var(--mono)}
.vrow{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.vnum{font-family:var(--mono);font-size:14px;color:var(--ink)}
.vstate{font-size:13px;color:var(--muted)}
.vstate.new{color:var(--gold)}
.vstate.err{color:var(--stop)}
.vstate a{color:var(--gold);font-weight:500;margin-left:6px}
.num{max-width:150px}
.pathrow{display:flex;gap:8px;align-items:center}
.pathrow input{flex:1 1 auto;min-width:0;text-overflow:ellipsis}
.browse{flex:none;background:none;border:1px solid var(--line);color:var(--muted);border-radius:3px;
  padding:8px 13px;font-size:13px;font-family:var(--sans);cursor:pointer;white-space:nowrap}
.browse:hover:not(:disabled){border-color:var(--accent);color:var(--accent)}

.modal{position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;
  justify-content:center;z-index:50;padding:24px}
.modal[hidden]{display:none}
.mbox{background:var(--panel);border:1px solid var(--line);border-radius:8px;width:min(720px,100%);
  max-height:80vh;display:flex;flex-direction:column;box-shadow:0 12px 40px var(--shadow)}
.mhead{padding:14px 18px;border-bottom:1px solid var(--line)}
.mhead h3{margin:0 0 8px;font-size:16px;font-weight:500;color:var(--ink)}
.mpath{width:100%;background:var(--sunk);border:1px solid var(--line);color:var(--ink);
  font-family:var(--mono);font-size:13px;padding:7px 9px;border-radius:3px}
.mlist{overflow-y:auto;flex:1;padding:6px 0}
.mrow{display:flex;align-items:center;gap:10px;padding:7px 18px;cursor:pointer;
  font-family:var(--mono);font-size:13.5px;color:var(--ink)}
.mrow:hover{background:var(--sunk)}
.mrow .ic{color:var(--accent);flex:none;width:15px;text-align:center}
.mrow.file .ic{color:var(--dim)}
.mrow.file{color:var(--muted)}
.mfoot{padding:12px 18px;border-top:1px solid var(--line);display:flex;gap:10px;align-items:center}
.mempty{padding:18px;color:var(--dim);font-size:13px}

.extwrap{display:flex;flex-wrap:wrap;gap:14px 18px;align-items:center}
.exts{display:flex;flex-wrap:wrap;gap:16px;align-items:center}
#extExtra{flex:1 1 360px;min-width:280px;width:auto}
.exts label{display:flex;align-items:center;gap:7px;color:var(--ink);font-family:var(--mono);font-size:13.5px;cursor:pointer}

table{width:100%;border-collapse:collapse}
th{text-align:left;font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;
   color:var(--dim);font-weight:400;padding:0 10px 8px;border-bottom:1px solid var(--line)}
td{padding:5px 10px;border-bottom:1px solid var(--line2)}
td input[type=text]{padding:6px 8px}
input[type=color]{width:30px;height:30px;padding:0;border:1px solid var(--line);border-radius:4px;background:none;cursor:pointer}
.swwrap{display:flex;align-items:center;gap:9px}
.xbtn{background:none;border:1px solid var(--line);color:var(--dim);border-radius:3px;
  width:26px;height:26px;line-height:1;cursor:pointer;font-size:15px}
.xbtn:hover{border-color:var(--stop);color:var(--stop)}
.tools{display:flex;gap:9px;padding:14px 10px 0;align-items:center}
.note{color:var(--dim);font-size:13px;margin:0 0 16px}
.note code{font-family:var(--mono);font-size:12.5px}

.bar{flex:none;background:var(--panel);border-top:1px solid var(--line);
  padding:11px 22px;display:flex;align-items:center;gap:11px;z-index:20;box-shadow:0 -2px 8px var(--shadow)}
button.act{background:var(--btn-bg);border:1px solid var(--accent);color:var(--btn-ink);font-family:var(--sans);
  font-size:14px;font-weight:500;padding:9px 20px;border-radius:3px;cursor:pointer}
button.act:hover:not(:disabled){background:var(--btn-hi-bg);color:var(--btn-hi-ink)}
button.ghost{background:none;border:1px solid var(--line);color:var(--muted)}
button.ghost:hover:not(:disabled){border-color:var(--muted);color:var(--ink);background:none}
button.nudge{background:var(--gold-bg);border-color:var(--gold-line);color:var(--gold-ink)}
button.nudge:hover:not(:disabled){background:var(--gold);color:#231A00}
button.live{background:var(--stop-bg);border-color:var(--stop);color:var(--stop-ink)}
button.live:hover:not(:disabled){background:var(--stop);color:var(--panel)}
@media (prefers-reduced-motion:no-preference){button.live{animation:lp 2.4s ease-in-out infinite}}
@keyframes lp{0%,100%{box-shadow:0 0 0 0 rgba(224,115,109,0)}50%{box-shadow:0 0 0 3px rgba(224,115,109,.22)}}
@media (prefers-reduced-motion:no-preference){button.nudge{animation:np 2.4s ease-in-out infinite}}
@keyframes np{0%,100%{box-shadow:0 0 0 0 rgba(232,192,90,0)}50%{box-shadow:0 0 0 3px rgba(232,192,90,.22)}}
button.danger{background:none;border:1px solid var(--line);color:var(--stop)}
button.danger:hover:not(:disabled){background:var(--stop);color:var(--panel);border-color:var(--stop)}
button:disabled{opacity:.4;cursor:default;animation:none}
button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.spacer{flex:1}
#msg{font-family:var(--sans);font-size:13px;color:var(--muted)}
#msg.ok{color:var(--accent)} #msg.err{color:var(--stop)} #msg.warn{color:var(--gold)}
#theme{background:none;border:1px solid var(--line);color:var(--muted);border-radius:3px;
  padding:5px 11px;font-size:12.5px;font-family:var(--sans);cursor:pointer}
#theme:hover{color:var(--ink);border-color:var(--muted)}
@media(max-width:640px){.row{grid-template-columns:1fr;gap:5px}.cell{min-width:50%}.striptail{width:100%;justify-content:flex-end;padding:8px 14px}nav button{padding:13px 15px;font-size:15px}}
</style></head><body>

<div class="strip" id="strip"></div>
<nav>
  <button data-p="monitor" class="sel">Monitor</button>
  <button data-p="settings">Settings</button>
  <button data-p="colors" id="tab-colors">Colors</button>
</nav>

<div class="wrap">
  <div class="page sel" id="p-monitor">
    <div id="monwrap">
      <div id="log"><div id="empty">Not running. Press Start watching to begin.</div></div>
      <div class="dbgbar" id="dbgbar">
        <button type="button" id="dbgtoggle" class="dbgbtn"><span id="dbgcaret">&#9656;</span> Debug</button>
        <span class="dbghint" id="dbgcount"></span>
        <span class="spacer"></span>
        <button type="button" id="dbgcopy" class="dbgbtn" hidden>Copy all</button>
      </div>
      <div id="dbg" hidden></div>
    </div>
  </div>

  <div class="page" id="p-settings">
    <form id="f" autocomplete="off"></form>
  </div>

  <div class="page" id="p-colors">
    <p class="note">Key is the color token as it appears in a file name, matched without case. Name is the label sent to the platform, and the swatch is what shows on the queue item. Saved to <code id="cpath"></code></p>
    <fieldset><legend>Color map</legend><div class="rows" style="padding-top:14px">
      <table><thead><tr><th style="width:44px"></th><th>Key in file name</th><th>Name sent to platform</th><th style="width:130px">Hex</th><th style="width:44px"></th></tr></thead>
      <tbody id="ctb"></tbody></table>
      <div class="tools">
        <button type="button" class="act ghost" id="cadd">Add color</button>
        <button type="button" class="act" id="csave">Save colors</button>
        <span id="cmsg" style="font-family:var(--mono);font-size:13px;color:var(--muted);font-family:var(--sans)"></span>
      </div>
    </div></fieldset>
  </div>
</div>

<div class="modal" id="passdlg" hidden>
  <div class="mbox" style="max-width:520px">
    <div class="mhead">
      <h3 id="passtitle">Share on the network</h3>
      <p class="note" style="margin:6px 0 0">Anyone on your network who has this passphrase will be able to reach Watch2Print. Choose something you can say out loud across the shop.</p>
    </div>
    <div style="padding:16px 18px">
      <label for="passinput" style="display:block;margin-bottom:6px">Passphrase</label>
      <input type="text" id="passinput" class="mpath" autocomplete="off" spellcheck="false" placeholder="at least 6 characters">
      <div style="margin-top:10px"><button type="button" class="act ghost" id="passsuggest">Suggest one</button></div>
    </div>
    <div class="mfoot">
      <button type="button" class="act" id="passok">Turn on sharing</button>
      <span class="spacer"></span>
      <button type="button" class="act ghost" id="passcancel">Cancel</button>
    </div>
  </div>
</div>

<div class="modal" id="pick" hidden>
  <div class="mbox">
    <div class="mhead">
      <h3 id="ptitle">Choose a folder</h3>
      <input type="text" class="mpath" id="ppath" spellcheck="false">
    </div>
    <div class="mlist" id="plist"></div>
    <div class="mfoot">
      <button type="button" class="act" id="pok">Use this folder</button>
      <button type="button" class="act ghost" id="pup">Up one level</button>
      <span class="spacer"></span>
      <button type="button" class="act ghost" id="pcancel">Cancel</button>
    </div>
  </div>
</div>

<div class="bar">
  <button class="act" id="start">Start watching</button>
  <button class="act ghost" id="stop" disabled>Stop</button>
  <button class="act ghost" id="reload" title="Re-read the history file so hand-added entries take effect without restarting">Reload history</button>
  <button class="act" id="save">Save changes</button>
  <span id="msg"></span>
  <span class="spacer"></span>
  <button class="act danger" id="quit">Quit</button>
</div>

<script>
const SECRETS=['apiKeySimplyPrint','apiKeyPrintago','passwordPrinterOS'];
const COMMON=[
 ['Watching',['watchFolder','configFolder','historyFile','colormapFile','watchExtensions','scanOnStartup','debounceSeconds','safetyScanSeconds']],
 ['Queue',['dryRun','amount','group']]
];
// Engine defaults, read straight out of the Get-Cfg calls in
// Watch2Print_Engine_MP.ps1, so an operator can tell what a value should be.
const DEFAULTS={
 watchExtensions:'.gcode', scanOnStartup:'off', debounceSeconds:'5 minutes',
 safetyScanSeconds:'120 minutes', dryRun:'off', amount:'1', group:'0', u1MinMatchScore:'2'
};
const HINTS={
 watchFolder:'Folder scanned for new files. Subfolders included.',
 watchExtensions:'File types to pick up. Tick these or add your own.',
 configFolder:'Where this settings file lives. Pick a new folder and it moves there.',
 historyFile:'Records what has already been sent, so nothing uploads twice',
 colormapFile:'Where the Colors tab saves to',
 scanOnStartup:'Process files already in the folder at start, not just new ones',
 debounceSeconds:'Files arriving in this window share one queue priority',
 safetyScanSeconds:'Periodic full re-scan, in case an event was missed. 0 turns it off.',
 dryRun:'Print what would be sent, without sending anything.',
 amount:'How many copies of each file to add to the queue',
 group:'Queue group id to file prints under. 0 means none.',
 u1MinMatchScore:'Match strength needed before the U1 tags a slot: 2 points for colour, 2 for material family, out of 4.',
 companyIdSimplyPrint:'The number in your SimplyPrint panel URL. The API addresses are built from it.',
 storeIdPrintago:'The store id from your app.printago.io URL',
 usernamePrinterOS:'Your 3DPrinterOS account e-mail',
 defaultPrinterIdPrinterOS:'Fallback when the file name matches nothing. Printers are found automatically.'
};
const COMMON_EXTS=['.gcode','.3mf','.stl'];
// Which settings are filesystem paths, and whether they point at a folder
// or a file. Drives the Browse buttons.
const PATHFIELDS={watchFolder:'dir', configFolder:'dir', historyFile:'file', colormapFile:'file'};
const LABEL=k=>k.replace(/([A-Z])/g,' $1').replace(/^./,c=>c.toUpperCase())
                .replace(/ Simply Print| Printago| Printer O S/,'').trim();
const esc=s=>String(s).replace(/[&<>"]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m]));
let CFG={},PLATS=[],WARN={},COLORS=[],OS='',RUNNING=false,SEEN=0,DEAD=false;
let VERSION='',UPDATE=null,STARTUP=false,MISSES=0,NETREADY=true;
let BINDMODE='local',REMOTE='readonly',AUTH='local',LANURL='';
let DIRTY=false, SAVED=false;

function applyTheme(t){
  document.documentElement.dataset.theme=t;
  const b=document.getElementById('theme');
  if(b) b.textContent = t==='dark' ? 'Light mode' : 'Dark mode';
}
function activePlat(){ return PLATS.find(p=>p.Key===CFG.platform) || PLATS[0] || {Fields:[]}; }

// Amber on Save means unsaved edits. Amber on Start means saved settings the
// watcher has not picked up yet. Never both at once.
function cues(){
  const s=document.getElementById('save'), st=document.getElementById('start');
  s.classList.toggle('nudge', DIRTY && !RUNNING);
  st.classList.toggle('nudge', SAVED && !DIRTY && !RUNNING);
  // Stop goes red only while there is something to stop.
  document.getElementById('stop').classList.toggle('live', RUNNING);
}
function markDirty(){ DIRTY=true; SAVED=false; cues(); msg('Unsaved changes','warn'); }

document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{
  document.querySelectorAll('nav button').forEach(x=>x.classList.toggle('sel',x===b));
  document.querySelectorAll('.page').forEach(p=>p.classList.toggle('sel',p.id==='p-'+b.dataset.p));

});

// Set while a sharing change is in flight. strip() replaces its own HTML on
// every status change, which re-creates the access checkbox from the stored
// value - so any poll landing before the change was confirmed put the toggle
// straight back to where it started.
let SWITCHING=false, PENDINGMODE='';
function strip(c){
  const cells=[
    ['status', RUNNING?'watching':'idle', RUNNING?'on':'idle', true],
    ['platform', (PLATS.find(p=>p.Key===c.platform)||{}).Label || c.platform || '-'],
    ['mode', c.dryRun?'dry run':'live', c.dryRun?'off':'on'],
    ['watch folder', c.watchFolder||'not set'],
    ['host', OS||'-']
  ];
  const startupCell = `<div class="cell"><div class="k">on startup</div>
    <label class="tgl"><input type="checkbox" id="startuptgl" ${STARTUP?'checked':''}>
    <span class="tglui"></span><span class="tgltxt">${STARTUP?'on':'off'}</span></label></div>`;
  // Only the host may change this, so a read-only visitor sees the state
  // without a control that would fail if they touched it.
  const shared = SWITCHING ? PENDINGMODE==='network' : BINDMODE==='network';
  const accessCell = `<div class="cell"><div class="k">access</div>
    <label class="tgl">${AUTH==='local'
      ? `<input type="checkbox" id="sharetgl" ${shared?'checked':''}><span class="tglui"></span>`
      : ''}<span class="tgltxt">${shared?'network':'local only'}</span></label></div>`;
  document.getElementById('strip').innerHTML=cells.map(([k,v,cls,dot])=>
    `<div class="cell"><div class="k">${k}</div><div class="v ${cls||''}">${
      dot?`<span class="dot ${RUNNING?'live':''}"></span>`:''}${esc(v)}</div></div>`).join('')
    + startupCell + accessCell
    + `<div class="striptail"><button id="theme" type="button"></button>`
    + `<img class="mark dark" alt="Prevolve" src="data:image/png;base64,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">`
    + `<img class="mark light" alt="Prevolve" src="data:image/png;base64,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"></div>`;
  applyTheme(document.documentElement.dataset.theme);
  const sh=document.getElementById('sharetgl');
  if(sh) sh.onchange=e=>{
    if(e.target.checked) askPassphrase(true);   // choose it before anything changes
    else setBindMode('local');
  };

  const st=document.getElementById('startuptgl');
  if(st) st.onchange=async e=>{
    const want=e.target.checked;
    try{
      const j=await post('/api/startup',{enabled:want});
      STARTUP=!!j.startup; strip(CFG);
      msg(STARTUP?'Watch2Print will start when you sign in.':'Watch2Print will no longer start automatically.','ok');
    }catch(err){
      e.target.checked=STARTUP;   // put it back; the change did not happen
      msg("Couldn't change that: "+err.message,'err');
    }
  };
  document.getElementById('theme').onclick=async()=>{
    const t=document.documentElement.dataset.theme==='dark'?'light':'dark';
    applyTheme(t); CFG.theme=t;
    // Its own endpoint on purpose: a display preference must persist without
    // going through the settings form, and must work while the engine runs.
    try{ await post('/api/theme',{theme:t}); }catch(e){}
  };

}

function hintBlock(k){
  const h=HINTS[k]||'';
  const d=DEFAULTS[k]?`<span class="def">(Default: ${esc(DEFAULTS[k])})</span>`:'';
  if(!h&&!d) return '';
  return `<span class="hint">${h}${h&&d?' ':''}${d}</span>`;
}

function extField(v){
  const list=String(v||'').split(',').map(s=>s.trim()).filter(Boolean);
  const extra=list.filter(x=>!COMMON_EXTS.includes(x.toLowerCase()));
  // Checkboxes and the free-text box share one flex row; the input wraps
  // underneath on its own when the window gets narrow.
  return `<div class="extwrap"><div class="exts">${COMMON_EXTS.map(x=>
      `<label><input type="checkbox" class="extbox" value="${x}" ${
        list.some(l=>l.toLowerCase()===x)?'checked':''}>${x}</label>`).join('')}</div>
    <input type="text" id="extExtra" value="${esc(extra.join(', '))}" title="Other extensions, separated by comma. (eg. .step, .obj, etc.)" placeholder="Other extensions, separated by comma. (eg. .step, .obj, etc.)"></div>`;
}

function field(k,v){
  if(k==='watchExtensions') return extField(v);
  // Both intervals are stored in seconds because that is what the engine
  // reads, but shown in minutes because that is the unit a person thinks in.
  if(k==='safetyScanSeconds')
    return `<input type="text" class="num" id="safetyScanMinutes" value="${Math.round((Number(v)||0)/60)}">`;
  if(k==='debounceSeconds')
    return `<input type="text" class="num" id="debounceMinutes" value="${Math.round((Number(v)||0)/60)}">`;
  if(k==='hostPrinterOS'){
    const opts=[['cloud','Cloud (cloud.3dprinteros.com)'],['acorn','Acorn (acorn.3dprinteros.com)']];
    return `<select id="hostPrinterOS">${opts.map(([val,lbl])=>
      `<option value="${val}" ${String(v).toLowerCase()===val?'selected':''}>${lbl}</option>`).join('')}</select>`;
  }
  const sec=SECRETS.includes(k);
  if(typeof v==='boolean') return `<input type="checkbox" id="${k}" ${v?'checked':''}>`;
  const warn=WARN[k]?`<span class="pathwarn">${esc(WARN[k])}</span>`:'';
  if(PATHFIELDS[k]){
    const kind=PATHFIELDS[k];
    return `<div class="pathrow"><input type="text" id="${k}" value="${esc(v??'')}" title="${esc(v??'')}">
      <button type="button" class="browse" data-for="${k}" data-kind="${kind}">Browse\u2026</button></div>${warn}`;
  }
  const num=(typeof v==='number')?'num':'';
  return `<input type="text" class="${num}" id="${k}" value="${sec?'':esc(v??'')}" title="${
    sec?'':esc(v??'')}" placeholder="${sec?esc(v||'not set')+' \u2014 leave blank to keep':''}">${warn}`;
}

function render(){
  const c=CFG, p=activePlat();
  let html=`<fieldset><legend>Platform</legend><div class="rows"><div class="row">
    <label for="platform">Send prints to<span class="hint">Only this platform's settings are shown below</span></label>
    <select id="platform">${PLATS.map(x=>
      `<option value="${x.Key}" ${x.Key===c.platform?'selected':''}>${esc(x.Label)}</option>`).join('')}</select>
  </div></div></fieldset>`;

  const groups=COMMON.concat([[p.Label||'Platform', (p.Fields||[]).filter(k=>k in c)]]);
  for(const [title,keys] of groups){
    const rows=keys.filter(k=>k in c).filter(k=>{
      if(k==='amount'&&!p.Amount) return false;
      if(k==='group'&&!p.Group) return false;
      if(k==='u1MinMatchScore'&&!p.U1) return false;
      return true;
    }).map(k=>{
      const lbl = k==='configFolder'      ? 'Config Folder'
                : k==='safetyScanSeconds' ? 'Safety re-scan (minutes)'
                : k==='debounceSeconds'    ? 'Batch window (minutes)'
                : k==='hostPrinterOS'      ? 'Server'
                : LABEL(k);
      return `<div class="row"><label for="${k}">${lbl}${hintBlock(k)}</label>${field(k,c[k])}</div>`;
    }).join('');
    if(rows) html+=`<fieldset><legend>${esc(title)}</legend><div class="rows">${rows}</div></fieldset>`;
  }
  // Only the host sees the sharing controls. A remote user changing the
  // passphrase or the access level could lock the shop out of its own watcher.
  if(AUTH==='local'){
    html+=`<fieldset><legend>Sharing</legend><div class="rows">
      <div class="row"><label>Who can reach this<span class="hint">Switched on from the access toggle at the top of the window. Sharing always starts off when Watch2Print launches.</span></label>
        <div class="vrow"><span class="vnum">${BINDMODE==='network'?'Anyone on the network with the passphrase':'This machine only'}</span></div></div>
      <div class="row"><label for="remoteAccess">What they can do<span class="hint">Read-only lets the shop watch the log without being able to stop the watcher or change settings.</span></label>
        <select id="remoteAccess">
          <option value="readonly" ${REMOTE==='readonly'?'selected':''}>Look only</option>
          <option value="full" ${REMOTE==='full'?'selected':''}>Full control</option>
        </select></div>
      <div class="row"><label>Address for others<span class="hint">Bookmark this on the other machines. It only answers while sharing is on.</span></label>
        <div class="vrow"><span class="vnum">${esc(LANURL||'')}</span>
        ${NETREADY?'':'<span class="vstate err">Windows is not set up for this port yet \u2014 turn sharing off and on to fix it.</span>'}</div></div>
      <div class="row"><label>Passphrase<span class="hint">Changing it signs everybody out.</span></label>
        <div class="vrow"><button type="button" class="act ghost" id="newpass">Set passphrase</button>
        <span id="passstate" class="vstate"></span></div></div>
    </div></fieldset>`;
  }

  // Host only, like Sharing: the folder browser walks the host filesystem
  // and the file lives on the host's disk.
  if(AUTH==='local'){
    const L=window.LOGINFO||{};
    const ret=Number(CFG.logRetentionMonths??3);
    html+=`<fieldset><legend>Logging</legend><div class="rows">
      <div class="row"><label for="logToFile">Save logs to file<span class="hint">Everything in the Activity and Debug panes is also written to a debug file, including engine start and stop. A new file begins every 30 days or 50 MB, named debug_datestart-dateend.</span></label>
        <input type="checkbox" id="logToFile" ${CFG.logToFile!==false?'checked':''}></div>
      <div class="row"><label for="logRetentionMonths">Keep old logs<span class="hint">Finished log files older than this are deleted automatically. The file being written is never touched.</span></label>
        <select id="logRetentionMonths">${[[1,'1 month'],[3,'3 months'],[6,'6 months'],[12,'12 months'],[0,'Forever']].map(([v,l])=>`<option value="${v}" ${ret===v?'selected':''}>${l}</option>`).join('')}</select></div>
      <div class="row"><label for="logFolder">Log folder<span class="hint">Leave blank for the default. If this folder is missing or unwritable, files fall back to the logs folder inside the config folder: ${esc(L.defaultFolder||'')}</span></label>
        <div class="pathrow"><input type="text" id="logFolder" value="${esc(CFG.logFolder??'')}" title="${esc(CFG.logFolder??'')}"><button type="button" class="browse" data-for="logFolder" data-kind="dir">Browse\u2026</button></div></div>
      <div class="row"><label>Current file<span class="hint">${L.fallback?'Using the fallback folder \u2014 the chosen folder was not usable.':'Where this session is being recorded.'}</span></label>
        <div class="vrow"><span class="vnum">${esc(L.file||'(logging off)')}${L.sizeKB?` \u2014 ${L.sizeKB} KB`:''}</span>
        <button type="button" class="act ghost" id="openlogs" ${L.enabled?'':'hidden'}>Open folder</button></div></div>
    </div></fieldset>`;
  }

  // Last section on purpose: useful, rarely urgent, and it gives the page a
  // natural end rather than trailing off after the platform credentials.
  html+=`<fieldset><legend>Version</legend><div class="rows">
    <div class="row"><label>Installed<span class="hint">The build currently running</span></label>
      <div class="vrow"><span class="vnum" id="vernum">${esc(VERSION||'unknown')}</span></div></div>
    <div class="row"><label>Updates</label>
      <div class="vrow">
        <button type="button" class="act ghost" id="vercheck">Check now</button>
        <button type="button" class="act nudge" id="verapply" hidden>Update</button>
        <span id="verstate" class="vstate"></span>
      </div></div>
  </div></fieldset>`;

  document.getElementById('f').innerHTML=html;
  document.getElementById('platform').onchange=e=>{ CFG.platform=e.target.value; markDirty(); render(); strip(CFG); };
  document.querySelectorAll('#f input,#f select').forEach(el=>{
    if(el.id==='platform') return;   // has its own handler above
    el.addEventListener('input',markDirty); el.addEventListener('change',markDirty);
    // Keep the hover tooltip in step with a value too long for the box.
    if(el.type==='text') el.addEventListener('input',()=>{
      el.title = el.value || el.placeholder || '';
    });
  });
  document.querySelectorAll('.browse').forEach(b=>b.onclick=()=>openPicker(b.dataset.for,b.dataset.kind));
  document.getElementById('tab-colors').hidden = !p.Colormap;
  const ol=document.getElementById('openlogs');
  if(ol) ol.onclick=async()=>{ try{ await post('/api/openlogs',{}); }catch(e){} };
  const ra=document.getElementById('remoteAccess');
  if(ra) ra.onchange=async e=>{
    try{
      const cfg=collect(); cfg.remoteAccess=e.target.value;
      await post('/api/config',cfg);
      REMOTE=e.target.value;
      msg(REMOTE==='full'?'Others can now change settings and stop the watcher.'
                         :'Others can now only watch the log.','ok');
    }catch(err){ msg("Couldn't change that: "+err.message,'err'); }
  };
  const np=document.getElementById('newpass');
  if(np) np.onclick=()=>{
    document.getElementById('passtitle').textContent='Change the passphrase';
    askPassphrase();
    // Reuse the same dialog, but this time it only sets the passphrase.
    const ok=document.getElementById('passok');
    ok.textContent='Change passphrase';
    ok.onclick=async()=>{
      const p=document.getElementById('passinput').value.trim();
      if(p.length<6){ msg('Use at least 6 characters for the passphrase.','err'); return; }
      document.getElementById('passdlg').hidden=true;
      try{
        await post('/api/passphrase',{passphrase:p});
        const st=document.getElementById('passstate');
        if(st){ st.textContent='Passphrase changed. Everyone has been signed out.'; st.className='vstate new'; }
      }catch(err){ msg("Couldn't do that: "+err.message,'err'); }
    };
  };

  document.getElementById('vercheck').onclick=()=>checkUpdate();
  document.getElementById('verapply').onclick=applyUpdate;
  paintVersion();
  setLocks(); cues();
}

// ---- network sharing ---------------------------------------------------
function askPassphrase(forToggle){
  const d=document.getElementById('passdlg');
  document.getElementById('passinput').value='';
  if(forToggle){
    // Settings reuses this dialog and replaces the button's handler, so the
    // toggle has to claim it back every time it opens.
    document.getElementById('passtitle').textContent='Share on the network';
    const ok=document.getElementById('passok');
    ok.textContent='Turn on sharing';
    ok.onclick=()=>{
      const p=document.getElementById('passinput').value.trim();
      if(p.length<6){ msg('Use at least 6 characters for the passphrase.','err'); return; }
      d.hidden=true;
      setBindMode('network',p);
    };
  }
  d.hidden=false;
  setTimeout(()=>document.getElementById('passinput').focus(),50);
}
function closePassphrase(revert){
  document.getElementById('passdlg').hidden=true;
  if(revert){ const s=document.getElementById('sharetgl'); if(s) s.checked=(BINDMODE==='network'); }
}
document.getElementById('passcancel').onclick=()=>closePassphrase(true);
document.getElementById('passdlg').addEventListener('click',e=>{
  if(e.target.id==='passdlg') closePassphrase(true);
});
document.getElementById('passsuggest').onclick=async()=>{
  try{
    const r=await fetch('/api/suggestpass');
    const j=await r.json();
    document.getElementById('passinput').value=j.passphrase||'';
  }catch(e){}
};
document.getElementById('passinput').addEventListener('keydown',e=>{
  if(e.key==='Enter'){ e.preventDefault(); document.getElementById('passok').click(); }
});
async function setBindMode(mode,passphrase){
  SWITCHING=true; PENDINGMODE=mode;
  msg(mode==='network'?'Turning on network sharing\u2026':'Switching back to this machine only\u2026');
  try{
    const j=await post('/api/bindmode', passphrase?{mode:mode,passphrase:passphrase}:{mode:mode});
    BINDMODE=j.mode;
    // The switch happens live: http://+:PORT covers localhost too, so this
    // page keeps working and there is nothing to restart.
    if(j.warning) msg(j.warning,'err');
    else if(mode==='network'){
      const url=j.url||LANURL;
      // No navigation: the listener does not move any more, so this tab keeps
      // working and stays on whichever section it was already showing.
      msg('Shared at '+url+' \u2014 others will need the passphrase.'
          + (j.needsPermission?' Accept the Windows prompt to finish.':''), 'ok');
    }
    else msg('Back to this machine only - other machines can no longer reach it.','ok');
    // The server answers before it rebinds, so this reply only means "asked".
    // Read the real state back and say so if it did not take - the toggle
    // flicking back with no explanation was worse than the original failure.
    setTimeout(async()=>{
      try{
        const r=await fetch('/api/config');
        const c=await r.json();
        const actual=c.bindMode||'local';
        BINDMODE=actual; REMOTE=c.remoteAccess||REMOTE; LANURL=c.lanUrl||LANURL;
        SWITCHING=false;
        strip(CFG);
        if(actual!==mode){
          msg(mode==='network'
            ? 'Sharing was not switched on - Windows did not grant permission. Try again and accept the prompt.'
            : 'Sharing could not be switched off. Try again.','err');
        }
      }catch(e){ SWITCHING=false; }
    },1800);
  }catch(err){
    SWITCHING=false;
    const s=document.getElementById('sharetgl'); if(s) s.checked=(BINDMODE==='network');
    msg("Couldn't change that: "+err.message,'err');
  }
}

function paintVersion(){
  const el=document.getElementById('verstate'), btn=document.getElementById('verapply');
  if(!el) return;
  const n=document.getElementById('vernum');
  if(n) n.textContent=VERSION||'unknown';
  if(btn) btn.hidden=true;

  if(!UPDATE){ el.className='vstate'; el.textContent=''; return; }

  switch(UPDATE.status){
    case 'available':
      el.className='vstate new';
      el.textContent='Version '+UPDATE.version+' is available'
        + (UPDATE.notes?' \u2014 '+UPDATE.notes:'') + '.';
      if(btn) btn.hidden=false;
      break;
    case 'current':
      el.className='vstate'; el.textContent='Up to date.'; break;
    case 'disabled':
      el.className='vstate';
      el.textContent='No update source set, so there is nothing to check.'; break;
    case 'error':
      // A failed check must never read as "up to date" - that is the one
      // answer that stops anyone looking into it.
      el.className='vstate err';
      el.textContent="Couldn't check: "+(UPDATE.message||'unknown error'); break;
  }
}

async function checkUpdate(){
  const el=document.getElementById('verstate');
  if(el){ el.className='vstate'; el.textContent='Checking\u2026'; }
  try{
    const j=await post('/api/checkupdate');
    VERSION=j.version||VERSION;
    UPDATE=j.update||null;
    paintVersion();
  }catch(e){
    if(el){ el.className='vstate err'; el.textContent="Couldn't check: "+e.message; }
  }
}

async function applyUpdate(){
  const el=document.getElementById('verstate'), btn=document.getElementById('verapply');
  if(UPDATE&&UPDATE.self){
    // End-to-end: download, verify, swap, restart, watchdog. The confirm is
    // the operator's acknowledgement of the brief watcher downtime.
    if(!confirm('Updating to version '+UPDATE.version+' will download the new build, install it, and restart Watch2Print automatically. The watcher pauses briefly while it restarts. Continue?')) return;
    if(btn) btn.disabled=true;
    try{
      if(el){ el.className='vstate'; el.textContent='Downloading\u2026'; }
      await post('/api/applyupdate');
      if(el){ el.textContent='Installing and restarting\u2026 this page will reload itself.'; }
      await post('/api/selfupdate');
      if(btn) btn.hidden=true;
      pollForRestart();
    }catch(e){
      if(el){ el.className='vstate err'; el.textContent="Couldn't update: "+e.message; }
      if(btn) btn.disabled=false;
    }
    return;
  }
  // Legacy path: a custom version.json updateUrl still downloads for a
  // manual install.
  if(btn) btn.disabled=true;
  if(el){ el.className='vstate'; el.textContent='Downloading\u2026'; }
  try{
    const j=await post('/api/applyupdate');
    if(el){
      el.className='vstate new';
      el.textContent='Downloaded to '+j.path+'. '+(j.next||'Quit Watch2Print, then run that file to finish updating.');
    }
    if(btn) btn.hidden=true;
  }catch(e){
    if(el){ el.className='vstate err'; el.textContent="Couldn't download: "+e.message; }
  }finally{
    if(btn) btn.disabled=false;
  }
}

function pollForRestart(){
  const el=document.getElementById('verstate');
  let waited=0;
  const iv=setInterval(async()=>{
    waited+=2;
    try{
      const r=await fetch('/api/config',{cache:'no-store'});
      if(r.ok){
        const j=await r.json();
        if(j.appVersion && j.appVersion!==VERSION){ clearInterval(iv); location.reload(); return; }
      }
    }catch(e){}
    if(waited>=120){
      clearInterval(iv);
      if(el){ el.className='vstate err'; el.textContent='The restart is taking longer than expected. If Watch2Print did not come back on the new version, the previous version was restored automatically \u2014 reload this page to see where things stand.'; }
    }
  },2000);
}

function colorRows(){
  document.getElementById('ctb').innerHTML=COLORS.map((r,i)=>`
   <tr>
    <td><div class="swwrap"><input type="color" value="${esc(/^#[0-9a-f]{6}$/i.test(r.hex||'')?r.hex:'#ffffff')}"
        oninput="COLORS[${i}].hex=this.value;document.getElementById('hx${i}').value=this.value"></div></td>
    <td><input type="text" value="${esc(r.key||'')}" oninput="COLORS[${i}].key=this.value"></td>
    <td><input type="text" value="${esc(r.name||'')}" oninput="COLORS[${i}].name=this.value"></td>
    <td><input type="text" id="hx${i}" value="${esc(r.hex||'')}" oninput="COLORS[${i}].hex=this.value"></td>
    <td><button type="button" class="xbtn" onclick="COLORS.splice(${i},1);colorRows()">&times;</button></td>
   </tr>`).join('') || `<tr><td colspan="5" style="color:var(--dim);padding:14px 10px">No colors yet. Add one to get started.</td></tr>`;
}
document.getElementById('cadd').onclick=()=>{COLORS.push({key:'',name:'',hex:'#FFFFFF'});colorRows();};
document.getElementById('csave').onclick=async()=>{
  const m=document.getElementById('cmsg'); m.textContent='Saving...'; m.style.color='var(--muted)';
  try{ const j=await post('/api/colors',COLORS);
       m.textContent='Saved '+j.count+' colors'; m.style.color='var(--accent)';
       SAVED=true; cues();
  }catch(e){ m.textContent="Couldn't save: "+e.message; m.style.color='var(--stop)'; }
};

function setLocks(){
  // A visitor who cannot act should not be shown live buttons that will
  // simply fail; disable them and say why once, in the status line.
  if(AUTH==='readonly'){
    const m=document.getElementById('msg');
    if(m && !m.textContent) { m.className=''; m.textContent='Shared read-only \u2014 you can watch, but changes are made on the machine running Watch2Print.'; }
    ['start','stop','save','reload','quit'].forEach(id=>{
      const b=document.getElementById(id); if(b){ b.disabled=true; b.classList.remove('nudge','live'); }
    });
    document.querySelectorAll('#f input,#f select,#p-colors input,#p-colors button')
      .forEach(i=>i.disabled=true);
    return;
  }
  document.querySelectorAll('#f input,#f select').forEach(i=>i.disabled=RUNNING);
  document.querySelectorAll('#p-colors input,#p-colors button').forEach(i=>i.disabled=RUNNING);
  document.getElementById('reload').disabled=false;   // meaningful in both states
  document.getElementById('save').disabled=RUNNING;
  document.getElementById('start').disabled=RUNNING;
  document.getElementById('stop').disabled=!RUNNING;
}

let DBGLINES=0, DROPPED=0;
function rowHtml(l){
  return `<div class="ln"><span class="ts">${l.t}</span><span class="${l.c?'c-'+l.c:''}">${esc(l.x)}</span></div>`;
}
const PANE_CAP = 4000;
function trimPane(box){
  // Drop from the top once the pane is well past what anyone will scroll back
  // through. Cheaper than it looks: this only runs when lines arrive.
  let extra = box.children.length - PANE_CAP;
  while(extra-- > 0 && box.firstChild) box.removeChild(box.firstChild);
}
function appendTo(box,lines){
  if(!lines.length) return;
  // Only auto-scroll when already near the bottom, so reading back through
  // the log is not yanked away every time a new line lands.
  const near=box.scrollHeight-box.scrollTop-box.clientHeight<60;
  box.insertAdjacentHTML('beforeend', lines.map(rowHtml).join(''));
  trimPane(box);
  if(near) box.scrollTop=box.scrollHeight;
}
function appendLog(lines){
  const e=document.getElementById('empty'); if(e) e.remove();
  // The activity pane is a filtered view; the debug pane is everything.
  appendTo(document.getElementById('log'), lines.filter(l=>l.k!=='d'));
  appendTo(document.getElementById('dbg'), lines);
  DBGLINES+=lines.length;
  const el=document.getElementById('dbgcount');
  el.textContent = DBGLINES
    ? DBGLINES+' line'+(DBGLINES===1?'':'s')+' this session'
      + (DROPPED? '  \u00b7 '+DROPPED+' older line'+(DROPPED===1?'':'s')+' discarded' : '')
    : '';
}
// Layout is pure CSS now - see the flex column on body. Kept as a no-op so
// the calls scattered through the code do not have to be hunted down.
function sizeMonitor(){}

document.getElementById('dbgtoggle').onclick=()=>{
  const d=document.getElementById('dbg'), c=document.getElementById('dbgcaret');
  const show=d.hidden;
  d.hidden=!show; c.classList.toggle('open',show);
  document.getElementById('dbgcopy').hidden=!show;
  document.getElementById('dbgbar').classList.toggle('grab',show);
  if(show){ d.scrollTop=d.scrollHeight; }
};

// Drag the bar to trade height between the two panes. Both keep a minimum so
// neither can be collapsed to nothing by accident.
(function(){
  const bar=document.getElementById('dbgbar'), dbg=document.getElementById('dbg'),
        wrap=document.getElementById('monwrap');
  let dragging=false, startY=0, startH=0;
  bar.addEventListener('mousedown',e=>{
    if(dbg.hidden) return;                    // nothing to resize
    if(e.target.closest('button')) return;    // let the buttons work
    dragging=true; startY=e.clientY; startH=dbg.offsetHeight;
    bar.classList.add('dragging');
    document.body.style.cursor='ns-resize';
    e.preventDefault();
  });
  window.addEventListener('mousemove',e=>{
    if(!dragging) return;
    const max=wrap.offsetHeight-bar.offsetHeight-70;   // leave the log usable
    dbg.style.height=Math.max(70,Math.min(max,startH-(e.clientY-startY)))+'px';
  });
  window.addEventListener('mouseup',()=>{
    if(!dragging) return;
    dragging=false; bar.classList.remove('dragging'); document.body.style.cursor='';
    // Persist server-side rather than in browser storage: the same operator
    // may open this from a different machine on the same farm.
    post('/api/uistate',{debugHeight:dbg.offsetHeight}).catch(()=>{});
  });
})();
document.getElementById('dbgcopy').onclick=()=>{
  // Handing someone a log should not mean screenshotting a scroll pane.
  const txt=[...document.querySelectorAll('#dbg .ln')].map(r=>r.innerText).join('\n');
  navigator.clipboard.writeText(txt).then(
    ()=>msg('Debug log copied to the clipboard.','ok'),
    ()=>msg("Couldn't copy - select the text manually.",'err'));
};

async function poll(){
  if(DEAD) return;
  try{
    const r=await fetch('/api/status?since='+SEEN);
    if(r.status===401){ location.href='/login'; return; }
    const j=await r.json();
    if(typeof j.auth==='string' && j.auth!==AUTH){ AUTH=j.auth; setLocks(); strip(CFG); }
    const was=RUNNING; RUNNING=j.running;
    // The server clears its buffer on every Start, so the log restarts at 0.
    // Without this the page keeps asking for "everything after line 60",
    // finds nothing, and goes silent for the whole next run.
    if(j.next < SEEN){
      SEEN=0; DBGLINES=0; DROPPED=0;
      document.getElementById('log').innerHTML='';
      document.getElementById('dbg').innerHTML='';
    }
    if(typeof j.dropped==='number') DROPPED=j.dropped;
    if(j.lines&&j.lines.length){ appendLog(j.lines); SEEN=j.next; }
    if(typeof j.startup==='boolean' && j.startup!==STARTUP){ STARTUP=j.startup; strip(CFG); }
    if(was!==RUNNING){ if(RUNNING) SAVED=false; setLocks(); strip(CFG); cues(); }
  }catch(e){
    // The listener is briefly down while it rebinds between local and network
    // mode. Declaring the app dead on the first missed poll turned a two
    // second gap into a page that never recovered.
    MISSES++;
    if(MISSES>=5){ DEAD=true; msg("Lost connection to Watch2Print. It may have been stopped.",'err'); }
    else if(MISSES>=2){ msg('Reconnecting\u2026'); }
    return;
  }
  MISSES=0;
}
function msg(t,cls){const m=document.getElementById('msg');m.className=cls||'';m.textContent=t;}

// ---- filesystem picker ------------------------------------------------
let PICK={target:null,kind:'dir',cur:''};
async function browseTo(p){
  const r=await fetch('/api/browse?path='+encodeURIComponent(p||''));
  const j=await r.json();
  PICK.cur=j.path||'';
  document.getElementById('ppath').value=PICK.cur;
  const list=document.getElementById('plist');
  const row=(cls,ic,name,path)=>`<div class="mrow ${cls}" data-path="${esc(path)}"><span class="ic">${ic}</span>${esc(name)}</div>`;
  let html='';
  if(j.roots&&j.roots.length) html+=j.roots.map(x=>row('dir','\u25B8',x,x)).join('');
  html+=(j.dirs||[]).map(d=>row('dir','\u25B8',d.name,d.path)).join('');
  if(PICK.kind==='file') html+=(j.files||[]).map(f=>row('file','\u00B7',f.name,f.path)).join('');
  list.innerHTML=html||`<div class="mempty">${j.error?esc(j.error):'Nothing here.'}</div>`;
  list.scrollTop=0;
  list.querySelectorAll('.mrow').forEach(el=>el.onclick=()=>{
    if(el.classList.contains('file')){ commitPick(el.dataset.path); }
    else browseTo(el.dataset.path);
  });
  document.getElementById('pok').textContent =
    PICK.kind==='dir' ? 'Use this folder' : 'Use this path';
}
async function openPicker(target,kind){
  PICK.target=target; PICK.kind=kind;
  const start=(document.getElementById(target)||{}).value||'';
  // Ask the host for a real OS dialog. Only if this machine has no GUI
  // toolkit available do we fall back to the in-page list.
  try{
    const j=await post('/api/pickpath',{kind:kind,start:start});
    if(j.cancelled) return;
    if(j.path){ commitPick(j.path); return; }
  }catch(e){ }
  document.getElementById('ptitle').textContent =
    kind==='dir' ? 'Choose a folder' : 'Choose a file';
  document.getElementById('pick').hidden=false;
  browseTo(start);
}
function commitPick(v){
  const el=document.getElementById(PICK.target);
  if(el){ el.value=v; el.title=v; markDirty(); }
  document.getElementById('pick').hidden=true;
}
document.getElementById('pcancel').onclick=()=>document.getElementById('pick').hidden=true;
document.getElementById('pup').onclick=async()=>{
  const r=await fetch('/api/browse?path='+encodeURIComponent(PICK.cur));
  const j=await r.json();
  browseTo(j.parent||'');
};
document.getElementById('pok').onclick=()=>commitPick(document.getElementById('ppath').value);
document.getElementById('ppath').addEventListener('keydown',e=>{
  if(e.key==='Enter'){ e.preventDefault(); browseTo(e.target.value); }
});
document.getElementById('pick').addEventListener('click',e=>{
  if(e.target.id==='pick') document.getElementById('pick').hidden=true;
});
document.addEventListener('keydown',e=>{
  if(e.key==='Escape') document.getElementById('pick').hidden=true;
});

function collect(){
  const out={};
  for(const k of Object.keys(CFG)){
    if(k==='watchExtensions'){
      const ticked=[...document.querySelectorAll('.extbox')].filter(b=>b.checked).map(b=>b.value);
      const extraEl=document.getElementById('extExtra');
      const extra=extraEl?extraEl.value.split(',').map(s=>s.trim()).filter(Boolean):[];
      out[k]=ticked.concat(extra).join(',');
      continue;
    }
    if(k==='safetyScanSeconds'||k==='debounceSeconds'){
      const el=document.getElementById(k==='safetyScanSeconds'?'safetyScanMinutes':'debounceMinutes');
      out[k]=el?Math.max(0,Math.round(Number(el.value)||0))*60:CFG[k];
      continue;
    }
    if(k==='theme'){ out[k]=document.documentElement.dataset.theme; continue; }
    if(k==='updateUrl'){ out[k]=CFG[k]; continue; }   // no UI field; never clobber it
    // Set through their own endpoints, never through the settings form.
    // Do NOT send these. They are owned by the access toggle and the
    // passphrase dialog, and CFG holds whatever was loaded when the page
    // opened - so echoing them back made Save changes silently re-enable
    // sharing using a stale value.
    if(k==='bindMode'||k==='accessPassHash'){ continue; }
    if(k==='remoteAccess'){ const s=document.getElementById('remoteAccess'); out[k]=s?s.value:CFG[k]; continue; }
    const el=document.getElementById(k);
    // CFG holds a MASK for secrets ("set (36 chars)"), never the real value.
    // Platform filtering means the inactive platforms' fields are not
    // rendered, so this branch runs for them - and sending CFG[k] back wrote
    // the mask over the real credential, which then got encrypted. Never
    // echo a secret we do not have.
    if(!el){ if(!SECRETS.includes(k)) out[k]=CFG[k]; continue; }
    if(el.type==='checkbox'){out[k]=el.checked;continue;}
    if(SECRETS.includes(k)){if(el.value!=='')out[k]=el.value;continue;}
    const o=CFG[k];
    out[k]=(typeof o==='number'&&el.value!==''&&!isNaN(el.value))?Number(el.value):el.value;
  }
  out.platform=CFG.platform;
  return out;
}

async function loadConfig(keepTheme){
  const r=await fetch('/api/config'); const j=await r.json();
  const prev=document.documentElement.dataset.theme;
  CFG=j.config; PLATS=j.platforms||[]; WARN=j.warnings||{}; COLORS=j.colors||[]; OS=j.os||'';
  CFG.configFolder=j.configFolder||'';   // UI-only: never written into the file
  window.LOGINFO=j.log||{};
  STARTUP=!!j.startup;
  document.getElementById('cpath').textContent=j.colorPath||'(none)';
  VERSION=j.version||''; UPDATE=j.update||null;
  BINDMODE=j.bindMode||'local'; REMOTE=j.remoteAccess||'readonly';
  AUTH=j.auth||'local'; LANURL=j.lanUrl||''; NETREADY=(j.netReady!==false);
  if(j.debugHeight){ document.getElementById('dbg').style.height=j.debugHeight+'px'; }
  applyTheme(keepTheme?prev:(CFG.theme==='light'?'light':'dark'));
  render(); strip(CFG); colorRows();
}

async function post(url,body){
  const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},
                           body:body?JSON.stringify(body):'{}'});
  // A 503 from http.sys, or a login page, is HTML. Parsing it as JSON gave
  // the useless "Unexpected token '<'" instead of saying what went wrong.
  const txt=await r.text();
  let j;
  try{ j=JSON.parse(txt); }
  catch(e){
    if(r.status===503) throw new Error('Watch2Print is not listening on this address. Open it at http://localhost:'+location.port+' instead.');
    if(r.status===401){ location.href='/login'; throw new Error('Signing in\u2026'); }
    throw new Error('The app returned an unexpected response (HTTP '+r.status+').');
  }
  // Session expired or the passphrase was rotated: go and sign in again
  // rather than showing a confusing error on every button.
  if(r.status===401 && j.signin){ location.href='/login'; throw new Error('Signing in\u2026'); }
  if(!r.ok||j.error) throw new Error(j.error||('HTTP '+r.status));
  return j;
}

document.getElementById('save').onclick=async()=>{
  msg('Saving...');
  try{
    const rsp=await post('/api/config',collect());
    await loadConfig(true);          // keep the theme on screen, never snap back
    DIRTY=false; SAVED=true; cues();
    msg(rsp.moved ? ('Saved. Settings file moved to '+rsp.moved) : 'Saved. Start the watcher to apply.','ok');
  }catch(e){ msg("Couldn't save: "+e.message,'err'); }
};
document.getElementById('start').onclick=async()=>{
  msg('Starting...');
  try{ await post('/api/start'); RUNNING=true; SAVED=false; DIRTY=false; setLocks(); strip(CFG); cues(); msg(''); await poll(); }
  catch(e){ msg("Couldn't start: "+e.message,'err'); }
};
document.getElementById('stop').onclick=async()=>{
  try{ await post('/api/stop'); msg(''); }catch(e){ msg("Couldn't stop: "+e.message,'err'); }
};
document.getElementById('reload').onclick=async()=>{
  if(!RUNNING){
    // Not an error worth a red message: stopping and starting already re-reads
    // the file, so there is genuinely nothing to do here.
    msg('Not needed - the history file is read fresh every time you press Start.');
    return;
  }
  msg('Requesting reload...');
  try{ await post('/api/reloadhistory'); msg('Reload requested - watch the log.','ok'); }
  catch(e){ msg("Couldn't reload: "+e.message,'err'); }
};
document.getElementById('quit').onclick=async()=>{
  if(!confirm(RUNNING?'The engine is still watching. Quit anyway?':'Quit Watch2Print?')) return;
  try{ await post('/api/quit'); }catch(e){}
  DEAD=true; msg('Watch2Print has shut down. You can close this tab.','err');
};
window.addEventListener('beforeunload',e=>{ if(DIRTY){ e.preventDefault(); e.returnValue=''; } });

loadConfig().then(()=>{ sizeMonitor(); poll(); setInterval(poll,1000); });
setTimeout(sizeMonitor,150);   // after the strip has rendered its final height
</script></body></html>
'@
}

# =====================================================================
# SERVER
# =====================================================================
# ---- single instance ---------------------------------------------------
# Two copies watching one folder is exactly the failure this network feature
# exists to prevent: the history ledger is written by whichever finishes
# first, and the other carries a stale view of what has been sent. A named
# mutex is cheaper and more reliable than probing the port.
$script:InstanceMutex = $null
$mutexNew = $false
try {
    $script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Global\Watch2Print_SingleInstance', [ref]$mutexNew)
} catch {
    # A mutex we cannot take is not a reason to refuse to run.
    $mutexNew = $true
}
if (-not $mutexNew) {
    Write-Host ''
    Write-Host '  Watch2Print is already running on this machine.' -ForegroundColor Yellow
    Write-Host '  Opening the copy already running rather than starting a second one.' -ForegroundColor DarkGray
    if (-not $NoBrowser) {
        try {
            $u = "http://localhost:$Port"
            if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { Start-Process $u }
            elseif ($IsMacOS) { & open $u }
            else { & xdg-open $u 2>$null }
        } catch { }
    }
    return
}

# ---- bind ---------------------------------------------------------------
# local   - this machine only, enforced in software.
# network - reachable from the LAN, behind a passphrase.
#
# Ports get held by other instances, by a stale http.sys reservation from a
# process that already exited, or by unrelated software. Refusing to start is
# the wrong answer for something meant to run unattended: walk up until one
# binds, and say which one was taken.
# ALWAYS start with sharing OFF, whatever the config remembers. Coming back up
# shared because it was shared yesterday is the wrong default for something
# that launches itself at sign-in: it should not be reachable from the network
# unless somebody decided so today.
$bindMode = 'local'
try {
    $c0 = Read-W2PConfig
    if (([string]$c0.bindMode) -eq 'network') {
        if ($c0.PSObject.Properties.Name -contains 'bindMode') { $c0.bindMode = 'local' }
        Write-W2PConfig -Obj $c0
    }
} catch { }

# Bind '+' whenever we are permitted to, even with sharing off, and refuse
# remote requests in software instead.
#
# Binding localhost while sharing is off does NOT work once a URL reservation
# exists: the reservation covers the whole port, so localhost on it is refused
# outright, and the app then walked up to the next free port. That is why
# nothing answered on 8787 from another machine.
$listener   = $null
$portTried  = $Port
$prefixUsed = ''
foreach ($hostPart in @('+', 'localhost')) {
    for ($i = 0; $i -lt 20; $i++) {
        $candidate = $Port + $i
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://${hostPart}:$candidate/")
        try {
            $l.Start()
            $listener = $l; $portTried = $candidate; $prefixUsed = $hostPart
            break
        } catch { try { $l.Close() } catch {} }
    }
    if ($listener) { break }
}

if (-not $listener) {
    throw "Could not bind any port from $Port to $($Port + 19). Something is occupying the whole range, or this account lacks permission to listen."
}
if ($portTried -ne $Port) {
    Write-Host ("  Port $Port was busy - using $portTried instead.") -ForegroundColor DarkYellow
}
$Port = $portTried

# One-time upgrade of any config still holding plain-text credentials.
try {
    $cfg0 = Read-W2PConfig
    $broken = Repair-MaskedSecrets $cfg0
    if ($broken.Count) {
        Write-W2PConfig -Obj $cfg0
        Write-Host ''
        Write-Host ("  These credentials were corrupted by an earlier bug and have been cleared:") -ForegroundColor Yellow
        foreach ($b in $broken) { Write-Host ("    - {0}" -f $b) -ForegroundColor Yellow }
        Write-Host '  Re-enter them on the Settings tab. They cannot be recovered.' -ForegroundColor Yellow
    }
    if (Protect-ConfigSecrets $cfg0) {
        Write-W2PConfig -Obj $cfg0
        Write-Host ''
        Write-Host '  Credentials in the settings file have been encrypted.' -ForegroundColor Green
        $kp = Get-W2PKeyPath
        if ($kp) { Write-Host "  Key file: $kp  (keep this off shared storage)" -ForegroundColor DarkGray }
        else     { Write-Host '  Protected with Windows DPAPI for your user account on this machine.' -ForegroundColor DarkGray }
    }
} catch { Write-Host "  Could not encrypt credentials: $($_.Exception.Message)" -ForegroundColor Yellow }

# Older configs predate the logging keys. Add them with their defaults so
# the Settings form can render and save them (the form only round-trips
# keys that exist in the file).
try {
    $mig = Read-W2PConfig
    $dirty = $false
    foreach ($pair in @(@('logToFile', $true), @('logRetentionMonths', 3), @('logFolder', ''))) {
        if (-not ($mig.PSObject.Properties.Name -contains $pair[0])) {
            $mig | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]
            $dirty = $true
        }
    }
    if ($dirty) { Write-W2PConfig -Obj $mig }
} catch { }

# Self-update aftercare: if this start is healthy, the previous build's .bak
# is no longer needed (the helper usually removes it; this covers a helper
# that died early). On Windows, keep Add/Remove Programs honest about the
# version - the exe swap bypasses the installer's registry write.
try {
    $selfTarget = if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    } else { $script:SelfPath }
    if ($selfTarget -and (Test-Path -LiteralPath ($selfTarget + '.bak'))) {
        Remove-Item -LiteralPath ($selfTarget + '.bak') -Force -ErrorAction SilentlyContinue
    }
} catch { }
if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
    try {
        Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction Stop | ForEach-Object {
            $k = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($k.DisplayName -like 'Watch2Print*' -and $k.DisplayVersion -ne $script:AppVersion) {
                Set-ItemProperty $_.PSPath -Name DisplayVersion -Value $script:AppVersion -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

Initialize-W2PFileLog
Write-W2PFileLog ('===== SESSION START - Watch2Print {0} on {1}, port {2} =====' -f $script:AppVersion, (Get-OSKey), $Port)

Write-Host ''
Write-Host '  watch2print - web UI' -ForegroundColor Cyan
Write-Host "  http://localhost:$Port" -ForegroundColor Green
if ($prefixUsed -eq '+') {
    Write-Host ("  http://{0}:{1}   (reachable once sharing is turned on)" -f (Get-W2PLanAddress), $Port) -ForegroundColor DarkGray
}
Write-Host ("  sharing: {0}" -f $(if ($bindMode -eq 'network') { 'on' } else { 'off - this machine only' })) -ForegroundColor DarkGray
if ($prefixUsed -eq '+' -and -not (Test-W2PFirewall -Port $Port)) {
    # Read-only check, so nothing prompts here. Turning sharing on repairs it.
    Write-Host ("  NOTE: no firewall rule for port {0}, so other machines cannot reach it yet." -f $Port) -ForegroundColor Yellow
    Write-Host '        Turning sharing on will repair the rule.' -ForegroundColor Yellow
}
Write-Host "  engine: $Engine" -ForegroundColor DarkGray
Write-Host "  config: $Config" -ForegroundColor DarkGray
Write-Host "  PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor DarkGray
Write-Host '  Quit from the tray icon or the page (Ctrl+C if a console is attached)' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoBrowser) {
    $url = "http://localhost:$Port"
    try {
        if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { Start-Process $url }
        elseif ($IsMacOS) { & open $url }
        else { & xdg-open $url 2>$null }
    } catch { Write-Host "  (open $url yourself)" -ForegroundColor DarkYellow }
}

function Invoke-NativePathPicker {
    <#
      Opens the operating system's own file/folder dialog on the machine
      running this server and returns the chosen path.

      Two Windows details, both learned the hard way:
        - A ScriptBlock cast to [Threading.ThreadStart] runs on a thread
          with NO PowerShell runspace, so the first cmdlet throws. Use a
          real runspace whose ApartmentState is STA instead.
        - Do NOT hand ShowDialog an owner Form created just to force
          TopMost. An owner with Opacity 0 swallows the dialog: it never
          paints, no error is raised, and the call simply returns nothing.
          Ownerless ShowDialog() works.

      Returns a path, '' if the user cancelled, or $null when this machine
      has no GUI picker - in which case the page falls back to its own list.
    #>
    param([ValidateSet('dir','file')][string]$Kind = 'dir', [string]$Start = '')

    $os = Get-OSKey

    if ($os -eq 'windows') {
        $script = @'
param([string]$Kind, [string]$Start)
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
if ($Kind -eq 'dir') {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Choose a folder'
    $d.ShowNewFolderButton = $true
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.SelectedPath = $Start }
} else {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = 'Choose a file'
    $d.CheckFileExists = $false
    $d.Filter = 'All files (*.*)|*.*'
    if ($Start) {
        $dir = if (Test-Path -LiteralPath $Start -PathType Container) { $Start } else { Split-Path -Parent $Start }
        if ($dir -and (Test-Path -LiteralPath $dir)) { $d.InitialDirectory = $dir }
    }
}
# Bringing the dialog IN FRONT of the browser fights two Windows rules:
#
#  1. Foreground lock. A background process cannot steal focus, so
#     Activate() quietly does nothing. TopMost z-ordering does NOT need
#     those rights, so an owner window in the always-on-top band is the
#     lever that actually works.
#  2. That owner has to be a genuinely visible window. Opacity 0 makes the
#     dialog never paint at all, and parking it at -32000 leaves it not
#     really visible, so it never joins the top-most band. One opaque
#     pixel at 0,0 satisfies Windows and is invisible in practice.
#
# AttachThreadInput then lets us borrow the foreground thread's input
# state for long enough that SetForegroundWindow is actually honoured.
$sig = @(
    '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);'
    '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'
    '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);'
    '[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);'
    '[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);'
    '[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();'
) -join [Environment]::NewLine
Add-Type -Namespace W2P -Name Fg -MemberDefinition $sig -ErrorAction SilentlyContinue

$owner = $null
try {
    $owner = New-Object System.Windows.Forms.Form
    $owner.FormBorderStyle = 'None'
    $owner.StartPosition   = 'Manual'
    $owner.Left = 0; $owner.Top = 0
    $owner.Width = 1; $owner.Height = 1
    $owner.ShowInTaskbar = $false
    $owner.TopMost       = $true
    $owner.Show()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $fg  = [W2P.Fg]::GetForegroundWindow()
        $fgT = [W2P.Fg]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
        $me  = [W2P.Fg]::GetCurrentThreadId()
        if ($fgT -ne $me) { [void][W2P.Fg]::AttachThreadInput($fgT, $me, $true) }
        [void][W2P.Fg]::BringWindowToTop($owner.Handle)
        [void][W2P.Fg]::SetForegroundWindow($owner.Handle)
        if ($fgT -ne $me) { [void][W2P.Fg]::AttachThreadInput($fgT, $me, $false) }
    } catch { }

    $owner.Activate()
    [System.Windows.Forms.Application]::DoEvents()
    $res = $d.ShowDialog($owner)
} catch {
    $res = $null
}
# If the owner route produced nothing usable, retry without one rather than
# leaving the user with a button that silently does nothing.
if ($null -eq $res) { $res = $d.ShowDialog() }
if ($owner) { try { $owner.Close(); $owner.Dispose() } catch {} }

if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
    if ($Kind -eq 'dir') { $d.SelectedPath } else { $d.FileName }
} else { '' }
$d.Dispose()
'@
        try {
            $rs = [runspacefactory]::CreateRunspace()
            $rs.ApartmentState = 'STA'
            $rs.ThreadOptions  = 'ReuseThread'
            $rs.Open()
            $psi = [powershell]::Create()
            $psi.Runspace = $rs
            $null = $psi.AddScript($script).AddArgument($Kind).AddArgument($Start)
            $out = $psi.Invoke()
            $errs = @($psi.Streams.Error)
            $psi.Dispose(); $rs.Close(); $rs.Dispose()
            if ($errs.Count) {
                Write-Host ("       native dialog failed: {0}" -f $errs[0].Exception.Message) -ForegroundColor DarkYellow
                return $null
            }
            $vals = @($out | Where-Object { $_ -is [string] })
            if ($vals.Count -eq 0) {
                Write-Host '       native dialog returned nothing' -ForegroundColor DarkYellow
                return $null
            }
            return [string]$vals[-1]
        } catch {
            Write-Host ("       native dialog failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
            return $null
        }
    }

    if ($os -eq 'macos') {
        $verb = if ($Kind -eq 'dir') { 'choose folder' } else { 'choose file' }
        try {
            $p = & osascript -e "POSIX path of ($verb)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $p) { return ([string]$p).Trim() }
            return ''
        } catch { return $null }
    }

    foreach ($tool in @('zenity','kdialog')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { continue }
        try {
            if ($tool -eq 'zenity') {
                $za = @('--file-selection')
                if ($Kind -eq 'dir') { $za += '--directory' }
                if ($Start) { $za += "--filename=$Start" }
                $p = & zenity @za 2>$null
            } else {
                $base = if ($Start) { $Start } else { $HOME }
                $p = if ($Kind -eq 'dir') { & kdialog --getexistingdirectory $base 2>$null }
                     else { & kdialog --getopenfilename $base 2>$null }
            }
            if ($LASTEXITCODE -eq 0 -and $p) { return ([string]$p).Trim() }
            return ''
        } catch { }
    }
    return $null
}

function Get-LoginHtml {
    param([string]$Message = '')
    # A REAL form that POSTs and navigates, not a fetch() call. That is what
    # makes Chrome and every password manager offer to save it. The hidden
    # username field is there for the same reason: most managers will not save
    # a password with no accompanying username.
    $err = ''
    if ($Message) { $err = "<p class=""err"">$Message</p>" }
    $body = @'
<!doctype html>
<html lang="en" data-theme="dark"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Watch2Print - sign in</title>
<link rel="icon" type="image/png" href="/favicon.png?v=3">
<style>
:root{--bg:#081007;--panel:#122016;--sunk:#050B05;--line:#2A3E2C;--ink:#D3E4D0;
  --muted:#9DB29A;--dim:#7E9280;--accent:#B7EDB3;--btn:#174A12;--stop:#E88781;
  --sans:"Manrope",Helvetica,"Segoe UI",system-ui,sans-serif;
  --mono:ui-monospace,"Cascadia Mono",Consolas,monospace}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
  background:var(--bg);color:var(--ink);font-family:var(--sans);font-size:15px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;
  padding:34px 34px 28px;width:min(400px,92vw)}
h1{margin:0 0 4px;font-size:22px;font-weight:600}
p.sub{margin:0 0 24px;color:var(--muted);font-size:13.5px;line-height:1.5}
label{display:block;color:var(--muted);font-size:13px;margin:0 0 6px}
input{width:100%;background:var(--sunk);border:1px solid var(--line);color:var(--ink);
  font-family:var(--mono);font-size:14px;padding:10px 12px;border-radius:3px}
input:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px rgba(183,237,179,.16)}
button{width:100%;margin-top:18px;background:var(--btn);border:1px solid var(--accent);
  color:#E4F6E2;font-family:var(--sans);font-size:15px;font-weight:500;padding:11px;
  border-radius:3px;cursor:pointer}
button:hover{background:var(--accent);color:#0A2D04}
.err{background:#3A1A18;border:1px solid var(--stop);color:#F5B3AF;padding:9px 12px;
  border-radius:3px;font-size:13.5px;margin:0 0 18px}
.foot{margin-top:20px;color:var(--dim);font-size:12px;line-height:1.5}
</style></head><body>
<form class="card" method="POST" action="/login">
  <h1>Watch2Print</h1>
  <p class="sub">This watcher is shared across the network. Enter the passphrase to continue.</p>
  __ERR__
  <input type="text" name="username" value="watch2print" autocomplete="username" hidden>
  <label for="p">Passphrase</label>
  <input id="p" name="passphrase" type="password" autocomplete="current-password" autofocus>
  <button type="submit">Sign in</button>
  <p class="foot">Ask whoever set this up for the passphrase. It is shown on the host machine under Settings.</p>
</form>
</body></html>
'@
    return ($body -replace '__ERR__', $err)
}

function Send-Response {
    param($Context, [string]$Body, [string]$Type = 'application/json', [int]$Code = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode  = $Code
    $Context.Response.ContentType = "$Type; charset=utf-8"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

# --- system tray icon ---------------------------------------------------
# With no console window there has to be SOMETHING on screen the operator can
# get back to, or an app they closed the browser tab on is simply gone with no
# way to reach it short of Task Manager.
#
# The icon runs on this same thread rather than a second one: the accept loop
# below already waits in 200ms slices, so pumping Windows messages there is
# enough to keep the menu responsive without any threading at all.
$script:Tray = $null
function Initialize-W2PTray {
    param([string]$Url)
    if (-not (Get-W2PIsWindowsHost)) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $ni = New-Object System.Windows.Forms.NotifyIcon
        # Borrow the exe's own icon so the tray matches the file the user
        # double-clicked. Falls back to a stock icon when run as a .ps1.
        $ico = $null
        try {
            $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($exe -notmatch '(?i)(powershell|pwsh)\.exe$') {
                $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
            }
        } catch { }
        if (-not $ico) { $ico = [System.Drawing.SystemIcons]::Application }
        $ni.Icon = $ico
        $ni.Text = 'Watch2Print'
        $ni.Visible = $true

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $open = $menu.Items.Add('Open Watch2Print')
        $open.add_Click({ try { Start-Process $script:TrayUrl } catch { } })
        $null = $menu.Items.Add('-')
        $quit = $menu.Items.Add('Quit')
        $quit.add_Click({ $script:Quit = $true })
        $ni.ContextMenuStrip = $menu
        # Double-clicking the tray icon is the shortest path back to the UI.
        $ni.add_DoubleClick({ try { Start-Process $script:TrayUrl } catch { } })

        $script:TrayUrl = $Url
        $script:Tray = $ni
    } catch {
        Write-Host ("  (no tray icon: {0})" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Get-W2PIsWindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool]$IsWindows
}

function Remove-W2PTray {
    if ($script:Tray) {
        try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }
        $script:Tray = $null
    }
}

$script:Quit = $false
$script:GrantNow = $false
Initialize-W2PTray -Url "http://localhost:$Port"

# Under systemd or Task Scheduler nobody is there to press Start, so the
# service form of this app has to begin watching on its own.
if ($AutoStart) {
    $r = Start-Engine
    if ($r.ok) { Write-Host '  auto-start: engine running' -ForegroundColor Green }
    else       { Write-Host "  auto-start FAILED: $($r.error)" -ForegroundColor Red }
}

try {
    while ($listener.IsListening -and -not $script:Quit) {

        # A mode change no longer touches the listener.
        #
        # Earlier versions rebound between http://localhost:PORT and
        # http://+:PORT, which meant adding and removing the URL reservation -
        # a UAC prompt in BOTH directions, and every 503, 400 and "access
        # denied" this feature produced. Once permission has been granted the
        # listener simply stays on '+', and local-only is enforced in software
        # by refusing non-local requests. Same outcome, one prompt ever, and
        # nothing to go wrong at the http.sys layer.
        if ($script:GrantNow) {
            $script:GrantNow = $false
            $g = Grant-W2PNetworkAccess -Port $Port
            if (-not $g.ok) {
                Write-Host '  Windows did not grant permission to share on the network.' -ForegroundColor Yellow
                Write-Host '  Staying on this machine only. Turn sharing on again and accept the prompt.' -ForegroundColor DarkGray
                try {
                    $c0 = Read-W2PConfig
                    if ($c0.PSObject.Properties.Name -contains 'bindMode') { $c0.bindMode = 'local' }
                    Write-W2PConfig -Obj $c0
                } catch { }
            } else {
                # Move onto '+' if we are not there yet. When we already are,
                # the grant above has just re-made the reservation and the
                # firewall rule for the port actually in use, so there is
                # nothing further to do here.
                if ($prefixUsed -ne '+') {
                    try { $listener.Stop(); $listener.Close() } catch { }
                    $res = Start-W2PListener -HostPart '+' -Port $Port
                    if ($res.ok) {
                        $listener = $res.listener
                        $prefixUsed = '+'
                        $bindMode = 'network'
                        Write-Host ("  Now shared on the network: http://{0}:{1}" -f (Get-W2PLanAddress), $Port) -ForegroundColor Green
                    } else {
                        Write-Host ("  Could not open the shared address: {0}" -f $res.error) -ForegroundColor Red
                        $back = Start-W2PListener -HostPart 'localhost' -Port $Port
                        if ($back.ok) { $listener = $back.listener; $prefixUsed = 'localhost'; $bindMode = 'local' }
                        else { Write-Host '  Could not reopen any address. Quit and start Watch2Print again.' -ForegroundColor Red; $script:Quit = $true }
                        try {
                            $c0 = Read-W2PConfig
                            if ($c0.PSObject.Properties.Name -contains 'bindMode') { $c0.bindMode = 'local' }
                            Write-W2PConfig -Obj $c0
                        } catch { }
                    }
                }
            }
            continue
        }

        # Async accept with a short wait, rather than the blocking GetContext().
        # GetContext() swallows Ctrl+C: the thread sits in unmanaged code and
        # never returns to run the handler. This loop stays responsive and also
        # gives us a tick to drain the engine's log queue.
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(200)) {
            Sync-EngineLog
            # Keeps the tray menu responsive without a second thread.
            if ($script:Tray) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } }
            if ($script:Quit) { break }
        }
        if ($script:Quit) { break }
        $ctx = $task.GetAwaiter().GetResult()

        Sync-EngineLog

        $path = $ctx.Request.Url.AbsolutePath
        $verb = $ctx.Request.HttpMethod
        if ($path -ne '/api/status') { Write-Host ("  {0,-4} {1}" -f $verb, $path) -ForegroundColor DarkGray }

        try {
            # ---- access control -------------------------------------------
            # Everything below this gate assumes the caller is allowed. Local
            # requests always are; remote ones need a session, and may be
            # limited to looking.
            $auth = Get-W2PRequestAuth -Context $ctx

            # The listener stays on '+' once permission is granted, so sharing
            # being OFF is enforced right here rather than by unbinding. If
            # this check is ever removed, "local only" silently stops meaning
            # anything at all.
            if ((Get-W2PBindMode) -ne 'network' -and -not $ctx.Request.IsLocal) {
                Send-Response -Context $ctx -Body 'Watch2Print is not being shared on the network right now.' -Type 'text/plain' -Code 403
                continue
            }

            if ($auth -eq 'none' -and $path -ne '/login' -and $path -notlike '/favicon*') {
                if ($verb -eq 'POST') {
                    # An API call from a signed-out browser: answer in JSON so
                    # the page can say so, rather than dumping HTML into fetch.
                    Send-Response -Context $ctx -Body (@{ error = 'Not signed in.'; signin = $true } | ConvertTo-Json) -Code 401
                } elseif ($path -eq '/api/status' -or $path -eq '/api/config') {
                    Send-Response -Context $ctx -Body (@{ error = 'Not signed in.'; signin = $true } | ConvertTo-Json) -Code 401
                } else {
                    Send-Response -Context $ctx -Body (Get-LoginHtml) -Type 'text/html' -Code 401
                }
                continue
            }

            # Read-only visitors may watch, not act. The host is never limited.
            # Everything that changes state or reveals the filesystem. Omitting
            # one is a silent hole: /api/passphrase was missed on the first
            # pass, which would have let a read-only visitor rotate the secret
            # and lock the shop out of its own watcher.
            # Deliberately NOT here: /api/theme and /api/uistate are per-viewer
            # display preferences, and /api/checkupdate only reads.
            $writeEndpoints = @('/api/config','/api/start','/api/stop','/api/quit','/api/colors',
                                '/api/reloadhistory','/api/applyupdate','/api/selfupdate','/api/startup',
                                '/api/pickpath','/api/browse','/api/bindmode','/api/passphrase')
            # POSTs to these are writes and stay blocked. Their GETs are how a
            # read-only viewer renders at all (GET /api/config crashed the page
            # with a 403 before this verb check). /api/browse and /api/pickpath
            # reveal the filesystem on GET, so those are blocked on any verb.
            $fsEndpoints = @('/api/browse','/api/pickpath')
            if ($auth -eq 'readonly' -and ((($verb -eq 'POST') -and ($writeEndpoints -contains $path)) -or ($fsEndpoints -contains $path))) {
                Send-Response -Context $ctx -Body (@{
                    error = 'This Watch2Print is shared read-only. Changes can only be made on the machine running it.'
                } | ConvertTo-Json) -Code 403
                continue
            }

            if ($verb -eq 'GET' -and $path -eq '/login') {
                Send-Response -Context $ctx -Body (Get-LoginHtml) -Type 'text/html'
            }
            elseif ($verb -eq 'POST' -and $path -eq '/login') {
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $form = $reader.ReadToEnd(); $reader.Close()
                $pass = ''
                foreach ($pair in ($form -split '&')) {
                    $kv = $pair -split '=', 2
                    if ($kv.Count -eq 2 -and $kv[0] -eq 'passphrase') {
                        $pass = [System.Uri]::UnescapeDataString($kv[1].Replace('+',' '))
                    }
                }
                if (Test-W2PPassphrase $pass) {
                    $tok = New-W2PSession
                    Write-Host ("       signed in from {0}" -f $ctx.Request.RemoteEndPoint) -ForegroundColor Green
                    # 302 back to the app, carrying the session cookie. The
                    # navigation is also what prompts the browser to offer to
                    # save the passphrase.
                    $ctx.Response.StatusCode = 302
                    $ctx.Response.AddHeader('Set-Cookie', ("w2p_session={0}; Path=/; Max-Age={1}; HttpOnly; SameSite=Lax" -f $tok, ($script:SessionTTL * 86400)))
                    $ctx.Response.AddHeader('Location', '/')
                    $ctx.Response.OutputStream.Close()
                } else {
                    Write-Host ("       failed sign-in from {0}" -f $ctx.Request.RemoteEndPoint) -ForegroundColor DarkYellow
                    Send-Response -Context $ctx -Body (Get-LoginHtml -Message 'That passphrase was not recognised.') -Type 'text/html' -Code 401
                }
            }
            elseif ($verb -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                Send-Response -Context $ctx -Body (Get-Html) -Type 'text/html'
            }
            elseif ($verb -eq 'GET' -and ($path -eq '/favicon.png' -or $path -eq '/favicon.ico')) {
                $bytes = [System.Convert]::FromBase64String($script:FaviconB64)
                $ctx.Response.StatusCode  = 200
                $ctx.Response.ContentType = 'image/png'
                # No caching: an icon that updates with the build is worth more
                # than one fewer request, and a stale favicon is baffling.
                $ctx.Response.AddHeader('Cache-Control','no-cache, no-store, must-revalidate')
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/checkupdate') {
                $script:UpdateInfo = Test-W2PUpdate
                Send-Response -Context $ctx -Body (@{
                    version = $script:AppVersion
                    update  = $script:UpdateInfo
                } | ConvertTo-Json -Depth 5)
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/applyupdate') {
                try {
                    $info = $script:UpdateInfo
                    if (-not $info -or $info.status -ne 'available') { throw 'No update is available to install.' }
                    $dest = Install-W2PUpdate -Url $info.url -ToTemp:([bool]$info.self)
                    $script:UpdateDest = $dest
                    Write-Host ("       update downloaded -> {0}" -f $dest) -ForegroundColor Green
                    $uos = Get-OSKey
                    $unext = switch ($uos) {
                        'windows' { '' }   # the UI shows an Install now button instead
                        'linux'   { ("Install it with:  sudo apt install {0}" -f $dest) }
                        default   { 'Unzip it and replace Watch2Print.app in Applications, then open the app again.' }
                    }
                    Send-Response -Context $ctx -Body (@{ ok = $true; path = $dest; os = $uos; next = $unext } | ConvertTo-Json)
                } catch {
                    Send-Response -Context $ctx -Body (@{ error = $_.Exception.Message } | ConvertTo-Json) -Code 400
                }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/selfupdate') {
                try {
                    $info = $script:UpdateInfo
                    if (-not $info -or $info.status -ne 'available' -or -not $info.self) { throw 'No self-installable update is staged.' }
                    if (-not $script:UpdateDest -or -not (Test-Path -LiteralPath $script:UpdateDest)) { throw 'Download the update first.' }
                    [void](Test-W2PDownloadValid -Path $script:UpdateDest -Version $info.version)
                    Write-W2PFileLog ("self-update to {0} starting; handing off to the swap helper" -f $info.version)
                    $mode = Invoke-W2PSelfUpdate -NewFile $script:UpdateDest -Version $info.version
                    Send-Response -Context $ctx -Body (@{ ok = $true; version = $info.version; mode = $mode } | ConvertTo-Json)
                    if ($mode -eq 'exe' -or $mode -eq 'pwsh') { $script:Quit = $true }
                    # systemd/launchd: the helper stops this process itself.
                } catch {
                    Send-Response -Context $ctx -Body (@{ error = $_.Exception.Message } | ConvertTo-Json) -Code 400
                }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/bindmode') {
                try {
                    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd() | ConvertFrom-Json
                    $reader.Close()
                    $want = if ([string]$body.mode -eq 'network') { 'network' } else { 'local' }

                    $cur = Read-W2PConfig
                    $resp = @{ ok = $true; mode = $want }

                    if ($want -eq 'network') {
                        # The passphrase comes from the operator. One they chose
                        # is one they will remember and can tell someone over
                        # the noise of a print floor; a generated string gets
                        # written on a sticky note.
                        $chosen = [string]$body.passphrase
                        if (-not [string]::IsNullOrWhiteSpace($chosen)) {
                            if ($chosen.Trim().Length -lt 6) { throw 'Use at least 6 characters.' }
                            $chosen = $chosen.Trim()
                            if ($cur.PSObject.Properties.Name -contains 'accessPassHash') { $cur.accessPassHash = (Get-W2PHash $chosen) }
                            else { $cur | Add-Member -NotePropertyName 'accessPassHash' -NotePropertyValue (Get-W2PHash $chosen) }
                            $script:Sessions.Clear()
                        } elseif ([string]::IsNullOrWhiteSpace([string]$cur.accessPassHash)) {
                            throw 'Set a passphrase before sharing this on the network.'
                        }
                        # Permission is granted during the rebind, after this
                        # response has been sent - a UAC prompt raised here
                        # would block the whole server until it was answered.
                        $resp.url = ('http://{0}:{1}' -f (Get-W2PLanAddress), $Port)
                    }

                    if ($cur.PSObject.Properties.Name -contains 'bindMode') { $cur.bindMode = $want }
                    else { $cur | Add-Member -NotePropertyName 'bindMode' -NotePropertyValue $want }
                    Write-W2PConfig -Obj $cur

                    Write-Host ("       access mode -> {0}" -f $want) -ForegroundColor Green
                    # Switching OFF needs nothing: the listener stays where it
                    # is and remote requests are simply refused from now on.
                    # Switching ON only needs Windows permission the first
                    # time; after that the prefix is already open.
                    # Permission is needed if we are not on '+' yet, if the
                    # reservation is for a different port, or if the firewall
                    # rule is. Any one of those alone makes the LAN address
                    # silently unreachable - which is exactly what happened
                    # when the listener moved to 8788 and the rule stayed on
                    # the port it was created for.
                    $resp.needsPermission = ($want -eq 'network' -and (
                        $prefixUsed -ne '+' -or
                        -not (Test-W2PUrlAcl   -Port $Port) -or
                        -not (Test-W2PFirewall -Port $Port)
                    ))
                    Send-Response -Context $ctx -Body ($resp | ConvertTo-Json -Depth 5)
                    if ($resp.needsPermission) { $script:GrantNow = $true }
                } catch {
                    Send-Response -Context $ctx -Body (@{ error = $_.Exception.Message } | ConvertTo-Json) -Code 400
                }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/passphrase') {
                # Regenerate. Local only - the write gate above already blocks
                # remote callers, so nobody can rotate the secret remotely and
                # lock the shop out.
                try {
                    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd() | ConvertFrom-Json
                    $reader.Close()
                    $pass = [string]$body.passphrase
                    if ([string]::IsNullOrWhiteSpace($pass)) { $pass = New-W2PPassphrase }   # asked for a suggestion
                    if ($pass.Trim().Length -lt 6) { throw 'Use at least 6 characters.' }
                    $pass = $pass.Trim()
                    $cur = Read-W2PConfig
                    if ($cur.PSObject.Properties.Name -contains 'accessPassHash') { $cur.accessPassHash = (Get-W2PHash $pass) }
                    else { $cur | Add-Member -NotePropertyName 'accessPassHash' -NotePropertyValue (Get-W2PHash $pass) }
                    Write-W2PConfig -Obj $cur
                    $script:Sessions.Clear()   # everyone signs in again
                    Send-Response -Context $ctx -Body (@{ ok = $true; passphrase = $pass } | ConvertTo-Json)
                } catch {
                    Send-Response -Context $ctx -Body (@{ error = $_.Exception.Message } | ConvertTo-Json) -Code 400
                }
            }
            elseif ($verb -eq 'GET' -and $path -eq '/api/suggestpass') {
                Send-Response -Context $ctx -Body (@{ passphrase = (New-W2PPassphrase) } | ConvertTo-Json)
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/startup') {
                try {
                    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd() | ConvertFrom-Json
                    $reader.Close()
                    $want = [bool]$body.enabled
                    $now  = Set-W2PStartupEnabled -Enabled $want
                    Write-Host ("       start at sign-in: {0}" -f $(if ($now) { 'on' } else { 'off' })) -ForegroundColor Green
                    Send-Response -Context $ctx -Body (@{ ok = $true; startup = $now } | ConvertTo-Json)
                } catch {
                    Send-Response -Context $ctx -Body (@{ error = $_.Exception.Message } | ConvertTo-Json) -Code 400
                }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/uistate') {
                # Display preferences, not settings: must persist while the
                # engine is running, so this does not go through /api/config.
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Close()
                $px = 0
                if ([int]::TryParse([string]$body.debugHeight, [ref]$px) -and $px -ge 70 -and $px -le 2000) {
                    $cur = Read-W2PConfig
                    if ($cur.PSObject.Properties.Name -contains 'debugHeight') { $cur.debugHeight = $px }
                    else { $cur | Add-Member -NotePropertyName 'debugHeight' -NotePropertyValue $px }
                    Write-W2PConfig -Obj $cur
                }
                Send-Response -Context $ctx -Body (@{ ok = $true } | ConvertTo-Json)
            }
            elseif ($verb -eq 'GET' -and $path -eq '/api/status') {
                $since = 0
                $q = $ctx.Request.QueryString['since']
                if (-not ($q -and [int]::TryParse($q, [ref]$since))) { $since = 0 }
                if ($since -lt 0) { $since = 0 }
                # Indices are ABSOLUTE line numbers across the life of the run,
                # not offsets into the buffer, so trimming the front cannot
                # strand the browser at a number the buffer no longer reaches.
                $total = $script:LogDropped + $script:Log.Count
                if ($since -gt $total) { $since = $total }        # buffer was cleared on restart
                $start = $since - $script:LogDropped
                if ($start -lt 0) { $start = 0 }                  # caller fell behind the window
                $slice = if ($start -lt $script:Log.Count) {
                    $script:Log.GetRange($start, $script:Log.Count - $start)
                } else { @() }
                $payload = @{
                    running = $script:Running; next = $total; lines = @($slice)
                    dropped = $script:LogDropped
                    startup = (Get-W2PStartupEnabled)
                    auth    = $auth
                } | ConvertTo-Json -Depth 5 -Compress
                Send-Response -Context $ctx -Body $payload
            }
            elseif ($verb -eq 'GET' -and $path -eq '/api/config') {
                $cfgNow = Read-W2PConfig
                $warn = @{}
                foreach ($k in $script:PathKeys) {
                    $w = Test-PathShape ([string]$cfgNow.$k)
                    if ($w) { $warn[$k] = $w }
                }
                $body = @{
                    path         = $Config
                    configFolder = (Split-Path -Parent $Config)
                    config    = (Get-SafeConfig)
                    os        = (Get-OSKey)
                    platforms = @($script:Platforms)
                    warnings  = $warn
                    colors    = @(Read-ColorMapRaw)
                    colorPath = $ColorMap
                    debugHeight = $(if ($cfgNow.PSObject.Properties.Name -contains 'debugHeight') { [int]$cfgNow.debugHeight } else { 0 })
                    startup     = (Get-W2PStartupEnabled)
                    version     = $script:AppVersion
                    bindMode    = (Get-W2PBindMode)
                    remoteAccess= (Get-W2PRemoteAccess)
                    auth        = $auth
                    lanUrl      = ('http://{0}:{1}' -f (Get-W2PLanAddress), $Port)
                    port        = $Port
                    netReady    = (($prefixUsed -eq '+') -and (Test-W2PFirewall -Port $Port))
                    appVersion  = $script:AppVersion
                    log         = @{
                        enabled = $script:FL.enabled
                        file    = $(if ($script:FL.path) { Split-Path -Leaf $script:FL.path } else { '' })
                        sizeKB  = [int]($script:FL.size / 1KB)
                        folder  = $script:FL.folder
                        fallback = $script:FL.fellBack
                        defaultFolder = (Get-W2PLogFolderDefault)
                    }
                } | ConvertTo-Json -Depth 10
                Send-Response -Context $ctx -Body $body
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/config') {
                if ($script:Running) { throw 'Stop the engine before changing settings.' }
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $incoming = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Close()
                # Merge onto disk rather than replace, so keys the page never
                # showed - and blank secrets - survive a save.
                $current = Read-W2PConfig
                # configFolder is a UI-only field: it says where the config file
                # itself should live, so it must never be written into the file.
                $wantDir = [string]$incoming.configFolder
                foreach ($p in $incoming.PSObject.Properties) {
                    if ($p.Name -eq 'configFolder') { continue }
                    # Owned by the access toggle and the passphrase dialog.
                    # Accepting them here let a stale settings form turn
                    # network sharing back on behind the operator's back.
                    if ($p.Name -eq 'bindMode' -or $p.Name -eq 'accessPassHash') { continue }
                    if ($Secrets -contains $p.Name -and [string]::IsNullOrEmpty([string]$p.Value)) { continue }
                    # Never let the UI's own mask overwrite a real credential.
                    if ($Secrets -contains $p.Name -and (Test-IsMaskedSecret ([string]$p.Value))) { continue }
                    if ($current.PSObject.Properties.Name -contains $p.Name) { $current.$($p.Name) = $p.Value }
                    else { $current | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
                }
                # apiBase and filesBase are just the company id on the end of a
                # fixed host, so derive them rather than making anyone type them.
                if ([string]$current.platform -eq 'simplyprint') {
                    $cid = ([string]$current.companyIdSimplyPrint).Trim()
                    if ($cid) {
                        $current.apiBase   = "https://api.simplyprint.io/$cid"
                        $current.filesBase = "https://files.simplyprint.io/$cid"
                    }
                }
                [void](Protect-ConfigSecrets $current)
                $current = Save-OSPaths $current
                Write-W2PConfig -Obj $current
                Write-Host '       config saved' -ForegroundColor Green
                Initialize-W2PFileLog

                # Relocate the config file if a different folder was chosen.
                # The point is that picking a folder is enough: no one should
                # have to create an empty file there first.
                $moved = $null
                $curDir = Split-Path -Parent $Config
                if ($wantDir -and ($wantDir.TrimEnd('\','/') -ne $curDir.TrimEnd('\','/'))) {
                    if (-not (Test-Path -LiteralPath $wantDir -PathType Container)) {
                        throw "That folder does not exist: $wantDir"
                    }
                    $dest = Join-Path $wantDir (Split-Path -Leaf $Config)
                    if ((Resolve-Path -LiteralPath $wantDir).Path -ne (Resolve-Path -LiteralPath $curDir).Path) {
                        Move-Item -LiteralPath $Config -Destination $dest -Force
                        $Config = $dest
                        $moved  = $dest
                        # Startup only searches beside the script and the data dir,
                        # so a config moved anywhere else was orphaned on restart.
                        # The pointer closes that gap.
                        try { Set-Content -LiteralPath (Join-Path (Get-W2PDataDir) 'config.location') -Value $dest -Encoding UTF8 } catch { }
                        Write-Host "       config moved -> $dest" -ForegroundColor Green
                    }
                }
                Send-Response -Context $ctx -Body (@{ ok = $true; moved = $moved } | ConvertTo-Json)
            }
            elseif ($verb -eq 'GET' -and $path -eq '/api/browse') {
                # Browsers cannot hand back an absolute filesystem path, so the
                # picker walks the real filesystem here instead. Read-only.
                $want = [string]$ctx.Request.QueryString['path']
                $res = @{ path=''; parent=$null; dirs=@(); files=@(); roots=@() }
                try {
                    if ([string]::IsNullOrWhiteSpace($want)) {
                        if ((Get-OSKey) -eq 'windows') {
                            $res.roots = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                                           ForEach-Object { $_.Root })
                        } else { $res.roots = @('/', $HOME) }
                        $res.path = ''
                    } else {
                        $full = (Resolve-Path -LiteralPath $want -ErrorAction Stop).Path
                        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
                            $full = Split-Path -Parent $full
                        }
                        $res.path   = $full
                        $par        = Split-Path -Parent $full
                        $res.parent = if ($par -and $par -ne $full) { $par } else { $null }
                        $res.dirs = @(Get-ChildItem -LiteralPath $full -Directory -Force -ErrorAction SilentlyContinue |
                                      Where-Object { $_.Name -notmatch '^\.' } |
                                      Sort-Object Name | Select-Object -First 400 |
                                      ForEach-Object { @{ name=$_.Name; path=$_.FullName } })
                        $res.files = @(Get-ChildItem -LiteralPath $full -File -Force -ErrorAction SilentlyContinue |
                                       Sort-Object Name | Select-Object -First 400 |
                                       ForEach-Object { @{ name=$_.Name; path=$_.FullName } })
                    }
                } catch { $res.error = $_.Exception.Message }
                Send-Response -Context $ctx -Body ($res | ConvertTo-Json -Depth 5 -Compress)
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/pickpath') {
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $req = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Close()
                $kind = if ([string]$req.kind -eq 'file') { 'file' } else { 'dir' }
                $picked = Invoke-NativePathPicker -Kind $kind -Start ([string]$req.start)
                if ($null -eq $picked) {
                    # No native dialog here; the page falls back to its own list.
                    Send-Response -Context $ctx -Body (@{ unavailable = $true } | ConvertTo-Json)
                } elseif ($picked -eq '') {
                    Send-Response -Context $ctx -Body (@{ cancelled = $true } | ConvertTo-Json)
                } else {
                    Write-Host ("       picked: {0}" -f $picked) -ForegroundColor Green
                    Send-Response -Context $ctx -Body (@{ path = $picked } | ConvertTo-Json)
                }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/theme') {
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Close()
                $val = if ([string]$body.theme -eq 'light') { 'light' } else { 'dark' }
                $cur = Read-W2PConfig
                if ($cur.PSObject.Properties.Name -contains 'theme') { $cur.theme = $val }
                else { $cur | Add-Member -NotePropertyName 'theme' -NotePropertyValue $val }
                Write-W2PConfig -Obj $cur
                Send-Response -Context $ctx -Body (@{ ok = $true; theme = $val } | ConvertTo-Json)
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/colors') {
                if ($script:Running) { throw 'Stop the engine before changing colors.' }
                if (-not $ColorMap) { throw 'No colormap file is configured.' }
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $rows = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Close()
                $n = Write-ColorMapRaw -Rows @($rows)
                Write-Host "       colormap saved ($n rows)" -ForegroundColor Green
                Send-Response -Context $ctx -Body (@{ ok = $true; count = $n } | ConvertTo-Json)
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/start') {
                $r = Start-Engine
                if ($r.ok) { Send-Response -Context $ctx -Body (@{ ok = $true } | ConvertTo-Json) }
                else       { Send-Response -Context $ctx -Body (@{ error = $r.error } | ConvertTo-Json) -Code 400 }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/reloadhistory') {
                $r = Request-HistoryReload
                if ($r.ok) { Send-Response -Context $ctx -Body (@{ ok = $true } | ConvertTo-Json) }
                else       { Send-Response -Context $ctx -Body (@{ error = $r.error } | ConvertTo-Json) -Code 400 }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/stop') {
                $r = Request-Stop
                if ($r.ok) { Send-Response -Context $ctx -Body (@{ ok = $true } | ConvertTo-Json) }
                else       { Send-Response -Context $ctx -Body (@{ error = $r.error } | ConvertTo-Json) -Code 400 }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/openlogs') {
                # Host only: this opens a window on the SERVER's screen, which
                # would baffle a remote viewer and reveals the host filesystem.
                if ($auth -ne 'local') { Send-Response -Context $ctx -Body (@{ error = 'Host only' } | ConvertTo-Json) -Code 403 }
                else {
                    $f = $script:FL.folder
                    if ($f -and (Test-Path -LiteralPath $f)) {
                        try {
                            if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { Start-Process explorer.exe $f }
                            elseif ($IsMacOS) { & open $f }
                            else { & xdg-open $f 2>$null }
                        } catch { }
                    }
                    Send-Response -Context $ctx -Body (@{ ok = $true; folder = $f } | ConvertTo-Json)
                }
            }
            elseif ($verb -eq 'POST' -and $path -eq '/api/quit') {
                Send-Response -Context $ctx -Body (@{ ok = $true } | ConvertTo-Json)
                $script:Quit = $true
            }
            else {
                Send-Response -Context $ctx -Body (@{ error = 'Not found' } | ConvertTo-Json) -Code 404
            }
        } catch {
            Write-Host "       ERROR: $($_.Exception.Message)" -ForegroundColor Red
            try { Send-Response -Context $ctx -Body (@{ error = $_.Exception.Message } | ConvertTo-Json) -Code 500 } catch {}
        }
    }
}
finally {
    Write-W2PFileLog '===== SESSION END ====='
    if ($script:Running) {
        Write-Host '  stopping engine...' -ForegroundColor DarkYellow
        if ($script:sync) { $script:sync.Running = $false }
        # Give the engine a moment to finish the file it is on. It checks the
        # flag between files, so this is a graceful stop, not a kill.
        $deadline = (Get-Date).AddSeconds(20)
        while ($script:handle -and -not $script:handle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
        Stop-EngineHard
    }
    Remove-W2PTray
    try { if ($script:InstanceMutex) { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose() } } catch {}
    try { $listener.Stop(); $listener.Close() } catch {}
    Write-Host '  stopped' -ForegroundColor DarkGray
}
