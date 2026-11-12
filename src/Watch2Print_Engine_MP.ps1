# =========================
# watch2print - MULTI-PLATFORM ENGINE (experimental fork)
# Watch a folder -> Upload -> Add to Queue, against SimplyPrint,
# Printago, or 3DPrinterOS. PS 5.1 compatible.
# =========================
# Forked from the SimplyPrint-only engine. The entire SimplyPrint code
# path below is spliced in VERBATIM from the original so its behavior is
# byte-for-byte unchanged; the two new providers live in their own
# clearly-marked sections and share only the filename parser, the file
# stability wait, the colormap, and the watch loop.
# =========================
#
# PROVIDER CAPABILITY MATRIX
# --------------------------------------------------------------------
#                        SimplyPrint    Printago      3DPrinterOS
#   upload                   yes          yes            yes
#   chunked upload           yes          n/a (PUT)      no
#   queue add                yes          yes            yes (per printer)
#   copies / amount          yes          yes            emulated (loop)
#   group                    yes          no             (project name)
#   machine-model routing    for_models   printer tags   ptype + printer id
#   material / color tags    yes          NO             NO
#   gcode analysis polling   yes          NO             NO
#   U1 slot scoring          yes          NO             NO
#   rush queue position      yes          NO             NO
#   colormap used            yes          no             no
# --------------------------------------------------------------------
#
# UNVERIFIED: the Printago and 3DPrinterOS paths were written against
# published documentation only and have never been run against a live
# account. Use the Dry run toggle first - it prints every request the
# engine WOULD send without touching the network.
# =========================

# Which platform this run is talking to: 'simplyprint' | 'printago' | 'printeros'
$script:Platform = 'simplyprint'

# Set from config; when true no mutating HTTP call is made.
$script:DryRun = $false

# Extensions the watcher reacts to, lowercase, dot-prefixed, e.g. @('.gcode','.3mf')
$script:WatchExtensions = @('.gcode')

function Get-PlatformCaps {
    # Single source of truth for what each platform can do. The GUI greys out
    # controls using the same table, so the two can never disagree.
    param([string]$Platform)

    switch (([string]$Platform).ToLowerInvariant()) {
        'printago' {
            return @{
                key             = 'printago'
                label           = 'Printago'
                amount          = $true
                group           = $false
                modelRouting    = $true
                materialTags    = $false
                analysisPolling = $false
                u1Scoring       = $false
                rushPosition    = $false
                colormap        = $false
                chunkedUpload   = $false
                field1Label     = 'Store ID'
                field2Label     = 'API key'
                field1Hint      = '(the store id from your Printago URL)'
            }
        }
        'printeros' {
            return @{
                key             = 'printeros'
                label           = '3DPrinterOS'
                amount          = $true      # emulated by repeating print_file
                group           = $false     # has its own Project name field instead
                modelRouting    = $true      # ptype + printer id map
                materialTags    = $false
                analysisPolling = $false
                u1Scoring       = $false
                rushPosition    = $false
                colormap        = $false
                chunkedUpload   = $false
                field1Label     = 'Username'
                field2Label     = 'Password'
                field1Hint      = '(your 3DPrinterOS account e-mail)'
            }
        }
        default {
            return @{
                key             = 'simplyprint'
                label           = 'SimplyPrint'
                amount          = $true
                group           = $true
                modelRouting    = $true
                materialTags    = $true
                analysisPolling = $true
                u1Scoring       = $true
                rushPosition    = $true
                colormap        = $true
                chunkedUpload   = $true
                field1Label     = 'Company ID'
                field2Label     = 'API key'
                field1Hint      = '(the number in your SimplyPrint panel URL)'
            }
        }
    }
}


# =========================
# TAG HELPERS (PS 5.1 safe)
# =========================

# Cache filament types so we don't hammer the API
$script:FilamentTypesCache = $null

# Cache printers/models so we don't hammer the API
$script:PrintersCache      = $null
$script:ModelIndexCache    = $null

# Tracks rush items added during the CURRENT scan pass: id (string) -> priority (int).
# Reset at the start of every scan pass in the main loop. Used by the rush positioner
# to tell "already in the queue" (old) from "added just now" (new) by queue item id.
$script:CurrentPassRush    = @{}

# --- API HELPERS (Moved up so they are available for parsing logic) ---

# --- CREDENTIAL PROTECTION ---------------------------------------------
# API keys and passwords are stored as  enc:v1:<base64>  instead of plain
# text. Two schemes, because the platforms differ:
#
#   Windows      DPAPI, scoped to the current user on this machine. No key
#                file to protect, and the blob is useless if copied away.
#   Linux/macOS  AES-256 with a random key at ~/.config/watch2print/key.bin,
#                mode 600. The key lives OUTSIDE any synced folder on
#                purpose: keeping it next to the config would make the
#                encryption decorative.
#
# This protects against a config being read by accident - a shared Dropbox
# folder, a screenshot, a pasted file. It does NOT protect against someone
# who already has the user account.
$script:W2PEncPrefix = 'enc:v1:'

function Test-W2PEncrypted {
    param([string]$Value)
    return ($Value -is [string] -and $Value.StartsWith($script:W2PEncPrefix))
}

function Get-W2PIsWindows {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool]$IsWindows
}

function Get-W2PKeyPath {
    if (Get-W2PIsWindows) { return $null }   # DPAPI needs no key file
    $dir = if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'watch2print' }
           else { Join-Path $HOME '.config/watch2print' }
    return (Join-Path $dir 'key.bin')
}

function Get-W2PKey {
    # 32 random bytes, created once, readable only by this user.
    $path = Get-W2PKeyPath
    if (-not $path) { return $null }
    if (Test-Path -LiteralPath $path) { return [System.IO.File]::ReadAllBytes($path) }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $key = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
    [System.IO.File]::WriteAllBytes($path, $key)
    try { & chmod 600 $path 2>$null } catch { }
    try { & chmod 700 $dir  2>$null } catch { }
    return $key
}

function Protect-W2PSecret {
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    if (Test-W2PEncrypted $Plain) { return $Plain }   # already protected
    try {
        if (Get-W2PIsWindows) {
            $sec = ConvertTo-SecureString -String $Plain -AsPlainText -Force
            return $script:W2PEncPrefix + (ConvertFrom-SecureString -SecureString $sec)
        }
        $key = Get-W2PKey
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key; $aes.GenerateIV()
        $enc = $aes.CreateEncryptor()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
        $ct = $enc.TransformFinalBlock($bytes, 0, $bytes.Length)
        $out = New-Object byte[] ($aes.IV.Length + $ct.Length)
        [Array]::Copy($aes.IV, 0, $out, 0, $aes.IV.Length)
        [Array]::Copy($ct, 0, $out, $aes.IV.Length, $ct.Length)
        $aes.Dispose()
        return $script:W2PEncPrefix + [Convert]::ToBase64String($out)
    } catch {
        Write-Host "  WARNING: could not encrypt a credential ($($_.Exception.Message)). Storing as-is." -ForegroundColor Yellow
        return $Plain
    }
}

function Unprotect-W2PSecret {
    param([string]$Value)
    if (-not (Test-W2PEncrypted $Value)) { return $Value }   # plain text passes through
    $payload = $Value.Substring($script:W2PEncPrefix.Length)
    try {
        if (Get-W2PIsWindows) {
            $sec = ConvertTo-SecureString -String $payload
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        $key = Get-W2PKey
        $raw = [Convert]::FromBase64String($payload)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $iv = New-Object byte[] 16
        [Array]::Copy($raw, 0, $iv, 0, 16)
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        $pt = $dec.TransformFinalBlock($raw, 16, $raw.Length - 16)
        $aes.Dispose()
        return [System.Text.Encoding]::UTF8.GetString($pt)
    } catch {
        # Wrong machine, wrong user, or a missing key file all land here.
        Write-Host "  WARNING: a stored credential could not be decrypted on this machine. Re-enter it in Settings." -ForegroundColor Yellow
        return ''
    }
}

# --- HISTORY LEDGER IO -------------------------------------------------
# The ledger is shared across machines and PowerShell editions. Left to the
# defaults it is written three different ways: 5.1 -Encoding UTF8 emits a
# BOM, PS7 does not, and a BOM-less file read back by 5.1 falls through to
# the system codepage - which mangles every non-ASCII path and re-uploads
# it. Confirmed on Linux 08-05-2026: the baseline wrote no BOM.
#
# So: always write UTF-8 WITH a BOM (5.1 needs it to detect UTF-8), and
# always read as UTF-8 explicitly. Edition- and platform-independent.
function Get-W2PHistoryEncoding {
    return (New-Object System.Text.UTF8Encoding($true))
}

function Add-W2PHistoryLine {
    param([Parameter(Mandatory=$true)][string]$Path,
          [Parameter(Mandatory=$true)][string]$Line)
    # AppendAllText on a missing file writes the BOM; on an existing file it
    # appends raw bytes and leaves the original BOM alone. Both correct.
    [System.IO.File]::AppendAllText($Path, ($Line + "`r`n"), (Get-W2PHistoryEncoding))
}

function Read-W2PHistoryLines {
    param([Parameter(Mandatory=$true)][string]$Path)
    # ReadAllLines with an explicit UTF8Encoding strips a BOM if present and
    # never guesses a codepage if absent, so legacy files still load.
    return [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-W2PHistoryFile {
    param([Parameter(Mandatory=$true)][string]$Path,
          [Parameter(Mandatory=$true)][string[]]$Lines)
    [System.IO.File]::WriteAllLines($Path, $Lines, (Get-W2PHistoryEncoding))
}

function Merge-HistoryFromDisk {
    # ADDITIVE ONLY - never replace the set wholesale. Memory legitimately
    # holds paths the file does not: the loop marks a file seen after
    # Upload-AndQueue regardless of outcome, while Add-ToHistory only writes
    # on success. Overwriting would resurrect those and re-upload them.
    #
    # Gated on LastWriteTime so the common case costs one file stat rather
    # than a full read of a ledger that runs to tens of thousands of lines.
    param(
        [Parameter(Mandatory=$true)]$Seen,
        [switch]$Force,
        [switch]$Quiet
    )

    if ([string]::IsNullOrWhiteSpace($script:historyFile))  { return 0 }
    if (-not (Test-Path -LiteralPath $script:historyFile))  { return 0 }

    try   { $stamp = (Get-Item -LiteralPath $script:historyFile).LastWriteTimeUtc }
    catch { return 0 }

    if (-not $Force -and $script:historyStamp -and $stamp -le $script:historyStamp) { return 0 }

    $added = 0
    try {
        # Streams rather than loading the whole ledger. Explicit UTF8 for the
        # same reason Read-W2PHistoryLines uses it: never let the codepage
        # decide, or non-ASCII paths mangle and re-upload.
        foreach ($line in [System.IO.File]::ReadLines($script:historyFile, (New-Object System.Text.UTF8Encoding($false)))) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $k = $line.Trim()
            if (-not $Seen.ContainsKey($k)) { $Seen[$k] = $true; $added++ }
        }
        $script:historyStamp = $stamp
    } catch {
        if (-not $Quiet) { Write-Host ("Could not re-read the history file: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow }
        return 0
    }

    if ($added -gt 0 -and -not $Quiet) {
        Write-Host ("History reloaded: {0} entry(s) added from disk." -f $added) -ForegroundColor Green
    }
    return $added
}

function Get-FilamentTypes {
    if ($script:FilamentTypesCache) { return $script:FilamentTypesCache }

    # FORK NOTE: off SimplyPrint there is no filament-type endpoint to call,
    # but Parse-JobFileName still needs to recognise a material token in order
    # to find where the material blocks start. Fall back to a static family
    # list. The ids are synthetic and harmless because no other platform
    # consumes them - only the "is this token a material?" test matters.
    # On SimplyPrint this branch never fires, so behavior is unchanged.
    if ($script:Platform -ne 'simplyprint') {
        $script:FilamentTypesCache = Get-OfflineFilamentTypes
        return $script:FilamentTypesCache
    }

    # Credentials are only populated by Start-Watch2PrintEngine. Callers that
    # reach the parser without going through it (-SelfTest) leave these empty,
    # which built a hostname-less URI and threw. Fall back to the offline list
    # and deliberately DON'T cache it, so a later live run still fetches real ids.
    if ([string]::IsNullOrWhiteSpace($script:apiBase) -or [string]::IsNullOrWhiteSpace($script:apiKey)) {
        return Get-OfflineFilamentTypes
    }

    $url  = "$($script:apiBase)/filament/type/Get"
    $resp = Invoke-RestMethod -Method Get -Uri $url -Headers @{ "X-API-KEY" = $script:apiKey; "accept" = "application/json" }

    if (-not $resp.status) { throw "Get Filament Types failed: $($resp.message)" }

    $script:FilamentTypesCache = $resp.data
    return $script:FilamentTypesCache
}

function Resolve-MaterialTypeId {
    param([string]$MaterialToken)

    if ([string]::IsNullOrWhiteSpace($MaterialToken)) { return $null }

    # Remove spaces and hyphens, then make lowercase for a bulletproof comparison
    $normToken = $MaterialToken.Trim().ToLowerInvariant() -replace '[\s-]', ''
    $types = Get-FilamentTypes

    # TIER 1: Exact match on Profile Name
    $hit = $types | Where-Object {
        $_.profile_name -and (($_.profile_name.ToString().ToLowerInvariant() -replace '[\s-]', '') -eq $normToken)
    } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    # TIER 2: Generic Material Match
    $hit = $types | Where-Object {
        $_.material_type_name -and (($_.material_type_name.ToString().ToLowerInvariant() -replace '[\s-]', '') -eq $normToken) -and
        $_.profile_name -and (($_.profile_name.ToString().ToLowerInvariant() -replace '[\s-]', '') -eq $normToken)
    } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    # TIER 3: Exact match on Material Type Name
    $hit = $types | Where-Object {
        $_.material_type_name -and (($_.material_type_name.ToString().ToLowerInvariant() -replace '[\s-]', '') -eq $normToken)
    } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    # TIER 4: Contains Match
    $hit = $types | Where-Object {
        $_.profile_name -and (($_.profile_name.ToString().ToLowerInvariant() -replace '[\s-]', '').Contains($normToken))
    } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    return $null
}

function Get-ColorInfo {
    param([string]$ColorName)

    if ([string]::IsNullOrWhiteSpace($ColorName)) {
        return @{ name="Unknown"; hex="#D9DAD1" }
    }

    $c = $ColorName.Trim()

    # Deliberately NOT $script:ColorMap. The console harness has its own
    # [string]$ColorMap parameter (a FILE PATH) living in the same script
    # scope this engine is dot-sourced into. Sharing the name meant this
    # read could return the path string instead of the hashtable, and
    # .ContainsKey() blew up mid-upload.
    $map = $script:W2PColorMap
    if ($map -isnot [System.Collections.IDictionary]) { $map = Get-DefaultColorMap }

    $key = $c.ToLowerInvariant()
    if ($map.ContainsKey($key)) {
        return $map[$key]
    }

    # Warn once per unknown colour per run. Silently substituting a default
    # grey is how an entire weekend of uploads went out untagged without
    # anything in the log to show for it.
    if (-not $script:W2PColorWarned) { $script:W2PColorWarned = @{} }
    if (-not $script:W2PColorWarned.ContainsKey($key)) {
        $script:W2PColorWarned[$key] = $true
        Write-Host ("Colour '{0}' is not in the colour map - sending the default grey #D9DAD1. Add it on the Colors tab." -f $c) -ForegroundColor Yellow
    }
    return @{ name=$c; hex="#D9DAD1" }
}

# --- U1 MATCHING HELPERS ---

function Normalize-Hex {
    param([string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex)) { return "" }
    $x = $Hex.Trim().ToUpperInvariant()
    if (-not $x.StartsWith("#")) { $x = "#$x" }
    return $x
}

function Normalize-Family {
    param([string]$Family)
    if ([string]::IsNullOrWhiteSpace($Family)) { return "" }
    return ($Family.Trim().ToUpperInvariant() -replace '[\s-]', '')
}

function Get-FamilyTextForTypeId {
    # Returns a normalized, searchable string built from a filament type's
    # material_type_name + profile_name (e.g. type 231507 -> "ROAMRTPUROAMRTPU").
    # Used to test whether a slice's generic family (e.g. "TPU") appears in the
    # filename material's identity, so custom profiles like RoamrTPU or 78ATPUFoam
    # are correctly recognized as TPU. Uses the cached type list.
    param([int]$TypeId)
    if (-not $TypeId) { return "" }
    $types = Get-FilamentTypes
    $hit = $types | Where-Object { $null -ne $_.id -and [int]$_.id -eq $TypeId } | Select-Object -First 1
    if (-not $hit) { return "" }
    $mtn = [string]$hit.material_type_name
    $pn  = [string]$hit.profile_name
    return (Normalize-Family ("$mtn $pn"))
}

# --- PARSING LOGIC ---

function Parse-JobFileName {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    $base  = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $parts = $base -split "_"

    if ($parts.Count -lt 6) {
        return [pscustomobject]@{
            ok     = $false
            reason = "Expected >= 6 underscore-delimited parts, got $($parts.Count): $base"
            raw    = $base
        }
    }

    $mach = $parts[$parts.Count - 1] 
    $job  = $parts[0]                

    $materialsFound = @()
    $maxMaterials = 4

    # Iterate backwards in chunks of 3 to discover 1 to 4 material blocks
    for ($m = 0; $m -lt $maxMaterials; $m++) {
        $matIdx   = $parts.Count - 2 - ($m * 3)
        $brandIdx = $parts.Count - 3 - ($m * 3)
        $colorIdx = $parts.Count - 4 - ($m * 3)

        # Ensure we don't bleed into the Job or Partname
        if ($colorIdx -lt 2) {
            break 
        }

        $potentialMatToken = $parts[$matIdx]
        $matCheck = Resolve-MaterialTypeId -MaterialToken $potentialMatToken

        if ($matCheck) {
            # Valid material found. Insert at beginning so order is Mat1, Mat2...
            $materialsFound = @( @{
                color    = $parts[$colorIdx]
                brand    = $parts[$brandIdx]
                material = $potentialMatToken
            } ) + $materialsFound
        } else {
            # Sequence broken (we hit the 'Side' or 'Partname'), stop looking
            break 
        }
    }

    # Fallback in case API fails or offline parsing breaks
    if ($materialsFound.Count -eq 0) {
        $materialsFound = @( @{
            color    = $parts[$parts.Count - 4]
            brand    = $parts[$parts.Count - 3]
            material = $parts[$parts.Count - 2]
        } )
    }

    $M = $materialsFound.Count
    $remainingParts = $parts.Count - ($M * 3) - 2

    $side = ""
    $pn = ""

    # Assign remaining parts based on what is left
    if ($remainingParts -eq 1) {
        $pn = $parts[1]
    } elseif ($remainingParts -ge 2) {
        $sideIdx = $parts.Count - ($M * 3) - 2
        $side = $parts[$sideIdx]
        $pn = ($parts[1..($sideIdx - 1)] -join "_")
    } else {
        return [pscustomobject]@{
            ok     = $false
            reason = "Not enough parts to determine Job and Partname: $base"
            raw    = $base
        }
    }

    # === RUSH QUEUE DETECTION ===
    # If partname ends with "-N" (e.g. "FoamHeelCup-1"), strip it and capture
    # the number as the desired queue position. For now this is used as a binary
    # flag (any number -> push to top), but the value is preserved for future
    # multi-position use.
    $queuePosition = $null
    if ($pn -match '^(.*)-(\d+)$') {
        $pn            = $Matches[1]
        $queuePosition = [int]$Matches[2]
        Write-Host "Rush position detected: queue position $queuePosition (stripped from partname)" -ForegroundColor Magenta
    }

    return [pscustomobject]@{
        ok            = $true
        raw           = $base
        mode          = if ($M -eq 1) { "single" } else { "multi" }
        job           = $job
        partname      = $pn
        side          = $side
        machineModel  = $mach
        materials     = $materialsFound
        queuePosition = $queuePosition
    }
}

# =========================
# RUSH PRIORITY HELPERS
# =========================

function Get-RushPriorityFromName {
    # Returns the rush priority number (1, 2, ...) embedded in a filename's
    # partname (e.g. "FoamHeelCup-1" -> 1), or $null if the file isn't a rush job.
    # Per the naming convention, ONLY the partname ever carries a trailing
    # "-<number>", so scanning the underscore fields for one is reliable.
    param([Parameter(Mandatory=$true)][string]$FileName)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }

    foreach ($field in ($base -split "_")) {
        if ($field -match '-(\d+)$') {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Get-RushInsertPosition {
    # Rule B - AGED PRIORITY BLOCKS.
    #
    # Desired queue order, top downward:
    #   [ existing priority jobs - left completely untouched ]
    #   [ this pass's new priority jobs: all -1s (FIFO), then -2s (FIFO), ... ]
    #   [ normal jobs ]
    #
    # A new priority job NEVER reorders anything already in the queue. It lands
    # below the ENTIRE existing priority block, and the -N number only sorts the
    # jobs added during THIS scan pass among themselves (lower number = higher).
    #
    # "Already in the queue" vs "added this pass" is told apart by queue item id:
    # $script:CurrentPassRush holds the ids of rush items added this pass.
    #
    #   position = (count of OLD priority items, any tier)
    #            + (count of THIS-PASS priority items with tier <= this one, incl. this one)
    #
    # Returns the 1-based target position, or $null if the queue couldn't be read.
    param(
        [Parameter(Mandatory=$true)][int]$NewPriority,
        [Parameter(Mandatory=$true)]$NewItemId
    )

    # Register this item as part of the current pass BEFORE counting.
    $script:CurrentPassRush["$NewItemId"] = $NewPriority

    $resp = Invoke-RestMethod -Method Get -Uri $getItemsUrl `
        -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" }

    # GetItems may return the list as 'queue' (array), 'queue.items', or 'items'.
    $items = $null
    if ($resp.queue -is [System.Array]) {
        $items = $resp.queue
    } elseif ($resp.queue -and $resp.queue.items) {
        $items = $resp.queue.items
    } elseif ($resp.items) {
        $items = $resp.items
    }

    if (-not $items) { return $null }

    $oldPriorityCount = 0   # existing priority jobs (not from this pass), any tier
    $newAtOrAbove     = 0   # this-pass priority jobs with tier <= NewPriority (incl. this one)

    foreach ($it in $items) {
        $fn = $null
        try { $fn = $it.filename } catch { $fn = $null }
        if ([string]::IsNullOrWhiteSpace($fn)) { continue }

        $p = Get-RushPriorityFromName -FileName $fn
        if ($null -eq $p) { continue }   # normal job - never counts

        $itemId = $null
        try { $itemId = [string]$it.id } catch { $itemId = $null }

        if ($itemId -and $script:CurrentPassRush.ContainsKey($itemId)) {
            # Added during this pass -> part of the new block, sorted by tier
            if ($p -le $NewPriority) { $newAtOrAbove++ }
        } else {
            # Already in the queue before this pass -> untouched old block (any tier)
            $oldPriorityCount++
        }
    }

    $pos = $oldPriorityCount + $newAtOrAbove
    if ($pos -lt 1) { return $null }
    return $pos
}

# --- external queue-change monitor (SimplyPrint only) --------------------
# Files also land in the queue from the panel, other tools, and LLM agents.
# The API exposes no command log, so the engine diffs queue snapshots and
# flags every change it did not make itself - one highlighted line per
# event, so an unexplained queue never stays a mystery. Read-only: two GET
# polls a minute, plus one history lookup per disappearance.
$script:W2PAddedIds  = @{}     # queue item ids THIS watcher created
$script:ExtQueueSnap = $null   # id -> filename from the previous poll

function Read-QueueItems {
    $resp = Invoke-RestMethod -Method Get -Uri $getItemsUrl `
        -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" }
    if ($resp.queue -is [System.Array])      { return $resp.queue }
    if ($resp.queue -and $resp.queue.items)  { return $resp.queue.items }
    if ($resp.items)                         { return $resp.items }
    return @()
}

function Test-InPrintHistory {
    param([string]$ItemId, [string]$FileName)
    # Job records reference their queue item (the history export calls it
    # queued_item). Found there = the item left the queue by STARTING, not
    # by someone deleting it. Field names are probed defensively because
    # the response shape is not pinned by the docs.
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$apiBase/jobs/GetPaginatedPrintJobs" `
             -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" } `
             -ContentType "application/json" -Body (@{ page = 1; page_size = 50 } | ConvertTo-Json)
        $jobs = $null
        if ($r.jobs) { $jobs = $r.jobs } elseif ($r.items) { $jobs = $r.items } elseif ($r.data) { $jobs = $r.data }
        foreach ($j in @($jobs)) {
            foreach ($f in @('queued_item','queue_item_id','queue_item','queueItemId')) {
                try { if ([string]$j.$f -eq $ItemId) { return $true } } catch { }
            }
            try { if ($FileName -and ([string]$j.filename -eq $FileName)) { return $true } } catch { }
        }
        return $false
    } catch { return $null }   # history unreachable -> unknown
}

function Watch-ExternalQueueChanges {
    if ($script:Platform -ne 'simplyprint') { return }
    $items = $null
    try { $items = Read-QueueItems } catch { return }   # transient API blip: skip this poll

    $now = @{}
    foreach ($it in @($items)) {
        $id = $null; $fn = $null
        try { $id = [string]$it.id } catch { }
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        try { $fn = [string]$it.filename } catch { }
        $now[$id] = $fn
    }

    if ($null -eq $script:ExtQueueSnap) {
        # First poll is a baseline: pre-existing items have unknown origin,
        # and alerting on all of them at startup would only be noise.
        $script:ExtQueueSnap = $now
        Write-Host ("External-change monitor active ({0} item(s) in queue at start)" -f $now.Count) -ForegroundColor DarkGray
        return
    }

    foreach ($id in @($now.Keys)) {
        if ($script:ExtQueueSnap.ContainsKey($id)) { continue }
        if ($script:W2PAddedIds.ContainsKey($id))  { continue }   # this watcher's own add
        $who = ''
        foreach ($it in @($items)) {
            $iid = $null
            try { $iid = [string]$it.id } catch { }
            if ($iid -ne $id) { continue }
            foreach ($f in @('user_name','username','user','added_by','by')) {
                $v = $null
                try { $v = [string]$it.$f } catch { }
                if ($v -and $v.Trim() -and -not $v.StartsWith('@')) { $who = " by $v"; break }
            }
            break
        }
        Write-Host ("EXTERNAL QUEUE ADD: '{0}' (id {1}){2} - added outside Watch2Print" -f $now[$id], $id, $who) -ForegroundColor Magenta
    }

    foreach ($id in @($script:ExtQueueSnap.Keys)) {
        if ($now.ContainsKey($id)) { continue }
        $fn = $script:ExtQueueSnap[$id]
        $hist = Test-InPrintHistory -ItemId $id -FileName $fn
        if ($hist -eq $true) { continue }   # started printing - normal exit
        if ($null -eq $hist) {
            Write-Host ("QUEUE ITEM GONE: '{0}' (id {1}) - started or was removed (history check unavailable)" -f $fn, $id) -ForegroundColor Magenta
        } else {
            Write-Host ("EXTERNAL QUEUE REMOVE: '{0}' (id {1}) - removed outside Watch2Print (not in print history)" -f $fn, $id) -ForegroundColor Magenta
        }
    }

    $script:ExtQueueSnap = $now
}

function Get-Printers {
    if ($script:PrintersCache) { return $script:PrintersCache }

    $all = @()
    $page = 1
    $pageSize = 100

    while ($true) {
        $url = "$apiBase/printers/Get"
        $payload = @{ page = $page; page_size = $pageSize } | ConvertTo-Json -Depth 5

        $resp = Invoke-RestMethod -Method Post -Uri $url `
            -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" } `
            -ContentType "application/json" `
            -Body $payload

        if (-not $resp.status) { throw "Get Printers failed: $($resp.message)" }

        if ($resp.data) { $all += $resp.data }

        if (-not $resp.page_amount -or $page -ge [int]$resp.page_amount) { break }
        $page++
    }

    $script:PrintersCache = $all
    return $script:PrintersCache
}

function Get-PrinterModelIndex {
    if ($script:ModelIndexCache) { return $script:ModelIndexCache }

    $printers = Get-Printers
    $models = @{}
    foreach ($p in $printers) {
        try {
            $m = $p.printer.model
            if ($m -and $m.id -and $m.name) {
                $models[[string]$m.id] = @{
                    id    = [int]$m.id
                    name  = [string]$m.name
                    brand = [string]$m.brand
                }
            }
        } catch { }
    }

    $script:ModelIndexCache = $models.Values
    return $script:ModelIndexCache
}

function Resolve-PrinterModelId {
    param([Parameter(Mandatory=$true)][string]$ModelToken)

    $t = $ModelToken.Trim().ToLowerInvariant()
    if (-not $t) { return $null }

    $models = Get-PrinterModelIndex

    $hit = $models | Where-Object { $_.name -and $_.name.ToLowerInvariant() -eq $t } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    $hit = $models | Where-Object { $_.name -and $_.name.ToLowerInvariant().Contains($t) } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    return $null
}

function Build-SimplyPrintTags {
    # Accepts an already-parsed meta object (from Parse-JobFileName) so the
    # filename is only parsed once per file by the caller.
    param([Parameter(Mandatory=$true)]$Meta)

    $meta = $Meta
    if (-not $meta.ok) {
        Write-Host "Tag parse skip: $($meta.reason)" -ForegroundColor DarkYellow
        return $null
    }

    $tags = @{}
    $finalMaterialTags = @()

    for ($i = 0; $i -lt $meta.materials.Count; $i++) {
        $mat = $meta.materials[$i]
        $colorInfo = Get-ColorInfo -ColorName $mat.color
        
        $matTypeId = $null
        try { $matTypeId = Resolve-MaterialTypeId -MaterialToken $mat.material } catch { $matTypeId = $null }

        if ($matTypeId) {
            $finalMaterialTags += @{
                type  = $matTypeId
                hex   = $colorInfo.hex
                color = $colorInfo.name
            }
        } else {
             Write-Host "No filament type match for '$($mat.material)'; skipping tags.material entry." -ForegroundColor DarkYellow
        }
    }

    if ($finalMaterialTags.Count -gt 0) { 
        $tags.material = $finalMaterialTags 
    }

    if ($tags.Keys.Count -eq 0) { return $null }
    return $tags
}

# =========================
# CORE FUNCTIONS
# =========================

function Wait-FileStable {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$MaxSeconds = 120
    )

    $deadline    = (Get-Date).AddSeconds($MaxSeconds)
    $lastSize    = -1
    $stableCount = 0

    while ((Get-Date) -lt $deadline) {
        try {
            $f    = Get-Item -LiteralPath $Path -ErrorAction Stop
            $size = $f.Length

            if ($size -eq $lastSize -and $size -gt 0) { $stableCount++ }
            else { $stableCount = 0; $lastSize = $size }

            if ($stableCount -ge 6) { return $true }
        } catch { }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Upload-FileToSimplyPrint {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    Add-Type -AssemblyName System.Net.Http

    $maxRetries = 3
    $retryCount = 0
    $baseWaitSeconds = 120

    while ($retryCount -le $maxRetries) {
        $client = New-Object System.Net.Http.HttpClient
        $client.DefaultRequestHeaders.Add("X-API-KEY", $apiKey)
        $client.DefaultRequestHeaders.Add("accept", "application/json")
        
        $mp = New-Object System.Net.Http.MultipartFormDataContent
        $fs = [System.IO.File]::OpenRead($FilePath)

        try {
            $sc = New-Object System.Net.Http.StreamContent($fs)
            $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
            $mp.Add($sc, "file", [System.IO.Path]::GetFileName($FilePath))

            $client.Timeout = [TimeSpan]::FromMinutes(10)

            if ($retryCount -gt 0) {
                Write-Host "`n--- RETRY ATTEMPT $retryCount of $maxRetries ---" -ForegroundColor Magenta
            }

            Write-Host ("Upload start: {0}" -f (Get-Date)) -ForegroundColor DarkCyan
            Write-Host "POST $uploadUrl"

            $task = $client.PostAsync($uploadUrl, $mp)

            if (-not $task.Wait([TimeSpan]::FromMinutes(10))) {
                throw "Upload timed out after 10 minutes (PostAsync did not complete)."
            }

            $resp = $task.Result
            Write-Host ("Upload response received: {0}" -f (Get-Date)) -ForegroundColor DarkCyan

            if (-not $resp) { throw "Upload failed: PostAsync returned null response" }
            if (-not $resp.Content) { throw "Upload failed: HTTP response had null Content. StatusCode=$($resp.StatusCode)" }

            $text = $resp.Content.ReadAsStringAsync().Result

            if (-not $resp.IsSuccessStatusCode) {
                throw "HTTP $($resp.StatusCode) :: $text"
            }
            if (-not $text) {
                throw "Upload failed: empty body returned despite success."
            }

            return ($text | ConvertFrom-Json)
        }
        catch {
            Write-Host "Upload failed with error:" -ForegroundColor Red
            Write-Host $_.Exception.Message

            if ($retryCount -ge $maxRetries) {
                Write-Host "Max retries ($maxRetries) reached. Giving up on this file." -ForegroundColor DarkRed
                throw $_ 
            }

            $retryCount++
            $waitTime = $baseWaitSeconds * [math]::Pow(2, $retryCount - 1)
            
            Write-Host "Backing off for $($waitTime / 60) minutes before retrying..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $waitTime
        }
        finally {
            if ($fs)     { $fs.Dispose() }
            if ($mp)     { $mp.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }
}

function Send-FileInChunks {
    # Chunked upload for files at/above the single-shot ceiling. Confirmed behavior
    # (07-19-2026): POST part 1 as file + totalSize -> response carries a
    # continueToken; POST each later part as continueToken + file; the token does
    # NOT rotate (reuse part 1's); the final part's response carries file.id.
    # 50MB chunks upload cleanly (larger single POSTs 502 at the CDN).
    param([Parameter(Mandatory=$true)][string]$FilePath)

    Add-Type -AssemblyName System.Net.Http

    $chunkSize   = 50MB
    $maxRetries  = 3
    $fileName    = [System.IO.Path]::GetFileName($FilePath)
    $totalSize   = (Get-Item -LiteralPath $FilePath).Length
    $totalParts  = [math]::Ceiling($totalSize / $chunkSize)

    Write-Host ("Chunked upload chosen: {0:N2} MB -> {1} parts of {2}MB" -f ($totalSize/1MB), $totalParts, [math]::Round($chunkSize/1MB)) -ForegroundColor DarkCyan

    $fs = [System.IO.File]::OpenRead($FilePath)
    try {
        $buffer        = New-Object byte[] $chunkSize
        $continueToken = $null
        $part          = 0

        while ($true) {
            $read = $fs.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $part++

            $chunk = New-Object byte[] $read
            [Array]::Copy($buffer, $chunk, $read)

            # Per-chunk retry with backoff (mirrors single-shot uploader).
            $retryCount = 0
            $chunkResp  = $null
            while ($true) {
                $client = New-Object System.Net.Http.HttpClient
                $client.Timeout = [TimeSpan]::FromMinutes(15)
                $client.DefaultRequestHeaders.Add("X-API-KEY", $apiKey)
                $client.DefaultRequestHeaders.Add("accept", "application/json")
                $mp = New-Object System.Net.Http.MultipartFormDataContent
                try {
                    # (byte[], offset, count) ctor - New-Object can't pick the single-arg overload
                    $bc = New-Object System.Net.Http.ByteArrayContent -ArgumentList @($chunk, 0, $read)
                    $bc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")

                    if (-not $continueToken) {
                        $mp.Add($bc, "file", $fileName)
                        $mp.Add((New-Object System.Net.Http.StringContent($totalSize.ToString())), "totalSize")
                        Write-Host ("  Uploading chunk {0} of {1}..." -f $part, $totalParts)
                    } else {
                        $mp.Add((New-Object System.Net.Http.StringContent($continueToken)), "continueToken")
                        $mp.Add($bc, "file", $fileName)
                        Write-Host ("  Uploading chunk {0} of {1}..." -f $part, $totalParts)
                    }

                    $task = $client.PostAsync($uploadUrl, $mp)
                    if (-not $task.Wait([TimeSpan]::FromMinutes(15))) { throw "Chunk POST timed out." }
                    $resp = $task.Result
                    $text = $resp.Content.ReadAsStringAsync().Result
                    if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode) :: $text" }
                    $chunkResp = ($text | ConvertFrom-Json)
                    break
                }
                catch {
                    Write-Host "  Chunk $part failed: $($_.Exception.Message)" -ForegroundColor Red
                    if ($retryCount -ge $maxRetries) { throw "Chunked upload aborted at part $part after $maxRetries retries." }
                    $retryCount++
                    $wait = 30 * [math]::Pow(2, $retryCount - 1)
                    Write-Host "  Retrying part $part in $wait s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $wait
                }
                finally {
                    if ($mp)     { $mp.Dispose() }
                    if ($client) { $client.Dispose() }
                }
            }

            if ($chunkResp.file.id) {
                Write-Host ("All {0} chunks uploaded and reassembled successfully." -f $totalParts) -ForegroundColor Green
                return $chunkResp
            } elseif ($chunkResp.continueToken) {
                if (-not $continueToken) { $continueToken = [string]$chunkResp.continueToken }
            } else {
                throw "Chunk $part returned neither file.id nor continueToken."
            }
        }

        throw "Chunked upload ended without a file.id (sent all $part parts)."
    }
    finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Invoke-SimplyPrintJob {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    Write-Host ""
    Write-Host "*** New GCODE detected: $FilePath" -ForegroundColor Cyan

    if (-not (Wait-FileStable -Path $FilePath -MaxSeconds 90)) {
        Write-Host "ERROR: File did not stabilize. Skipping." -ForegroundColor Red
        return
    }

    # Files at/above this go through the chunked uploader; below, single-shot.
    # 100MB is conservative - chunking a slightly-small file still uploads fine,
    # so this just guarantees anything genuinely large takes the safe path.
    $chunkThreshold = 100MB

    try {
        # 1) Upload (single-shot or chunked by size)
        $fileItem = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue

        if ($fileItem -and $fileItem.Length -ge $chunkThreshold) {
            Write-Host ("Uploading (chunked, {0:N2} MB)..." -f ($fileItem.Length / 1MB)) -ForegroundColor Yellow
            $uploadResp = Send-FileInChunks -FilePath $FilePath
        } else {
            Write-Host "Uploading (single-shot)..." -ForegroundColor Yellow
            Write-Host "POST $uploadUrl"
            $uploadResp = Upload-FileToSimplyPrint -FilePath $FilePath
        }

        $fileId = $null
        try { $fileId = $uploadResp.file.id } catch { $fileId = $null }

        if (-not $fileId) {
            Write-Host "ERROR: Upload response missing file.id; cannot queue." -ForegroundColor Red
            return
        }

        # 2) Parse the filename ONCE, then build tags from that parsed result
        $meta = Parse-JobFileName -FilePath $FilePath
        $tagsObj = Build-SimplyPrintTags -Meta $meta

        # 2b) Resolve printer model
        $modelId = $null
        if ($meta.ok -and $meta.machineModel) {
            try { $modelId = Resolve-PrinterModelId -ModelToken $meta.machineModel } catch { $modelId = $null }
        }

        if ($modelId) {
            Write-Host "Resolved printer model '$($meta.machineModel)' -> model id $modelId" -ForegroundColor Cyan
        } else {
            Write-Host "No model id match for machine token '$($meta.machineModel)'; leaving for_models unset." -ForegroundColor DarkYellow
        }

        # 3) Add to queue
        $body = @{
            fileId = $fileId
            amount = $amount
        }
        
        if ($null -ne $group -and $group -ne 0 -and $group -ne "") { 
            $body.Add("group", $group)
        }

        if ($modelId) { $body.Add("for_models", @($modelId)) }

        $bodyJson = ($body | ConvertTo-Json -Depth 10)

        Write-Host "Queuing File (Step 1/2)..." -ForegroundColor Yellow
        Write-Host "POST $queueUrl"
        Write-Host "Body: $bodyJson"

        $queueResp = Invoke-RestMethod `
            -Method Post `
            -Uri $queueUrl `
            -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" } `
            -ContentType "application/json" `
            -Body $bodyJson

        Write-Host "Queue OK. Response:" -ForegroundColor Green
        Write-Host ($queueResp | ConvertTo-Json -Depth 10)
        
        # 4) Smart Polling & Dynamic Tag Assignment
        $createdId = $null
        try { $createdId = $queueResp.created_id } catch {}
        if ($createdId) { $script:W2PAddedIds["$createdId"] = $true }   # external-change monitor: this one is ours

        if ($createdId -and $tagsObj) {
            
            Write-Host "Polling SimplyPrint for GCODE analysis (waiting for material data)..." -ForegroundColor DarkYellow
            $maxAttempts = 30 
            $attempt = 0
            $analysisReady = $false
            $materialData = $null
            
            while ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 2
                $attempt++
                
                try {
                    $pollUrl = "$apiBase/queue/GetItem?id=$createdId"
                    $pollResp = Invoke-RestMethod -Method Get -Uri $pollUrl -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" }
                    
                    if ($pollResp.item -and $pollResp.item.analysis -and $pollResp.item.analysis.materialData) {
                        $materialData = $pollResp.item.analysis.materialData
                        $analysisReady = $true
                        Write-Host "-> Full GCODE Analysis complete in $($attempt * 2) seconds!" -ForegroundColor Green
                        break
                    }
                } catch { }
            }

            if (-not $analysisReady) {
                Write-Host "-> WARNING: Analysis timed out or materialData missing. Tags might fail." -ForegroundColor Red
            }

            if ($tagsObj.material) {
                $mappedMaterials = @()

                # Ensure materialData is treated as an array even if it's a single object
                if ($materialData -and $materialData.GetType().Name -notmatch 'Array') {
                    $materialData = @($materialData)
                }
                
                if ($materialData) {
                    Write-Host "`nSimplyPrint Analysis found these slots:" -ForegroundColor Cyan
                    Write-Host ($materialData | ConvertTo-Json -Depth 3 -Compress) -ForegroundColor DarkGray
                }

                # ==========================================
                # DUAL PATH LOGIC (U1 vs STANDARD AMS)
                # ==========================================
                if ($meta.machineModel -match "U1") {

                    # --- PATH A: U1 DYNAMIC MATCH ---
                    # materialData is index-aligned to the extruder ({} = unused slot).
                    # Each used slot is scored against the filename materials (+2 color
                    # hex, +2 family substring, e.g. "TPU" in "RoamrTPU"); best scorer
                    # at/above $u1MinMatchScore is tagged, below is left untagged + warned.

                    # Build the filename-declared materials, each with searchable family text.
                    $fileMats = @()
                    for ($fm = 0; $fm -lt $tagsObj.material.Count; $fm++) {
                        $m = $tagsObj.material[$fm]
                        $famText = ""
                        try { $famText = Get-FamilyTextForTypeId -TypeId ([int]$m.type) } catch { $famText = "" }
                        $fileMats += @{
                            typeId     = $m.type
                            hex        = $m.hex
                            color      = $m.color
                            familyText = $famText
                            claimed    = $false
                        }
                    }

                    # Build the list of USED extruder slots from the analysis (ground truth).
                    $usedSlots = @()
                    if ($materialData) {
                        for ($k = 0; $k -lt $materialData.Count; $k++) {
                            $entry = $materialData[$k]
                            if ($null -eq $entry) { continue }
                            $slotFam = $null; try { $slotFam = [string]$entry.type }  catch { $slotFam = $null }
                            if ([string]::IsNullOrWhiteSpace($slotFam)) { continue }   # empty {} slot -> unused
                            $slotHex = $null; try { $slotHex = [string]$entry.color } catch { $slotHex = $null }
                            # Tag addressing must match the file's analysis shape: slots WITH a
                            # nozzle field need per-nozzle addressing (nozzle=slot, ext=0); slots
                            # WITHOUT need flat addressing (nozzle=0, ext=slot). Validated 07-16-2026.
                            $slotNoz = $null
                            try { if ($null -ne $entry.nozzle) { $slotNoz = [int]$entry.nozzle } } catch { $slotNoz = $null }
                            $usedSlots += @{ ext = $k; nozzle = $slotNoz; family = $slotFam; hex = $slotHex }
                        }
                    }

                    $anyUntagged = $false

                    if ($usedSlots.Count -eq 0) {
                        # No per-extruder analysis data - nothing to match against; leave untagged.
                        Write-Host "U1: no per-extruder analysis data; skipping material tags for this file." -ForegroundColor Red
                        $anyUntagged = $true
                    } else {
                        foreach ($slot in $usedSlots) {
                            $slotHexN = Normalize-Hex    $slot.hex
                            $slotFamN = Normalize-Family $slot.family

                            # Score every remaining (unclaimed) filename material for this slot.
                            $best      = $null
                            $bestScore = -1
                            $bestHexHit = $false
                            $bestFamHit = $false
                            foreach ($m in $fileMats) {
                                if ($m.claimed) { continue }
                                $hexHit = ($slotHexN -ne "" -and (Normalize-Hex $m.hex) -eq $slotHexN)
                                $famHit = ($slotFamN -ne "" -and $m.familyText -and $m.familyText.Contains($slotFamN))
                                $score  = 0
                                if ($hexHit) { $score += 2 }
                                if ($famHit) { $score += 2 }
                                if ($score -gt $bestScore) {
                                    $bestScore  = $score
                                    $best       = $m
                                    $bestHexHit = $hexHit
                                    $bestFamHit = $famHit
                                }
                            }

                            $acceptable = ($null -ne $best -and $bestScore -ge $u1MinMatchScore)

                            if ($acceptable) {
                                $best.claimed = $true
                                if ($null -ne $slot.nozzle) {
                                    $tagNoz = $slot.nozzle; $tagExt = 0          # per-nozzle shape
                                } else {
                                    $tagNoz = 0;            $tagExt = $slot.ext  # flat shape
                                }
                                $mappedMaterials += @{
                                    nozzle = $tagNoz
                                    ext    = $tagExt
                                    type   = $best.typeId
                                    hex    = $best.hex
                                    color  = $best.color
                                    width  = 1.75
                                }
                                if ($bestHexHit -and $bestFamHit) {
                                    Write-Host "U1: ext $($slot.ext) -> '$($best.color)' type $($best.typeId) [exact: color + family]." -ForegroundColor Cyan
                                } elseif ($bestHexHit -or $bestFamHit) {
                                    $sig = if ($bestHexHit) { "color only" } else { "family only" }
                                    Write-Host "U1: ext $($slot.ext) -> '$($best.color)' type $($best.typeId) [best guess: $sig; analysis family '$($slot.family)', hex '$($slot.hex)']." -ForegroundColor Yellow
                                } else {
                                    Write-Host "U1: ext $($slot.ext) -> '$($best.color)' type $($best.typeId) [WEAK guess: no color/family signal; analysis family '$($slot.family)', hex '$($slot.hex)']." -ForegroundColor Yellow
                                }
                            } else {
                                # Nothing left to assign, or best match below threshold ->
                                # leave this slot untagged and warn.
                                $anyUntagged = $true
                                if ($null -eq $best) {
                                    Write-Host "U1: ext $($slot.ext) left untagged (no filename material left to assign)." -ForegroundColor Red
                                } else {
                                    Write-Host "U1: ext $($slot.ext) left untagged (best match score $bestScore below threshold $u1MinMatchScore; analysis family '$($slot.family)', hex '$($slot.hex)')." -ForegroundColor Red
                                }
                            }
                        }
                    }

                    if ($anyUntagged) {
                        Write-Host "U1: one or more extruders were left untagged - review this file's routing manually." -ForegroundColor Red
                    }

                } else {
                    
                    # --- PATH B: STANDARD AMS (H2D, P1S, etc.) ---
                    # Use the stable logic that calculates extruders per nozzle
                    $mapping = @()
                    $extrudersSeenPerNozzle = @{}

                    if ($materialData) {
                        foreach ($mat in $materialData) {
                            $noz = 0
                            if ($mat.nozzle -ne $null) { $noz = [int]$mat.nozzle }
                            
                            if (-not $extrudersSeenPerNozzle.ContainsKey($noz)) {
                                $extrudersSeenPerNozzle[$noz] = 0
                            }
                            
                            $mappedExt = $extrudersSeenPerNozzle[$noz]
                            $extrudersSeenPerNozzle[$noz]++
                            
                            $mapping += @{ nozzle = $noz; ext = $mappedExt }
                        }
                    }
                    
                    for ($i = 0; $i -lt $tagsObj.material.Count; $i++) {
                        $baseMat = $tagsObj.material[$i]
                        
                        $finalNozzle = 0
                        $finalExt = $i 
                        
                        if ($mapping.Count -gt $i) {
                            $finalNozzle = $mapping[$i].nozzle
                            $finalExt    = $mapping[$i].ext
                        }
                        
                        $mappedMaterials += @{
                            nozzle = $finalNozzle
                            ext    = $finalExt
                            type   = $baseMat.type
                            hex    = $baseMat.hex
                            color  = $baseMat.color
                        }
                    }
                }

                # ==========================================
                # SEND TO API (assign once, verify once)
                # ==========================================
                Write-Host "`nAssigning dynamically mapped Material tags to Queue Item $createdId..." -ForegroundColor Magenta
                $matBody = @{
                    type     = 4             
                    id       = $createdId
                    edited   = "material"
                    material = $mappedMaterials
                } | ConvertTo-Json -Depth 10
                
                Write-Host "Payload being sent:`n$matBody" -ForegroundColor DarkGray

                try {
                    $matResp = Invoke-RestMethod -Method Post -Uri $assignTagUrl -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" } -ContentType "application/json" -Body $matBody
                    Write-Host "Material Assign OK:" -ForegroundColor Green
                    Write-Host ($matResp | ConvertTo-Json -Depth 5)

                    # Cheap persistence check: assign can return status:true while the
                    # platform drops an invalidly-addressed payload. One readback catches it.
                    Start-Sleep -Seconds 2
                    try {
                        $chk = Invoke-RestMethod -Method Get -Uri "$apiBase/queue/GetItem?id=$createdId" -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" }
                        if ($chk.item -and $chk.item.tags -and $chk.item.tags.material -and @($chk.item.tags.material).Count -ge 1) {
                            Write-Host "Verified: material tags persisted on the queue item." -ForegroundColor Green
                        } else {
                            Write-Host "WARNING: assign returned OK but material tags did not persist on item $createdId - tag it manually and investigate." -ForegroundColor Red
                        }
                    } catch { }
                } catch {
                    Write-Host "ERROR assigning material tags:" -ForegroundColor Red
                    Write-Host $_.Exception.Message
                    
                    if ($_.Exception.Response) {
                        try {
                            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            Write-Host "SimplyPrint Server Message:" -ForegroundColor Yellow
                            Write-Host $reader.ReadToEnd()
                        } catch {}
                    }
                }
            }
        }

        # 5) RUSH QUEUE POSITIONING (Rule B - aged priority blocks)
        # If the filename indicated a rush priority (e.g. "FoamHeelCup-1"), insert
        # the new item BELOW the entire existing priority block (untouched), above
        # all normal jobs. The -N number only orders the jobs added this scan pass
        # among themselves (lower number = higher; same number = FIFO). Result:
        #   old -1 | old -2 | new -1 | new -2 | normal | normal ...
        # SetOrder is a GET with query params per the API docs:
        #   GET /{id}/queue/SetOrder?queue_item={id}&from=1&to={position}
        # 'from' is deprecated by the API but must still be a positive integer.
        if ($meta.ok -and $null -ne $meta.queuePosition -and $createdId) {

            Write-Host ""
            Write-Host "*** RUSH JOB detected (priority $($meta.queuePosition)). Determining insert position..." -ForegroundColor Magenta

            # Fall back to the historical absolute position if the queue read fails.
            $targetPos = $meta.queuePosition

            try {
                $computed = Get-RushInsertPosition -NewPriority $meta.queuePosition -NewItemId $createdId
                if ($null -ne $computed -and $computed -ge 1) {
                    $targetPos = $computed
                    Write-Host "Inserting at position $targetPos - below the existing priority block, ordered within this pass (this pass so far: $($script:CurrentPassRush.Count) rush job(s))." -ForegroundColor Cyan
                } else {
                    Write-Host "Could not read existing queue; falling back to absolute position $targetPos." -ForegroundColor DarkYellow
                }
            } catch {
                Write-Host "Queue lookup for rush positioning failed; falling back to absolute position $targetPos." -ForegroundColor DarkYellow
                Write-Host $_.Exception.Message -ForegroundColor DarkYellow
            }

            Write-Host "*** RUSH JOB: Moving item $createdId to queue position $targetPos..." -ForegroundColor Magenta

            $rushUrl = "$setOrderUrl" + "?queue_item=$createdId&from=1&to=$targetPos"
            Write-Host "GET $rushUrl"

            try {
                $rushResp = Invoke-RestMethod `
                    -Method Get `
                    -Uri $rushUrl `
                    -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" }

                # Note: SetOrder returns 'success' (not 'status') per docs.
                Write-Host "SetOrder OK. Item moved to position $targetPos." -ForegroundColor Green
                Write-Host ($rushResp | ConvertTo-Json -Depth 5)

            } catch {
                Write-Host "ERROR: SetOrder call failed. Item was queued but NOT moved to rush position." -ForegroundColor Red
                Write-Host $_.Exception.Message

                if ($_.Exception.Response) {
                    try {
                        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                        Write-Host "SimplyPrint Server Message:" -ForegroundColor Yellow
                        Write-Host $reader.ReadToEnd()
                    } catch {}
                }
            }
        }

        try {
            Add-W2PHistoryLine -Path $historyFile -Line $FilePath
        } catch {
            Write-Host "Warning: Could not append to history file right now. Dropbox lock might be active." -ForegroundColor Yellow
        }

    }
    catch {
        Write-Host "ERROR during upload/queue:" -ForegroundColor Red
        Write-Host $_.Exception.Message
        
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                Write-Host "SimplyPrint Server Message:" -ForegroundColor Yellow
                Write-Host $reader.ReadToEnd()
            } catch {}
        }
    }
}


# =========================
# SHARED HELPERS (platform-agnostic)
# =========================

function ConvertTo-ExtensionList {
    # Accepts ".gcode,3mf; .stl" or an array and returns a clean, lowercase,
    # dot-prefixed, de-duplicated array. Blank input falls back to .gcode so a
    # misconfigured file can never make the watcher silently match nothing.
    param($Raw)

    $parts = @()
    if ($null -eq $Raw) {
        $parts = @()
    } elseif ($Raw -is [System.Array]) {
        $parts = $Raw
    } else {
        $parts = ([string]$Raw) -split '[,;\s]+'
    }

    $out  = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($p in $parts) {
        if ($null -eq $p) { continue }
        $e = ([string]$p).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        if (-not $e.StartsWith('.')) { $e = '.' + $e }
        if ($seen.ContainsKey($e)) { continue }
        $seen[$e] = $true
        $out.Add($e)
    }

    if ($out.Count -eq 0) { $out.Add('.gcode') }
    # Returns loose strings, which PowerShell unrolls. EVERY caller must wrap
    # the result in @(...) so a single extension stays an array. Do not add a
    # leading comma here: `return ,$arr` plus a caller-side @() double-wraps,
    # and a later [string[]] cast then flattens it to one bogus string.
    return $out.ToArray()
}

function Test-WatchedExtension {
    # True when the path ends in one of the configured extensions.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $ext = ''
    try { $ext = [System.IO.Path]::GetExtension($Path) } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($ext)) { return $false }
    return (@($script:WatchExtensions) -contains $ext.ToLowerInvariant())
}

function Get-FileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PrintagoFileType {
    # Printago's part record carries a 'type' discriminator derived from the
    # file. Anything unrecognized is passed through as the bare extension.
    param([string]$Path)
    $e = ''
    try { $e = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant() } catch { $e = '' }
    if ([string]::IsNullOrWhiteSpace($e)) { return 'stl' }
    if ($e -eq 'stp') { return 'step' }
    return $e
}

function Write-DryRunPlan {
    # Prints what WOULD happen for this file without making any network call.
    # Used by every provider so an account-less test run still exercises the
    # filename parser, the routing decision, and the capability gating.
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)]$Meta,
        [Parameter(Mandatory=$true)][string[]]$Steps
    )

    $size = 0
    try { $size = (Get-Item -LiteralPath $FilePath).Length } catch {}

    Write-Host ""
    Write-Host "=== DRY RUN - no request will be sent ===" -ForegroundColor Magenta
    Write-Host ("File:      {0}" -f $FilePath)
    Write-Host ("Size:      {0:N2} MB" -f ($size / 1MB))
    Write-Host ("Platform:  {0}" -f (Get-PlatformCaps $script:Platform).label)

    if ($Meta -and $Meta.ok) {
        Write-Host ("Parsed:    job='{0}' part='{1}' side='{2}' machine='{3}' materials={4} rush={5}" -f `
            $Meta.job, $Meta.partname, $Meta.side, $Meta.machineModel, $Meta.materials.Count, `
            $(if ($null -eq $Meta.queuePosition) { 'none' } else { $Meta.queuePosition }))
        for ($i = 0; $i -lt $Meta.materials.Count; $i++) {
            $m = $Meta.materials[$i]
            Write-Host ("           mat[{0}]: color='{1}' brand='{2}' material='{3}'" -f $i, $m.color, $m.brand, $m.material) -ForegroundColor DarkGray
        }
    } else {
        $why = 'unparsed'
        if ($Meta) { $why = [string]$Meta.reason }
        Write-Host ("Parsed:    FAILED - {0}" -f $why) -ForegroundColor DarkYellow
    }

    Write-Host "Would send:" -ForegroundColor Magenta
    foreach ($s in $Steps) { Write-Host ("  -> {0}" -f $s) }
    Write-Host "=== end dry run ===" -ForegroundColor Magenta
    Write-Host ""
}

function Add-ToHistory {
    param([Parameter(Mandatory=$true)][string]$FilePath)
    try {
        Add-W2PHistoryLine -Path $script:historyFile -Line $FilePath
    } catch {
        Write-Host "Warning: Could not append to history file right now. Dropbox lock might be active." -ForegroundColor Yellow
    }
}

function Write-HttpErrorBody {
    # Pulls the response body out of a terminating web exception so API-level
    # error messages are visible instead of just "400 Bad Request".
    param($ErrorRecord, [string]$Source = 'Server')
    Write-Host $ErrorRecord.Exception.Message -ForegroundColor Red
    if ($ErrorRecord.Exception.Response) {
        try {
            $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            Write-Host ("{0} message:" -f $Source) -ForegroundColor Yellow
            Write-Host $reader.ReadToEnd()
        } catch {}
    }
}

function ConvertFrom-TokenMap {
    # Parses "U1=12345, P1S=67890" into a lookup keyed by uppercased token.
    # Used to translate a filename's machine token into a platform-specific
    # printer id on platforms that cannot queue against a model pool.
    param([string]$Raw)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $map }
    foreach ($pair in ($Raw -split '[,;\r\n]+')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $kv = $pair -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $k = $kv[0].Trim().ToUpperInvariant()
        $v = $kv[1].Trim()
        if ($k -and $v) { $map[$k] = $v }
    }
    return $map
}

function Resolve-MappedPrinterId {
    # Exact token match first, then a contains-match so "U1" in the map still
    # catches a filename machine token of "KingroonU1".
    param([string]$MachineToken, $Map, [string]$Fallback)

    if ($Map -and -not [string]::IsNullOrWhiteSpace($MachineToken)) {
        $t = $MachineToken.Trim().ToUpperInvariant()
        if ($Map.ContainsKey($t)) { return $Map[$t] }
        foreach ($k in $Map.Keys) {
            if ($t.Contains($k)) { return $Map[$k] }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return $Fallback.Trim() }
    return $null
}

function Get-OfflineFilamentTypes {
    # Static stand-in for SimplyPrint's /filament/type/Get, used by the
    # filename parser on platforms that have no such endpoint. Shaped like the
    # real response (id / profile_name / material_type_name) so
    # Resolve-MaterialTypeId works unmodified. The ids are synthetic.
    $families = @(
        'PLA','PLA+','PLA-CF','PETG','PETG-CF','ABS','ABS-CF','ASA','TPU','TPE',
        'PA','PA-CF','PA6','PA12','Nylon','PC','PC-CF','PVA','BVOH','HIPS',
        'PP','PPS','PPS-CF','PEEK','PEI','PVB','PET','PCTG','Wood','Metal'
    )
    $i = 900000
    $out = @()
    foreach ($f in $families) {
        $i++
        $out += [pscustomobject]@{
            id                 = $i
            profile_name       = $f
            material_type_name = $f
        }
    }
    return $out
}


# =========================================================================
# PROVIDER: PRINTAGO
# =========================================================================
# Flow (from Printago's published one-off-print example):
#   1. POST /v1/storage/signed-upload-urls  { filenames: [name] }
#        -> signedUrls[0].uploadUrl  (S3-style pre-signed PUT)
#        -> signedUrls[0].path       (the fileUri to reference later)
#   2. PUT  <uploadUrl>  with the raw file bytes
#   3. POST /v1/parts    { name, fileUris, fileHashes, type, storeId, ... }
#        -> id  (the partId)
#   4. POST /v1/builds   { parts: [ { partId, quantity, tags, label } ] }
#
# Auth is two headers: "Authorization: ApiKey <key>" and
# "x-printago-storeid: <storeId>".
#
# Routing: Printago matches a job to a printer with a tag expression on the
# build entry, not with a model id. Two supported shapes:
#   { "printer.id": "=<PRINTER_ID>" }     - pin to one specific printer
#   { "user.tags":  "&=TAG1|TAG2" }       - any printer carrying those tags
# The filename's machine token becomes the user.tag unless a specific
# printer id is configured, in which case that wins.
#
# NOT SUPPORTED HERE (no equivalent in the API surface we have):
#   material/color tagging, gcode analysis polling, U1 slot scoring,
#   queue reordering / rush positions, job groups.
#
# CAUTION: Printago is a model-centric platform - it wants STL/3MF/STEP and
# slices in the cloud. Whether a pre-sliced .gcode is accepted as a part is
# undocumented. The engine warns rather than refusing, so you can find out.
# =========================================================================

function Get-PrintagoHeaders {
    return @{
        'Authorization'      = ("ApiKey {0}" -f $script:pgApiKey)
        'x-printago-storeid' = $script:pgStoreId
        'accept'             = 'application/json'
    }
}

function Invoke-PrintagoApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Endpoint,
        $Body = $null
    )

    $url = "{0}/v1/{1}" -f $script:pgBase, $Endpoint.TrimStart('/')
    Write-Host ("{0} {1}" -f $Method.ToUpperInvariant(), $url)

    if ($null -ne $Body) {
        $json = ($Body | ConvertTo-Json -Depth 12)
        Write-Host ("Body: {0}" -f $json) -ForegroundColor DarkGray
        return Invoke-RestMethod -Method $Method -Uri $url -Headers (Get-PrintagoHeaders) `
                                 -ContentType 'application/json' -Body $json
    }
    return Invoke-RestMethod -Method $Method -Uri $url -Headers (Get-PrintagoHeaders)
}

function Send-FileToPrintago {
    # Steps 1 and 2: reserve a signed URL, then PUT the bytes straight at it.
    # The PUT goes to object storage, NOT to the Printago API, so it must not
    # carry the API auth headers.
    #
    # CONTENT-TYPE IS PART OF THE SIGNATURE. Printago hands back a Google Cloud
    # Storage V2 signed URL, whose StringToSign is:
    #
    #     PUT \n <Content-MD5> \n <Content-Type> \n <Expires> \n <resource>
    #
    # GCS recomputes that from the headers we actually send and compares. If we
    # send a Content-Type the signer did not sign over, we get
    # 403 SignatureDoesNotMatch even though the key and URL are perfectly valid.
    # Most signers leave Content-Type empty, so sending NO header is the right
    # default. We try the alternatives in order rather than making anyone guess,
    # and report which one worked so it can be pinned later.
    param([Parameter(Mandatory=$true)][string]$FilePath)

    $name = [System.IO.Path]::GetFileName($FilePath)

    Write-Host "Requesting signed upload URL..." -ForegroundColor Yellow
    $signed = Invoke-PrintagoApi -Method 'Post' -Endpoint 'storage/signed-upload-urls' -Body @{ filenames = @($name) }

    if (-not $signed -or -not $signed.signedUrls -or @($signed.signedUrls).Count -lt 1) {
        throw "Printago returned no signed upload URL for '$name'."
    }

    $entry     = @($signed.signedUrls)[0]
    $uploadUrl = [string]$entry.uploadUrl
    $fileUri   = [string]$entry.path

    if ([string]::IsNullOrWhiteSpace($uploadUrl)) { throw "Printago signed URL response had no uploadUrl." }
    if ([string]::IsNullOrWhiteSpace($fileUri))   { throw "Printago signed URL response had no path." }

    # Dump the whole entry: if the API dictates required headers or a content
    # type, it will be visible here instead of having to be inferred.
    try {
        Write-Host ("signed-url entry: {0}" -f ($entry | ConvertTo-Json -Depth 6 -Compress)) -ForegroundColor DarkGray
    } catch {}

    # Honour a dictated content type if the response carries one.
    $dictated = $null
    foreach ($prop in @('contentType','content_type','mimeType','mime_type')) {
        try {
            if ($entry.PSObject.Properties.Name -contains $prop -and -not [string]::IsNullOrWhiteSpace([string]$entry.$prop)) {
                $dictated = [string]$entry.$prop
                break
            }
        } catch {}
    }

    if ($dictated) {
        Write-Host ("Response dictates Content-Type '{0}' - using only that." -f $dictated) -ForegroundColor Cyan
        $strategies = @($dictated)
    } elseif (-not [string]::IsNullOrWhiteSpace($script:pgUploadContentType)) {
        Write-Host ("Using configured Content-Type '{0}'." -f $script:pgUploadContentType) -ForegroundColor Cyan
        $strategies = @($script:pgUploadContentType)
    } else {
        # '' means: send no Content-Type header at all.
        $strategies = @('', 'application/octet-stream', 'application/x-www-form-urlencoded')
    }

    $size = (Get-Item -LiteralPath $FilePath).Length
    Add-Type -AssemblyName System.Net.Http

    $sigFailures = New-Object System.Collections.Generic.List[string]

    foreach ($ct in $strategies) {
        $ctLabel = if ([string]::IsNullOrEmpty($ct)) { '(no Content-Type header)' } else { $ct }
        Write-Host ("Uploading {0:N2} MB to signed URL, Content-Type = {1}" -f ($size / 1MB), $ctLabel) -ForegroundColor Yellow

        $transientRetries = 0
        while ($true) {
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromMinutes(20)
            $fs = $null
            try {
                $fs = [System.IO.File]::OpenRead($FilePath)
                $sc = New-Object System.Net.Http.StreamContent($fs)
                # StreamContent adds no Content-Type of its own, so leaving this
                # alone genuinely sends none.
                if (-not [string]::IsNullOrEmpty($ct)) {
                    $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ct)
                }

                $task = $client.PutAsync($uploadUrl, $sc)
                if (-not $task.Wait([TimeSpan]::FromMinutes(20))) { throw "Signed-URL PUT timed out." }

                $resp = $task.Result
                if ($resp.IsSuccessStatusCode) {
                    Write-Host "Upload complete." -ForegroundColor Green
                    if ([string]::IsNullOrEmpty($ct)) {
                        Write-Host "Working setting: no Content-Type header. Leave 'Upload Content-Type' blank in the config." -ForegroundColor Green
                    } else {
                        Write-Host ("Working setting: Content-Type '{0}'. Set 'uploadContentTypePrintago' to this to skip the probing next time." -f $ct) -ForegroundColor Green
                    }
                    return $fileUri
                }

                $text = ''
                try { $text = $resp.Content.ReadAsStringAsync().Result } catch {}
                $code = [int]$resp.StatusCode

                # A signature mismatch is deterministic. Retrying the identical
                # request after a delay can never help - move to the next
                # Content-Type immediately instead of re-sending 36 MB.
                if ($code -eq 403 -and $text -match 'SignatureDoesNotMatch') {
                    Write-Host ("Signature mismatch with {0} - not a transient error, trying the next Content-Type." -f $ctLabel) -ForegroundColor DarkYellow
                    $sigFailures.Add($ctLabel)
                    break
                }

                throw ("HTTP {0} :: {1}" -f $code, $text)
            }
            catch {
                if ($_.Exception.Message -match 'SignatureDoesNotMatch') { $sigFailures.Add($ctLabel); break }
                Write-Host ("Signed-URL PUT failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
                if ($transientRetries -ge 2) { throw }
                $transientRetries++
                $wait = 30 * [math]::Pow(2, $transientRetries - 1)
                Write-Host ("Retrying in {0} s..." -f $wait) -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            }
            finally {
                if ($fs)     { $fs.Dispose() }
                if ($client) { $client.Dispose() }
            }
        }
    }

    throw ("Signed-URL PUT rejected every Content-Type tried ({0}). The signature is computed over the Content-Type, so Printago must be signing with one this engine has not guessed - check the 'signed-url entry' line above for a dictated header, or set uploadContentTypePrintago in the config." -f ($sigFailures -join ', '))
}

function Get-PrintagoFilamentFamily {
    # Printago derives a base type from the gcode ("TPU"). Filenames carry a
    # product name ("HP-TPU", "PLA-CF"). Reduce to the family so a constraint
    # we send has a chance of matching what the file already declares.
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $t = $Token.Trim().ToUpperInvariant()
    foreach ($fam in @('PETG','PLA','ABS','ASA','TPU','TPE','PVA','BVOH','HIPS','PPS','PEEK','PEI','PCTG','PET','PA','PC','PP')) {
        if ($t -eq $fam -or $t.EndsWith("-$fam") -or $t.StartsWith("$fam-") -or $t.Contains($fam)) { return $fam }
    }
    return $t
}

function Compare-PrintagoField {
    # The parts endpoint echoes the stored record back, so a single request
    # tells us whether a field we sent was honoured, ignored, or overwritten by
    # Printago's own gcode parsing. That is the whole experiment.
    param([string]$Name, $Sent, $Returned)

    $s = ''; $r = ''
    try { $s = ($Sent     | ConvertTo-Json -Depth 8 -Compress) } catch { $s = [string]$Sent }
    try { $r = ($Returned | ConvertTo-Json -Depth 8 -Compress) } catch { $r = [string]$Returned }
    if ([string]::IsNullOrWhiteSpace($s)) { $s = '(empty)' }
    if ([string]::IsNullOrWhiteSpace($r)) { $r = '(empty)' }

    if ($s -eq $r) {
        Write-Host ("  {0,-22} ACCEPTED   sent {1}" -f $Name, $s) -ForegroundColor Green
    } elseif ($r -eq '(empty)' -or $r -eq '[]' -or $r -eq 'null') {
        Write-Host ("  {0,-22} IGNORED    sent {1}, stored nothing" -f $Name, $s) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  {0,-22} OVERWRITTEN sent {1}" -f $Name, $s) -ForegroundColor DarkYellow
        Write-Host ("  {0,-22}             got  {1}" -f '', $r) -ForegroundColor DarkYellow
    }
}

$script:pgMaterialsDumped = $false

function Invoke-PrintagoTry {
    # Read-only GET that reports rather than throws. Used only for discovery.
    param([string]$Endpoint, [switch]$Quiet)
    try {
        $r = Invoke-RestMethod -Method Get -Uri ("{0}/v1/{1}" -f $script:pgBase, $Endpoint) `
                               -Headers (Get-PrintagoHeaders) -TimeoutSec 40
        Write-Host ("  200  /v1/{0}" -f $Endpoint) -ForegroundColor Green
        return $r
    } catch {
        $code = ''
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if (-not $code) { $code = 'ERR' }
        if (-not $Quiet) { Write-Host ("  {0,-4} /v1/{1}" -f $code, $Endpoint) -ForegroundColor DarkGray }
        return $null
    }
}

function Get-PrintagoRows {
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Array]) { return @($Response) }
    foreach ($k in @('items','materials','variants','data','results','printers')) {
        try { if ($Response.PSObject.Properties.Name -contains $k) { return @($Response.$k) } } catch {}
    }
    return @($Response)
}

function Show-PrintagoMaterials {
    # One read-only discovery pass per run: base materials, their colour
    # variants, and how a printer reports what is loaded. Those three together
    # are everything needed to wire a real material override.
    # NOTE: this runs once per RUN. Change something in Printago, then Stop and
    # Start the watcher to see the new state.
    if ($script:pgMaterialsDumped) { return }
    if (-not $script:pgDumpMaterials) { return }
    $script:pgMaterialsDumped = $true

    Write-Host ""
    Write-Host "=== Printago material library discovery (read-only, once per run) ===" -ForegroundColor Magenta

    $mats = $null
    foreach ($ep in @('materials?limit=200','materials','filaments','base-materials')) {
        $mats = Invoke-PrintagoTry $ep
        if ($mats) { break }
    }

    $rows = Get-PrintagoRows $mats
    if ($rows.Count -eq 0) {
        Write-Host "  No materials found. Nothing can be matched or overridden until the library has entries." -ForegroundColor Red
        Write-Host "=== end material discovery ===" -ForegroundColor Magenta
        Write-Host ""
        return
    }

    Write-Host ("  {0} base material(s):" -f $rows.Count) -ForegroundColor Cyan
    foreach ($m in $rows) {
        $mid = [string]$m.id
        $hasProfile = $true
        try {
            $hasProfile = -not ([string]::IsNullOrWhiteSpace([string]$m.filamentUserProfileId) -and
                                [string]::IsNullOrWhiteSpace([string]$m.filamentSystemProfileId))
        } catch {}

        Write-Host ("    {0}  brand='{1}'  type='{2}'  id={3}" -f $m.name, $m.brand, $m.type, $mid) -ForegroundColor Cyan
        if (-not $hasProfile) {
            Write-Host "        NO SLICING PROFILE ATTACHED (filamentUserProfileId and filamentSystemProfileId are both null)." -ForegroundColor Red
            Write-Host "        Printago will not match jobs to a material without a profile for the printer model + nozzle." -ForegroundColor Red
        }

        # Colour variants live on a second level and are what an override points at.
        $variants = $null
        foreach ($ep in @(("materials/{0}/variants" -f $mid), ("materials/{0}" -f $mid),
                          ("material-variants?materialId={0}" -f $mid), ("materials/{0}/colors" -f $mid))) {
            $variants = Invoke-PrintagoTry $ep -Quiet
            if ($variants) {
                Write-Host ("        variants via /v1/{0}:" -f $ep) -ForegroundColor Green
                $vrows = Get-PrintagoRows $variants
                if ($vrows.Count -eq 0) {
                    Write-Host "        (endpoint responded but listed no variants)" -ForegroundColor DarkYellow
                } else {
                    foreach ($v in ($vrows | Select-Object -First 20)) {
                        Write-Host ("        {0}" -f ($v | ConvertTo-Json -Depth 6 -Compress)) -ForegroundColor DarkGray
                    }
                }
                break
            }
        }
        if (-not $variants) {
            Write-Host "        Could not list colour variants from any candidate endpoint." -ForegroundColor DarkYellow
        }
    }

    # What a printer advertises is what a job has to match against.
    Write-Host "  Printers and their loaded materials:" -ForegroundColor Cyan
    $pr = Invoke-PrintagoTry 'printers'
    foreach ($x in (Get-PrintagoRows $pr | Select-Object -First 5)) {
        Write-Host ("    {0}" -f ($x | ConvertTo-Json -Depth 8 -Compress)) -ForegroundColor DarkGray
    }

    Write-Host "  ^ send this whole block; it contains everything needed to wire the override." -ForegroundColor Magenta
    Write-Host "=== end material discovery ===" -ForegroundColor Magenta
    Write-Host ""
}

$script:pgMatCache = $null

function Get-PrintagoMaterialIndex {
    # Base materials plus their colour variants, fetched once and cached.
    if ($script:pgMatCache) { return $script:pgMatCache }
    $idx = New-Object System.Collections.Generic.List[object]
    $mats = $null
    foreach ($ep in @('materials?limit=200','materials')) { $mats = Invoke-PrintagoTry $ep -Quiet; if ($mats) { break } }
    foreach ($m in (Get-PrintagoRows $mats)) {
        $mid = [string]$m.id
        if (-not $mid) { continue }
        $vs = Invoke-PrintagoTry ("materials/{0}/variants" -f $mid) -Quiet
        foreach ($v in (Get-PrintagoRows $vs)) {
            if (-not $v.id) { continue }
            $idx.Add([pscustomobject]@{
                MaterialId = $mid; MaterialName = [string]$m.name; Brand = [string]$m.brand
                Type = [string]$m.type; VariantId = [string]$v.id
                VariantName = [string]$v.name; VariantColor = [string]$v.color
            })
        }
    }
    $script:pgMatCache = $idx
    return $idx
}

function Get-PrintagoNorm { param([string]$s); if (-not $s) { return '' }; return (($s -replace '[^A-Za-z0-9]','').ToLowerInvariant()) }

function Resolve-PrintagoVariant {
    # Filename tokens -> a colour variant in this store. Brand and material name
    # are normalised so HP-TPU matches HPTPU.
    param($Mat)
    if (-not $Mat) { return $null }
    $wantColor = Get-PrintagoNorm ([string]$Mat.color)
    $wantBrand = Get-PrintagoNorm ([string]$Mat.brand)
    $wantMat   = Get-PrintagoNorm ([string]$Mat.material)
    if (-not $wantColor) { return $null }

    $all = Get-PrintagoMaterialIndex
    $cand = @($all | Where-Object { (Get-PrintagoNorm $_.VariantName) -eq $wantColor })
    if ($cand.Count -eq 0) { return $null }

    if ($wantBrand) {
        $b = @($cand | Where-Object { (Get-PrintagoNorm $_.Brand) -eq $wantBrand })
        if ($b.Count -gt 0) { $cand = $b }
    }
    if ($wantMat) {
        $m = @($cand | Where-Object {
            (Get-PrintagoNorm $_.MaterialName) -eq $wantMat -or (Get-PrintagoNorm $_.Type) -eq $wantMat -or
            (Get-PrintagoNorm $_.MaterialName).Contains($wantMat) -or $wantMat.Contains((Get-PrintagoNorm $_.Type))
        })
        if ($m.Count -gt 0) { $cand = $m }
    }
    return $cand[0]
}

function Invoke-PrintagoWrite {
    # Write attempt that reports the server's validation body instead of just
    # the status line. Returns $true on success.
    param([string]$Method, [string]$Endpoint, $Body, [string]$Label)
    try {
        $json = ($Body | ConvertTo-Json -Depth 10)
        Write-Host ("  {0} /v1/{1}  [{2}]" -f $Method.ToUpperInvariant(), $Endpoint, $Label) -ForegroundColor DarkGray
        Write-Host ("      body: {0}" -f $json) -ForegroundColor DarkGray
        $r = Invoke-RestMethod -Method $Method -Uri ("{0}/v1/{1}" -f $script:pgBase, $Endpoint) `
                               -Headers (Get-PrintagoHeaders) -ContentType 'application/json' -Body $json -TimeoutSec 60
        Write-Host ("      OK: {0}" -f ($r | ConvertTo-Json -Depth 8 -Compress)) -ForegroundColor Green
        return $true
    } catch {
        $code = ''
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if (-not $code) { $code = 'ERR' }
        $bodyTxt = ''
        if ($_.Exception.Response) {
            try {
                $rd = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $bodyTxt = $rd.ReadToEnd(); $rd.Close()
            } catch {}
        }
        if ($bodyTxt.Length -gt 900) { $bodyTxt = $bodyTxt.Substring(0,900) + ' ...[truncated]' }
        Write-Host ("      {0}: {1}" -f $code, $bodyTxt) -ForegroundColor DarkYellow
        return $false
    }
}

function Set-PrintagoPartMaterial {
    # WHAT WE KNOW SO FAR, from live probing:
    #   GET  /v1/part-material-assignments?partId=X   -> 200  (route exists)
    #   POST /v1/part-material-assignments            -> 404  (no POST route)
    #   PATCH /v1/parts/{id} {materials:[...]}        -> 200 but SILENTLY IGNORED
    #         (updatedAt did not move, materials stayed at the gcode value)
    # So the collection is readable but not writable by the obvious verbs.
    # Trimmed to the routes that showed any sign of life, plus PUT, instead of
    # brute-forcing 27 combinations.
    param([string]$PartId, $Variant)

    if (-not $Variant) { return $false }
    Write-Host "Assigning material to the part..." -ForegroundColor Yellow

    # Read the collection first: if the UI has ever written one of these, the
    # record shape tells us exactly what to send.
    $existing = Invoke-PrintagoTry ("part-material-assignments?partId={0}" -f $PartId)
    if ($null -ne $existing) {
        Write-Host ("      current assignments: {0}" -f ($existing | ConvertTo-Json -Depth 8 -Compress)) -ForegroundColor DarkGray
    }

    $vhex = [string]$Variant.VariantColor
    if ($vhex.Length -eq 9) { $vhex = $vhex.Substring(0,7) }

    $body = @{ partId=$PartId; index=0; materialId=$Variant.MaterialId; materialVariantId=$Variant.VariantId }

    $attempts = @(
        @{ m='Put';   ep=("part-material-assignments"); b=$body;          l='PUT collection' }
        @{ m='Put';   ep=("parts/{0}/material-assignments" -f $PartId); b=$body; l='PUT on part' }
        @{ m='Post';  ep=("parts/{0}/material-assignments" -f $PartId); b=@($body); l='POST array on part' }
        @{ m='Patch'; ep=("parts/{0}" -f $PartId); b=@{ materialAssignments=@($body) }; l='PATCH part materialAssignments' }
        @{ m='Patch'; ep=("parts/{0}" -f $PartId); b=@{ materials=@(@{ index=0; type=$Variant.Type; color=$vhex }) }; l='PATCH part materials' }
    )

    foreach ($a in $attempts) {
        if (Invoke-PrintagoWrite -Method $a.m -Endpoint $a.ep -Body $a.b -Label $a.l) {
            # A 200 is not proof. Read the part back and check the value moved.
            Start-Sleep -Milliseconds 800
            $check = Invoke-PrintagoTry ("parts/{0}" -f $PartId) -Quiet
            $now = ''
            try { $now = (@($check.materials)[0].color) } catch {}
            if ($now -and ($now -replace '[^0-9A-Fa-f]','').ToUpper().StartsWith(($vhex -replace '[^0-9A-Fa-f]','').ToUpper())) {
                Write-Host ("MATERIAL OVERRIDE CONFIRMED via {0} /v1/{1} ({2}) - colour is now {3}" -f $a.m.ToUpper(), $a.ep, $a.l, $now) -ForegroundColor Green
                return $true
            }
            Write-Host ("      accepted but ignored: part colour is still {0}" -f $now) -ForegroundColor DarkYellow
        }
    }

    Write-Host "No route accepted a material override. Printago appears to treat gcode-derived material as authoritative." -ForegroundColor Red
    Write-Host "Next step: set the override once by hand in the Printago UI, then run" -ForegroundColor Cyan
    Write-Host ("  .\Watch2Print_Console.ps1 -Probe -ProbePart {0}" -f $PartId) -ForegroundColor Cyan
    Write-Host "  which reads back the record the UI created and reveals the real schema." -ForegroundColor Cyan
    return $false
}

function Resolve-PrintagoModelName {
    # Filenames carry a short machine token ("P1S"); Printago wants its full
    # model name ("Bambu Lab P1S"). The map is user-editable because only the
    # operator knows what their fleet is actually called in Printago.
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $m = ConvertFrom-TokenMap $script:pgModelMap
    $t = $Token.Trim().ToUpperInvariant()
    if ($m.ContainsKey($t)) { return $m[$t] }
    foreach ($k in $m.Keys) { if ($t.Contains($k)) { return $m[$k] } }
    return $null
}

function Build-PrintagoRoutingTags {
    # Turns the parsed machine token into Printago's tag-expression object.
    # A configured printer id always beats a token-derived tag.
    param($Meta)

    if (-not [string]::IsNullOrWhiteSpace($script:pgPrinterId)) {
        return @{ 'printer.id' = ("={0}" -f $script:pgPrinterId.Trim()) }
    }

    $tags = @{}

    if ($Meta -and $Meta.ok -and -not [string]::IsNullOrWhiteSpace($Meta.machineModel)) {
        $tokens = @($Meta.machineModel.Trim())
        if (-not [string]::IsNullOrWhiteSpace($script:pgExtraTags)) {
            foreach ($t in ($script:pgExtraTags -split '[,;|]+')) {
                if (-not [string]::IsNullOrWhiteSpace($t)) { $tokens += $t.Trim() }
            }
        }
        $tags['user.tags'] = ("&={0}" -f ($tokens -join '|'))

        # Printago derives printer.modelName from the gcode and stamps it onto
        # the part. Build-level tags land in the same requiredPrinterTags
        # dictionary, so sending our own key here is the lever for making the
        # FILENAME win over what the slicer baked in.
        if ($script:pgOverrideModel) {
            $model = Resolve-PrintagoModelName -Token $Meta.machineModel
            if ($model) {
                $tags['printer.modelName'] = ("={0}" -f $model)
                Write-Host ("Model override: filename token '{0}' -> printer.modelName '={1}' (overriding whatever the gcode declared)" -f $Meta.machineModel, $model) -ForegroundColor Cyan
            } else {
                Write-Host ("Model override is on, but '{0}' is not in the model map - leaving the gcode's model requirement in place." -f $Meta.machineModel) -ForegroundColor DarkYellow
                Write-Host "        Add a mapping like 'P1S=Bambu Lab P1S' on the Settings tab." -ForegroundColor DarkYellow
            }
        }
    }

    return $tags
}

function Invoke-PrintagoJob {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    Write-Host ""
    Write-Host "*** New file detected (Printago): $FilePath" -ForegroundColor Cyan

    if (-not (Wait-FileStable -Path $FilePath -MaxSeconds 90)) {
        Write-Host "ERROR: File did not stabilize. Skipping." -ForegroundColor Red
        return
    }

    $meta     = Parse-JobFileName -FilePath $FilePath
    $name     = [System.IO.Path]::GetFileName($FilePath)
    $partType = Get-PrintagoFileType -Path $FilePath
    $tags     = Build-PrintagoRoutingTags -Meta $meta

    $label = $name
    if ($meta.ok) {
        $label = ("{0}_{1}" -f $meta.job, $meta.partname)
        if (-not [string]::IsNullOrWhiteSpace($meta.side)) { $label = "$label`_$($meta.side)" }
    }

    $qty = 1
    try { if ([int]$script:amount -ge 1) { $qty = [int]$script:amount } } catch { $qty = 1 }

    if ($partType -eq 'gcode') {
        Write-Host "NOTE: uploading pre-sliced .gcode as a Printago part. Printago's own Fuse" -ForegroundColor DarkGray
        Write-Host "      folder-watcher lists .gcode as a supported part type, so this should be" -ForegroundColor DarkGray
        Write-Host "      accepted, but cloud slicing is bypassed." -ForegroundColor DarkGray
    }
    if ($meta.ok -and $meta.materials.Count -gt 0) {
        if ($script:pgSendMaterialTypes) {
            Write-Host ("NOTE: {0} material(s) parsed from the filename. Printago reads type and colour out of the gcode and ignores allowedFilamentTypes on a gcode part, so colour/brand cannot be overridden until materialAssignments is wired." -f $meta.materials.Count) -ForegroundColor DarkYellow
        } else {
            Write-Host ("NOTE: {0} material(s) parsed from the filename, but material constraints are switched off for Printago." -f $meta.materials.Count) -ForegroundColor DarkYellow
        }
    }
    if ($meta.ok -and $null -ne $meta.queuePosition) {
        Write-Host "NOTE: rush position parsed from the filename, but Printago has no queue reordering call - it is ignored." -ForegroundColor DarkYellow
    }

    if ($script:DryRun) {
        $tagText = if ($tags.Keys.Count -eq 0) { '{}' } else { ($tags | ConvertTo-Json -Compress) }
        Write-DryRunPlan -FilePath $FilePath -Meta $meta -Steps @(
            ("POST {0}/v1/storage/signed-upload-urls  filenames=[{1}]" -f $script:pgBase, $name),
            ("PUT  <signed url>  ({0} bytes)" -f (Get-Item -LiteralPath $FilePath).Length),
            ("POST {0}/v1/parts   name='{1}' type='{2}' storeId='{3}'" -f $script:pgBase, $name, $partType, $script:pgStoreId),
            ("POST {0}/v1/builds  quantity={1} label='{2}' tags={3}" -f $script:pgBase, $qty, $label, $tagText)
        )
        Add-ToHistory -FilePath $FilePath
        return
    }

    try {
        Show-PrintagoMaterials

        # 1+2) signed URL and upload
        $fileUri = Send-FileToPrintago -FilePath $FilePath

        # 3) create the part record
        Write-Host "Creating part..." -ForegroundColor Yellow
        $hash = Get-FileSha256 -Path $FilePath

        $variantEarly = $null
        if ($meta.ok -and $meta.materials.Count -gt 0) { $variantEarly = Resolve-PrintagoVariant -Mat $meta.materials[0] }

        # EXPERIMENT: populate allowedFilamentTypes from the filename instead of
        # sending []. Printago parses type and colour out of the gcode itself, so
        # this is the one documented part-level material lever we have. The
        # response is echoed back and diffed below, which settles empirically
        # whether the field is writable on a gcode part.
        # Same override applied at part level. Whichever of the two Printago
        # honours, the write-back check below will show it.
        $partPrintTags = @{}
        if ($script:pgOverrideModel -and $meta.ok) {
            $pm = Resolve-PrintagoModelName -Token $meta.machineModel
            if ($pm) { $partPrintTags['printer.modelName'] = ("={0}" -f $pm) }
        }

        $allowedTypes = @()
        # CONFIRMED IGNORED on gcode parts: sent ["TPU"], stored []. Kept behind
        # a flag (default off) in case it behaves differently for STL/3MF parts,
        # where Printago slices in the cloud and has no embedded filament data.
        if ($script:pgSendMaterialTypes -and $meta.ok -and $meta.materials.Count -gt 0) {
            $seenFam = @{}
            foreach ($m in $meta.materials) {
                $fam = Get-PrintagoFilamentFamily -Token ([string]$m.material)
                if ($fam -and -not $seenFam.ContainsKey($fam)) { $seenFam[$fam] = $true; $allowedTypes += $fam }
            }
            if ($allowedTypes.Count -gt 0) {
                Write-Host ("Requesting filament constraint: {0} (from filename token(s))" -f ($allowedTypes -join ', ')) -ForegroundColor Cyan
            }
        }

        # UNTRIED UNTIL NOW: every previous attempt set materials AFTER the part
        # existed, by which point Printago had already parsed the gcode and
        # taken ownership of the field. Supplying it in the create call is the
        # one ordering left to test.
        $createMaterials = $null
        if ($variantEarly) {
            $vh = [string]$variantEarly.VariantColor
            if ($vh.Length -eq 9) { $vh = $vh.Substring(0,7) }
            $createMaterials = @(@{ index = 0; type = $variantEarly.Type; color = $vh })
            Write-Host ("Supplying materials at part-create time: {0}" -f ($createMaterials | ConvertTo-Json -Depth 5 -Compress)) -ForegroundColor Cyan
        }

        $partBody = @{
            name                       = $name
            description                = ''
            fileUris                   = @($fileUri)
            fileHashes                 = @($hash)
            parameters                 = @()
            printTags                  = $partPrintTags
            allowedFilamentTypes       = $allowedTypes
            materials                  = $createMaterials
            type                       = $partType
            overriddenProcessProfileId = $null
            storeId                    = $script:pgStoreId
        }
        $partResp = Invoke-PrintagoApi -Method 'Post' -Endpoint 'parts' -Body $partBody

        $partId = $null
        try { $partId = [string]$partResp.id } catch {}
        if ([string]::IsNullOrWhiteSpace($partId)) {
            Write-Host "ERROR: Printago part response had no id; cannot queue." -ForegroundColor Red
            Write-Host ($partResp | ConvertTo-Json -Depth 6) -ForegroundColor DarkGray
            return
        }
        Write-Host ("Part created: {0}" -f $partId) -ForegroundColor Green

        # Report exactly which of our writes survived.
        try {
            Write-Host "Field write-back check (what Printago kept vs what we sent):" -ForegroundColor Cyan
            Compare-PrintagoField -Name 'allowedFilamentTypes' -Sent $allowedTypes -Returned $partResp.allowedFilamentTypes
            Compare-PrintagoField -Name 'printTags'            -Sent $partPrintTags -Returned $partResp.printTags
            if ($partResp.PSObject.Properties.Name -contains 'materials') {
                Write-Host ("  {0,-22} derived by Printago from the gcode: {1}" -f 'materials', ($partResp.materials | ConvertTo-Json -Depth 6 -Compress)) -ForegroundColor DarkGray
            }
            Write-Host ("full part response: {0}" -f ($partResp | ConvertTo-Json -Depth 10 -Compress)) -ForegroundColor DarkGray
        } catch {}

        # 4) queue it as a build
        Write-Host "Creating build (queueing)..." -ForegroundColor Yellow

        # Material override. The part's own materials array is parsed out of the
        # gcode and is read-only, so the only place a filename can win is
        # materialAssignments on the build. Its schema is undocumented, so we
        # try the plausible shapes: an HTTP error creates nothing and we move
        # on; the first success is evaluated and we stop, so at most one build
        # is ever created.
        $variant = $null
        if ($meta.ok -and $meta.materials.Count -gt 0) {
            $variant = Resolve-PrintagoVariant -Mat $meta.materials[0]
            if ($variant) {
                Write-Host ("Material override: '{0} {1} {2}' -> variant '{3}' ({4}) on material '{5}'" -f `
                    $meta.materials[0].color, $meta.materials[0].brand, $meta.materials[0].material, `
                    $variant.VariantName, $variant.VariantId, $variant.MaterialName) -ForegroundColor Cyan

                $gType = ''
                try { $gType = Get-PrintagoNorm ([string](@($partResp.materials)[0].type)) } catch {}
                $vType = Get-PrintagoNorm $variant.Type
                if ($gType -and $vType -and $gType -ne $vType) {
                    Write-Host ("REFUSING override: gcode is sliced for {0} but the variant is {1}. Temperatures are baked into the file." -f $gType.ToUpper(), $vType.ToUpper()) -ForegroundColor Red
                    $variant = $null
                }
            } else {
                Write-Host ("No variant in this store matches '{0}' / '{1}' / '{2}'. Leaving the gcode's material." -f `
                    $meta.materials[0].color, $meta.materials[0].brand, $meta.materials[0].material) -ForegroundColor DarkYellow
            }
        }

        # part_material_assignments is its own entity, so write it here rather
        # than trying to smuggle it into the build payload.
        if ($variant) {
            if ($script:pgTryMaterialOverride) {
                [void](Set-PrintagoPartMaterial -PartId $partId -Variant $variant)
            } else {
                Write-Host ("Matched variant '{0}' ({1}) but the override is switched off - every write route Printago exposes has been tested and rejects it for gcode parts. Set tryMaterialOverridePrintago=true in the config to retry once the schema is known." -f $variant.VariantName, $variant.VariantId) -ForegroundColor DarkGray
            }
        }

        $shapes = @()
        if ($false -and $variant) {
            $vhex = [string]$variant.VariantColor
            if ($vhex.Length -eq 9) { $vhex = $vhex.Substring(0,7) }   # #RRGGBBAA -> #RRGGBB

            # Mirror of the part's own materials array is the strongest guess:
            # Printago stores [{type,color,index}] there, so an override may
            # simply be the same shape.
            $shapes += ,@{ n='mirror part materials';   v=@(@{ index=0; type=$variant.Type; color=$vhex }) }
            $shapes += ,@{ n='array materialVariantId'; v=@(@{ index=0; materialId=$variant.MaterialId; materialVariantId=$variant.VariantId }) }
            $shapes += ,@{ n='array variantId only';    v=@(@{ index=0; variantId=$variant.VariantId }) }
            $shapes += ,@{ n='array variantId+matId';   v=@(@{ index=0; materialId=$variant.MaterialId; variantId=$variant.VariantId }) }
            $shapes += ,@{ n='array slot';              v=@(@{ slot=0; materialVariantId=$variant.VariantId }) }
            $shapes += ,@{ n='array filamentIndex';     v=@(@{ filamentIndex=0; materialVariantId=$variant.VariantId }) }
            $shapes += ,@{ n='bare id array';           v=@($variant.VariantId) }
            $shapes += ,@{ n='map index->variant';      v=@{ '0' = @{ materialId=$variant.MaterialId; variantId=$variant.VariantId } } }
        }
        $shapes += ,@{ n='none'; v=$null }

        $buildResp = $null
        $usedShape = 'none'
        foreach ($s in $shapes) {
            $entry = @{ partId=$partId; quantity=$qty; tags=$tags; label=$label; parameterOverrides=@() }
            if ($null -ne $s.v) { $entry['materialAssignments'] = $s.v }
            try {
                if ($null -ne $s.v) { Write-Host ("  trying materialAssignments shape: {0}" -f $s.n) -ForegroundColor DarkGray }
                $buildResp = Invoke-PrintagoApi -Method 'Post' -Endpoint 'builds' -Body @{ parts = @($entry) }
                $usedShape = $s.n
                break
            } catch {
                Write-Host ("  shape '{0}' rejected: {1}" -f $s.n, $_.Exception.Message) -ForegroundColor DarkYellow
                # The status line alone is useless. The body carries the
                # validation detail that names the expected schema.
                if ($_.Exception.Response) {
                    try {
                        $rd = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                        $bodyTxt = $rd.ReadToEnd()
                        $rd.Close()
                        if ($bodyTxt.Length -gt 1200) { $bodyTxt = $bodyTxt.Substring(0,1200) + ' ...[truncated]' }
                        Write-Host ("      server said: {0}" -f $bodyTxt) -ForegroundColor Red
                    } catch {}
                }
            }
        }
        if (-not $buildResp) { throw "Every build submission shape was rejected." }

        Write-Host "Build queued OK." -ForegroundColor Green

        try {
            $pb = @($buildResp.partBuilds)[0]
            if ($pb -and $pb.requiredPrinterTags) {
                Write-Host "Final routing requirements Printago will match against:" -ForegroundColor Cyan
                foreach ($k in $pb.requiredPrinterTags.PSObject.Properties.Name) {
                    Write-Host ("  {0,-26} {1}" -f $k, $pb.requiredPrinterTags.$k) -ForegroundColor Cyan
                }
            }
            if ($variant) {
                $ma = $null
                try { $ma = $pb.materialAssignments } catch {}
                if ($null -ne $ma -and "$ma" -ne '') {
                    Write-Host ("  MATERIAL OVERRIDE TOOK EFFECT via shape '{0}': {1}" -f $usedShape, ($ma | ConvertTo-Json -Depth 6 -Compress)) -ForegroundColor Green
                    Write-Host ("  Pin it by setting materialShapePrintago to '{0}'." -f $usedShape) -ForegroundColor Green
                } else {
                    Write-Host ("  MATERIAL OVERRIDE IGNORED - shape '{0}' was accepted by the API but materialAssignments came back empty." -f $usedShape) -ForegroundColor Red
                }
            }
            $mats2 = $null
            try { $mats2 = $pb.partCopy.materials } catch {}
            if ($mats2) { Write-Host ("  part materials now: {0}" -f ($mats2 | ConvertTo-Json -Depth 6 -Compress)) -ForegroundColor DarkGray }
        } catch {}
        Write-Host ($buildResp | ConvertTo-Json -Depth 8)

        Add-ToHistory -FilePath $FilePath
    }
    catch {
        Write-Host "ERROR during Printago upload/queue:" -ForegroundColor Red
        Write-HttpErrorBody -ErrorRecord $_ -Source 'Printago'
    }
}


# =========================================================================
# PROVIDER: 3DPrinterOS  (Global API v2.1)
# =========================================================================
# Flow:
#   1. POST /apiglobal/login    { username, password }  -> message.session
#   2. POST /apiglobal/upload   multipart: session, file, project_name
#        -> message.file_id
#   3. POST /apiglobal/file_update  { session, updates: {<id>:{ptype:<n>}} }
#        (optional - tells the cloud which printer type the gcode targets)
#   4. POST /apiglobal/print_file   { session, file_id, printer_id, only_queue }
#
# THE BIG DIFFERENCE FROM SIMPLYPRINT: there is no "queue this for any
# machine of model X" call. print_file requires a concrete printer_id. So a
# filename's machine token has to resolve to ONE printer, which is what the
# Printer ID map on the Settings tab is for ("U1=12345, P1S=67890"). If the
# token doesn't resolve and no default is set, the file is still uploaded
# but nothing is queued, and the log says so loudly.
#
# Auth is a session string, not an API key. It is cached for the life of the
# run and silently re-established once if the cloud rejects it.
#
# NOT SUPPORTED HERE: material/color tagging, gcode analysis polling, U1 slot
# scoring, queue reordering / rush positions. 'amount' is emulated by calling
# print_file repeatedly - there is no quantity parameter.
# =========================================================================

$script:posSession       = $null
$script:posPrinterTypes  = $null

function Invoke-PrinterOSCall {
    # Every 3DPrinterOS endpoint is a form POST that returns HTTP 200 with a
    # {result:bool, message:...} envelope - failures are in the body, not the
    # status code, so success has to be checked explicitly.
    param(
        [Parameter(Mandatory=$true)][string]$Endpoint,
        [hashtable]$Fields = @{},
        [switch]$NoSession
    )

    $url  = "{0}/apiglobal/{1}" -f $script:posBase, $Endpoint.TrimStart('/')
    $body = @{}
    foreach ($k in $Fields.Keys) { $body[$k] = $Fields[$k] }
    if (-not $NoSession) { $body['session'] = $script:posSession }

    Write-Host ("POST {0}" -f $url)
    $redacted = @{}
    foreach ($k in $body.Keys) {
        if ($k -eq 'password' -or $k -eq 'session') { $redacted[$k] = '<redacted>' } else { $redacted[$k] = $body[$k] }
    }
    Write-Host ("Body: {0}" -f ($redacted | ConvertTo-Json -Compress)) -ForegroundColor DarkGray

    return Invoke-RestMethod -Method Post -Uri $url `
                             -ContentType 'application/x-www-form-urlencoded' -Body $body
}

function Connect-PrinterOS {
    # Establishes (or refreshes) the session token.
    param([switch]$Force)

    if ($script:posSession -and -not $Force) { return $script:posSession }

    Write-Host "Logging in to 3DPrinterOS..." -ForegroundColor Yellow
    $resp = Invoke-PrinterOSCall -Endpoint 'login' -NoSession -Fields @{
        username = $script:posUsername
        password = $script:posPassword
    }

    if (-not $resp.result) {
        throw ("3DPrinterOS login failed: {0}" -f $resp.message)
    }

    $script:posSession = [string]$resp.message.session
    if ([string]::IsNullOrWhiteSpace($script:posSession)) {
        throw "3DPrinterOS login succeeded but returned no session token."
    }

    Write-Host "Logged in; session established." -ForegroundColor Green
    return $script:posSession
}

function Invoke-PrinterOSChecked {
    # Wrapper that retries exactly once behind a fresh login when the cloud
    # says the session is no good.
    param(
        [Parameter(Mandatory=$true)][string]$Endpoint,
        [hashtable]$Fields = @{}
    )

    Connect-PrinterOS | Out-Null
    $resp = Invoke-PrinterOSCall -Endpoint $Endpoint -Fields $Fields

    if (-not $resp.result) {
        $msg = [string]$resp.message
        if ($msg -match '(?i)session') {
            Write-Host "Session rejected; re-authenticating and retrying once..." -ForegroundColor DarkYellow
            Connect-PrinterOS -Force | Out-Null
            $resp = Invoke-PrinterOSCall -Endpoint $Endpoint -Fields $Fields
        }
    }
    return $resp
}

function Get-PrinterOSTypes {
    if ($script:posPrinterTypes) { return $script:posPrinterTypes }
    try {
        $resp = Invoke-PrinterOSChecked -Endpoint 'get_printer_types' -Fields @{}
        if ($resp.result) { $script:posPrinterTypes = $resp.message }
    } catch {
        Write-Host ("Could not fetch 3DPrinterOS printer types: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
    return $script:posPrinterTypes
}

function Resolve-PrinterOSTypeId {
    # Best-effort match of a filename machine token against the cloud's
    # printer-type descriptions. Returns $null when nothing matches, which
    # simply means the ptype update is skipped.
    param([string]$ModelToken)

    if ([string]::IsNullOrWhiteSpace($ModelToken)) { return $null }
    $types = Get-PrinterOSTypes
    if (-not $types) { return $null }

    $t = $ModelToken.Trim().ToLowerInvariant() -replace '[\s-]', ''

    $hit = $types | Where-Object {
        $_.description -and (($_.description.ToString().ToLowerInvariant() -replace '[\s-]', '') -eq $t)
    } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    $hit = $types | Where-Object {
        $_.description -and (($_.description.ToString().ToLowerInvariant() -replace '[\s-]', '').Contains($t))
    } | Select-Object -First 1
    if ($hit) { return [int]$hit.id }

    return $null
}

function Get-PrinterOSFieldValue {
    # 3DPrinterOS has not published the printer object schema, and it has
    # changed shape between deployments. Rather than hardcode key names that
    # may be wrong for someone else's account, look for the first property
    # whose NAME matches a pattern. Returns $null when nothing matches.
    param($Object, [string]$Pattern)

    if ($null -eq $Object -or $Object -isnot [psobject]) { return $null }
    $p = $Object.PSObject.Properties | Where-Object { $_.Name -match $Pattern } | Select-Object -First 1
    if ($p) { return $p.Value }
    return $null
}

function Get-PrinterOSPrinters {
    # Pulls the account's actual printers once per run and caches them.
    #
    # This replaces the old hand-maintained printer ID map. 3DPrinterOS queues
    # to a specific machine rather than a model pool, so SOME id is required -
    # but asking the operator to copy database ids out of a web UI before the
    # tool works at all is a terrible first-run experience. Poll instead.
    #
    # UNVERIFIED FIELD NAMES: developed against an account with zero printers
    # registered, so the response body was empty and the real key names were
    # never observed. The matching below is deliberately loose, and the raw
    # shape of the first printer is logged once so a real deployment tells us
    # what the schema actually is.
    param([switch]$Force)

    # NOTE: an empty List is falsy in PowerShell, so testing the list itself
    # would re-poll on every single file when the account has no printers.
    if ($null -ne $script:posPrinters -and -not $Force) { return $script:posPrinters }

    $list = New-Object System.Collections.Generic.List[object]
    try {
        $resp = Invoke-PrinterOSChecked -Endpoint 'get_printers_list' -Fields @{}
        if (-not $resp.result) {
            Write-Host ("Could not list 3DPrinterOS printers: {0}" -f $resp.message) -ForegroundColor DarkYellow
            $script:posPrinters = $list
            return $list
        }

        $rows = @($resp.message)

        # Log the raw shape once. This is the line that turns the guesswork
        # above into fact the first time a real account runs this.
        if ($rows.Count -gt 0 -and $rows[0] -is [psobject] -and -not $script:posSchemaLogged) {
            Write-Host ("[3DPrinterOS printer fields: {0}]" -f (($rows[0].PSObject.Properties.Name) -join ', ')) -ForegroundColor DarkGray
            $script:posSchemaLogged = $true
        }

        foreach ($r in $rows) {
            if ($r -isnot [psobject]) { continue }
            $id = Get-PrinterOSFieldValue -Object $r -Pattern '(?i)^(printer_id|id)$'
            if (-not $id) { continue }
            $list.Add([pscustomobject]@{
                Id    = [string]$id
                Name  = [string](Get-PrinterOSFieldValue -Object $r -Pattern '(?i)(name|alias|description|title)')
                Type  = [string](Get-PrinterOSFieldValue -Object $r -Pattern '(?i)(ptype|type_id|printer_type)')
                Model = [string](Get-PrinterOSFieldValue -Object $r -Pattern '(?i)(model|type_name|printer_model)')
                Raw   = $r
            })
        }
    } catch {
        Write-Host ("Could not list 3DPrinterOS printers: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    $script:posPrinters = $list
    return $list
}

function Resolve-PrinterOSPrinterId {
    # Match a filename machine token (P1S, U1, H2D...) against the polled
    # inventory. Order: exact id, then model/name contains, then the printer
    # type id resolved from the same token, then the configured default.
    #
    # Only IDLE-ish printers would be a better target, but status field names
    # are unknown for the same reason as above, so every printer is a
    # candidate and 3DPrinterOS does its own queue admission.
    param([string]$MachineToken)

    $token = ''
    if (-not [string]::IsNullOrWhiteSpace($MachineToken)) {
        $token = ($MachineToken.Trim().ToLowerInvariant() -replace '[\s_-]', '')
    }

    $printers = Get-PrinterOSPrinters

    if ($token -and $printers.Count -gt 0) {
        # 1) the token IS an id (someone typed a real printer id in the filename)
        $hit = $printers | Where-Object { $_.Id -eq $MachineToken.Trim() } | Select-Object -First 1
        if ($hit) { return $hit }

        # 2) model or friendly name contains the token
        $hit = $printers | Where-Object {
            $m = ("{0} {1}" -f $_.Model, $_.Name).ToLowerInvariant() -replace '[\s_-]', ''
            $m -and $m.Contains($token)
        } | Select-Object -First 1
        if ($hit) { return $hit }

        # 3) fall back to printer TYPE - the one lookup we know works - and
        #    find a machine of that class.
        $ptype = Resolve-PrinterOSTypeId -ModelToken $MachineToken
        if ($ptype) {
            $hit = $printers | Where-Object { $_.Type -eq [string]$ptype } | Select-Object -First 1
            if ($hit) { return $hit }
        }
    }

    # 4) explicit operator override always wins over nothing - but only if it
    #    looks like an id. 3DPrinterOS printer ids are numeric; a model token
    #    such as 'P1S' pasted in here reaches print_file and comes back as
    #    'Wrong data given', which reads like a bug in the tool rather than a
    #    typo in a settings box. Catch it here and say so plainly.
    $fb = ([string]$script:posDefaultPrinterId).Trim()
    if (-not [string]::IsNullOrWhiteSpace($fb)) {
        if ($fb -match '^\d+$') {
            return [pscustomobject]@{
                Id = $fb; Name = '(configured default)'
                Type = ''; Model = ''; Raw = $null
            }
        }
        if (-not $script:posBadFallbackWarned) {
            Write-Host ("Fallback printer ID '{0}' is not a 3DPrinterOS printer id." -f $fb) -ForegroundColor DarkYellow
            Write-Host "  That field wants the numeric id of a specific machine, not a model name." -ForegroundColor DarkYellow
            Write-Host "  Clear it on the Settings tab, or paste the id from the printer's URL." -ForegroundColor DarkYellow
            $script:posBadFallbackWarned = $true
        }
    }

    return $null
}

function Send-FileToPrinterOS {
    # /apiglobal/upload is the one endpoint that must be multipart rather than
    # urlencoded, because it carries the file itself.
    param([Parameter(Mandatory=$true)][string]$FilePath)

    Add-Type -AssemblyName System.Net.Http

    Connect-PrinterOS | Out-Null

    $url  = "{0}/apiglobal/upload" -f $script:posBase
    $name = [System.IO.Path]::GetFileName($FilePath)

    $maxRetries = 3
    $retryCount = 0

    while ($true) {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(20)
        $mp = New-Object System.Net.Http.MultipartFormDataContent
        $fs = $null
        try {
            $mp.Add((New-Object System.Net.Http.StringContent($script:posSession)), 'session')
            $mp.Add((New-Object System.Net.Http.StringContent('Watch2Print')), 'upload_soft_name')
            if (-not [string]::IsNullOrWhiteSpace($script:posProject)) {
                $mp.Add((New-Object System.Net.Http.StringContent($script:posProject)), 'project_name')
            }

            $fs = [System.IO.File]::OpenRead($FilePath)
            $sc = New-Object System.Net.Http.StreamContent($fs)
            $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
            $mp.Add($sc, 'file', $name)

            Write-Host ("POST {0}  (multipart, {1})" -f $url, $name)

            $task = $client.PostAsync($url, $mp)
            if (-not $task.Wait([TimeSpan]::FromMinutes(20))) { throw "Upload timed out." }

            $resp = $task.Result
            $text = $resp.Content.ReadAsStringAsync().Result
            if (-not $resp.IsSuccessStatusCode) { throw ("HTTP {0} :: {1}" -f [int]$resp.StatusCode, $text) }

            $json = ($text | ConvertFrom-Json)
            if (-not $json.result) { throw ("Upload rejected: {0}" -f $json.message) }

            return $json
        }
        catch {
            Write-Host ("3DPrinterOS upload failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            if ($retryCount -ge $maxRetries) { throw }
            $retryCount++
            $wait = 30 * [math]::Pow(2, $retryCount - 1)
            Write-Host ("Retrying in {0} s..." -f $wait) -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }
        finally {
            if ($fs)     { $fs.Dispose() }
            if ($mp)     { $mp.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }
}

function Invoke-PrinterOSJob {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    Write-Host ""
    Write-Host "*** New file detected (3DPrinterOS): $FilePath" -ForegroundColor Cyan

    if (-not (Wait-FileStable -Path $FilePath -MaxSeconds 90)) {
        Write-Host "ERROR: File did not stabilize. Skipping." -ForegroundColor Red
        return
    }

    $meta = Parse-JobFileName -FilePath $FilePath

    $machineToken = ''
    if ($meta.ok) { $machineToken = [string]$meta.machineModel }

    # Dry run promises no network, so resolve only against what is already
    # cached plus the configured fallback - never trigger a fresh login here.
    $printer = if ($script:DryRun -and -not $script:posPrinters) {
        if ($script:posDefaultPrinterId) {
            [pscustomobject]@{ Id = $script:posDefaultPrinterId.Trim(); Name = '(configured default)'; Type = ''; Model = ''; Raw = $null }
        } else { $null }
    } else {
        Resolve-PrinterOSPrinterId -MachineToken $machineToken
    }
    $printerId = if ($printer) { $printer.Id } else { $null }

    $qty = 1
    try { if ([int]$script:amount -ge 1) { $qty = [int]$script:amount } } catch { $qty = 1 }

    if ($meta.ok -and $meta.materials.Count -gt 0) {
        Write-Host ("NOTE: {0} material(s) parsed from the filename, but 3DPrinterOS has no material/color tagging in this engine - they are ignored." -f $meta.materials.Count) -ForegroundColor DarkYellow
    }
    if ($meta.ok -and $null -ne $meta.queuePosition) {
        Write-Host "NOTE: rush position parsed from the filename, but 3DPrinterOS has no queue reordering call - it is ignored." -ForegroundColor DarkYellow
    }
    if ($qty -gt 1) {
        Write-Host ("NOTE: 3DPrinterOS has no quantity parameter; {0} copies will be queued as {0} separate print_file calls." -f $qty) -ForegroundColor DarkYellow
    }

    if ($script:DryRun) {
        $pidText = if ($printerId) {
            if ($printer.Name) { "{0}  ({1})" -f $printerId, $printer.Name } else { $printerId }
        } else { 'UNRESOLVED - would upload only, nothing queued' }
        Write-DryRunPlan -FilePath $FilePath -Meta $meta -Steps @(
            ("POST {0}/apiglobal/login             (session cached for the run)" -f $script:posBase),
            ("POST {0}/apiglobal/get_printers_list (inventory, cached for the run)" -f $script:posBase),
            ("POST {0}/apiglobal/upload            file='{1}' project_name='{2}'" -f $script:posBase, [System.IO.Path]::GetFileName($FilePath), $script:posProject),
            ("POST {0}/apiglobal/print_file        printer_id={1}  only_queue=1  x{2}" -f $script:posBase, $pidText, $qty)
        )
        Add-ToHistory -FilePath $FilePath
        return
    }

    try {
        # 1+2) log in and upload
        Write-Host "Uploading to 3DPrinterOS..." -ForegroundColor Yellow
        $uploadResp = Send-FileToPrinterOS -FilePath $FilePath

        $fileId = $null
        try { $fileId = [string]$uploadResp.message.file_id } catch {}
        if ([string]::IsNullOrWhiteSpace($fileId)) {
            Write-Host "ERROR: Upload response missing message.file_id; cannot queue." -ForegroundColor Red
            Write-Host ($uploadResp | ConvertTo-Json -Depth 6) -ForegroundColor DarkGray
            return
        }
        Write-Host ("Upload OK. file_id = {0}" -f $fileId) -ForegroundColor Green

        # NOTE: the old file_update / ptype call lived here and has been
        # removed. Six different parameter shapes were probed against a live
        # account and every one returned "Wrong parameters"; the field it set
        # is not consumed by print_file, so the call bought nothing but a
        # confusing red line in the log. If 3DPrinterOS ever documents the
        # real shape, this is where it goes back.

        # 3) queue it - requires a concrete printer instance, not a model class
        if (-not $printerId) {
            $known = (Get-PrinterOSPrinters).Count
            Write-Host ""
            Write-Host "Uploaded, but not queued - no printer to send it to." -ForegroundColor Yellow
            if ($known -eq 0) {
                Write-Host "  This account has no printers registered with 3DPrinterOS. Files will" -ForegroundColor Yellow
                Write-Host "  keep uploading and can be assigned by hand in the web UI." -ForegroundColor Yellow
            } elseif ([string]::IsNullOrWhiteSpace($machineToken)) {
                Write-Host "  The filename carried no machine token, and no default printer is set." -ForegroundColor Yellow
            } else {
                Write-Host ("  None of the {0} printer(s) on this account matched machine token '{1}'." -f $known, $machineToken) -ForegroundColor Yellow
                Write-Host "  Set a default printer on the Settings tab to catch unmatched files." -ForegroundColor Yellow
            }
            # NOT added to history: nothing was queued, so a retry after the
            # operator fixes the setting should still see this file.
            return
        }

        $label = if ($printer.Name) { ("{0} (id {1})" -f $printer.Name, $printerId) } else { ("id {0}" -f $printerId) }
        Write-Host ("Routing '{0}' -> {1}" -f $machineToken, $label) -ForegroundColor Cyan

        $queued = 0
        for ($c = 1; $c -le $qty; $c++) {
            if ($qty -gt 1) { Write-Host ("Queueing copy {0} of {1}..." -f $c, $qty) -ForegroundColor Yellow }
            else            { Write-Host "Queueing print job..." -ForegroundColor Yellow }

            $q = Invoke-PrinterOSChecked -Endpoint 'print_file' -Fields @{
                file_id    = $fileId
                printer_id = $printerId
                only_queue = 1
            }

            if ($q.result) {
                $queued++
                Write-Host ("Queued OK. job_id = {0}" -f $q.message.job_id) -ForegroundColor Green
            } else {
                Write-Host ("ERROR: print_file rejected: {0}" -f $q.message) -ForegroundColor Red
                if ("$($q.message)" -match '(?i)no rights') {
                    Write-Host ("  Printer id {0} is not on this account. If it came from a stale" -f $printerId) -ForegroundColor Red
                    Write-Host "  default printer setting, clear it and let auto-detect run." -ForegroundColor Red
                    Get-PrinterOSPrinters -Force | Out-Null
                }
                break
            }
        }

        # Only mark the file done if something actually made it into the queue.
        # Recording a failed job here would hide it from every future retry.
        if ($queued -gt 0) { Add-ToHistory -FilePath $FilePath }
    }
    catch {
        Write-Host "ERROR during 3DPrinterOS upload/queue:" -ForegroundColor Red
        Write-HttpErrorBody -ErrorRecord $_ -Source '3DPrinterOS'
    }
}


# =========================================================================
# DISPATCHER
# =========================================================================
# Everything above this point is provider-specific. Everything below is
# shared. Upload-AndQueue keeps its original name so the watch loop reads
# the same as it always did; it just routes to the selected platform now.
# =========================================================================

function Invoke-SimplyPrintDryRun {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    $meta = Parse-JobFileName -FilePath $FilePath
    $size = 0
    try { $size = (Get-Item -LiteralPath $FilePath).Length } catch {}
    $route = if ($size -ge 100MB) { 'chunked (50MB parts)' } else { 'single-shot' }

    $steps = @(
        ("POST {0}  ({1})" -f $script:uploadUrl, $route),
        ("POST {0}  fileId=<from upload> amount={1} group={2}" -f $script:queueUrl, $script:amount, $script:group)
    )
    if ($meta.ok -and $meta.machineModel) {
        $steps += ("GET  {0}/printers/Get  -> resolve for_models from machine token '{1}'" -f $script:apiBase, $meta.machineModel)
    }
    if ($meta.ok -and $meta.materials.Count -gt 0) {
        $steps += ("GET  {0}/queue/GetItem  (poll for gcode analysis, up to 60 s)" -f $script:apiBase)
        $steps += ("POST {0}  material tags x{1}" -f $script:assignTagUrl, $meta.materials.Count)
    }
    if ($meta.ok -and $null -ne $meta.queuePosition) {
        $steps += ("GET  {0}  rush -> priority {1}" -f $script:setOrderUrl, $meta.queuePosition)
    }

    Write-DryRunPlan -FilePath $FilePath -Meta $meta -Steps $steps
    Add-ToHistory -FilePath $FilePath
}

function Upload-AndQueue {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    switch ($script:Platform) {
        'printago' { Invoke-PrintagoJob  -FilePath $FilePath; return }
        'printeros' { Invoke-PrinterOSJob -FilePath $FilePath; return }
        default {
            if ($script:DryRun) { Invoke-SimplyPrintDryRun -FilePath $FilePath; return }
            Invoke-SimplyPrintJob -FilePath $FilePath
            return
        }
    }
}

# =========================
# DEFAULT COLOR MAP (fallback if colormap.json is missing/empty)
# =========================
function Get-DefaultColorMap {
    return @{
        "black"        = @{ name="Black";        hex="#000000" }
        "white"        = @{ name="White";        hex="#FFFFFF" }
        "red"          = @{ name="Red";          hex="#D50000" }
        "green"        = @{ name="Green";        hex="#4CAF50" }
        "blue"         = @{ name="Blue";         hex="#2196F3" }
        "grey"         = @{ name="grey";         hex="#9F9F9F" }
        "gray"         = @{ name="gray";         hex="#9F9F9F" }
        "orange"       = @{ name="Orange";       hex="#FF9800" }
        "yellow"       = @{ name="Yellow";       hex="#FFEB3B" }
        "purple"       = @{ name="Purple";       hex="#800080" }
        "transparent"  = @{ name="Transparent";  hex="#D9DAD1" }
        "natural"      = @{ name="Natural";      hex="#E3E3E3" }
        "bright green" = @{ name="Bright Green"; hex="#66FF00" }
        "teal"         = @{ name="Teal";         hex="#009688" }
        "neon green"   = @{ name="Neon Green";   hex="#2EFF6D" }
        "aqua"         = @{ name="Aqua";         hex="#12685E" }
        "beige"        = @{ name="Beige";        hex="#FFFFFF" }
        "pink"         = @{ name="Pink";         hex="#E91E63" }
    }
}


# =========================
# ENGINE ENTRY POINT
# =========================
# Memory-light recursive enumeration across every configured extension. Uses
# lazy Directory.Enumerate* (strings, not FileInfo objects) with
# per-directory try/catch so a single access-denied subfolder doesn't abort
# the whole walk. Far lighter on RAM than Get-ChildItem -Recurse over a large
# (e.g. Dropbox) tree. Enumerates once per directory and filters in-process
# rather than walking the tree once per extension.
function Get-WatchFilesSafe {
    param([string]$Root)
    $results = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path $Root)) { return $results }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                if (Test-WatchedExtension -Path $f) { $results.Add($f) }
            }
        } catch {}
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) }
        } catch {}
    }
    return $results
}

# Reclaim memory: compact the large-object heap, run a full GC, and ask the OS
# to trim the process working set. Called after big enumerations and on a slow
# idle timer so a long-running watcher doesn't hold a large resident set.
function Invoke-MemoryReclaim {
    if (-not ('W2PMem' -as [type])) {
        try {
            Add-Type -Namespace 'W2P' -Name 'Mem' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(System.IntPtr hProcess);
public static void Trim() { EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle); }
'@ -ErrorAction Stop
        } catch {}
    }
    try { [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce } catch {}
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()
    try { [W2P.Mem]::Trim() } catch {}
}


# Called by the GUI on a background runspace. All configuration arrives via
# $Config (a PSCustomObject). $Sync is a synchronized hashtable whose .Running
# flag lets the GUI stop the loop cleanly. $ColorMap is a hashtable of
# key -> @{ name; hex }. Logging still happens through Write-Host, which the
# GUI host overrides to capture and route by color.
function Start-Watch2PrintEngine {
    param(
        [Parameter(Mandatory=$true)] $Config,
        [Parameter(Mandatory=$true)] $Sync,
        $ColorMap = $null,
        [int] $ScanIntervalSeconds = 1200
    )

    # ---- tiny config accessor: missing / blank properties fall back cleanly
    function Get-Cfg {
        param([string]$Name, $Default = '')
        if ($Config.PSObject.Properties.Name -contains $Name -and $null -ne $Config.$Name) {
            $v = $Config.$Name
            # Single chokepoint for decryption: every caller downstream sees
            # plain text without knowing anything about how it was stored.
            if ($v -is [string] -and (Test-W2PEncrypted $v)) { $v = Unprotect-W2PSecret $v }
            if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { return $Default }
            return $v
        }
        return $Default
    }

    # --- Platform selection -------------------------------------------------
    $script:Platform = ([string](Get-Cfg 'platform' 'simplyprint')).Trim().ToLowerInvariant()
    if ($script:Platform -notin @('simplyprint','printago','printeros')) { $script:Platform = 'simplyprint' }
    $caps = Get-PlatformCaps $script:Platform

    $script:DryRun = $false
    try { $script:DryRun = [bool](Get-Cfg 'dryRun' $false) } catch { $script:DryRun = $false }

    # --- Watched extensions -------------------------------------------------
    $script:WatchExtensions = @(ConvertTo-ExtensionList (Get-Cfg 'watchExtensions' '.gcode'))

    # --- Shared settings ----------------------------------------------------
    $script:watchFolder = [string](Get-Cfg 'watchFolder' '')
    $script:group       = Get-Cfg 'group'  0
    $script:amount      = Get-Cfg 'amount' 1

    $debounceSeconds = 300
    $tmp = 0
    if ([int]::TryParse([string](Get-Cfg 'debounceSeconds' '300'), [ref]$tmp) -and $tmp -gt 0) { $debounceSeconds = $tmp }
    $safetyScanSeconds = 3600
    $tmp = 0
    if ([int]::TryParse([string](Get-Cfg 'safetyScanSeconds' '7200'), [ref]$tmp) -and $tmp -ge 0) { $safetyScanSeconds = $tmp }
    $scanOnStartup = $false
    try { $scanOnStartup = [bool](Get-Cfg 'scanOnStartup' $false) } catch { $scanOnStartup = $false }

    $hf = [string](Get-Cfg 'historyFile' '')
    if (-not [string]::IsNullOrWhiteSpace($hf)) {
        $script:historyFile = $hf
    } else {
        # One history file per platform so switching targets doesn't make the
        # engine think already-sent files were sent to the NEW platform too.
        $script:historyFile = Join-Path $script:watchFolder ("watch2print_history_{0}.txt" -f $script:Platform)

        # On SimplyPrint, adopt the production build's history if we have none
        # of our own. Without this the fork sees an empty history and does a
        # full baseline walk of the whole tree on first run - slow, silent, and
        # completely unnecessary when the answer already exists on disk.
        if ($script:Platform -eq 'simplyprint' -and -not (Test-Path $script:historyFile)) {
            $legacy = Join-Path $script:watchFolder 'simplyprint_history.txt'
            if (Test-Path $legacy) {
                try {
                    Copy-Item -LiteralPath $legacy -Destination $script:historyFile -Force
                    Write-Host "Adopted existing history from simplyprint_history.txt (no baseline needed)." -ForegroundColor Green
                } catch {
                    Write-Host ("Could not copy the existing history file: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
                }
            }
        }
    }

    # Colormap: provided map wins, else built-in defaults. Only SimplyPrint
    # consumes it, but it is always loaded so the GUI tab stays meaningful.
    #
    # This used to be silent, which made a broken map indistinguishable from a
    # working one: every colour quietly became the #D9DAD1 fallback and the
    # only way to notice was to read an upload payload. Say what was loaded.
    $mapSource = 'built-in defaults'
    if ($ColorMap -is [System.Collections.IDictionary] -and $ColorMap.Count -gt 0) {
        $script:W2PColorMap = $ColorMap
        $mapSource = 'colormap.json'
    } else {
        $script:W2PColorMap = Get-DefaultColorMap
        if ($null -ne $ColorMap -and $ColorMap -isnot [System.Collections.IDictionary]) {
            Write-Host ("WARNING: the colour map arrived as {0}, not a lookup table. Using built-in colours." -f $ColorMap.GetType().Name) -ForegroundColor Red
        } elseif ($ColorMap -is [System.Collections.IDictionary]) {
            Write-Host "WARNING: the colour map loaded but is EMPTY. Using built-in colours." -ForegroundColor Red
        }
    }
    Write-Host ("Colours:       {0} loaded from {1}" -f $script:W2PColorMap.Count, $mapSource) -ForegroundColor DarkGray

    # Reset per-run caches.
    $script:FilamentTypesCache = $null
    $script:W2PColorWarned     = @{}
    $script:PrintersCache      = $null
    $script:ModelIndexCache    = $null
    $script:CurrentPassRush    = @{}
    $script:posSession         = $null
    $script:posPrinterTypes    = $null

    # Force TLS 1.2 (older PS 5.1 environments) and skip 100-Continue stalls.
    [Net.ServicePointManager]::SecurityProtocol  = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::Expect100Continue = $false

    # --- Per-platform credentials and endpoints -----------------------------
    $endpointLabel = ''

    switch ($script:Platform) {

        'printago' {
            $script:pgStoreId   = [string](Get-Cfg 'storeIdPrintago'   '')
            $script:pgApiKey    = [string](Get-Cfg 'apiKeyPrintago'    '')
            $script:pgPrinterId = [string](Get-Cfg 'printerIdPrintago' '')
            $script:pgExtraTags = [string](Get-Cfg 'extraTagsPrintago' '')
            # Blank = send no Content-Type on the signed PUT, which is what a
            # GCS V2 URL signed with an empty content type requires.
            $script:pgUploadContentType = [string](Get-Cfg 'uploadContentTypePrintago' '')
            $script:pgModelMap      = [string](Get-Cfg 'modelMapPrintago' '')
            $script:pgOverrideModel = $false
            try { $script:pgOverrideModel = [bool](Get-Cfg 'overrideModelPrintago' $false) } catch {}
            $script:pgSendMaterialTypes = $false
            try { $script:pgSendMaterialTypes = [bool](Get-Cfg 'sendMaterialTypesPrintago' $false) } catch {}
            $script:pgTryMaterialOverride = $false
            try { $script:pgTryMaterialOverride = [bool](Get-Cfg 'tryMaterialOverridePrintago' $false) } catch {}
            $script:pgDumpMaterials = $true
            try { $script:pgDumpMaterials = [bool](Get-Cfg 'dumpMaterialsPrintago' $true) } catch {}
            $script:pgBase      = 'https://api.printago.io'

            if ([string]::IsNullOrWhiteSpace($script:pgStoreId)) {
                Write-Host "ERROR: No Printago store ID set. Enter it on the Settings tab." -ForegroundColor Red
                return
            }
            if ([string]::IsNullOrWhiteSpace($script:pgApiKey)) {
                Write-Host "ERROR: No Printago API key set. Enter it on the Settings tab." -ForegroundColor Red
                return
            }
            $endpointLabel = ("{0}/v1  (store {1})" -f $script:pgBase, $script:pgStoreId)
        }

        'printeros' {
            $script:posUsername         = [string](Get-Cfg 'usernamePrinterOS' '')
            $script:posPassword         = [string](Get-Cfg 'passwordPrinterOS' '')
            $script:posProject          = [string](Get-Cfg 'projectPrinterOS'  '')
            $script:posDefaultPrinterId = [string](Get-Cfg 'defaultPrinterIdPrinterOS' '')

            # Printer inventory is polled from the account at startup rather
            # than hand-mapped in config. Clear any cache from a previous run
            # so switching accounts or hosts cannot serve stale ids.
            $script:posPrinters       = $null
            $script:posBadFallbackWarned = $false
            $script:posPrinterTypes = $null
            $script:posSession      = $null

            $hostSel = ([string](Get-Cfg 'hostPrinterOS' 'cloud')).Trim().ToLowerInvariant()
            if ($hostSel -eq 'acorn') {
                $script:posBase = 'https://acorn.3dprinteros.com'
            } else {
                $script:posBase = 'https://cloud.3dprinteros.com'
            }

            if ([string]::IsNullOrWhiteSpace($script:posUsername)) {
                Write-Host "ERROR: No 3DPrinterOS username set. Enter it on the Settings tab." -ForegroundColor Red
                return
            }
            if ([string]::IsNullOrWhiteSpace($script:posPassword)) {
                Write-Host "ERROR: No 3DPrinterOS password set. Enter it on the Settings tab." -ForegroundColor Red
                return
            }
            $endpointLabel = ("{0}/apiglobal  (user {1})" -f $script:posBase, $script:posUsername)
        }

        default {
            # --- SimplyPrint: unchanged from the original engine -------------
            # The two bases live on DIFFERENT hosts and are both built from the
            # company ID. No trailing slash - endpoint paths are appended.
            #   apiBase   = https://api.simplyprint.io/{companyId}
            #   filesBase = https://files.simplyprint.io/{companyId}
            $companyId = ([string](Get-Cfg 'companyIdSimplyPrint' (Get-Cfg 'companyId' ''))).Trim().Trim('/')

            $derivedApi   = if ($companyId) { "https://api.simplyprint.io/$companyId" }   else { '' }
            $derivedFiles = if ($companyId) { "https://files.simplyprint.io/$companyId" } else { '' }

            $cfgApi   = [string](Get-Cfg 'apiBase'   '')
            $cfgFiles = [string](Get-Cfg 'filesBase' '')
            $script:apiBase   = if ($cfgApi)   { $cfgApi.Trim().TrimEnd('/') }   else { $derivedApi }
            $script:filesBase = if ($cfgFiles) { $cfgFiles.Trim().TrimEnd('/') } else { $derivedFiles }

            if ([string]::IsNullOrWhiteSpace($script:apiBase)) {
                Write-Host "ERROR: No company ID set. Enter it on the Settings tab." -ForegroundColor Red
                return
            }

            $script:apiKey = [string](Get-Cfg 'apiKeySimplyPrint' (Get-Cfg 'apiKey' ''))
            if ([string]::IsNullOrWhiteSpace($script:apiKey)) {
                Write-Host "ERROR: No API key configured. Set it on the Settings tab." -ForegroundColor Red
                return
            }

            $u = 2
            if ([int]::TryParse([string](Get-Cfg 'u1MinMatchScore' '2'), [ref]$u)) { $script:u1MinMatchScore = $u }
            else { $script:u1MinMatchScore = 2 }

            $script:uploadUrl    = "$($script:filesBase)/files/Upload"
            $script:queueUrl     = "$($script:apiBase)/queue/AddItem"
            $script:assignTagUrl = "$($script:apiBase)/tags/Assign"
            $script:setOrderUrl  = "$($script:apiBase)/queue/SetOrder"
            $script:getItemsUrl  = "$($script:apiBase)/queue/GetItems"

            $endpointLabel = $script:apiBase
        }
    }

    # --- Banner -------------------------------------------------------------
    $safetyLabel  = if ($safetyScanSeconds -le 0) { 'off' } else { ('{0} min' -f [math]::Round($safetyScanSeconds/60,1)) }
    $startupLabel = if ($scanOnStartup) { 'on' } else { 'off' }
    $extLabel     = (@($script:WatchExtensions) -join ' ')

    Write-Host ("=== {0} Watcher Starting ===" -f $caps.label) -ForegroundColor Cyan
    if ($script:DryRun) {
        Write-Host "*** DRY RUN ENABLED - nothing will be uploaded or queued ***" -ForegroundColor Magenta
    }
    Write-Host "Watching:      $($script:watchFolder)"
    Write-Host "Extensions:    $extLabel"
    Write-Host "History:       $($script:historyFile)"
    Write-Host "Endpoint:      $endpointLabel"
    Write-Host ("Batch window:  {0} min   Safety re-scan: {1}   Startup scan: {2}" -f ([math]::Round($debounceSeconds/60,1)), $safetyLabel, $startupLabel)

    # Say out loud which features are inert on this platform, so a missing tag
    # later is never a mystery.
    $off = New-Object System.Collections.Generic.List[string]
    if (-not $caps.materialTags) { $off.Add('material/color tags') }
    if (-not $caps.rushPosition) { $off.Add('rush queue positions') }
    if (-not $caps.u1Scoring)    { $off.Add('U1 slot scoring') }
    if (-not $caps.group)        { $off.Add('group') }
    if ($off.Count -gt 0) {
        Write-Host ("Not available on {0}: {1}" -f $caps.label, ($off -join ', ')) -ForegroundColor DarkYellow
    }

    # Pull the 3DPrinterOS printer inventory up front, so routing problems
    # surface at startup instead of on the first file at 2am. Non-fatal: a
    # failure here still leaves uploading (and manual assignment) working.
    if ($script:Platform -eq 'printeros' -and -not $script:DryRun) {
        Write-Host "Polling 3DPrinterOS for available printers..." -ForegroundColor DarkGray
        $inv = Get-PrinterOSPrinters -Force
        if ($inv.Count -eq 0) {
            Write-Host "No printers registered on this 3DPrinterOS account." -ForegroundColor DarkYellow
            Write-Host "  Files will upload and wait for manual assignment in the web UI." -ForegroundColor DarkYellow
        } else {
            Write-Host ("Printers available: {0}" -f $inv.Count) -ForegroundColor Green
            foreach ($p in $inv) {
                $desc = @($p.Name, $p.Model) | Where-Object { $_ } | Select-Object -First 1
                Write-Host ("    id={0,-10} {1}" -f $p.Id, $desc) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($script:watchFolder) -or -not (Test-Path $script:watchFolder)) {
        Write-Host "ERROR: Watch folder is missing or does not exist: '$($script:watchFolder)'" -ForegroundColor Red
        return
    }

    # --- FileSystemWatcher: OS change-notification instead of polling -------
    # FileSystemWatcher.Filter only accepts ONE pattern, so with several
    # extensions in play the filter is widened to everything and the extension
    # test happens in-process when the event is drained.
    $fsw = $null
    try {
        $fsw = New-Object System.IO.FileSystemWatcher
        $fsw.Path                  = $script:watchFolder
        $extArr                    = @($script:WatchExtensions)
        $fsw.Filter                = if ($extArr.Count -eq 1) { '*' + $extArr[0] } else { '*.*' }
        Write-Host ("Watcher filter: '{0}' for [{1}]  (subdirectories: on)" -f $fsw.Filter, $extLabel) -ForegroundColor DarkGray
        $fsw.IncludeSubdirectories = $true
        $fsw.InternalBufferSize    = 65536   # 64KB (max) - fewer dropped events in bursts
        $fsw.NotifyFilter          = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::DirectoryName
        Register-ObjectEvent -InputObject $fsw -EventName Created -SourceIdentifier 'W2P_Created' | Out-Null
        Register-ObjectEvent -InputObject $fsw -EventName Renamed -SourceIdentifier 'W2P_Renamed' | Out-Null
        $fsw.EnableRaisingEvents = $true
    } catch {
        Write-Host "ERROR: Could not start folder watcher: $($_.Exception.Message)" -ForegroundColor Red
        if ($fsw) { $fsw.Dispose() }
        return
    }

    Write-Host "Watcher armed - new files are being captured from now on, even while the checks below run." -ForegroundColor Green
    Write-Host ""

    # --- Load history / baseline -------------------------------------------
    $seen = @{}
    $script:historyStamp = $null
    Write-Host "Loading history from $($script:historyFile)..."
    if (Test-Path $script:historyFile) {
        Read-W2PHistoryLines -Path $script:historyFile | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) { $seen[$_.Trim()] = $true }
        }
    } else {
        Write-Host "No history file found. Baselining current folder to prevent mass upload..." -ForegroundColor Yellow
        Write-Host "(One-off. On a large synced tree this can take a while - progress below.)" -ForegroundColor DarkGray
        $swBase   = [System.Diagnostics.Stopwatch]::StartNew()
        $lastTick = [datetime]::Now
        $existingFiles = New-Object System.Collections.Generic.List[string]
        $stackB = New-Object System.Collections.Generic.Stack[string]
        $stackB.Push($script:watchFolder)
        while ($stackB.Count -gt 0) {
            if (-not $Sync.Running) { Write-Host "Baseline cancelled." -ForegroundColor Yellow; break }
            $dirB = $stackB.Pop()
            try {
                foreach ($fB in [System.IO.Directory]::EnumerateFiles($dirB)) {
                    if (Test-WatchedExtension -Path $fB) { $existingFiles.Add($fB) }
                }
            } catch {}
            try { foreach ($dB in [System.IO.Directory]::EnumerateDirectories($dirB)) { $stackB.Push($dB) } } catch {}
            # Heartbeat so a long walk never looks like a hang.
            if (([datetime]::Now - $lastTick).TotalSeconds -ge 3) {
                Write-Host ("  ...baselining: {0} matching file(s), {1} folder(s) queued, {2}s elapsed" -f `
                            $existingFiles.Count, $stackB.Count, [int]$swBase.Elapsed.TotalSeconds) -ForegroundColor DarkGray
                $lastTick = [datetime]::Now
            }
        }
        $swBase.Stop()
        Write-Host ("Baseline walk finished in {0}s." -f [int]$swBase.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        foreach ($p in $existingFiles) { $seen[$p] = $true }
        try {
            if ($existingFiles.Count -gt 0) {
                Write-W2PHistoryFile -Path $script:historyFile -Lines $existingFiles
                Write-Host "Baseline successfully created. Tracked $($existingFiles.Count) files." -ForegroundColor Green
            } else {
                Write-Host "Baseline finished. No existing matching files found." -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "ERROR: Could not create history file. Check permissions for $($script:historyFile)" -ForegroundColor Red
            Write-Host $_.Exception.Message
        }
        $existingFiles = $null
        Invoke-MemoryReclaim
    }

    # Baseline the stamp so the first merge only picks up genuinely new lines.
    try { $script:historyStamp = (Get-Item -LiteralPath $script:historyFile).LastWriteTimeUtc } catch {}

    Write-Host "Existing files tracked: $($seen.Count)"

    # --- Initial catch-up (OPTIONAL) ---------------------------------------
    # This is a full recursive walk of the watch tree to find files that were
    # added while the app was closed. On a large Dropbox tree that walk is the
    # main startup disk spike, so it only runs when explicitly enabled. When
    # off, new files are still caught live by the watcher (and by the safety
    # re-scan, if enabled).
    if ($scanOnStartup) {
        $initial = New-Object System.Collections.Generic.List[string]
        foreach ($p in (Get-WatchFilesSafe -Root $script:watchFolder)) {
            if ($p -match 'conflicted copy') { continue }
            if (-not $seen.ContainsKey($p)) { $initial.Add($p) }
        }
        if ($initial.Count -gt 0 -and $Sync.Running) {
            $script:CurrentPassRush = @{}
            Write-Host ("=== Initial catch-up: {0} file(s) ===" -f $initial.Count) -ForegroundColor Cyan
            foreach ($path in $initial) {
                if (-not $Sync.Running) { break }
                if (-not $seen.ContainsKey($path)) {
                    try { Upload-AndQueue -FilePath $path } catch { Write-Host "Upload error for $path : $($_.Exception.Message)" -ForegroundColor Red }
                    $seen[$path] = $true
                }
            }
        }
        $initial = $null
        Invoke-MemoryReclaim
    } else {
        Write-Host "Startup scan disabled - watching live for new files only." -ForegroundColor DarkGray
    }

    # The watcher was armed before the baseline, so a file dropped DURING
    # startup may have been swept up as "pre-existing". Those are real arrivals
    # - pull them back out and hand them to the first loop pass.
    $armedNew = New-Object System.Collections.Generic.List[string]
    foreach ($evt in @(Get-Event -ErrorAction SilentlyContinue)) {
        $ep = $null
        try { if ($evt.SourceEventArgs) { $ep = $evt.SourceEventArgs.FullPath } } catch {}
        Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
        if (-not $ep) { continue }
        if (-not (Test-WatchedExtension -Path $ep)) { continue }
        if ($ep -match 'conflicted copy') { continue }
        if (-not $armedNew.Contains($ep)) { $armedNew.Add($ep) }
    }
    if ($armedNew.Count -gt 0) {
        Write-Host ("{0} file(s) arrived during startup - queueing them now." -f $armedNew.Count) -ForegroundColor Cyan
        foreach ($ep in $armedNew) { if ($seen.ContainsKey($ep)) { [void]$seen.Remove($ep) } }
    }

    Write-Host ("Waiting for new files ({0}) - event-driven..." -f $extLabel) -ForegroundColor Green
    Write-Host ""


    # --- Priority-block state ----------------------------------------------
    # The batch window does NOT delay uploads. Files upload immediately as they
    # arrive. The window only defines the priority grouping: the first new file
    # opens a block (resets CurrentPassRush) and every file that arrives within
    # $debounceSeconds joins that same block for rush ordering. When the window
    # lapses, the next file opens a fresh block. (Only SimplyPrint acts on it.)
    $batchDeadline = $null
    $nextSafety    = if ($safetyScanSeconds -gt 0) { (Get-Date).AddSeconds($safetyScanSeconds) } else { [datetime]::MaxValue }
    $nextReclaim   = (Get-Date).AddMinutes(5)
    $nextExtCheck  = (Get-Date).AddSeconds(20)
    $firstPass     = $true
    $eventCount    = 0
    $uploadCount   = 0
    $extWarned     = @{}

    try {
        while ($Sync.Running) {

            # Operator asked for a reload. -Force skips the timestamp gate: an
            # explicit request should act now, not decide the file looks
            # unchanged.
            if ($Sync.ReloadHistory) {
                $Sync.ReloadHistory = $false
                $n = Merge-HistoryFromDisk -Seen $seen -Force
                if ($n -eq 0) { Write-Host "History reloaded: no new entries on disk." -ForegroundColor DarkGray }
            }

            # Close an expired window so the next file starts a new priority block.
            if ($batchDeadline -and (Get-Date) -ge $batchDeadline) { $batchDeadline = $null }

            # Collect this iteration's new candidates (watcher events + safety scan),
            # de-duplicated, then upload each one right away.
            $candidates = New-Object System.Collections.Generic.List[string]
            $candSet    = @{}

            # 0) Files that landed while the engine was still starting up
            if ($firstPass) {
                $firstPass = $false
                foreach ($p in $armedNew) {
                    if ($seen.ContainsKey($p))    { continue }
                    if ($candSet.ContainsKey($p)) { continue }
                    $candidates.Add($p); $candSet[$p] = $true
                }
            }

            # 1) Watcher events. Every single one is logged, including the ones
            # that get dropped and why - silence during a failure is worse than
            # a noisy debug pane, and this all lands in Debug, not Activity.
            foreach ($evt in @(Get-Event -ErrorAction SilentlyContinue)) {
                $path = $null
                $kind = [string]$evt.SourceIdentifier
                try { if ($evt.SourceEventArgs) { $path = $evt.SourceEventArgs.FullPath } } catch {}
                Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
                if (-not $path) { continue }
                $eventCount++
                $leaf = [System.IO.Path]::GetFileName($path)

                if (-not (Test-WatchedExtension -Path $path)) {
                    # Once per extension per run. Enough to explain "why didn't
                    # my file upload", without a line for every stray file.
                    $ux = ''
                    try { $ux = [System.IO.Path]::GetExtension($path).ToLowerInvariant() } catch {}
                    if ($ux -and -not $extWarned.ContainsKey($ux)) {
                        $extWarned[$ux] = $true
                        Write-Host ("event {0}: {1} - ignored, '{2}' is not in the watched list [{3}]. Further '{2}' files will not be logged." -f `
                                    $kind, $leaf, $ux, $extLabel) -ForegroundColor DarkGray
                    }
                    continue
                }
                if ($path -match 'conflicted copy') {
                    Write-Host ("event {0}: {1} - ignored, Dropbox conflicted copy" -f $kind, $leaf) -ForegroundColor DarkGray
                    continue
                }
                if ($seen.ContainsKey($path)) {
                    Write-Host ("event {0}: {1} - ignored, already in history" -f $kind, $leaf) -ForegroundColor DarkGray
                    continue
                }
                if ($candSet.ContainsKey($path)) { continue }

                Write-Host ("event {0}: {1} - accepted" -f $kind, $leaf) -ForegroundColor DarkGray
                $candidates.Add($path); $candSet[$path] = $true
            }

            # 2) Safety re-scan backstop (in case the watcher dropped events).
            # Streamed inline so it never materializes the whole tree - only
            # genuinely-new paths are retained (usually none).
            if ($safetyScanSeconds -gt 0 -and (Get-Date) -ge $nextSafety) {
                # BEFORE the walk, not after: the walk is what bulk-queues
                # anything missing from $seen, so a late merge suppresses
                # nothing until the following cycle.
                [void](Merge-HistoryFromDisk -Seen $seen)
                Write-Host "Safety re-scan..." -ForegroundColor DarkCyan
                $stack = New-Object System.Collections.Generic.Stack[string]
                $stack.Push($script:watchFolder)
                while ($stack.Count -gt 0) {
                    $dir = $stack.Pop()
                    try {
                        foreach ($p in [System.IO.Directory]::EnumerateFiles($dir)) {
                            if (-not (Test-WatchedExtension -Path $p)) { continue }
                            if ($p -match 'conflicted copy') { continue }
                            if ($seen.ContainsKey($p))       { continue }
                            if ($candSet.ContainsKey($p))    { continue }
                            $candidates.Add($p); $candSet[$p] = $true
                        }
                    } catch {}
                    try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) } } catch {}
                }
                $stack = $null
                $nextSafety = (Get-Date).AddSeconds($safetyScanSeconds)
                Invoke-MemoryReclaim
            }

            # 2b) External queue-change monitor (SimplyPrint): flag queue
            # adds/removes this watcher did not perform.
            if ((Get-Date) -ge $nextExtCheck) {
                Watch-ExternalQueueChanges
                $nextExtCheck = (Get-Date).AddSeconds(45)
            }

            # Periodic idle reclaim so the resident set doesn't creep up over time.
            if ((Get-Date) -ge $nextReclaim) {
                Invoke-MemoryReclaim
                $nextReclaim = (Get-Date).AddMinutes(5)
            }

            # 3) Upload each candidate immediately, sharing/opening the priority window.
            foreach ($path in $candidates) {
                if (-not $Sync.Running) { break }
                if ($seen.ContainsKey($path)) { continue }
                if (-not $batchDeadline) {
                    $script:CurrentPassRush = @{}
                    $batchDeadline = (Get-Date).AddSeconds($debounceSeconds)
                    Write-Host ("=== New priority block (files in the next {0} min share priority) ===" -f [math]::Round($debounceSeconds/60,1)) -ForegroundColor Cyan
                }
                try { Upload-AndQueue -FilePath $path; $uploadCount++ } catch { Write-Host "Upload error for $path : $($_.Exception.Message)" -ForegroundColor Red }
                $seen[$path] = $true
            }

            Start-Sleep -Milliseconds 500
        }
    } finally {
        try { $fsw.EnableRaisingEvents = $false } catch {}
        Unregister-Event -SourceIdentifier 'W2P_Created' -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier 'W2P_Renamed' -ErrorAction SilentlyContinue
        try { $fsw.Dispose() } catch {}
    }

    Write-Host ("=== Watcher stopped - {0} event(s) seen, {1} file(s) sent this run ===" -f $eventCount, $uploadCount) -ForegroundColor Cyan
}
