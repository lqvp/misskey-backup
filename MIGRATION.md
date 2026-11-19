# 移行手順（旧 backup.sh → v2）

旧スクリプト（設定直書き版）から v2（backup.env 版）への移行手順です。
動作中のサーバーで行います。所要時間は 10〜15 分、バックアップの空きが
ない時間帯（深夜など）を推奨しますが、手順自体は任意の時間に実行できます。

## 前提

- 旧スクリプトは `/home/misskey/backup.sh` で cron 登録されているものとします
  （README の `0 4 * * * /home/misskey/backup.sh` 想定）
- 新ファイルは `/home/misskey/misskey-backup/` に配置する想定で書きます

## 1. 事前確認

```bash
# jq が入っているか（通知を使う場合に必要）
command -v jq || sudo apt install -y jq

# gdrive のパスを確認（旧スクリプトの GDRIVE_PATH と同じもの）
command -v gdrive
```

## 2. 新ファイルの設置

```bash
cd /home/misskey
git clone https://github.com/lqvp/misskey-backup.git misskey-backup
# すでに clone 済みなら git pull で最新に

cd misskey-backup
cp backup.env.example backup.env
chmod 600 backup.env
chmod +x backup.sh
```

## 3. 設定の移行

旧スクリプト `/home/misskey/backup.sh` 冒頭の USER CONFIGURATION の値を
`backup.env` に転記します。

| 旧スクリプトの変数 | backup.env の項目 | 備考 |
|---|---|---|
| `DB_USER` | `DB_USER` | そのまま |
| `DB_NAME` | `DB_NAME` | そのまま |
| `DOCKER_CONTAINER_NAME` | `DOCKER_CONTAINER_NAME` | そのまま |
| `BACKUP_DIR` | `BACKUP_DIR` | そのまま |
| `MISSKEY_INSTANCE` | `MISSKEY_INSTANCE` | そのまま |
| `MISSKEY_TOKEN` | `MISSKEY_TOKEN` | そのまま |
| `DISCORD_WEBHOOK_URL` | `DISCORD_WEBHOOK_URL` | そのまま |
| `GDRIVE_PARENT_ID` | `GDRIVE_PARENT_ID` | そのまま |
| `GDRIVE_PATH` | `GDRIVE_PATH` | 絶対パス推奨 |
| （なし） | `RETENTION_DAYS` | 旧デフォルトは 14 |
| （なし） | `COMPRESS_DUMP` | 圧縮したくなければ 0 |

## 4. テスト実行

cron はまだ触りません。手動で 1 回実行して動作確認します。

```bash
/home/misskey/misskey-backup/backup.sh
```

確認ポイント:

- `backup.env` と同じディレクトリの `BACKUP_DIR` に
  `misskey_backup_YYYYMMDDHHMMSS.sql.gz`（または `.sql`）が生成される
- 同ディレクトリに `backup_YYYYMMDDHHMMSS.log` が出力される
- Discord / Misskey に「開始」「完了」の通知が届く
- Google Drive の指定フォルダにファイルがアップロードされる

失敗する場合は `BACKUP_DIR` 内のログファイルにエラー内容が出ています。

## 5. cron の切替

```bash
crontab -e
```

古い行をコメントアウトまたは削除し、新しい行を追加します。

```
# 0 4 * * * /home/misskey/backup.sh
0 4 * * * /home/misskey/misskey-backup/backup.sh
```

## 6. 旧スクリプトの退役

新設定で数日運用して問題がなければ、旧スクリプトを削除します。

```bash
mv /home/misskey/backup.sh /home/misskey/backup.sh.old
# 数日〜1週間問題なければ削除
# rm /home/misskey/backup.sh.old
```

## トラブルシューティング

- **「設定ファイルが見つかりません」**: `backup.env` が `backup.sh` と同じ
  ディレクトリ（または `/etc/misskey-backup/`）にあるか確認してください。
- **「別のバックアップが実行中です」**: 前回実行が異常終了した場合でも
  `flock` は自動解除されるため、基本的に待つか、他の cron が重なっていないか
  確認してください。
- **Google Drive にアップロードされない**: `gdrive` の認証が切れていないか、
  `GDRIVE_PARENT_ID` が正しいか確認してください。
