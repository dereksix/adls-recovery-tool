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

# Number of concurrent restore operations per storage account.
# Higher = faster, but uses more of the account's API budget.
# This is a SHARED account — other workloads need headroom.
# Default: 64 workers. Hard-capped at 256 to stay safe.
$MaxConcurrency = 64

# Hard ceiling on requests per second (across all workers).
# Workers will pace themselves to stay under this limit.
# The account limit is ~20,000 req/sec but you're sharing it.
# Default: 500. Safe range: 100–2000.
$MaxRequestsPerSecond = 500

# Retry attempts for transient failures (429 throttling, 503 service busy).
# Uses exponential backoff between retries.
$MaxRetries = 3
