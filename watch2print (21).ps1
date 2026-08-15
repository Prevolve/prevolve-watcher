# =========================
# SimplyPrint watch2print (PS 5.1 compatible)
# New .gcode (including subdirectories) -> Upload -> Add to Queue (+ filename-based tags)
# Vibed by Dave - created: 01-09-2026
# =========================
# Color Map current as of: 07-16-2026
# =========================
# Dual Material Support Added: 02-12-2026
# Persistent History Added: 02-20-2026
# JSON Config Implementation Added: 02-20-2026
# Material Resolution Improved: 02-24-2026
# Two-Step Tag Assignment Added: 02-26-2026
# Dynamic Nozzle/Extruder Math Added: 02-27-2026
# Default Queue Fallback Fix Added: 02-27-2026
# Exponential Backoff Added: 03-04-2026
# File Parsing Logic Improved: 03-13-2026
# Custom Tag Bloat Removed: 03-13-2026
# Double Underscore Crash Fix: 03-16-2026
# Dynamic Multi-Material (1-4) Support: 04-06-2026
# 100MB Guardrail Added: 04-06-2026 (replaced 07-19-2026 by chunked upload, see below)
# Rush Queue Positioning (-N suffix) Added: 05-22-2026
# Rush Priority FIFO (insert below earlier priority jobs): 06-17-2026
# Rush Rule B - Aged Priority Blocks (old block untouched, new block sorted below): 06-17-2026
# Cleanup: parse filename once per file; scan before first sleep: 06-19-2026
# U1 (04-13 to 07-16-2026, iterated): hardcoded slots -> materialData-driven best-guess
#   matcher (scored color+family, $u1MinMatchScore threshold, unmatched slots warned).
#   Tag addressing follows the file's analysis shape (validated 07-16-2026): slots with
#   a nozzle field -> nozzle=slot, ext=0; without -> nozzle=0, ext=slot. Width required.
#   Obsolete toggles/poison-pill removed; U1 on PATH A, Bambu/AMS on PATH B.
# Chunked upload for files >=100MB (50MB parts, non-rotating token): 07-19-2026
# =========================

# === LOAD CONFIGURATION ===
$configFile = "P:\Dropbox\Prevolve Dropbox\David Chrobuck\automation\simplyprint_config.json"

# Automatically fix the hidden ".txt" extension if Notepad added it
if (Test-Path "$configFile.txt") {
    Rename-Item -Path "$configFile.txt" -NewName "simplyprint_config.json" -Force
}

if (-not (Test-Path $configFile)) {
    Write-Host "ERROR: Config file not found at $configFile" -ForegroundColor Red
    Write-Host "Please check the automation folder and ensure the file exists."
    Exit
}

# Parse the JSON file into variables
$config      = Get-Content -Raw $configFile | ConvertFrom-Json
$apiBase     = $config.apiBase
$filesBase   = $config.filesBase
$apiKey      = $config.apiKey
$watchFolder = $config.watchFolder
$group       = $config.group
$amount      = $config.amount

# Dynamically set the history file to live inside the watch folder
$historyFile = "$watchFolder\simplyprint_history.txt"

# === ENDPOINTS ===
$uploadUrl    = "$filesBase/files/Upload"
$queueUrl     = "$apiBase/queue/AddItem"
$assignTagUrl = "$apiBase/tags/Assign"
$setOrderUrl  = "$apiBase/queue/SetOrder"
$getItemsUrl  = "$apiBase/queue/GetItems"

# U1 min match confidence: +2 color match, +2 family match per slot.
# 4 = exact only, 2 = one signal needed (default), 0 = accept anything.
# Slots scoring below the threshold are left untagged (warned in log).
$u1MinMatchScore = 2

Write-Host "=== SimplyPrint Watcher Starting ==="
Write-Host "Loaded Config: $configFile"
Write-Host "Watching:      $watchFolder"
Write-Host "History:       $historyFile"
Write-Host ""

# Force TLS 1.2 for older PS 5.1 environments
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Avoid long “100-Continue” stalls on some networks/proxies
[Net.ServicePointManager]::Expect100Continue = $false

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

function Get-FilamentTypes {
    if ($script:FilamentTypesCache) { return $script:FilamentTypesCache }

    $url  = "$apiBase/filament/type/Get"
    $resp = Invoke-RestMethod -Method Get -Uri $url -Headers @{ "X-API-KEY" = $apiKey; "accept" = "application/json" }

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

    $map = @{
        "black"  = @{ name="Black";  hex="#000000" }
        "white"  = @{ name="White";  hex="#FFFFFF" }
        "red"    = @{ name="Red";    hex="#D50000" }
        "green"  = @{ name="Green";  hex="#4CAF50" }
        "blue"   = @{ name="Blue";   hex="#2196F3" }
        "grey"   = @{ name="grey";   hex="#9F9F9F" }
        "gray"   = @{ name="gray";   hex="#9F9F9F" }
        "orange" = @{ name="Orange"; hex="#FF9800" }
        "yellow" = @{ name="Yellow"; hex="#FFEB3B" }
        "purple" = @{ name="Purple"; hex="#800080" }
        "transparent" = @{ name="Transparent"; hex="#D9DAD1" }
        "natural" = @{ name="Natural"; hex="#E3E3E3" }
        "bright green" = @{ name="Bright Green"; hex="#66FF00" }
        "teal" = @{ name="Teal"; hex="#009688" }
        "neon green" = @{ name="Neon Green"; hex="#2EFF6D" }
        "aqua" = @{ name="Aqua"; hex="#12685E" }
        "beige" = @{ name="Beige"; hex="#FFFFFF" }	# beige prints white so we just code it in as white
        "pink"  = @{ name="Pink";  hex="#E91E63" }

    }

    $key = $c.ToLowerInvariant()
    if ($map.ContainsKey($key)) {
        return $map[$key]
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

function Upload-AndQueue {
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
            $FilePath | Out-File -FilePath $historyFile -Append -Encoding UTF8
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
# MAIN LOOP
# =========================

$seen = @{}

Write-Host "Loading history from $historyFile..."
if (Test-Path $historyFile) {
    Get-Content $historyFile | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) {
            $seen[$_.Trim()] = $true
        }
    }
} else {
    Write-Host "No history file found. Baselining current folder to prevent mass upload..."
    $existingFiles = @()
    
    Get-ChildItem -Path $watchFolder -Filter "*.gcode" -File -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        $seen[$_.FullName] = $true
        $existingFiles += $_.FullName
    }

    try {
        if ($existingFiles.Count -gt 0) {
            $existingFiles | Out-File -FilePath $historyFile -Encoding UTF8 -Force
            Write-Host "Baseline successfully created. Tracked $($existingFiles.Count) files." -ForegroundColor Green
        } else {
            Write-Host "Baseline finished. No existing .gcode files found." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "ERROR: Could not create history file. Check permissions for $historyFile" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
}

Write-Host "Existing .gcode tracked:" $seen.Count
Write-Host "Waiting for new .gcode files..."
Write-Host ""

while ($true) {

    # New scan pass = a new "batch". Forget the previous pass's rush items so that
    # everything already in the queue is treated as the (untouched) OLD priority
    # block, and only files added in THIS pass are sorted into the new block.
    $script:CurrentPassRush = @{}

    Get-ChildItem -Path $watchFolder -Filter "*.gcode" -File -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        
        if ($_.FullName -match "conflicted copy") { return } 
        
        if (-not $seen.ContainsKey($_.FullName)) {
            Upload-AndQueue -FilePath $_.FullName
            $seen[$_.FullName] = $true
        }
    }

    # Wait for the next pass. (Scan happens first, above, so files already present
    # when the script starts are picked up immediately instead of after a 20-min wait.)
    Start-Sleep -Seconds 1200
}