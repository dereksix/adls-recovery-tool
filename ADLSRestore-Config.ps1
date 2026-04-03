#╔══════════════════════════════════════════════════════════════════════════════╗
#║                                                                            ║
#║   ADLS Gen2 Data Recovery — Configuration File                             ║
#║                                                                            ║
#║   INSTRUCTIONS:                                                            ║
#║     1. Fill in each storage account below                                  ║
#║     2. Copy/paste the template block to add more accounts                  ║
#║     3. Save this file                                                      ║
#║     4. Run: .\Restore-SoftDeletedADLS.ps1                                  ║
#║                                                                            ║
#║   WHERE TO FIND THESE VALUES:                                              ║
#║     StorageAccountName:                                                    ║
#║       Azure Portal > Storage Account > Overview > "Storage account name"   ║
#║                                                                            ║
#║     StorageAccountKey:                                                     ║
#║       Azure Portal > Storage Account > Access keys > key1 "Key" value      ║
#║                                                                            ║
#║     FileSystem:                                                            ║
#║       Azure Portal > Storage Account > Containers > container name         ║
#║                                                                            ║
#║     Path:                                                                  ║
#║       The folder path to scan for deleted items (e.g. "delta")             ║
#║       Use "/" to scan the entire container                                 ║
#║                                                                            ║
#╚══════════════════════════════════════════════════════════════════════════════╝

$Accounts = @(

    # ── Account 1 ──────────────────────────────────────────────────────────────
    @{
        StorageAccountName = ""    # e.g. "prodstorageacct01"
        StorageAccountKey  = ""
        FileSystem         = ""    # e.g. "datalake"
        Path               = ""    # e.g. "delta" or "/"
    }

    # ── Account 2 ──────────────────────────────────────────────────────────────
    @{
        StorageAccountName = ""
        StorageAccountKey  = ""
        FileSystem         = ""
        Path               = ""
    }

    # ── Account 3 ──────────────────────────────────────────────────────────────
    @{
        StorageAccountName = ""
        StorageAccountKey  = ""
        FileSystem         = ""
        Path               = ""
    }

    # ┌──────────────────────────────────────────────────────────────────────────┐
    # │  Need more accounts? Copy the block below and paste it here:           │
    # │                                                                        │
    # │  @{                                                                    │
    # │      StorageAccountName = ""                                           │
    # │      StorageAccountKey  = ""                                           │
    # │      FileSystem         = ""                                           │
    # │      Path               = ""                                           │
    # │  }                                                                     │
    # │                                                                        │
    # └──────────────────────────────────────────────────────────────────────────┘
)

# ── Optional Settings (safe to leave as-is) ───────────────────────────────────

# Only recover items deleted on or after this date.
# Leave blank to recover ALL soft-deleted items within the retention window.
# Examples: "2026-03-15", "2026-01-01"
$SinceDate = ""

# Only recover items deleted on or before this date.
# Use together with $SinceDate to define a date range.
# Leave blank for no upper bound.
# Examples: "2026-03-20", "2026-03-31"
$BeforeDate = ""

# Where to save log and CSV files. Default: same folder as the script.
$OutputFolder = ""
