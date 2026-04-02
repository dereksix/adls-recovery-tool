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
$scriptVersion = "5.0.0"

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

# Setup output folder
if (-not $OutputFolder -or $OutputFolder -eq '') {
    $OutputFolder = Join-Path $scriptDir "ADLSRecovery_$($startTime.ToString('yyyyMMdd_HHmmss'))"
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

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
                    -Path $acct.Path -MaxCount 100 -ContinuationToken $token -ErrorAction Stop

                if (-not $deleted -or $deleted.Count -eq 0) { break }

                foreach ($d in $deleted) {
                    $deletedOn = $d.DeletedOn
                    $deletedOnStr = if ($deletedOn) { $deletedOn.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
                    $contentLength = try { $d.ContentLength } catch { 0 }
                    if (-not $contentLength) { $contentLength = 0 }

                    $retentionDaysNum = try { $d.RemainingRetentionDays } catch { $null }
                    $remainingDays = ''
                    $urgency = 'UNKNOWN'
                    if ($retentionDaysNum) {
                        $remainingDays = $retentionDaysNum
                        $urgency = if ($retentionDaysNum -le 3) { 'CRITICAL' } elseif ($retentionDaysNum -le 7) { 'WARNING' } else { 'OK' }
                    } elseif ($deletedOn) {
                        $daysSince = [math]::Floor(((Get-Date -AsUTC) - $deletedOn).TotalDays)
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
                    MaxCount          = 100
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

                    $deletedOn = $blob.DeletedOn
                    $deletedOnStr = if ($deletedOn) { $deletedOn.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
                    $contentLength = try { $blob.Length } catch { 0 }
                    if (-not $contentLength) { $contentLength = 0 }

                    $retentionDaysNum = try { $blob.RemainingDaysBeforePermanentDelete } catch { $null }
                    $remainingDays = ''
                    $urgency = 'UNKNOWN'
                    if ($retentionDaysNum) {
                        $remainingDays = $retentionDaysNum
                        $urgency = if ($retentionDaysNum -le 3) { 'CRITICAL' } elseif ($retentionDaysNum -le 7) { 'WARNING' } else { 'OK' }
                    } elseif ($deletedOn) {
                        $daysSince = [math]::Floor(((Get-Date -AsUTC) - $deletedOn).TotalDays)
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
#  STEP 4 — RESTORE (parallel across accounts)
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Step 4: Restoring deleted items..." -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

$restoreJob = $validAccounts | ForEach-Object -Parallel {
    $acct = $_
    $sinceDateFilter = $using:sinceDateFilter
    $outputFolder = $using:OutputFolder
    $progressDir = $using:progressDir

    $name = $acct.StorageAccountName
    $storageType = $acct.StorageType
    $acctLabel = "${name}_$($acct.FileSystem)"
    $logFile = Join-Path $outputFolder "${acctLabel}_restore.log"
    $csvFile = Join-Path $outputFolder "${acctLabel}_restore.csv"
    $progressFile = Join-Path $progressDir "${acctLabel}_restore.txt"

    Import-Module Az.Storage -MinimumVersion 4.9.0 -Force

    function Write-RestoreLog {
        param([string]$Message, [string]$Level = 'INFO')
        $ts = (Get-Date -AsUTC).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $entry = "[$ts UTC] [$Level] $Message"
        $entry | Out-File -FilePath $logFile -Append -Encoding UTF8
    }

    $ctx = New-AzStorageContext -StorageAccountName $name -StorageAccountKey $acct.StorageAccountKey -ErrorAction Stop
    Write-RestoreLog "Connected to $name ($storageType)"

    $restored = 0
    $failed = 0
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($storageType -eq 'ADLS Gen2') {
        # ── ADLS Gen2 restore ────────────────────────────────────────
        $token = $null
        $toRestore = [System.Collections.Generic.List[object]]::new()

        do {
            try {
                $deleted = Get-AzDataLakeGen2DeletedItem -Context $ctx -FileSystem $acct.FileSystem `
                    -Path $acct.Path -MaxCount 100 -ContinuationToken $token -ErrorAction Stop

                if (-not $deleted -or $deleted.Count -eq 0) { break }

                foreach ($d in $deleted) {
                    if ($sinceDateFilter -and $d.DeletedOn -and $d.DeletedOn -lt $sinceDateFilter) { continue }
                    $toRestore.Add($d)
                }

                $token = $deleted[$deleted.Count - 1].ContinuationToken
            } catch {
                Write-RestoreLog "Error during discovery: $_" -Level ERROR
                break
            }
        } while (-not [string]::IsNullOrEmpty($token))

        Write-RestoreLog "Found $($toRestore.Count) items to restore"
        $totalToRestore = $toRestore.Count
        "restoring|0|$totalToRestore" | Out-File -FilePath $progressFile -Force -Encoding UTF8

        $i = 0
        foreach ($item in $toRestore) {
            $i++
            $itemPath = $item.Path
            $deletedOn = $item.DeletedOn
            $deletedOnStr = if ($deletedOn) { $deletedOn.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
            $contentLength = try { $item.ContentLength } catch { 0 }
            if (-not $contentLength) { $contentLength = 0 }

            try {
                $null = $item | Restore-AzDataLakeGen2DeletedItem -ErrorAction Stop
                $restored++
                Write-RestoreLog "[$i/$($toRestore.Count)] RESTORED $itemPath" -Level SUCCESS
                $results.Add([PSCustomObject]@{
                    StorageAccount = $name
                    StorageType    = 'ADLS Gen2'
                    FileSystem     = $acct.FileSystem
                    Path           = $itemPath
                    DeletedOn      = $deletedOnStr
                    SizeBytes      = $contentLength
                    Status         = 'Restored'
                    Error          = ''
                })
            } catch {
                $failed++
                Write-RestoreLog "[$i/$($toRestore.Count)] FAILED $itemPath - $_" -Level ERROR
                $results.Add([PSCustomObject]@{
                    StorageAccount = $name
                    StorageType    = 'ADLS Gen2'
                    FileSystem     = $acct.FileSystem
                    Path           = $itemPath
                    DeletedOn      = $deletedOnStr
                    SizeBytes      = $contentLength
                    Status         = 'Failed'
                    Error          = $_.ToString()
                })
            }
            "restoring|$i|$totalToRestore" | Out-File -FilePath $progressFile -Force -Encoding UTF8
        }

    } else {
        # ── Blob Storage restore ─────────────────────────────────────
        $token = $null
        $toRestore = [System.Collections.Generic.List[object]]::new()

        do {
            try {
                $blobParams = @{
                    Container      = $acct.FileSystem
                    Context        = $ctx
                    IncludeDeleted = $true
                    MaxCount       = 100
                    ErrorAction    = 'Stop'
                }
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
                    if (-not $blob.IsDeleted) { continue }
                    if ($sinceDateFilter -and $blob.DeletedOn -and $blob.DeletedOn -lt $sinceDateFilter) { continue }
                    $toRestore.Add($blob)
                }

                $token = $blobResult[$blobResult.Count - 1].ContinuationToken
            } catch {
                Write-RestoreLog "Error during discovery: $_" -Level ERROR
                break
            }
        } while (-not [string]::IsNullOrEmpty($token))

        Write-RestoreLog "Found $($toRestore.Count) deleted blobs to restore"
        $totalToRestore = $toRestore.Count
        "restoring|0|$totalToRestore" | Out-File -FilePath $progressFile -Force -Encoding UTF8

        $i = 0
        foreach ($blob in $toRestore) {
            $i++
            $blobName = $blob.Name
            $deletedOn = $blob.DeletedOn
            $deletedOnStr = if ($deletedOn) { $deletedOn.ToString('yyyy-MM-dd HH:mm:ss UTC') } else { '(unknown)' }
            $contentLength = try { $blob.Length } catch { 0 }
            if (-not $contentLength) { $contentLength = 0 }

            try {
                $blob.BlobBaseClient.Undelete()
                $restored++
                Write-RestoreLog "[$i/$($toRestore.Count)] RESTORED $blobName" -Level SUCCESS
                $results.Add([PSCustomObject]@{
                    StorageAccount = $name
                    StorageType    = 'Blob'
                    FileSystem     = $acct.FileSystem
                    Path           = $blobName
                    DeletedOn      = $deletedOnStr
                    SizeBytes      = $contentLength
                    Status         = 'Restored'
                    Error          = ''
                })
            } catch {
                $failed++
                Write-RestoreLog "[$i/$($toRestore.Count)] FAILED $blobName - $_" -Level ERROR
                $results.Add([PSCustomObject]@{
                    StorageAccount = $name
                    StorageType    = 'Blob'
                    FileSystem     = $acct.FileSystem
                    Path           = $blobName
                    DeletedOn      = $deletedOnStr
                    SizeBytes      = $contentLength
                    Status         = 'Failed'
                    Error          = $_.ToString()
                })
            }
            "restoring|$i|$totalToRestore" | Out-File -FilePath $progressFile -Force -Encoding UTF8
        }
    }

    # Mark restore complete
    "done|$restored|$failed" | Out-File -FilePath $progressFile -Force -Encoding UTF8

    # Write restore CSV
    if ($results.Count -gt 0) {
        $results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
    }

    Write-RestoreLog "Complete: $restored restored, $failed failed"

    [PSCustomObject]@{
        StorageAccount = $name
        StorageType    = $storageType
        FileSystem     = $acct.FileSystem
        Attempted      = $toRestore.Count
        Restored       = $restored
        Failed         = $failed
        LogFile        = $logFile
        CsvFile        = $csvFile
    }
} -ThrottleLimit 10 -AsJob

# Poll restore progress
$completedRestores = @{}
while ($restoreJob.State -eq 'Running') {
    $grandDone = 0
    $grandTotal = 0
    foreach ($acct in $validAccounts) {
        $acctLabel = "$($acct.StorageAccountName)_$($acct.FileSystem)"
        $pFile = Join-Path $progressDir "${acctLabel}_restore.txt"
        if (Test-Path $pFile) {
            $pContent = (Get-Content $pFile -Raw -ErrorAction SilentlyContinue)
            if ($pContent) {
                $parts = $pContent.Trim() -split '\|'
                $status = $parts[0]
                if ($status -eq 'done' -and -not $completedRestores[$acctLabel]) {
                    $completedRestores[$acctLabel] = $true
                    $doneRestored = if ($parts.Count -gt 1) { $parts[1] } else { '0' }
                    $doneFailed = if ($parts.Count -gt 2) { $parts[2] } else { '0' }
                    $color = if ([int]$doneFailed -gt 0) { 'Yellow' } else { 'Green' }
                    Write-Host "    [DONE] $($acct.StorageAccountName) / $($acct.FileSystem) — $doneRestored restored, $doneFailed failed" -ForegroundColor $color
                } elseif ($status -eq 'restoring') {
                    $current = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
                    $total = if ($parts.Count -gt 2) { [int]$parts[2] } else { 0 }
                    $grandDone += $current
                    $grandTotal += $total
                }
            }
        }
    }
    # Add completed accounts to totals
    foreach ($acct in $validAccounts) {
        $acctLabel = "$($acct.StorageAccountName)_$($acct.FileSystem)"
        if ($completedRestores[$acctLabel]) {
            $pFile = Join-Path $progressDir "${acctLabel}_restore.txt"
            $pContent = (Get-Content $pFile -Raw -ErrorAction SilentlyContinue)
            if ($pContent) {
                $parts = $pContent.Trim() -split '\|'
                $doneR = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
                $doneF = if ($parts.Count -gt 2) { [int]$parts[2] } else { 0 }
                $grandDone += ($doneR + $doneF)
                $grandTotal += ($doneR + $doneF)
            }
        }
    }
    $pct = if ($grandTotal -gt 0) { [math]::Min(100, [math]::Round(($grandDone / $grandTotal) * 100)) } else { 0 }
    Write-Progress -Activity "Restoring deleted items" -Status "$grandDone of $grandTotal items ($pct%)" -PercentComplete $pct
    Start-Sleep -Milliseconds 500
}

# Show any remaining completions
foreach ($acct in $validAccounts) {
    $acctLabel = "$($acct.StorageAccountName)_$($acct.FileSystem)"
    if ($completedRestores[$acctLabel]) { continue }
    $pFile = Join-Path $progressDir "${acctLabel}_restore.txt"
    if (Test-Path $pFile) {
        $pContent = (Get-Content $pFile -Raw -ErrorAction SilentlyContinue)
        if ($pContent) {
            $parts = $pContent.Trim() -split '\|'
            $doneRestored = if ($parts.Count -gt 1) { $parts[1] } else { '0' }
            $doneFailed = if ($parts.Count -gt 2) { $parts[2] } else { '0' }
            $color = if ([int]$doneFailed -gt 0) { 'Yellow' } else { 'Green' }
            Write-Host "    [DONE] $($acct.StorageAccountName) / $($acct.FileSystem) — $doneRestored restored, $doneFailed failed" -ForegroundColor $color
        }
    }
}

Write-Progress -Activity "Restoring deleted items" -Completed
$restoreResults = @($restoreJob | Receive-Job -Wait -AutoRemoveJob)

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
