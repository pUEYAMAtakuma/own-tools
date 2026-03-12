#!/bin/bash
set -euo pipefail

# ---- 設定 ----
REGION="ap-northeast-1"
LOG_GROUP="/aws/batch/job"
# stream-name / default / hash
LOG_STREAM=""

# 取得期間を限定したい場合は下面を編集（空にするとストリーム全域を取得する）
# 例: FROM_HUMAN='2026-03-01 00:00:00 +09:00'
FROM_HUMAN=''
TO_HUMAN=''

# 出力ファイル
OUT_NDJSON="cw_${LOG_STREAM##*/}_events.ndjson"
OUT_CSV="cw_${LOG_STREAM##*/}_events.csv"

# ---- 日付を ms に変換（指定があれば） ----
if [ -n "$FROM_HUMAN" ]; then
  FROM_MS=$(($(date -d "$FROM_HUMAN" +%s) * 1000))
fi
if [ -n "$TO_HUMAN" ]; then
  TO_MS=$(($(date -d "$TO_HUMAN" +%s) * 1000))
fi

# 初期化
: >"$OUT_NDJSON"

# ---- get-log-events でページング取得 ----
prev_token=""
first_call=true

while :; do
  if $first_call; then
    # 初回（--start-from-head で最初から）
    cmd=(aws logs get-log-events --region "$REGION"
      --log-group-name "$LOG_GROUP"
      --log-stream-name "$LOG_STREAM"
      --start-from-head)
    [ -n "${FROM_MS:-}" ] && cmd+=(--start-time "$FROM_MS")
    [ -n "${TO_MS:-}" ] && cmd+=(--end-time "$TO_MS")
    first_call=false
  else
    # 続き（next token を指定）
    cmd=(aws logs get-log-events --region "$REGION"
      --log-group-name "$LOG_GROUP"
      --log-stream-name "$LOG_STREAM"
      --next-token "$prev_token")
  fi

  resp="$("${cmd[@]}")"

  # events[] を NDJSON で追記
  echo "$resp" | jq -c '.events[]' >>"$OUT_NDJSON"

  # 次トークンを確認（終了条件）
  token=$(echo "$resp" | jq -r '.nextForwardToken // empty')
  if [ -z "$token" ]; then
    break
  fi
  # トークンが変わらなければ終了（繰り返し防止）
  if [ "$token" = "$prev_token" ]; then
    break
  fi
  prev_token="$token"
done

# ---- NDJSON -> CSV (timestamp(ms), timestamp(JST), message) ----
# CSV ヘッダ
printf '%s\n' '"timestamp_ms","timestamp_jst","message"' >"$OUT_CSV"

# 各行を加工して出力（メッセージ中の " を "" にエスケープ）
while IFS= read -r line; do
  ts=$(echo "$line" | jq -r '.timestamp')
  msg=$(echo "$line" | jq -r '.message' | sed 's/"/""/g')
  # JST 表示（date が GNU date の環境を想定）
  timestamp_jst=$(TZ=Asia/Tokyo date -d "@$((ts / 1000))" '+%Y-%m-%d %H:%M:%S%z')
  # CSV に追記
  printf '%s,"%s","%s"\n' "$ts" "$timestamp_jst" "$msg" >>"$OUT_CSV"
done <"$OUT_NDJSON"

echo "完了: $OUT_NDJSON と $OUT_CSV を作成しました。"

# 大きいファイルは S3 にコピーする例（必要なら有効化）
# aws s3 cp "$OUT_NDJSON" s3://your-bucket/path/
# aws s3 cp "$OUT_CSV" s3://your-bucket/path/
