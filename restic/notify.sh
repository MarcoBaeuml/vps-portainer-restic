#!/bin/bash

# Telegram notification script for Restic backups
# Usage: notify.sh [success|failure]

STATUS="$1"
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ "$STATUS" = "success" ]; then
    # Get backup statistics from latest snapshot
    STATS=$(restic stats latest --mode raw-data 2>/dev/null)
    SNAPSHOT_JSON=$(restic snapshots latest --json 2>/dev/null)
    
    # Extract statistics from restic stats output
    TOTAL_SIZE=$(echo "$STATS" | grep "Total Size:" | awk '{print $3, $4}')
    TOTAL_BLOBS=$(echo "$STATS" | grep "Total Blob Count:" | awk '{print $4}')
    
    # Parse snapshot summary from JSON
    TOTAL_FILES=$(echo "$SNAPSHOT_JSON" | grep -o '"total_files_processed":[0-9]*' | cut -d: -f2)
    FILES_NEW=$(echo "$SNAPSHOT_JSON" | grep -o '"files_new":[0-9]*' | cut -d: -f2)
    FILES_CHANGED=$(echo "$SNAPSHOT_JSON" | grep -o '"files_changed":[0-9]*' | cut -d: -f2)
    DATA_ADDED=$(echo "$SNAPSHOT_JSON" | grep -o '"data_added":[0-9]*' | cut -d: -f2)
    
    # Get snapshot ID
    SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON" | grep -o '"short_id":"[^"]*"' | cut -d'"' -f4)
    
    # Convert data_added to human readable (bytes to MB)
    if [ -n "$DATA_ADDED" ] && [ "$DATA_ADDED" != "0" ]; then
        DATA_ADDED_MB=$(awk "BEGIN {printf \"%.2f\", $DATA_ADDED/1048576}")
        DATA_ADDED_STR="${DATA_ADDED_MB} MB"
    else
        DATA_ADDED_STR="0 MB"
    fi
    
    # Calculate total changed files
    TOTAL_CHANGED=$((${FILES_NEW:-0} + ${FILES_CHANGED:-0}))
    
    # Create change summary
    if [ "$TOTAL_CHANGED" -eq 0 ]; then
        CHANGE_SUMMARY="No changes"
    else
        CHANGE_PARTS=()
        [ "${FILES_NEW:-0}" -gt 0 ] && CHANGE_PARTS+=("${FILES_NEW} new")
        [ "${FILES_CHANGED:-0}" -gt 0 ] && CHANGE_PARTS+=("${FILES_CHANGED} modified")
        CHANGE_SUMMARY=$(IFS=", "; echo "${CHANGE_PARTS[*]}")
    fi
    
    MESSAGE="✅ <b>Backup Successful</b>

🖥 <b>Host:</b> ${HOSTNAME}
🕐 <b>Completed:</b> ${TIMESTAMP}

📊 <b>Snapshot ${SNAPSHOT_ID:-unknown}</b>
├ 💾 Repository Size: ${TOTAL_SIZE:-N/A}
├ 📄 Total Files: ${TOTAL_FILES:-N/A}
├ 📦 Total Blobs: ${TOTAL_BLOBS:-N/A}
├ 📤 Data Added: ${DATA_ADDED_STR}
├ 📝 Changes: ${CHANGE_SUMMARY}
└ 📁 Path: ${BACKUP_PATHS}

✓ Backup and pruning completed"

elif [ "$STATUS" = "failure" ]; then
    MESSAGE="❌ <b>Backup Failed</b>

🖥 <b>Host:</b> ${HOSTNAME}
📦 <b>Bucket:</b> ${S3_BUCKET}
🕐 <b>Failed at:</b> ${TIMESTAMP}
📁 <b>Path:</b> ${BACKUP_PATHS}

⚠️ <b>Check logs:</b>
<code>docker logs restic-backup --tail 50</code>"

else
    echo "Usage: $0 [success|failure]"
    exit 1
fi

# Check if Telegram credentials are configured
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] || \
   [ "$TELEGRAM_BOT_TOKEN" = "telegram_bot_token" ] || [ "$TELEGRAM_CHAT_ID" = "telegram_chat_id" ]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Telegram notifications disabled (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not configured)"
    echo "[INFO] Backup status: $STATUS on host: $HOSTNAME"
    exit 0
fi

# Send notification to Telegram
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "parse_mode=HTML" \
    -F "text=${MESSAGE}")

# Check if notification was sent successfully
if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Telegram notification sent successfully ($STATUS)"
else
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - Failed to send Telegram notification: $RESPONSE"
fi