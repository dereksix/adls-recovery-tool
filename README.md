# Azure Storage Data Recovery Tool

A production-ready PowerShell utility for recovering soft-deleted files from Azure Storage accounts. Supports both **ADLS Gen2** (hierarchical namespace) and **Blob Storage** (flat namespace) — auto-detects which type each account uses.

## Background

This tool is based on the soft-delete recovery approach documented in [Microsoft's official Azure documentation](https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage?tabs=dotnet), which provides reference-level code samples showing the relevant cmdlets and API calls. However, those examples are intended to demonstrate the API surface — not to be run in production. They lack pagination, error handling, multi-account support, progress tracking, and logging.

This project takes the core concepts from the Microsoft docs and builds them into a robust, customer-facing recovery tool that handles real-world scenarios: thousands of files, multiple storage accounts, retention tracking, parallel execution, and full audit trails.

## What It Does

- **Auto-detects** storage type (ADLS Gen2 vs Blob Storage) per account — no need to know which you have
- **Scans** all configured storage accounts in parallel for soft-deleted items
- **Reports** an inventory with retention status (critical/warning/OK), item counts, sizes, and deletion timeline
- **Restores** all recoverable items with per-item error handling — one failure doesn't stop the rest
- **Logs** everything to per-account log files and CSV reports for audit trails and post-mortems
- **Auto-installs** the required Az.Storage module if it's missing or outdated

The entire workflow is interactive — no flags or parameters to remember:

```
Step 1: Test connections and detect storage type (ADLS Gen2 or Blob)
Step 2: Scan and inventory all deleted items (parallel)
Step 3: Review results, confirm Y/N
Step 4: Restore everything (parallel)
Step 5: Final summary with per-account success/fail counts
```

## Requirements

- **PowerShell 7.2+** ([Download here](https://aka.ms/powershell-release?tag=stable))
- **Az.Storage module 4.9.0+** (auto-installed by the script if missing)
- Storage accounts must have **soft delete enabled** with items still within the retention period
- For ADLS Gen2: storage account must have **hierarchical namespace enabled**

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

Add as many accounts as needed — copy/paste the `@{ ... }` block for each one. You can mix ADLS Gen2 and Blob Storage accounts in the same config file.

### 3. Run

Open **PowerShell 7** (search for "pwsh" in the Start menu) and run:

```powershell
& "C:\path\to\Restore-SoftDeletedADLS.ps1"
```

The script will:
1. Check prerequisites and auto-install Az.Storage if needed
2. Test connections and auto-detect each account's storage type
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

## Supported Storage Types

| Storage Type | Soft Delete Recovery | Cmdlets Used |
|---|---|---|
| **ADLS Gen2** (hierarchical namespace) | `Get-AzDataLakeGen2DeletedItem` / `Restore-AzDataLakeGen2DeletedItem` | Full pagination with continuation tokens |
| **Blob Storage** (flat namespace) | `Get-AzStorageBlob -IncludeDeleted` / `BlobBaseClient.Undelete()` | Full pagination with continuation tokens |

The script auto-detects which type each account is at connection time — you don't need to know or specify it.

## Optional Settings

In `ADLSRestore-Config.ps1`, you can optionally set:

```powershell
# Only recover items deleted on or after this date
$SinceDate = "2026-03-15"

# Only recover items deleted on or before this date (use with $SinceDate for a date range)
$BeforeDate = "2026-03-20"

# Custom output folder for logs/CSVs
$OutputFolder = "C:\Recovery\Output"
```

## Performance

The bottleneck is Azure API call latency (~200-500ms per call), not the script:

| Operation | Speed |
|---|---|
| **Inventory** | ~100 items/second (batched 100 per API call) |
| **Restore** | ~2-5 items/second (1 API call per item) |
| **Parallelism** | All accounts run simultaneously — total time = slowest single account |

For 10,000 files across multiple accounts, expect ~1-2 minutes for inventory and ~30-80 minutes for restore.

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

### Script prints the path instead of running

Use the call operator `&`:

```powershell
& "C:\path\to\Restore-SoftDeletedADLS.ps1"
```

### Parse errors about "ForEach-Object" or "-Parallel"

You're running the script in **Windows PowerShell 5.1** instead of **PowerShell 7**. Use `pwsh` instead of `powershell`:

```powershell
pwsh -File "C:\path\to\Restore-SoftDeletedADLS.ps1"
```

### "No accounts configured"

All four fields must be filled in for each account: `StorageAccountName`, `StorageAccountKey`, `FileSystem`, and `Path`. Empty accounts are skipped. Use `"/"` for Path if you want to scan the entire container.

### No deleted items found

- Soft delete may not be enabled on the storage account
- The retention period may have expired for the deleted items
- The configured `Path` may not contain the deleted data — try `"/"`
- Confirm the account has hierarchical namespace enabled (for ADLS Gen2)

## Microsoft Documentation References

- [Manage and restore soft-deleted blobs](https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage)
- [Soft delete for blobs](https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-overview)
- [Get-AzDataLakeGen2DeletedItem](https://learn.microsoft.com/en-us/powershell/module/az.storage/get-azdatalakegen2deleteditem)
- [Restore-AzDataLakeGen2DeletedItem](https://learn.microsoft.com/en-us/powershell/module/az.storage/restore-azdatalakegen2deleteditem)

## License

MIT License — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome.
