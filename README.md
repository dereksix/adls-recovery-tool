# ADLS Gen2 Data Recovery Tool

A production-ready PowerShell utility for recovering soft-deleted files from Azure Data Lake Storage Gen2 (hierarchical namespace enabled) storage accounts.

## The Problem

Azure publishes the `Get-AzDataLakeGen2DeletedItem` and `Restore-AzDataLakeGen2DeletedItem` cmdlets, but provides no robust tooling around them. Teams facing a data loss incident are left writing ad-hoc scripts that commonly suffer from:

- **No pagination** — only the first page of deleted items is retrieved, silently leaving thousands of files unrecovered
- **No error handling** — a single failed restore kills the entire run
- **Broken date parsing** — Azure CLI returns JSON strings, not DateTime objects, causing filter comparisons to fail silently
- **No visibility** — no progress tracking, no logging, no way to know what was recovered vs what was missed
- **Sequential execution** — processing multiple storage accounts one at a time when they could run in parallel

This tool solves all of that.

## What It Does

- **Scans** all configured storage accounts in parallel for soft-deleted items
- **Reports** an inventory with retention status (critical/warning/OK), item counts, sizes, and deletion timeline
- **Restores** all recoverable items with per-item error handling — one failure doesn't stop the rest
- **Logs** everything to per-account log files and CSV reports for audit trails and post-mortems
- **Auto-installs** the required Az.Storage module if it's missing or outdated

The entire workflow is interactive — no flags or parameters to remember:

```
Step 1: Test connections to all storage accounts
Step 2: Scan and inventory all deleted items (parallel)
Step 3: Review results, confirm Y/N
Step 4: Restore everything (parallel)
Step 5: Final summary with per-account success/fail counts
```

## Requirements

- **PowerShell 7.2+** ([Download here](https://aka.ms/powershell-release?tag=stable))
- **Az.Storage module 4.9.0+** (auto-installed by the script if missing)
- Storage accounts must have **hierarchical namespace enabled** (ADLS Gen2)
- Storage accounts must have **soft delete enabled** with items still within the retention period

## Quick Start

### 1. Download

Download both files and place them in the same folder:

- `Restore-SoftDeletedADLS.ps1` — the main script
- `ADLSRestore-Config.ps1` — the configuration file

### 2. Configure

Open `ADLSRestore-Config.ps1` and fill in your storage accounts:

```powershell
$Accounts = @(
    @{
        StorageAccountName = "yourstorageaccount"
        StorageAccountKey  = "your-access-key=="
        FileSystem         = "your-container"
        Path               = "/"                   # "/" for entire container, or "delta" for a specific folder
    }
)
```

**Where to find these values:**

| Field | Location in Azure Portal |
|---|---|
| `StorageAccountName` | Storage Account > Overview > "Storage account name" |
| `StorageAccountKey` | Storage Account > Access keys > key1 > "Key" |
| `FileSystem` | Storage Account > Containers > container name |
| `Path` | The folder path to scan, or `"/"` for everything |

Add as many accounts as needed — copy/paste the `@{ ... }` block for each one.

### 3. Run

Open **PowerShell 7** (search for "pwsh" in the Start menu) and run:

```powershell
& "C:\path\to\Restore-SoftDeletedADLS.ps1"
```

The script will:
1. Check prerequisites and auto-install Az.Storage if needed
2. Test connections to all configured accounts
3. Scan all accounts in parallel and show what was deleted
4. Ask you to confirm before restoring
5. Restore everything in parallel and show a final summary

### 4. Review

All logs and CSVs are saved to an output folder (created automatically):

```
ADLSRecovery_20260402_143022/
  accountname_container_inventory.csv    # What was found
  accountname_container_inventory.log    # Scan details
  accountname_container_restore.csv     # What was restored (with status)
  accountname_container_restore.log     # Restore details
```

## Optional Settings

In `ADLSRestore-Config.ps1`, you can optionally set:

```powershell
# Only recover items deleted on or after this date
$SinceDate = "2026-03-15"

# Custom output folder for logs/CSVs
$OutputFolder = "C:\Recovery\Output"
```

## Common Issues

### "File cannot be loaded... not digitally signed"

Your execution policy blocks unsigned scripts. Run once as Administrator:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Then unblock the downloaded files:

```powershell
Unblock-File -Path ".\Restore-SoftDeletedADLS.ps1"
Unblock-File -Path ".\ADLSRestore-Config.ps1"
```

### "No accounts configured"

All four fields must be filled in for each account: `StorageAccountName`, `StorageAccountKey`, `FileSystem`, and `Path`. Empty accounts are skipped. Use `"/"` for Path if you want to scan the entire container.

### "The term 'Get-AzDataLakeGen2DeletedItem' is not recognized"

Az.Storage module is too old. The script auto-installs the correct version, but if that fails:

```powershell
Install-Module -Name Az.Storage -MinimumVersion 4.9.0 -Force
```

### No deleted items found

- Soft delete may not be enabled on the storage account
- The retention period may have expired for the deleted items
- The configured `Path` may not contain the deleted data — try `"/"`
- Confirm the account has hierarchical namespace enabled (ADLS Gen2, not Blob Storage)

## How It Works

The script uses the Az.Storage PowerShell module to interact with the ADLS Gen2 REST API:

1. **Discovery** — `Get-AzDataLakeGen2DeletedItem` enumerates soft-deleted items with pagination via continuation tokens, ensuring all items are found regardless of count
2. **Restore** — `Restore-AzDataLakeGen2DeletedItem` recovers each item individually with try/catch error handling
3. **Parallelism** — `ForEach-Object -Parallel` processes all storage accounts simultaneously (PowerShell 7+)

### Performance

The bottleneck is Azure API call latency (~200-500ms per call), not the script:

| Operation | Speed |
|---|---|
| **Inventory** | ~100 items/second (batched 100 per API call) |
| **Restore** | ~2-5 items/second (1 API call per item) |
| **Parallelism** | All accounts run simultaneously — total time = slowest single account |

For 10,000 files across 11 accounts, expect ~1-2 minutes for inventory and ~30-80 minutes for restore, depending on Azure API response times.

## License

MIT License — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome. This tool was built to fill a gap in Azure's tooling for ADLS Gen2 data recovery.
