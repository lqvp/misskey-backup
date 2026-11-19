#!/usr/bin/env bash
#
# misskey-backup v2
# PostgreSQL (Misskey) ダンプ → Google Drive アップロード → 通知 → 世代削除
#
# 設定はスクリプトと同じディレクトリ (または /etc/misskey-backup) の
# backup.env から読み込みます。backup.env.example をコピーして使ってください。
#
# テスト実行は DRY_RUN=1 を指定すると、ダンプ生成まで行い
# アップロード・通知・削除をスキップします。

set -o errexit
set -o pipefail
set -o nounset
set -o errtrace

# ---------------------------------------------------------------------------
# 設定の読み込み
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${CONFIG_FILE:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    for candidate in "$SCRIPT_DIR/backup.env" "/etc/misskey-backup/backup.env"; do
        if [[ -f "$candidate" ]]; then
            CONFIG_FILE="$candidate"
            break
        fi
    done
fi

if [[ -z "$CONFIG_FILE" ]]; then
    echo "エラー: 設定ファイルが見つかりません。" >&2
    echo "backup.env.example を backup.env としてコピーし、値を設定してください。" >&2
    exit 2
fi

# 設定ファイル内の値で未設定の変数のみ埋める（スクリプトのデフォルトを上書きしない）
DB_USER="user"
DB_NAME="misskey"
DOCKER_CONTAINER_NAME="misskey-db-1"
BACKUP_DIR="/home/misskey/backup"
MISSKEY_INSTANCE=""
MISSKEY_TOKEN=""
DISCORD_WEBHOOK_URL=""
HEALTHCHECK_URL=""
GDRIVE_PARENT_ID=""
GDRIVE_PATH="./gdrive"
RETENTION_DAYS=14
DRY_RUN=0
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ログ・通知の時刻表示のタイムゾーン（cron の実行時刻には影響しない）
export TZ="${TZ:-Asia/Tokyo}"

# ---------------------------------------------------------------------------
# ログとエラーハンドリング
# ---------------------------------------------------------------------------
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_backup_${TIMESTAMP}.sql"
LOG_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.log"

mkdir -p "$BACKUP_DIR"

# ログファイルへの書き込み可否を先に確認（ディスクフル等の早期検出）
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "エラー: ログファイルに書き込めません: $LOG_FILE" >&2
    exit 2
fi

# stdout/stderr をログにも残す（tee は bash のプロセス置換を使用）
exec 3>&1 1> >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

on_error() {
    local exit_code=$?
    local line_no=$1
    log "エラー: 行 ${line_no} でエラーが発生しました (exit code: ${exit_code})"
    # tee への書き込みは非同期のため、直近のログ行がファイルに届くのを待つ
    sleep 1
    # healthchecks.io に失敗を報告（無音障害検知。設定時のみ）
    if [[ -n "${HEALTHCHECK_URL:-}" && "$DRY_RUN" != "1" ]]; then
        curl -sf -m 10 --retry 2 "${HEALTHCHECK_URL}/fail" >/dev/null || true
    fi
    if [[ "$DRY_RUN" != "1" ]]; then
        notify_error "exit code: ${exit_code} (行 ${line_no})。詳細はサーバーのログを確認してください。"
    fi
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# 二重起動防止（同一ホストで同時実行しない）
# ---------------------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    log "警告: flock が見つからないため二重起動防止をスキップします"
else
    LOCK_FILE="${BACKUP_DIR}/backup.lock"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "エラー: 別のバックアップが実行中です ($LOCK_FILE)"
        exit 3
    fi
fi

# ---------------------------------------------------------------------------
# 通知
# ---------------------------------------------------------------------------
post_json() {
    local url="$1" payload="$2"
    # 通知の失敗でバックアップ全体を止めない
    curl -sf -m 30 --retry 2 -H "Content-Type: application/json" \
        -X POST -d "$payload" "$url" >/dev/null || \
        log "警告: 通知の送信に失敗しました (${url})"
}

notify_discord() {
    local message="$1"
    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        # JSON エスケープ（改行・引用符）
        local escaped
        escaped=$(printf '%s' "$message" | jq -Rs .)
        post_json "$DISCORD_WEBHOOK_URL" "{\"content\": ${escaped}}"
    fi
}

notify_misskey() {
    local message="$1"
    if [[ -n "$MISSKEY_INSTANCE" && -n "$MISSKEY_TOKEN" ]]; then
        local escaped
        escaped=$(printf '%s' "$message" | jq -Rs .)
        post_json "$MISSKEY_INSTANCE/api/notes/create" \
            "{\"i\": \"${MISSKEY_TOKEN}\", \"text\": ${escaped}, \"localOnly\": true, \"visibility\": \"home\"}"
    fi
}

notify_start() {
    log "バックアップを開始します"
    notify_discord "📌 データベースのバックアップを開始します。"
    notify_misskey "📌 データベースのバックアップを開始します。"
}

notify_error() {
    local message="$1"
    notify_discord "⚠️ バックアップ中にエラーが発生しました。
エラー内容: ${message}"
    notify_misskey "⚠️ バックアップ中にエラーが発生しました。
エラー内容: ${message}"
}

# ---------------------------------------------------------------------------
# バックアップ本体
# ---------------------------------------------------------------------------
# GNU stat / BSD stat の両方に対応
get_file_size() {
    local file_path="$1"
    if [[ ! -f "$file_path" ]]; then
        echo 0
    elif stat -c %s /dev/null >/dev/null 2>&1; then
        stat -c "%s" "$file_path"
    else
        stat -f %z "$file_path"
    fi
}

create_backup() {
    log "pg_dump を実行しています..."

    if ! docker inspect "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1; then
        log "エラー: コンテナ '$DOCKER_CONTAINER_NAME' が見つかりません"
        return 1
    fi

    # 一時ファイルに書き込み、検証してから確定させる（失敗時に中途半端なファイルを残さない）
    local tmp_file="${BACKUP_FILE}.tmp"

    if ! docker exec "$DOCKER_CONTAINER_NAME" pg_dump -U "$DB_USER" "$DB_NAME" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    # 空ダンプのガード（ディスクフル等でサイズ 0 や極小になるケース）
    if [[ ! -s "$tmp_file" ]]; then
        log "エラー: ダンプファイルが空です（ディスク容量を確認してください）"
        rm -f "$tmp_file"
        return 1
    fi

    # ダンプの整合性チェック: ヘッダとフッタを確認
    if ! head -n 2 "$tmp_file" | grep -q "PostgreSQL database dump"; then
        log "エラー: ダンプファイルのヘッダが不正です"
        rm -f "$tmp_file"
        return 1
    fi
    if ! tail -n 5 "$tmp_file" | grep -q "PostgreSQL database dump complete"; then
        log "エラー: ダンプが完了していません（フッタが不正）"
        rm -f "$tmp_file"
        return 1
    fi

    # 圧縮して保存容量を削減（必要なければ COMPRESS_DUMP=0）
    if [[ "${COMPRESS_DUMP:-1}" == "1" ]]; then
        gzip -f "$tmp_file"
        mv "${tmp_file}.gz" "$BACKUP_FILE.gz"
        BACKUP_FILE="${BACKUP_FILE}.gz"
    else
        mv "$tmp_file" "$BACKUP_FILE"
    fi
    log "バックアップ完了: $BACKUP_FILE ($(get_file_size "$BACKUP_FILE") bytes)"
}

# ---------------------------------------------------------------------------
# Google Drive へのアップロード（MD5 検証つき）
# ---------------------------------------------------------------------------
upload_to_gdrive() {
    local backup_file="$1"

    if [[ ! -x "$GDRIVE_PATH" && ! -x "$(command -v gdrive || true)" ]]; then
        log "エラー: gdrive コマンドが見つかりません (GDRIVE_PATH=$GDRIVE_PATH)"
        return 1
    fi

    log "Google Drive にアップロードしています..."
    local gdrive_output
    if ! gdrive_output=$("$GDRIVE_PATH" files upload --parent "$GDRIVE_PARENT_ID" "$backup_file" 2>&1); then
        log "gdrive の出力: $gdrive_output"
        return 1
    fi
    GDRIVE_OUTPUT="$gdrive_output"

    # アップロード結果の MD5 をローカルファイルと照合し、破損を検出する
    local remote_md5
    remote_md5=$(echo "$gdrive_output" | grep "^MD5:" | awk '{print $2}')
    if [[ -n "$remote_md5" ]]; then
        local local_md5
        if command -v md5sum >/dev/null 2>&1; then
            local_md5=$(md5sum "$backup_file" | awk '{print $1}')
        else
            local_md5=$(md5 -q "$backup_file")
        fi
        if [[ "$remote_md5" != "$local_md5" ]]; then
            log "エラー: アップロード後の MD5 が一致しません（ローカル: $local_md5 / リモート: $remote_md5）"
            return 1
        fi
        log "MD5 検証に成功しました"
    else
        # 出力フォーマット変更で MD5 が取れない場合は検証をスキップ（エラーにはしない）
        log "警告: gdrive の出力から MD5 を抽出できなかったため検証をスキップします"
    fi
}

# ---------------------------------------------------------------------------
# 世代管理（ダンプとログファイルの両方を掃除する）
# ---------------------------------------------------------------------------
clean_old_backups() {
    # -mtime +N は「N+1 日以上経過」で削除される点に注意
    log "${RETENTION_DAYS} 日より古いバックアップとログを削除しています..."
    find "$BACKUP_DIR" -type f \
        \( -name "${DB_NAME}_backup_*.sql" -o -name "${DB_NAME}_backup_*.sql.gz" -o -name "backup_*.log" \) \
        -mtime "+${RETENTION_DAYS}" -delete
    log "クリーンアップ完了"
}

# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------
main() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN モード: ダンプ生成のみ行い、アップロード・通知・削除をスキップします"
    else
        notify_start
    fi

    create_backup

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN モードのため、ここで終了します（アップロード・通知・削除は行いません）"
        return 0
    fi

    upload_to_gdrive "$BACKUP_FILE"

    # gdrive の出力から作成日時とURLを抽出（フォーマット変更時は警告のみ）
    local created_time
    created_time=$(echo "$GDRIVE_OUTPUT" | grep "Created:" | awk '{print $2" "$3}')
    local view_url
    view_url=$(echo "$GDRIVE_OUTPUT" | grep "ViewUrl:" | awk '{print $2}')
    if [[ -z "$created_time" ]]; then
        log "警告: gdrive の出力から作成日時を抽出できませんでした"
        created_time="（抽出失敗）"
    fi
    if [[ -z "$view_url" ]]; then
        log "警告: gdrive の出力から URL を抽出できませんでした"
        view_url="（抽出失敗）"
    fi

    # 前回との差分サイズ（前回分が無い場合は表示しない。
    # 圧縮/非圧縮でサイズが大きく変わるため、同じ形式のファイルとだけ比較する）
    local size_diff_text=""
    local last_backup=""
    if [[ "${COMPRESS_DUMP:-1}" == "1" ]]; then
        last_backup=$(LC_ALL=C ls -t "$BACKUP_DIR/${DB_NAME}_backup_"*.sql.gz 2>/dev/null | head -n 1 || true)
    else
        last_backup=$(LC_ALL=C ls -t "$BACKUP_DIR/${DB_NAME}_backup_"*.sql 2>/dev/null | head -n 1 || true)
    fi
    if [[ -n "$last_backup" ]]; then
        size_diff_text="前回との差分サイズ: $(($(get_file_size "$BACKUP_FILE") - $(get_file_size "$last_backup"))) バイト
"
    fi

    notify_discord "✅ データベースのバックアップが完了しました。
${size_diff_text}作成日時: ${created_time}
ダウンロードURL: ${view_url}"
    notify_misskey "✅ データベースのバックアップが完了しました。
${size_diff_text}作成日時: ${created_time}"

    clean_old_backups

    # healthchecks.io への生存報告（無音障害検知。設定時のみ）
    if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
        curl -sf -m 10 --retry 2 "$HEALTHCHECK_URL" >/dev/null || \
            log "警告: healthchecks.io への報告に失敗しました"
    fi

    log "すべての処理が完了しました"
}

main
