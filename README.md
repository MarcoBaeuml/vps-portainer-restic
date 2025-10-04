# Docker VPS Setup with Automated Backups

This repository contains a complete Docker-based VPS setup with automated backup and restore capabilities using Portainer for container management and Restic for S3 backup synchronization.

## Architecture Overview

### Directory Structure
```
docker/
├── portainer/
│   ├── docker-compose.yml       # Portainer container management UI
│   ├── data/                    # All Docker volumes stored here
│   │   ├── portainer/           # Portainer's own data
│   │   ├── nginx_proxy_manager/
│   │   ├── wordpress/
│   │   └── ...                 # Other application volumes
│   └── data_restore/           # Temporary location for restored backups
└── restic/
    ├── docker-compose.yml      # Restic backup service
    ├── .env                    # S3 and backup configuration
    ├── .env.example            # Template for configuration
    ├── notify.sh               # Telegram notification script
    └── cache/                  # Restic cache directory
```

### How It Works

**Centralized Volume Storage**: All Docker container volumes are stored in `portainer/data/` using absolute path mounts. This centralizes all persistent data in one location.

**Automated Backups**: The Restic service continuously monitors `portainer/data/` and syncs it to an S3-compatible bucket. This provides off-site backup without manual intervention.

**Point-in-Time Recovery**: Restic creates snapshots that can be restored to `portainer/data_restore/`, allowing you to test or recover specific versions of your data without affecting running containers.

**Hot Swapping Data**: By changing volume mounts in Portainer's UI from `data/` to `data_restore/`, you can instantly switch a container to use restored backup data.

## Initial Setup

### Prerequisites
- Docker and Docker Compose installed
- S3-compatible storage (Cloudflare R2, AWS S3, Backblaze B2, Wasabi, etc.)
  - **Tested with Cloudflare R2** - should work with any S3-compatible provider

## Installation

1. **Clone this repository**

2. **Make the notification script executable (optional)**:
```bash
chmod +x ./restic/notify.sh
```

3. **Configure Restic backup settings**:
```bash
cp ./restic/.env.example ./restic/.env
```

Edit the following variables:
- `S3_ENDPOINT`: Your S3 endpoint
  - Cloudflare R2: `https://<account-id>.r2.cloudflarestorage.com`
  - AWS S3: `s3.amazonaws.com` or `s3.<region>.amazonaws.com`
  - Backblaze B2: `s3.us-west-002.backblazeb2.com`
- `S3_BUCKET`: Your bucket name
- `AWS_ACCESS_KEY_ID`: S3 access key (for R2: use R2 API token)
- `AWS_SECRET_ACCESS_KEY`: S3 secret key (for R2: use R2 API secret)
- `RESTIC_PASSWORD`: Encryption password for backups (store securely!)
- `TELEGRAM_BOT_TOKEN`: (Optional) For backup notifications - leave as is to disable
- `TELEGRAM_CHAT_ID`: (Optional) Your Telegram chat ID - leave as is to disable

4. **Start services**:
```bash
# Start Portainer first
docker compose -f ./portainer/docker-compose.yml up -d

# Then start Restic backup service
docker compose -f ./restic/docker-compose.yml up -d
```

5. **Access Portainer**:
- Open `https://your-server-ip:9443`
- Create admin account on first login

## Usage

### Creating Backup-Compatible Containers

To ensure your containers' data is backed up, you **must** use absolute path volume mounts pointing to `portainer/data/`:

**Example: WordPress with MySQL**

```yaml
services:
  wordpress:
    image: wordpress:latest
    volumes:
      - /root/docker/portainer/data/wordpress/var/www/html:/var/www/html
    
  mysql:
    image: mysql:8.0
    volumes:
      - /root/docker/portainer/data/wordpress/var/lib/mysql:/var/lib/mysql
```

❌ **Incorrect** (won't be backed up):
```yaml
volumes:
  - wordpress_data:/var/www/html  # Named volume - not backed up!
  - ./local_folder:/data           # Relative path - not backed up!
```

### Backup Schedule

The current configuration backs up every hour (`BACKUP_CRON: "0 * * * *"`).

You can adjust this schedule by editing the `BACKUP_CRON` variable in `restic/docker-compose.yml` and restarting the service:
```bash
docker compose -f ./restic/docker-compose.yml up -d --force-recreate
```


## Restore Process

### Step 1: List Available Snapshots
```bash
docker compose -f ./restic/docker-compose.yml exec restic-backup restic snapshots
```

Output example:
```
ID        Time                 Host        Tags
----------------------------------------------------------------
a1b2c3d4  2025-10-04 14:30:00  server01    auto
e5f6g7h8  2025-10-03 14:30:00  server01    auto
```

### Step 2: Restore Snapshot to data_restore
```bash
docker compose -f ./restic/docker-compose.yml exec restic-backup restic restore <snapshot>:/data --target /restore
```

This restores the entire `data/` folder structure to `portainer/data_restore/`.

### Step 3: Switch Container to Use Restored Data

You have two strategies depending on your needs:

#### Strategy A: Replace Running Container (Downtime)
Best for: Testing if restore worked, permanent rollback to backup

**Via Portainer UI:**
1. Go to Portainer → Containers → Select your container
2. Stop the container
3. Duplicate container configuration
4. Change volume path from `/root/docker/portainer/data/...` to `/root/docker/portainer/data_restore/...`
5. Start the container with restored data



#### Strategy B: Run Dual Containers (No Downtime)
Best for: Comparing old vs restored data, testing before committing to restore

**Via Portainer UI:**
1. Go to Portainer → Containers → Select your container
2. Duplicate the container (creates a copy with new name)
3. In the duplicate, change:
   - Container name (e.g., `wordpress` → `wordpress-restored`)
   - Port mappings (e.g., `80:80` → `8080:80` to avoid conflicts)
   - Volume paths to use `data_restore/` instead of `data/`
4. Start both containers side-by-side
5. Compare data/functionality between original and restored versions
6. Once verified, stop/remove the container you don't need

This allows you to:
- Access production site on port 80
- Access restored version on port 8080
- Compare and verify data before committing to the restore

## System Recovery

If you need to perform a complete or partial system restore (e.g., after a server failure or migration to a new VPS), follow these steps:

### Recovery Steps

1. **Follow Steps 1-4 from the Installation section**

2. **List available snapshots**
```bash
docker compose -f ./restic/docker-compose.yml exec restic-backup restic snapshots
```

Choose the snapshot you want to restore (usually the most recent one).

3. **Temporarily remove read-only flag from data volume**

Edit `restic/docker-compose.yml` and remove the `:ro` (read-only) flag from the data volume mount:

```yaml
volumes:
  # Change from:
  - /root/docker/portainer/data:/data:ro
  # To:
  - /root/docker/portainer/data:/data
```

Then restart the container:
```bash
docker compose -f ./restic/docker-compose.yml up -d --force-recreate
```

**Why?** The read-only flag prevents Restic from writing the restored data to the `/data` directory.

4. **Restore data directly to the data folder**

Full restore:
```bash
docker compose -f ./restic/docker-compose.yml exec restic-backup restic restore <snapshot-id>:/data --target /data
```

Partial restore (specific files/folders):
```bash
docker compose -f ./restic/docker-compose.yml exec restic-backup restic restore <snapshot-id>:/data --target /data --include "/data/path/to/files/*"
```

This restores the backup directly to the `/data/` path in the container, which maps to `/root/docker/portainer/data/` on your host.

5. **Restart Portainer and verify**
```bash
docker compose -f ./portainer/docker-compose.yml up -d --force-recreate
```

Access Portainer at `https://your-server-ip:9443` and verify your containers are restored.

6. **Restart your application containers**
- Go to Portainer UI and start/recreate your containers to ensure they use the restored data

7. **Re-enable read-only flag for security**

Edit `restic/docker-compose.yml` and add back the `:ro` (read-only) flag:

```yaml
volumes:
  # Change from:
  - /root/docker/portainer/data:/data
  # To:
  - /root/docker/portainer/data:/data:ro
```

Then restart the container:
```bash
docker compose -f ./restic/docker-compose.yml up -d --force-recreate
```

**Important:** This prevents the backup container from accidentally modifying your production data during future backup operations.

## Security Considerations

1. **Backup Encryption**: All backups are encrypted with `RESTIC_PASSWORD`. Store this password securely - you cannot recover backups without it!