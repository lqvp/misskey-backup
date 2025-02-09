#!/bin/bash

# USER CONFIGURATION
DB_USER="user"
DB_NAME="misskey"
DOCKER_CONTAINER_NAME="misskey-db-1"
BACKUP_DIR="/home/misskey/backup"
MISSKEY_INSTANCE="https://example.com"
MISSKEY_TOKEN="token"
DISCORD_WEBHOOK_URL="webhook"
GDRIVE_PARENT_ID="id"
GDRIVE_PATH="./gdrive"

# TIMESTAMP
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_backup_${TIMESTAMP}.sql"

# ERROR HANDLING
set -o errexit
set -o pipefail
set -o nounset

# FUNCTIONS
notify_start() {
    curl -H "Content-Type: application/json" -X POST -d "{\"content\": \"📌 データベースのバックアップを開始します。\"}" "$DISCORD_WEBHOOK_URL"
    curl -X POST -H "Content-Type: application/json" -d "{
        \"i\": \"$MISSKEY_TOKEN\",
        \"text\": \"📌 データベースのバックアップを開始します。\",
        \"localOnly\": true,
        \"visibility\": \"home\"
    }" "$MISSKEY_INSTANCE/api/notes/create"
}

create_backup() {
    mkdir -p "$BACKUP_DIR"
    docker exec "$DOCKER_CONTAINER_NAME" pg_dump -U "$DB_USER" "$DB_NAME" > "$BACKUP_FILE"
}

get_file_size() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        stat -c "%s" "$file_path"
    else
        echo 0
    fi
}

calculate_size_diff() {
    local last_backup_size=$(get_file_size "$LAST_BACKUP")
    local current_size=$(get_file_size "$BACKUP_FILE")
    echo $(($current_size - $last_backup_size))
}

upload_to_gdrive() {
    local backup_file="$1"
    $GDRIVE_PATH files upload --parent "$GDRIVE_PARENT_ID" "$backup_file"
}

parse_gdrive_output() {
    local output="$1"
    local created_time=$(echo "$output" | grep "Created:" | awk '{print $2" "$3}')
    local view_url=$(echo "$output" | grep "ViewUrl:" | awk '{print $2}')
    echo "$created_time"
    echo "$view_url"
}

notify_success() {
    local size_diff="$1"
    local created_time="$2"
    local view_url="$3"
    curl -H "Content-Type: application/json" -X POST -d "{
        \"content\": \"✅ データベースのバックアップが完了しました。\\n前回との差分サイズ: ${size_diff} バイト\\n作成日時: ${created_time}\\nダウンロードURL: ${view_url}\"
    }" "$DISCORD_WEBHOOK_URL"
    curl -X POST -H "Content-Type: application/json" -d "{
        \"i\": \"$MISSKEY_TOKEN\",
        \"text\": \"✅ データベースのバックアップが完了しました。\\n前回との差分サイズ: ${size_diff} バイト\\n作成日時: ${created_time}\",
        \"localOnly\": true,
        \"visibility\": \"home\"
    }" "$MISSKEY_INSTANCE/api/notes/create"
}

clean_old_backups() {
    local backup_dir="$1"
    local days_to_keep=14
    echo "🧹 Cleaning up old backup files older than $days_to_keep days..."
    find "$backup_dir" -type f -name "${DB_NAME}_backup_*.sql" -mtime "+$days_to_keep" -delete
}

notify_cleanup() {
    curl -H "Content-Type: application/json" -X POST -d "{
        \"content\": \"🧹 オールドバックアップクリーンアップ完了。\"
    }" "$DISCORD_WEBHOOK_URL"
    curl -X POST -H "Content-Type: application/json" -d "{
        \"i\": \"$MISSKEY_TOKEN\",
        \"text\": \"🧹 オールドバックアップクリーンアップ完了。\",
        \"localOnly\": true,
        \"visibility\": \"home\"
    }" "$MISSKEY_INSTANCE/api/notes/create"
}

error_handler() {
    local error_message="$1"
    curl -H "Content-Type: application/json" -X POST -d "{
        \"content\": \"⚠️ バックアップ中にエラーが発生しました。\\nエラー内容: ${error_message}\"
    }" "$DISCORD_WEBHOOK_URL"
    curl -X POST -H "Content-Type: application/json" -d "{
        \"i\": \"$MISSKEY_TOKEN\",
        \"text\": \"⚠️ バックアップ中にエラーが発生しました。\\nエラー内容: ${error_message}\",
        \"localOnly\": true,
        \"visibility\": \"home\"
    }" "$MISSKEY_INSTANCE/api/notes/create"
}

# MAIN EXECUTION
notify_start

{
    # Create backup
    create_backup

    # Get file sizes
    LAST_BACKUP=$(ls -t "$BACKUP_DIR/${DB_NAME}_backup_*.sql" 2>/dev/null | grep -v "$TIMESTAMP" | head -n 1)
    SIZE_DIFF=$(calculate_size_diff)

    # Upload to Google Drive
    GDRIVE_OUTPUT=$(upload_to_gdrive "$BACKUP_FILE")
    CREATED_TIME=$(parse_gdrive_output "$GDRIVE_OUTPUT" | head -n 1)
    VIEW_URL=$(parse_gdrive_output "$GDRIVE_OUTPUT" | tail -n 1)

    # Notify success
    notify_success "$SIZE_DIFF" "$CREATED_TIME" "$VIEW_URL"

    # Clean old backups
    clean_old_backups "$BACKUP_DIR"
    notify_cleanup
} || {
    # Handle errors
    ERROR_MESSAGE=$(cat "/tmp/backup_error.log")
    error_handler "$ERROR_MESSAGE"
    exit 1
} 2> "/tmp/backup_error.log"
