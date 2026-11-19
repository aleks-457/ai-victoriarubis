#!/usr/bin/env bash
# daily-report.sh — будильник для ежедневного отчёта владельцу.
# Сам отчёт пишет агент: скрипт только «стучится» в его tmux-сессию с просьбой.
# Запускается из cron (см. crontab -l). Время владельца — МСК+2, сервер в МСК,
# поэтому в cron стоит 18:00 по серверу = 20:00 у владельца.
set -uo pipefail
export HOME="${HOME:-/root}"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

SESSION="${DAILY_REPORT_SESSION:-agent}"
# Telegram id владельца в коде не держим — репозиторий публичный. Берём из
# тех же secrets/channel.env, что использует сам агент (файл в .gitignore).
ENV_FILE="${DAILY_REPORT_ENV_FILE:-$HOME/ai-victoriarubis/secrets/channel.env}"
CHAT_ID="${DAILY_REPORT_CHAT_ID:-}"
[ -n "$CHAT_ID" ] || CHAT_ID=$(grep -m1 -E '^TELEGRAM_ALLOWED_CHAT_IDS=|^TELEGRAM_ALLOWED_USER_IDS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | cut -d, -f1 | tr -d '"\r')
LOG="${DAILY_REPORT_LOG:-$HOME/daily-report.log}"

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

[ -n "$CHAT_ID" ] || { log "chat id not found in $ENV_FILE — skipped"; exit 1; }

tmux has-session -t "=$SESSION:" 2>/dev/null || { log "session $SESSION not found — skipped"; exit 0; }

MSG="Время ежедневного отчёта (20:00 по времени Алексея, МСК+2). Напиши Алексею в Telegram через reply, chat_id ${CHAT_ID}: что сделал за сегодня, что в работе, что ждёт его решения. Коротко, простыми словами. Если за день ничего не делал — так и скажи одной строкой."

tmux send-keys -t "=$SESSION:" -l "$MSG"
sleep 1
tmux send-keys -t "=$SESSION:" Enter
log "nudged $SESSION for the daily report"
