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
WXOVSxy69P8AEoTslOacAgA=
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
