#!/usr/bin/env bash
#
# misskey-backup リストアスクリプト
# backup.sh が生成したダンプファイルを PostgreSQL に戻します。
#
# 使い方:
#   ./restore.sh <ダンプファイル>          対話確認つきで復元
#   ./restore.sh <ダンプファイル> --yes    確認をスキップ（自動化用）
#
# ダンプファイルは .sql（平文）または .sql.gz（gzip 圧縮）に対応しています。

set -o errexit
set -o pipefail
set -o nounset
set -o errtrace

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

DB_USER="user"
DB_NAME="misskey"
DOCKER_CONTAINER_NAME="misskey-db-1"
# shellcheck disable=SC1090
[[ -n "${CONFIG_FILE:-}" ]] && source "$CONFIG_FILE"

usage() {
    echo "使い方: $0 <ダンプファイル> [--yes]" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
DUMP_FILE="$1"
ASSUME_YES=0
[[ "${2:-}" == "--yes" ]] && ASSUME_YES=1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "エラー: $*"
    exit 1
}

# ---------------------------------------------------------------------------
# 事前チェック
# ---------------------------------------------------------------------------
[[ -f "$DUMP_FILE" ]] || die "ダンプファイルが見つかりません: $DUMP_FILE"

docker inspect "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1 || \
    die "コンテナ '$DOCKER_CONTAINER_NAME' が見つかりません"

count_tables() {
    docker exec "$DOCKER_CONTAINER_NAME" \
        psql -U "$DB_USER" -d "$DB_NAME" -t -A -c \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" \
        2>/dev/null || echo -1
}

BEFORE_TABLES=$(count_tables)
[[ "$BEFORE_TABLES" -ge 0 ]] || die "データベース '$DB_NAME' に接続できません（psql の接続設定を確認してください）"

log "リストア対象: $DUMP_FILE"
log "コンテナ: $DOCKER_CONTAINER_NAME / DB: $DB_NAME / 現在の public テーブル数: $BEFORE_TABLES"

# ---------------------------------------------------------------------------
# ダンプの整合性チェック
# ---------------------------------------------------------------------------
DUMP_TMP=""

cleanup() {
    [[ -n "$DUMP_TMP" && -f "$DUMP_TMP" ]] && rm -f "$DUMP_TMP"
}
trap cleanup EXIT

if [[ "$DUMP_FILE" == *.gz ]]; then
    log "gzip を解凍しています..."
    DUMP_TMP=$(mktemp /tmp/misskey_restore_XXXXXX.sql)
    if ! gunzip -c "$DUMP_FILE" > "$DUMP_TMP"; then
        die "解凍に失敗しました。ファイルが破損している可能性があります"
    fi
    RESTORE_FILE="$DUMP_TMP"
else
    RESTORE_FILE="$DUMP_FILE"
fi

[[ -s "$RESTORE_FILE" ]] || die "ダンプファイルが空です"
head -n 2 "$RESTORE_FILE" | grep -q "PostgreSQL database dump" || \
    die "ダンプのヘッダが不正です（pg_dump の形式ではありません）"
tail -n 5 "$RESTORE_FILE" | grep -q "PostgreSQL database dump complete" || \
    die "ダンプが完了していません（フッタが不正）"

log "整合性チェックに成功しました"

# ---------------------------------------------------------------------------
# 確認と実行
# ---------------------------------------------------------------------------
if [[ "$ASSUME_YES" != "1" ]]; then
    echo ""
    echo "警告: この操作は現在のデータベース '$DB_NAME' の内容をダンプの内容で上書きします。"
    read -r -p "続行しますか? (yes/no): " answer
    [[ "$answer" == "yes" ]] || die "中断しました"
fi

log "リストアを実行しています..."
if ! docker exec -i "$DOCKER_CONTAINER_NAME" \
    psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' \
    < "$RESTORE_FILE" > /tmp/misskey_restore_psql.log 2>&1; then
    tail -n 30 /tmp/misskey_restore_psql.log >&2
    die "リストア中にエラーが発生しました。上のログを確認してください"
fi

AFTER_TABLES=$(count_tables)
log "リストア完了: public テーブル数 ${BEFORE_TABLES} → ${AFTER_TABLES}"

if [[ "$AFTER_TABLES" -le 0 ]]; then
    die "リストア後のテーブル数が 0 です。データが正しく戻っていない可能性があります"
fi

log "ヒント: Misskey アプリケーションを再起動してください（例: docker compose restart web）"
log "リストアは完了しました"
