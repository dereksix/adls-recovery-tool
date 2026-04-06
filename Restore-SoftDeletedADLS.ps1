<#
.SYNOPSIS
    Azure Storage Data Recovery — Interactive script for restoring soft-deleted items.

.DESCRIPTION
    Supports BOTH storage account types:
      - ADLS Gen2 (hierarchical namespace enabled)
      - Blob Storage (flat namespace)

    Auto-detects which type each account is and uses the correct cmdlets.

    Reads storage accounts from ADLSRestore-Config.ps1, checks prerequisites,
    then walks you through: Inventory (what was deleted) -> Restore (get it back).

    Handles multiple storage accounts in parallel. Produces log files and CSV
    reports for each account plus a combined summary.

    Requires PowerShell 7.2+ and Az.Storage module (auto-installs if missing).

.EXAMPLE
    .\Restore-SoftDeletedADLS.ps1
#>

# ══════════════════════════════════════════════════════════════════════════════
#  SETUP
# ══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$startTime = Get-Date -AsUTC
$scriptVersion = "6.0.0"

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
    else { return "$bytes B" }
}

# ══════════════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Azure Storage Data Recovery Tool  v$scriptVersion" -ForegroundColor Cyan
Write-Host "    Supports ADLS Gen2 and Blob Storage" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
#  PREREQUISITES CHECK
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "  Checking prerequisites..." -ForegroundColor Yellow
Write-Host ""

# PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "  [FAIL] PowerShell 7.2+ is required. You have: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-Host "         Download from: https://aka.ms/powershell-release?tag=stable" -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}
Write-Host "  [OK] PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

# Az.Storage module
$azMod = Get-Module -ListAvailable Az.Storage | Sort-Object Version -Descending | Select-Object -First 1
if (-not $azMod -or $azMod.Version -lt [Version]"4.9.0") {
    Write-Host "  [--] Az.Storage module not found or too old. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name Az.Storage -MinimumVersion 4.9.0 -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
        $azMod = Get-Module -ListAvailable Az.Storage | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host "  [OK] Az.Storage $($azMod.Version) installed" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] Could not install Az.Storage: $_" -ForegroundColor Red
        Write-Host "         Run manually: Install-Module -Name Az.Storage -Force" -ForegroundColor Red
        Write-Host ""
        Read-Host "  Press Enter to exit"
        exit 1
    }
} else {
    Write-Host "  [OK] Az.Storage $($azMod.Version)" -ForegroundColor Green
}

Import-Module Az.Storage -MinimumVersion 4.9.0 -Force

# ══════════════════════════════════════════════════════════════════════════════
#  LOAD CONFIG
# ══════════════════════════════════════════════════════════════════════════════

$configPath = Join-Path $scriptDir "ADLSRestore-Config.ps1"

if (-not (Test-Path $configPath)) {
    Write-Host ""
    Write-Host "  [FAIL] Config file not found: $configPath" -ForegroundColor Red
    Write-Host "         Place ADLSRestore-Config.ps1 in the same folder as this script." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# Source the config file to load $Accounts, $SinceDate, $OutputFolder
. $configPath

# Filter out empty accounts (unfilled template rows)
$Accounts = @($Accounts | Where-Object {
    $_.StorageAccountName -and $_.StorageAccountKey -and $_.FileSystem -and $_.Path
})

if ($Accounts.Count -eq 0) {
    Write-Host ""
    Write-Host "  [FAIL] No accounts configured." -ForegroundColor Red
    Write-Host "         Open ADLSRestore-Config.ps1 and fill in at least one account." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

Write-Host "  [OK] Config loaded: $($Accounts.Count) storage account(s)" -ForegroundColor Green

# Parse optional settings
$sinceDateFilter = $null
if ($SinceDate -and $SinceDate -ne '') {
    try {
        $sinceDateFilter = [DateTime]::Parse($SinceDate).ToUniversalTime()
        Write-Host "  [OK] Date filter: items deleted since $($sinceDateFilter.ToString('yyyy-MM-dd'))" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] Could not parse SinceDate '$SinceDate' — ignoring, will scan all items" -ForegroundColor Yellow
    }
}

$beforeDateFilter = $null
if ($BeforeDate -and $BeforeDate -ne '') {
    try {
        # Set to end of day so "before 2026-03-20" includes the entire day
        $beforeDateFilter = [DateTime]::Parse($BeforeDate).ToUniversalTime().Date.AddDays(1)
        Write-Host "  [OK] Date filter: items deleted on or before $([DateTime]::Parse($BeforeDate).ToString('yyyy-MM-dd'))" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] Could not parse BeforeDate '$BeforeDate' — ignoring" -ForegroundColor Yellow
    }
}

if ($sinceDateFilter -and $beforeDateFilter -and $sinceDateFilter -ge $beforeDateFilter) {
    Write-Host "  [WARN] SinceDate is after BeforeDate — date range is empty, no items will match" -ForegroundColor Yellow
}

# Setup output folder
if (-not $OutputFolder -or $OutputFolder -eq '') {
    $OutputFolder = Join-Path $scriptDir "ADLSRecovery_$($startTime.ToString('yyyyMMdd_HHmmss'))"
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

# Parse parallelism settings (with hard caps)
if (-not $MaxConcurrency -or $MaxConcurrency -lt 1) { $MaxConcurrency = 64 }
$MaxConcurrency = [math]::Min($MaxConcurrency, 256)
if (-not $MaxRequestsPerSecond -or $MaxRequestsPerSecond -lt 1) { $MaxRequestsPerSecond = 500 }
$MaxRequestsPerSecond = [math]::Min($MaxRequestsPerSecond, 2000)
if (-not $MaxRetries -or $MaxRetries -lt 0) { $MaxRetries = 3 }
# Per-worker minimum delay (ms) to enforce the RPS ceiling
$script:WorkerDelayMs = [math]::Max(0, [math]::Ceiling(($MaxConcurrency / $MaxRequestsPerSecond) * 1000))
Write-Host "  [OK] Parallelism: $MaxConcurrency workers, ${MaxRequestsPerSecond} req/sec cap, $MaxRetries retries" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════════════════════
#  SHOW CONFIGURED ACCOUNTS
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Storage accounts to process:" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

$acctIndex = 0
foreach ($acct in $Accounts) {
    $acctIndex++
    Write-Host "    [$acctIndex] $($acct.StorageAccountName) / $($acct.FileSystem) / $($acct.Path)"
}

Write-Host ""
Write-Host "  Output folder: $OutputFolder"
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1 — TEST CONNECTIONS & DETECT STORAGE TYPE
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Step 1: Testing connections and detecting storage type..." -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

$validAccounts = [System.Collections.Generic.List[hashtable]]::new()

foreach ($acct in $Accounts) {
    $name = $acct.StorageAccountName
    try {
        $ctx = New-AzStorageContext -StorageAccountName $name -StorageAccountKey $acct.StorageAccountKey -ErrorAction Stop

        # Detect storage type: try ADLS Gen2 (HNS) first, fall back to Blob
        $storageType = 'Unknown'
        try {
            $null = Get-AzDataLakeGen2ChildItem -Context $ctx -FileSystem $acct.FileSystem -Path $acct.Path -MaxCount 1 -ErrorAction Stop
            $storageType = 'ADLS Gen2'
        } catch {
            $errMsg = $_.ToString()
            if ($errMsg -match 'hierarchical namespace' -or $errMsg -match 'HierarchicalNamespaceNotEnabled' -or $errMsg -match 'FilesystemNotFound' -eq $false) {
                # Not HNS — try Blob Storage
                try {
                    $null = Get-AzStorageContainer -Name $acct.FileSystem -Context $ctx -ErrorAction Stop
                    $storageType = 'Blob'
                } catch {
                    throw "Could not access container '$($acct.FileSystem)': $_"
                }
            } else {
                # It IS HNS but path might be empty or not exist yet — that's OK
                $storageType = 'ADLS Gen2'
            }
        }

        $acct['StorageType'] = $storageType
        Write-Host "    [OK] $name ($storageType)" -ForegroundColor Green
        $validAccounts.Add($acct)
    } catch {
        Write-Host "    [FAIL] $name — $_" -ForegroundColor Red
        Write-Host "           Skipping this account. Check the name and key in the config." -ForegroundColor Yellow
    }
}

if ($validAccounts.Count -eq 0) {
    Write-Host ""
    Write-Host "  No accounts connected successfully. Check your config and try again." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

$adlsCount = ($validAccounts | Where-Object { $_.StorageType -eq 'ADLS Gen2' }).Count
$blobCount = ($validAccounts | Where-Object { $_.StorageType -eq 'Blob' }).Count

Write-Host ""
Write-Host "  $($validAccounts.Count) of $($Accounts.Count) accounts connected." -ForegroundColor Green
if ($adlsCount -gt 0) { Write-Host "    ADLS Gen2:    $adlsCount" -ForegroundColor Green }
if ($blobCount -gt 0)  { Write-Host "    Blob Storage: $blobCount" -ForegroundColor Green }
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2 — INVENTORY (scan all accounts for deleted items)
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Step 2: Scanning for deleted items..." -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

$progressDir = Join-Path $OutputFolder "_progress"
if (-not (Test-Path $progressDir)) { New-Item -ItemType Directory -Path $progressDir -Force | Out-Null }

$invJob = $validAccounts | ForEach-Object -Parallel {
    $acct = $_
    $sinceDateFilter = $using:sinceDateFilter
    $beforeDateFilter = $using:beforeDateFilter
    $outputFolder = $using:OutputFolder
    $progressDir = $using:progressDir

    $name = $acct.StorageAccountName
    $storageType = $acct.StorageType
    $acctLabel = "${name}_$($acct.FileSystem)"
    $logFile = Join-Path $outputFolder "${acctLabel}_inventory.log"
    $csvFile = Join-Path $outputFolder "${acctLabel}_inventory.csv"
    $progressFile = Join-Path $progressDir "${acctLabel}_inv.txt"

    Import-Module Az.Storage -MinimumVersion 4.9.0 -Force

    $ctx = New-AzStorageContext -StorageAccountName $name -StorageAccountKey $acct.StorageAccountKey -ErrorAction Stop

    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    $errors = @()

    if ($storageType -eq 'ADLS Gen2') {
        # ── ADLS Gen2 inventory ──────────────────────────────────────
        $token = $null
        do {
            try {
                $deleted = Get-AzDataLakeGen2DeletedItem -Context $ctx -FileSystem $acct.FileSystem `
                    -Path $acct.Path -MaxCount 5000 -ContinuationToken $token -ErrorAction Stop

                if (-not $deleted -or $deleted.Count -eq 0) { break }

                foreach ($d in $deleted) {
                    try {
                        $deletedOn = $d.DeletedOn
                        if ($sinceDateFilter -and $deletedOn -and $deletedOn -lt $sinceDateFilter) { continue }
                        if ($beforeDateFilter -and $deletedOn -and $deletedOn -ge $beforeDateFilter) { continue }
                        $deletedOnStr = if ($deletedOn) { $deletedOn.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
                        $contentLength = try { $d.ContentLength } catch { 0 }
                        if (-not $contentLength) { $contentLength = 0 }
                        $retentionDaysNum = try { $d.RemainingDaysBeforePermanentDelete } catch { $null }
                        $remainingDays = ''
                        $urgency = 'UNKNOWN'
                        if ($retentionDaysNum) {
                            $remainingDays = $retentionDaysNum
                            $urgency = if ($retentionDaysNum -le 3) { 'CRITICAL' } elseif ($retentionDaysNum -le 7) { 'WARNING' } else { 'OK' }
                        } elseif ($deletedOn) {
                            $daysSince = [math]::Floor(([DateTimeOffset]::UtcNow - ([DateTimeOffset]$deletedOn)).TotalDays)
                            $remainingDays = "(deleted ${daysSince}d ago)"
                        }

                        $items.Add([PSCustomObject]@{
                            StorageAccount   = $name
                            StorageType      = 'ADLS Gen2'
                            FileSystem       = $acct.FileSystem
                            Path             = $d.Path
                            IsDirectory      = if ($d.IsDirectory) { $true } else { $false }
                            ItemType         = if ($d.Path -match '_delta_log') { '_delta_log' } else { 'data' }
                            DeletedOn        = $deletedOnStr
                            RemainingDays    = $remainingDays
                            RetentionUrgency = $urgency
                            SizeBytes        = $contentLength
                            DeletionId       = try { $d.DeletionId } catch { '' }
                        })
                    } catch {
                        $errors += "Item error on $($d.Path): $_"
                    }
                }

                "scanning|$($items.Count)" | Out-File -FilePath $progressFile -Force -Encoding UTF8
                $token = $deleted[$deleted.Count - 1].ContinuationToken
            } catch {
                $errors += $_.ToString()
                break
            }
        } while (-not [string]::IsNullOrEmpty($token))

    } else {
        # ── Blob Storage inventory ───────────────────────────────────
        $token = $null
        do {
            try {
                $blobParams = @{
                    Container         = $acct.FileSystem
                    Context           = $ctx
                    IncludeDeleted    = $true
                    MaxCount          = 5000
                    ErrorAction       = 'Stop'
                }
                # Scope to prefix if path is not root
                $pathPrefix = $acct.Path.Trim('/')
                if ($pathPrefix -and $pathPrefix -ne '') {
                    $blobParams['Prefix'] = $pathPrefix
                }
                if ($token) {
                    $blobParams['ContinuationToken'] = $token
                }

                $blobResult = Get-AzStorageBlob @blobParams

                if (-not $blobResult -or $blobResult.Count -eq 0) { break }

                foreach ($blob in $blobResult) {
                    # Only process deleted blobs
                    if (-not $blob.IsDeleted) { continue }

                    try {
                        $deletedOn = $blob.DeletedOn
                        if ($sinceDateFilter -and $deletedOn -and $deletedOn -lt $sinceDateFilter) { continue }
                        if ($beforeDateFilter -and $deletedOn -and $deletedOn -ge $beforeDateFilter) { continue }
                        $deletedOnStr = if ($deletedOn) { $deletedOn.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
                        $contentLength = try { $blob.Length } catch { 0 }
                        if (-not $contentLength) { $contentLength = 0 }

                        $retentionDaysNum = try { $blob.RemainingDaysBeforePermanentDelete } catch { $null }
                        $remainingDays = ''
                        $urgency = 'UNKNOWN'
                        if ($retentionDaysNum) {
                            $remainingDays = $retentionDaysNum
                            $urgency = if ($retentionDaysNum -le 3) { 'CRITICAL' } elseif ($retentionDaysNum -le 7) { 'WARNING' } else { 'OK' }
                        } elseif ($deletedOn) {
                            $daysSince = [math]::Floor(([DateTimeOffset]::UtcNow - ([DateTimeOffset]$deletedOn)).TotalDays)
                            $remainingDays = "(deleted ${daysSince}d ago)"
                        }

                        $items.Add([PSCustomObject]@{
                            StorageAccount   = $name
                            StorageType      = 'Blob'
                            FileSystem       = $acct.FileSystem
                            Path             = $blob.Name
                            IsDirectory      = $false
                            ItemType         = if ($blob.Name -match '_delta_log') { '_delta_log' } else { 'data' }
                            DeletedOn        = $deletedOnStr
                            RemainingDays    = $remainingDays
                            RetentionUrgency = $urgency
                            SizeBytes        = $contentLength
                            DeletionId       = ''
                        })
                    } catch {
                        $errors += "Item error on $($blob.Name): $_"
                    }
                }

                "scanning|$($items.Count)" | Out-File -FilePath $progressFile -Force -Encoding UTF8
                $token = $blobResult[$blobResult.Count - 1].ContinuationToken
            } catch {
                $errors += $_.ToString()
                break
            }
        } while (-not [string]::IsNullOrEmpty($token))
    }

    # Mark inventory complete
    "done|$($items.Count)" | Out-File -FilePath $progressFile -Force -Encoding UTF8

    # Write per-account CSV
    if ($items.Count -gt 0) {
        $items | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
    }

    # Write per-account log
    $logContent = @(
        "Account: $name / $($acct.FileSystem) / $($acct.Path) ($storageType)"
        "Scanned: $(Get-Date -AsUTC -Format 'yyyy-MM-dd HH:mm:ss UTC')"
        "Items found: $($items.Count)"
        if ($errors.Count -gt 0) { "Errors: $($errors -join '; ')" }
        ""
        ($items | Format-Table -AutoSize | Out-String)
    ) -join "`n"
    $logContent | Out-File -FilePath $logFile -Encoding UTF8 -Force

    [PSCustomObject]@{
        StorageAccount = $name
        StorageType    = $storageType
        FileSystem     = $acct.FileSystem
        Path           = $acct.Path
        ItemCount      = $items.Count
        TotalSizeBytes = ($items | Measure-Object -Property SizeBytes -Sum).Sum
        Critical       = ($items | Where-Object { $_.RetentionUrgency -eq 'CRITICAL' }).Count
        Warning        = ($items | Where-Object { $_.RetentionUrgency -eq 'WARNING' }).Count
        Errors         = $errors -join '; '
        CsvFile        = $csvFile
        Items          = $items
    }
} -ThrottleLimit 10 -AsJob

# Poll inventory progress
$completedAccounts = @{}
while ($invJob.State -eq 'Running') {
    foreach ($acct in $validAccounts) {
        $acctLabel = "$($acct.StorageAccountName)_$($acct.FileSystem)"
        if ($completedAccounts[$acctLabel]) { continue }
        $pFile = Join-Path $progressDir "${acctLabel}_inv.txt"
        if (Test-Path $pFile) {
            $pContent = (Get-Content $pFile -Raw -ErrorAction SilentlyContinue)
            if ($pContent) {
                $parts = $pContent.Trim() -split '\|'
                $status = $parts[0]
                $count = if ($parts.Count -gt 1) { $parts[1] } else { '0' }
                if ($status -eq 'done') {
                    $completedAccounts[$acctLabel] = $true
                    Write-Host "    [DONE] $($acct.StorageAccountName) / $($acct.FileSystem) — $count items found" -ForegroundColor Green
                }
            }
        }
    }
    $doneCount = $completedAccounts.Count
    $pct = if ($validAccounts.Count -gt 0) { [math]::Round(($doneCount / $validAccounts.Count) * 100) } else { 0 }
    Write-Progress -Activity "Scanning for deleted items" -Status "$doneCount of $($validAccounts.Count) accounts scanned ($pct%)" -PercentComplete $pct
    Start-Sleep -Milliseconds 500
}

# Show any remaining completions
foreach ($acct in $validAccounts) {
    $acctLabel = "$($acct.StorageAccountName)_$($acct.FileSystem)"
    if ($completedAccounts[$acctLabel]) { continue }
    $pFile = Join-Path $progressDir "${acctLabel}_inv.txt"
    if (Test-Path $pFile) {
        $pContent = (Get-Content $pFile -Raw -ErrorAction SilentlyContinue)
        if ($pContent) {
            $parts = $pContent.Trim() -split '\|'
            $count = if ($parts.Count -gt 1) { $parts[1] } else { '0' }
            Write-Host "    [DONE] $($acct.StorageAccountName) / $($acct.FileSystem) — $count items found" -ForegroundColor Green
        }
    }
}

Write-Progress -Activity "Scanning for deleted items" -Completed
$allInventory = @($invJob | Receive-Job -Wait -AutoRemoveJob)

# ══════════════════════════════════════════════════════════════════════════════
#  INVENTORY RESULTS
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    INVENTORY RESULTS" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

$totalItems = 0
$totalSize = 0
$totalCritical = 0
$totalWarning = 0
$hasErrors = $false

foreach ($inv in $allInventory) {
    $sizeStr = if ($inv.TotalSizeBytes) { Format-Size $inv.TotalSizeBytes } else { "0 B" }
    $totalItems += $inv.ItemCount
    if ($inv.TotalSizeBytes) { $totalSize += $inv.TotalSizeBytes }
    $totalCritical += $inv.Critical
    $totalWarning += $inv.Warning

    $color = if ($inv.Errors) { 'Red' } elseif ($inv.ItemCount -eq 0) { 'Yellow' } else { 'Green' }
    $typeLabel = if ($inv.StorageType) { " ($($inv.StorageType))" } else { '' }

    Write-Host "    $($inv.StorageAccount) / $($inv.FileSystem)$typeLabel" -ForegroundColor $color
    Write-Host "      Deleted items: $($inv.ItemCount)  |  Size: $sizeStr"

    if ($inv.Critical -gt 0) {
        Write-Host "      CRITICAL: $($inv.Critical) items expiring in 3 days or less!" -ForegroundColor Red
    }
    if ($inv.Warning -gt 0) {
        Write-Host "      WARNING:  $($inv.Warning) items expiring in 7 days or less" -ForegroundColor Yellow
    }
    if ($inv.Errors) {
        Write-Host "      ERROR:    $($inv.Errors)" -ForegroundColor Red
        $hasErrors = $true
    }
    Write-Host ""
}

Write-Host "  ────────────────────────────────────────────────────────────"
Write-Host "    TOTAL: $totalItems deleted items  |  $(Format-Size $totalSize)"
if ($totalCritical -gt 0) {
    Write-Host "    $totalCritical items need IMMEDIATE action (expiring in 3 days or less)" -ForegroundColor Red
}
Write-Host "  ────────────────────────────────────────────────────────────"
Write-Host ""
Write-Host "  Inventory CSVs saved to: $OutputFolder" -ForegroundColor Green
Write-Host ""

if ($totalItems -eq 0) {
    Write-Host "  No deleted items found across any account." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Possible reasons:" -ForegroundColor Yellow
    Write-Host "    - Soft delete may not be enabled on the storage accounts" -ForegroundColor Yellow
    Write-Host "    - Retention period may have expired for the deleted items" -ForegroundColor Yellow
    Write-Host "    - The configured paths may not contain deleted data" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3 — ASK TO PROCEED WITH RESTORE
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Step 3: Ready to restore?" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This will restore $totalItems deleted items across $($validAccounts.Count) account(s)."
Write-Host ""
Write-Host "    [Y] Yes, restore everything"
Write-Host "    [N] No, just keep the inventory reports and exit"
Write-Host ""

$choice = ''
while ($choice -notin @('Y', 'N')) {
    $input = Read-Host "  Enter Y or N"
    if ($input) { $choice = $input.Trim().ToUpper() }
}

if ($choice -eq 'N') {
    Write-Host ""
    Write-Host "  No changes made. Review the inventory CSVs in:" -ForegroundColor Yellow
    Write-Host "    $OutputFolder" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4 — RESTORE (parallel within each account)
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Step 4: Restoring deleted items ($MaxConcurrency parallel)..." -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

$restoreResults = @()

foreach ($acct in $validAccounts) {
    $acctName   = $acct.StorageAccountName
    $acctKey    = $acct.StorageAccountKey
    $storageType = $acct.StorageType
    $fileSystem = $acct.FileSystem
    $acctLabel  = "${acctName}_${fileSystem}"
    $logFile    = Join-Path $OutputFolder "${acctLabel}_restore.log"
    $csvFile    = Join-Path $OutputFolder "${acctLabel}_restore.csv"

    function Write-RestoreLog([string]$Message, [string]$Level = 'INFO') {
        $ts = (Get-Date -AsUTC).ToString('yyyy-MM-dd HH:mm:ss.fff')
        "[$ts UTC] [$Level] $Message" | Out-File -FilePath $logFile -Append -Encoding UTF8
    }

    $ctx = New-AzStorageContext -StorageAccountName $acctName -StorageAccountKey $acctKey -ErrorAction Stop
    Write-RestoreLog "Connected to $acctName ($storageType)"
    Write-Host "    $acctName / $fileSystem ($storageType)" -ForegroundColor Cyan

    # ── Resume support: detect previously restored items ─────────────────
    $alreadyRestored = [System.Collections.Generic.HashSet[string]]::new()
    if (Test-Path $logFile) {
        Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -match '\[SUCCESS\] \[\d+/\d+\] RESTORED (.+)$') {
                [void]$alreadyRestored.Add($Matches[1])
            }
        }
        if ($alreadyRestored.Count -gt 0) {
            Write-Host "      Resuming: skipping $($alreadyRestored.Count) already-restored items" -ForegroundColor Yellow
            Write-RestoreLog "Resume: $($alreadyRestored.Count) items previously restored — skipping"
        }
    }

    if ($storageType -eq 'ADLS Gen2') {
        # ── ADLS Gen2: Enumerate ─────────────────────────────────────────
        Write-Host "      Enumerating deleted items..." -NoNewline
        $toRestore = [System.Collections.Generic.List[hashtable]]::new()
        $token = $null
        do {
            try {
                $page = Get-AzDataLakeGen2DeletedItem -Context $ctx -FileSystem $fileSystem `
                    -Path $acct.Path -MaxCount 5000 -ContinuationToken $token -ErrorAction Stop
                if (-not $page -or $page.Count -eq 0) { break }
                foreach ($d in $page) {
                    if ($sinceDateFilter -and $d.DeletedOn -and $d.DeletedOn -lt $sinceDateFilter) { continue }
                    if ($beforeDateFilter -and $d.DeletedOn -and $d.DeletedOn -ge $beforeDateFilter) { continue }
                    $p = $d.Path
                    if ($alreadyRestored.Contains($p)) { continue }
                    $did = try { $d.DeletionId } catch { '' }
                    $don = if ($d.DeletedOn) { $d.DeletedOn.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
                    $sz  = try { if ($d.ContentLength) { $d.ContentLength } else { 0 } } catch { 0 }
                    $toRestore.Add(@{
                        Path       = $p
                        DeletionId = $did
                        DeletedOn  = $don
                        SizeBytes  = $sz
                    })
                }
                Write-Host "`r      Enumerating deleted items... $($toRestore.Count) found" -NoNewline
                $token = $page[$page.Count - 1].ContinuationToken
            } catch {
                Write-RestoreLog "Enumeration error: $_" -Level ERROR
                Write-Host ""
                Write-Host "      [ERROR] Enumeration failed: $_" -ForegroundColor Red
                break
            }
        } while (-not [string]::IsNullOrEmpty($token))
        Write-Host ""
        Write-RestoreLog "Found $($toRestore.Count) items to restore"

        if ($toRestore.Count -eq 0) {
            Write-Host "      Nothing to restore." -ForegroundColor Yellow
            $restoreResults += [PSCustomObject]@{
                StorageAccount = $acctName; StorageType = $storageType; FileSystem = $fileSystem
                Attempted = 0; Restored = 0; Failed = 0; LogFile = $logFile; CsvFile = $csvFile
            }
            continue
        }

        # ── ADLS Gen2: Parallel restore ──────────────────────────────────
        $totalItems = $toRestore.Count
        Write-Host "      Restoring $totalItems items ($MaxConcurrency parallel workers, adaptive throttle)..."
        $restoreStart = Get-Date
        $restoredCount = 0
        $failedCount = 0
        $throttledCount = 0

        # Shared throttle state across all workers: [0]=hitCount, [1]=lastHitEpochMs
        # When ANY worker gets a 429, all workers see it and back off.
        $throttleState = [long[]]::new(2)

        $toRestore | ForEach-Object -Parallel {
            $item       = $_
            $sName      = $using:acctName
            $sKey       = $using:acctKey
            $fs         = $using:fileSystem
            $maxRetries = $using:MaxRetries
            $thr        = $using:throttleState
            $baseDelay  = $using:WorkerDelayMs

            Import-Module Az.Storage -MinimumVersion 4.9.0
            $c = New-AzStorageContext -StorageAccountName $sName -StorageAccountKey $sKey

            # ── Rate limiting + adaptive pacing ──────────────────────────
            # Hard floor: enforce MaxRequestsPerSecond ceiling
            if ($baseDelay -gt 0) {
                Start-Sleep -Milliseconds ($baseDelay + (Get-Random -Maximum ([math]::Max(1, $baseDelay / 2))))
            } else {
                Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 50)
            }
            # Soft adaptive: if recent throttling detected, ALL workers back off more
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $msSinceHit = $now - $thr[1]
            if ($thr[0] -gt 0 -and $msSinceHit -lt 60000) {
                $delay = [math]::Min(10000, $thr[0] * 300 + (Get-Random -Maximum 500))
                Start-Sleep -Milliseconds $delay
            }

            $status = 'Failed'
            $errMsg = ''
            $wasThrottled = $false
            for ($att = 1; $att -le ($maxRetries + 1); $att++) {
                try {
                    Restore-AzDataLakeGen2DeletedItem -Context $c -FileSystem $fs `
                        -DeletedPath $item.Path -DeletionId $item.DeletionId -ErrorAction Stop
                    $status = 'Restored'
                    break
                } catch {
                    $errMsg = $_.ToString()
                    if ($att -le $maxRetries -and $errMsg -match '429|503|throttl|busy|SlowDown|ServerBusy') {
                        $wasThrottled = $true
                        # Signal ALL workers to slow down
                        [System.Threading.Interlocked]::Increment([ref]$thr[0])
                        $thr[1] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        # Per-retry exponential backoff + jitter
                        $backoff = [math]::Min(60000, [math]::Pow(2, $att) * 1000 + (Get-Random -Maximum 2000))
                        Start-Sleep -Milliseconds $backoff
                    } else { break }
                }
            }

            # Decay throttle pressure after sustained success (no hits for 30s)
            if (-not $wasThrottled -and $thr[0] -gt 0) {
                $quiet = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $thr[1]
                if ($quiet -gt 30000) {
                    $current = $thr[0]
                    if ($current -gt 0) {
                        [System.Threading.Interlocked]::CompareExchange([ref]$thr[0], [math]::Max(0, $current - 1), $current) | Out-Null
                    }
                }
            }

            $errOut = if ($status -eq 'Failed') { $errMsg } else { '' }
            [PSCustomObject]@{
                StorageAccount = $sName; StorageType = 'ADLS Gen2'; FileSystem = $fs
                Path = $item.Path; DeletedOn = $item.DeletedOn; SizeBytes = $item.SizeBytes
                Status = $status; Error = $errOut
                WasThrottled = $wasThrottled
            }
        } -ThrottleLimit $MaxConcurrency | ForEach-Object {
            # Main thread: log results and track progress as they stream in
            $r = $_
            if ($r.Status -eq 'Restored') { $restoredCount++ } else { $failedCount++ }
            if ($r.WasThrottled) { $throttledCount++ }
            $idx = $restoredCount + $failedCount
            $level  = if ($r.Status -eq 'Restored') { 'SUCCESS' } else { 'ERROR' }
            $detail = if ($r.Status -eq 'Restored') { "RESTORED $($r.Path)" } else { "FAILED $($r.Path) - $($r.Error)" }
            Write-RestoreLog "[$idx/$totalItems] $detail" -Level $level

            if ($idx % 200 -eq 0 -or $idx -eq $totalItems -or $r.Status -eq 'Failed') {
                $elapsed = (Get-Date) - $restoreStart
                $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($idx / $elapsed.TotalSeconds, 1) } else { 0 }
                $pct  = [math]::Round($idx / $totalItems * 100, 1)
                $eta  = if ($rate -gt 0) { [TimeSpan]::FromSeconds(($totalItems - $idx) / $rate).ToString('hh\:mm\:ss') } else { '--:--:--' }
                $thrLabel = if ($throttledCount -gt 0) { " | Throttled:$throttledCount" } else { '' }
                Write-Progress -Activity "Restoring $acctName/$fileSystem" `
                    -Status "[$idx/$totalItems] $pct% | $rate/sec | ETA $eta | OK:$restoredCount Fail:$failedCount$thrLabel" `
                    -PercentComplete ([math]::Min(100, [int]$pct))
            }
            $r  # pass through to CSV
        } | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

        Write-Progress -Activity "Restoring $acctName/$fileSystem" -Completed
        $restoreDuration = (Get-Date) - $restoreStart
        Write-RestoreLog "Complete: $restoredCount restored, $failedCount failed in $($restoreDuration.ToString('hh\:mm\:ss'))"

        $color = if ($failedCount -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "      Done: $restoredCount restored, $failedCount failed ($($restoreDuration.ToString('hh\:mm\:ss')))" -ForegroundColor $color
        Write-Host ""

        $restoreResults += [PSCustomObject]@{
            StorageAccount = $acctName; StorageType = $storageType; FileSystem = $fileSystem
            Attempted = $totalItems; Restored = $restoredCount; Failed = $failedCount
            LogFile = $logFile; CsvFile = $csvFile
        }

    } else {
        # ── Blob Storage: Enumerate ──────────────────────────────────────
        Write-Host "      Enumerating deleted blobs..." -NoNewline
        $toRestore = [System.Collections.Generic.List[hashtable]]::new()
        $token = $null
        do {
            try {
                $blobParams = @{
                    Container = $fileSystem; Context = $ctx; IncludeDeleted = $true
                    MaxCount = 5000; ErrorAction = 'Stop'
                }
                $prefix = $acct.Path.Trim('/')
                if ($prefix -and $prefix -ne '') { $blobParams['Prefix'] = $prefix }
                if ($token) { $blobParams['ContinuationToken'] = $token }

                $page = Get-AzStorageBlob @blobParams
                if (-not $page -or $page.Count -eq 0) { break }

                foreach ($blob in $page) {
                    if (-not $blob.IsDeleted) { continue }
                    if ($sinceDateFilter -and $blob.DeletedOn -and $blob.DeletedOn -lt $sinceDateFilter) { continue }
                    if ($beforeDateFilter -and $blob.DeletedOn -and $blob.DeletedOn -ge $beforeDateFilter) { continue }
                    $bName = $blob.Name
                    if ($alreadyRestored.Contains($bName)) { continue }
                    $don = if ($blob.DeletedOn) { $blob.DeletedOn.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
                    $sz  = try { if ($blob.Length) { $blob.Length } else { 0 } } catch { 0 }
                    $toRestore.Add(@{
                        Name      = $bName
                        DeletedOn = $don
                        SizeBytes = $sz
                    })
                }
                Write-Host "`r      Enumerating deleted blobs... $($toRestore.Count) found" -NoNewline
                $token = $page[$page.Count - 1].ContinuationToken
            } catch {
                Write-RestoreLog "Enumeration error: $_" -Level ERROR
                Write-Host ""
                Write-Host "      [ERROR] Enumeration failed: $_" -ForegroundColor Red
                break
            }
        } while (-not [string]::IsNullOrEmpty($token))
        Write-Host ""
        Write-RestoreLog "Found $($toRestore.Count) deleted blobs to restore"

        if ($toRestore.Count -eq 0) {
            Write-Host "      Nothing to restore." -ForegroundColor Yellow
            $restoreResults += [PSCustomObject]@{
                StorageAccount = $acctName; StorageType = $storageType; FileSystem = $fileSystem
                Attempted = 0; Restored = 0; Failed = 0; LogFile = $logFile; CsvFile = $csvFile
            }
            continue
        }

        # ── Blob Storage: Parallel restore ───────────────────────────────
        $totalItems = $toRestore.Count
        Write-Host "      Restoring $totalItems blobs ($MaxConcurrency parallel workers, adaptive throttle)..."
        $restoreStart = Get-Date
        $restoredCount = 0
        $failedCount = 0
        $throttledCount = 0

        # Shared throttle state across all workers: [0]=hitCount, [1]=lastHitEpochMs
        $throttleState = [long[]]::new(2)

        $toRestore | ForEach-Object -Parallel {
            $item       = $_
            $sName      = $using:acctName
            $sKey       = $using:acctKey
            $fs         = $using:fileSystem
            $maxRetries = $using:MaxRetries
            $thr        = $using:throttleState
            $baseDelay  = $using:WorkerDelayMs

            Import-Module Az.Storage -MinimumVersion 4.9.0
            $c = New-AzStorageContext -StorageAccountName $sName -StorageAccountKey $sKey

            # ── Rate limiting + adaptive pacing ──────────────────────────
            if ($baseDelay -gt 0) {
                Start-Sleep -Milliseconds ($baseDelay + (Get-Random -Maximum ([math]::Max(1, $baseDelay / 2))))
            } else {
                Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 50)
            }
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $msSinceHit = $now - $thr[1]
            if ($thr[0] -gt 0 -and $msSinceHit -lt 60000) {
                $delay = [math]::Min(10000, $thr[0] * 300 + (Get-Random -Maximum 500))
                Start-Sleep -Milliseconds $delay
            }

            $status = 'Failed'
            $errMsg = ''
            $wasThrottled = $false
            for ($att = 1; $att -le ($maxRetries + 1); $att++) {
                try {
                    # Create blob client directly via SDK and undelete
                    $cred = [Azure.Storage.StorageSharedKeyCredential]::new($sName, $sKey)
                    $uri  = [Uri]::new("https://${sName}.blob.core.windows.net/${fs}/$($item.Name)")
                    $blobClient = [Azure.Storage.Blobs.Specialized.BlobBaseClient]::new($uri, $cred)
                    $blobClient.Undelete()
                    $status = 'Restored'
                    break
                } catch {
                    $errMsg = $_.ToString()
                    if ($att -le $maxRetries -and $errMsg -match '429|503|throttl|busy|SlowDown|ServerBusy') {
                        $wasThrottled = $true
                        [System.Threading.Interlocked]::Increment([ref]$thr[0])
                        $thr[1] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        $backoff = [math]::Min(60000, [math]::Pow(2, $att) * 1000 + (Get-Random -Maximum 2000))
                        Start-Sleep -Milliseconds $backoff
                    } else { break }
                }
            }

            # Decay throttle pressure after sustained success
            if (-not $wasThrottled -and $thr[0] -gt 0) {
                $quiet = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $thr[1]
                if ($quiet -gt 30000) {
                    $current = $thr[0]
                    if ($current -gt 0) {
                        [System.Threading.Interlocked]::CompareExchange([ref]$thr[0], [math]::Max(0, $current - 1), $current) | Out-Null
                    }
                }
            }

            $errOut = if ($status -eq 'Failed') { $errMsg } else { '' }
            [PSCustomObject]@{
                StorageAccount = $sName; StorageType = 'Blob'; FileSystem = $fs
                Path = $item.Name; DeletedOn = $item.DeletedOn; SizeBytes = $item.SizeBytes
                Status = $status; Error = $errOut
                WasThrottled = $wasThrottled
            }
        } -ThrottleLimit $MaxConcurrency | ForEach-Object {
            $r = $_
            if ($r.Status -eq 'Restored') { $restoredCount++ } else { $failedCount++ }
            if ($r.WasThrottled) { $throttledCount++ }
            $idx = $restoredCount + $failedCount
            $level  = if ($r.Status -eq 'Restored') { 'SUCCESS' } else { 'ERROR' }
            $detail = if ($r.Status -eq 'Restored') { "RESTORED $($r.Path)" } else { "FAILED $($r.Path) - $($r.Error)" }
            Write-RestoreLog "[$idx/$totalItems] $detail" -Level $level

            if ($idx % 200 -eq 0 -or $idx -eq $totalItems -or $r.Status -eq 'Failed') {
                $elapsed = (Get-Date) - $restoreStart
                $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($idx / $elapsed.TotalSeconds, 1) } else { 0 }
                $pct  = [math]::Round($idx / $totalItems * 100, 1)
                $eta  = if ($rate -gt 0) { [TimeSpan]::FromSeconds(($totalItems - $idx) / $rate).ToString('hh\:mm\:ss') } else { '--:--:--' }
                $thrLabel = if ($throttledCount -gt 0) { " | Throttled:$throttledCount" } else { '' }
                Write-Progress -Activity "Restoring $acctName/$fileSystem" `
                    -Status "[$idx/$totalItems] $pct% | $rate/sec | ETA $eta | OK:$restoredCount Fail:$failedCount$thrLabel" `
                    -PercentComplete ([math]::Min(100, [int]$pct))
            }
            $r
        } | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

        Write-Progress -Activity "Restoring $acctName/$fileSystem" -Completed
        $restoreDuration = (Get-Date) - $restoreStart
        Write-RestoreLog "Complete: $restoredCount restored, $failedCount failed in $($restoreDuration.ToString('hh\:mm\:ss'))"

        $color = if ($failedCount -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "      Done: $restoredCount restored, $failedCount failed ($($restoreDuration.ToString('hh\:mm\:ss')))" -ForegroundColor $color
        Write-Host ""

        $restoreResults += [PSCustomObject]@{
            StorageAccount = $acctName; StorageType = $storageType; FileSystem = $fileSystem
            Attempted = $totalItems; Restored = $restoredCount; Failed = $failedCount
            LogFile = $logFile; CsvFile = $csvFile
        }
    }
}

# Clean up progress files
Remove-Item -Path $progressDir -Recurse -Force -ErrorAction SilentlyContinue

# ══════════════════════════════════════════════════════════════════════════════
#  FINAL SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

$endTime = Get-Date -AsUTC
$duration = $endTime - $startTime

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    RESTORE COMPLETE" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))"
Write-Host ""

$grandRestored = 0
$grandFailed = 0

foreach ($r in $restoreResults) {
    $grandRestored += $r.Restored
    $grandFailed += $r.Failed

    $color = if ($r.Failed -gt 0) { 'Yellow' } else { 'Green' }
    $typeLabel = if ($r.StorageType) { " ($($r.StorageType))" } else { '' }
    Write-Host "    $($r.StorageAccount) / $($r.FileSystem)$typeLabel" -ForegroundColor $color
    Write-Host "      Restored: $($r.Restored)  |  Failed: $($r.Failed)  |  Log: $($r.LogFile)"
    Write-Host ""
}

Write-Host "  ────────────────────────────────────────────────────────────"
Write-Host "    TOTAL RESTORED: $grandRestored" -ForegroundColor Green
if ($grandFailed -gt 0) {
    Write-Host "    TOTAL FAILED:   $grandFailed  (check logs for details)" -ForegroundColor Red
}
Write-Host "  ────────────────────────────────────────────────────────────"
Write-Host ""
Write-Host "  All logs and CSVs saved to: $OutputFolder" -ForegroundColor Green
Write-Host ""
Read-Host "  Press Enter to exit"
