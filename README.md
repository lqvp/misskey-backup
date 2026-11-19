# misskey-backup (v2)

Misskey の PostgreSQL データベースを pg_dump でバックアップし、
Google Drive にアップロードして Discord / Misskey に通知するスクリプトです。

## v2 の主な変更点

- 設定を `backup.env` に分離（トークン等をスクリプト本体から排除）
- `trap ERR` による確実なエラー捕捉とエラー通知
- `flock` による二重起動防止
- ダンプの整合性チェック（ヘッダ・フッタ検証、失敗時の中途ファイル削除）
- ダンプの gzip 圧縮に対応（`COMPRESS_DUMP`）
- アップロード後の MD5 照合による破損検出
- 通知の JSON 組み立てに `jq` を使用（メッセージ内の特殊文字で壊れない）
- ログファイルをバックアップディレクトリに保存（世代削除対象）
- healthchecks.io 対応（`HEALTHCHECK_URL`）
- リストアスクリプト [restore.sh](restore.sh) 同梱

## 必要なもの

- bash 4 以降
- Docker（pg_dump をコンテナ内で実行）
- [glotlabs/gdrive](https://github.com/glotlabs/gdrive)
- `jq`（通知を使う場合）
- `curl`

## 実行

```bash
./backup.sh
```

テスト実行（ダンプ生成のみ、アップロード・通知・削除をスキップ）:

```bash
DRY_RUN=1 ./backup.sh
```

cron で毎日実行する例:

```
0 19 * * * /home/misskey/backup.sh
```

注意: cron の時刻はサーバーのローカルタイムゾーンで解釈されます。
サーバーが UTC の場合、`0 19 * * *` は JST 翌朝 4:00 の実行になります。

## リストア

```bash
./restore.sh /home/misskey/backup/misskey_backup_YYYYMMDDHHMMSS.sql.gz
```

対話確認の後、`public` スキーマを作り直してダンプを復元します。
自動化する場合は `--yes` を付けます。復元後は Misskey を再起動してください。

既存環境からの移行は [MIGRATION.md](MIGRATION.md) を参照してください。

## 設定項目

`backup.env` の各項目の説明は [backup.env.example](backup.env.example) のコメントを参照してください。
