# misskey-backup (v2)

Misskey の PostgreSQL データベースを pg_dump でバックアップし、
Google Drive にアップロードして Discord / Misskey に通知するスクリプトです。

## v2 の主な変更点

- 設定を `backup.env` に分離（トークン等をスクリプト本体から排除）
- `trap ERR` による確実なエラー捕捉とエラー通知
- `flock` による二重起動防止
- ダンプの整合性チェック（ヘッダ・フッタ検証、失敗時の中途ファイル削除）
- ダンプの gzip 圧縮に対応（`COMPRESS_DUMP`）
- 通知の JSON 組み立てに `jq` を使用（メッセージ内の特殊文字で壊れない）
- ログファイルをバックアップディレクトリに保存

## 必要なもの

- bash 4 以降
- Docker（pg_dump をコンテナ内で実行）
- [glotlabs/gdrive](https://github.com/glotlabs/gdrive)
- `jq`（通知を使う場合）
- `curl`

## セットアップ

```bash
cp backup.env.example backup.env
$EDITOR backup.env   # 値を環境に合わせて編集
chmod 600 backup.env  # トークンを含むため
chmod +x backup.sh
```

## 実行

```bash
./backup.sh
```

または cron で毎日 4 時に実行:

```
0 4 * * * /home/misskey/backup.sh
```

既存環境からの移行は [MIGRATION.md](MIGRATION.md) を参照してください。

## 設定項目

`backup.env` の各項目の説明は [backup.env.example](backup.env.example) のコメントを参照してください。
