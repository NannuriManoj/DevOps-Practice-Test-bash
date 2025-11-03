# Bash Automated Backup System

A simple yet powerful **automated backup tool** built entirely in **Bash**.  
It creates compressed backups of a given directory, supports excluding unwanted folders, verifies the integrity of the backup using checksums, and logs all operations with timestamps.

---

## Features

Creates timestamped `.tar.gz` backup archives  
Supports file/folder exclusion patterns  
Generates and verifies SHA256 checksums  
Maintains a detailed log file of all operations  
Fully configurable using a simple `backup.config` file  

---

## Folder Structure
backup-system/
├── backup_simple.sh # Main backup script
├── backup.config # Configuration file
└── backups/ # Folder where backups & logs are stored


---

## Configuration

The script loads settings from `backup.config`.  
Here’s a sample configuration file:

```bash
# backup.config
BACKUP_DESTINATION="./backups"
EXCLUDE_PATTERNS=".git,node_modules,.cache"
```

## How It Works

Loads config: Reads backup.config (or uses defaults if missing).
Creates backup: Compresses the target folder into a .tar.gz archive.
Generates checksum: Uses sha256sum or similar tool to verify integrity.
Verifies backup: Ensures the archive isn’t corrupted.
Logs everything: Saves all progress to backup.log.

``` bash
chmod +x backup_simple.sh
./backup_simple.sh "/path/to/folder"
```

## Example Log Output
<img width="1527" height="421" alt="image" src="https://github.com/user-attachments/assets/8d50fe48-6660-49ce-9612-f3f7579a4c5e" />

