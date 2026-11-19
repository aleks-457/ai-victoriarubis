#!/usr/bin/env bash
# agent-watchdog.sh — держит агента живым: перезапускает при падении,
# чистит зависшие копии-дубликаты, замечает исчерпание лимита Claude
# и пишет владельцу напрямую, когда агент сам ответить не может.
set -uo pipefail
export HOME="${HOME:-/root}"
# ~/.local/bin — туда Claude Code ставит себя при самообновлении, ~/.bun/bin —
# движок моста. Без этих двух папок в путях перезапущенный агент падает с
# ошибкой "claude: No such file or directory".
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
# Сторож — системная служба (root, не пользовательская сессия), а команды
# `systemctl --user` (для Hermes-агентов) без этого не видят службы вообще:
# молча решают, что агент упал, хотя он жив. Нужно, даже если Hermes-агентов
# пока нет.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"

LOG="${WATCHDOG_LOG:-$HOME/watchdog.log}"
INTERVAL="${WATCHDOG_INTERVAL:-5}"
COOLDOWN="${WATCHDOG_COOLDOWN:-30}"
GRACE="${WATCHDOG_GRACE:-60}"

# ЗАПОЛНИ ПОД СЕБЯ: имя tmux-сессии -> папка агента (там, где start.sh)
declare -A AGENTS=(
  [agent]="/root/ai-victoriarubis"
)

# Агент на ДРУГОМ движке (Hermes) — не тмукс-сессия, а systemd-служба, живёт
# по своим правилам. Пусто, пока такого агента нет; появится — впиши сюда имя
# службы и путь к его дому (см. раздел про Hermes ниже, после Шага 3).
declare -A HERMES=()
declare -A HERMES_WHO=()

declare -A LAST_RESTART=()
declare -A LIMIT_NOTIFIED=()
declare -A HERMES_DOWN=()
declare -A HERMES_NOTIFIED=()
declare -A HERMES_RESTARTED=()
DOWN_AFTER="${WATCHDOG_HERMES_DOWN_AFTER:-3}"

# Вход в Claude (общий для всех агентов на этом сервере) и зависшие диалоги —
# те же проверки, что у нашей команды (Вика 10.11.2026: все защиты у всех).
CREDS="${WATCHDOG_CREDS:-$HOME/.claude/.credentials.json}"
LOGIN_FROZEN_LIMIT="${WATCHDOG_LOGIN_FROZEN_LIMIT:-10}"
declare -A LOGIN_NOTIFIED=()   # name -> creds mtime when the owner was told the login died
declare -A LOGIN_PANE=()       # name -> pane hash while the banner sits there unchanged
declare -A LOGIN_FROZEN=()     # name -> consecutive passes with that same frozen pane
declare -A DIALOG_SEEN=()      # name -> consecutive passes with a dialog waiting for a key

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

confirm_startup() {
  local name="$1" i scr
  for i in $(seq 1 40); do
    sleep 2
    tmux has-session -t "=$name:" 2>/dev/null || return 0
    scr=$(tmux capture-pane -t "=$name:" -p 2>/dev/null)
    if echo "$scr" | grep -q "bypass permissions on"; then
      log "startup complete for $name"; return 0
    elif echo "$scr" | grep -q "Bypass Permissions mode"; then
      tmux send-keys -t "=$name:" Down; sleep 0.5; tmux send-keys -t "=$name:" Enter
      log "accepted bypass-permissions dialog for $name"
    elif echo "$scr" | grep -q "for local development"; then
      tmux send-keys -t "=$name:" Enter
      log "confirmed dev-channels dialog for $name"
    fi
  done
}

ensure() {
  local name="$1" dir="$2" now last
  tmux has-session -t "=$name:" 2>/dev/null && return 0

  now=$(date +%s)
  last=${LAST_RESTART[$name]:-0}
  if (( now - last < COOLDOWN )); then
    return 0
  fi
  LAST_RESTART[$name]=$now

  if [ -x "$dir/start.sh" ]; then
    tmux new-session -d -s "$name" -c "$dir" "./start.sh"
    confirm_startup "$name" &
    log "restarted $name (dir $dir)"
  else
    log "ERROR $name: no executable start.sh in $dir"
  fi
}

pulse() {
  local name="$1" now last pane_pid
  tmux has-session -t "=$name:" 2>/dev/null || return 0
  now=$(date +%s); last=${LAST_RESTART[$name]:-0}
  (( now - last < GRACE )) && return 0
  pane_pid=$(tmux list-panes -t "=$name:" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$pane_pid" ] || return 0
  # До версии 2.1.252 мост в Telegram был отдельным процессом (bun server.ts),
  # начиная с неё он работает внутри самого claude. Признак живой связи —
  # любой из двух, иначе сторож убивал бы здорового агента каждую минуту.
  if ! pgrep -P "$pane_pid" -f "server.ts" >/dev/null 2>&1 \
     && ! ps -o args= -p "$pane_pid" 2>/dev/null | grep -q "dangerously-load-development-channels"; then
    log "NO PULSE for $name (Telegram bridge dead) — restarting"
    LAST_RESTART[$name]=$now
    tmux kill-session -t "=$name:" 2>/dev/null
  fi
}

sweep() {
  local name="$1" dir="$2" live_pid pid pcwd
  live_pid=$(tmux list-panes -t "=$name:" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$live_pid" ] || return 0
  for pid in $(pgrep -f 'server:dashi-channel' 2>/dev/null); do
    [ "$pid" = "$live_pid" ] && continue
    pcwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    case "$pcwd" in
      "$dir"|"$dir"/*) kill "$pid" 2>/dev/null && log "swept orphan claude $pid for $name (cwd $pcwd)" ;;
    esac
  done
}

# Пишет владельцу напрямую от бота ЭТОГО агента (сам агент недоступен —
# писать должен кто-то другой). Токен и Telegram ID владельца берутся из
# secrets/channel.env агента — тех же, что и сам агент использует.
notify_owner() {
  local src="$1" msg="$2" env_file token uid
  # Обычный агент передаёт свою ПАПКУ (токен в secrets/channel.env), а
  # Hermes-профиль передаёт свой файл .env напрямую — раскладка своя, а
  # смысл тот же: токен бота и твой Telegram-id.
  if [ -f "$src" ]; then env_file="$src"; else env_file="$src/secrets/channel.env"; fi
  token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$env_file" 2>/dev/null | cut -d= -f2-)
  uid=$(grep -m1 -E '^TELEGRAM_ALLOWED_USER_IDS=|^TELEGRAM_ALLOWED_USERS=' "$env_file" 2>/dev/null | cut -d= -f2- | cut -d, -f1)
  if [ -z "$token" ] || [ -z "$uid" ]; then
    log "notify_owner: missing token/user id in $env_file"
    return 1
  fi
  curl -s -m 10 "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${uid}" --data-urlencode "text=${msg}" >/dev/null
}

# check_hermes UNIT DIR WHO — для агента на Hermes: это не тмукс-сессия, а
# systemd-служба пользователя. Если она не "active" три проверки подряд —
# пробуем поднять сама (reset-failed нужен, если systemd уже сдался) и один
# раз пишем владельцу от бота ЭТОГО агента. Восстановление — молча, отдельное
# сообщение об этом было бы просто шумом.
check_hermes() {
  local unit="$1" dir="$2" who="$3" state
  state=$(systemctl --user is-active "$unit" 2>/dev/null)

  if [ "$state" = "active" ]; then
    HERMES_DOWN[$unit]=0
    HERMES_NOTIFIED[$unit]=""
    HERMES_RESTARTED[$unit]=""
    return 0
  fi

  HERMES_DOWN[$unit]=$(( ${HERMES_DOWN[$unit]:-0} + 1 ))
  [ "${HERMES_DOWN[$unit]}" -ge "$DOWN_AFTER" ] || return 0

  if [ -z "${HERMES_RESTARTED[$unit]:-}" ]; then
    HERMES_RESTARTED[$unit]=1
    systemctl --user reset-failed "$unit" 2>/dev/null
    systemctl --user restart "$unit" 2>/dev/null
    log "hermes unit $unit is ${state:-unknown} — tried to revive it"
  fi

  [ -n "${HERMES_NOTIFIED[$unit]:-}" ] && return 0
  notify_owner "$dir/.env" "${who}: я не работаю и не отвечаю в чате. Пробую подняться сама. Если через пару минут молчу — скажи тех-спецу." \
    && HERMES_NOTIFIED[$unit]=1
  log "hermes unit $unit is ${state:-unknown} — notified owner"
}

# Ловит момент "кончился лимит Claude" в две стадии.
#
# Стадия 1 — МЕНЮ. Реальный экран лимита (проверено на скриншоте Вики
# 2026-08-20) — это не баннер, а интерактивное меню:
#     What do you want to do?
#   > 1. Stop and wait for limit to reset
#     2. Upgrade your plan
# Пока оно на экране, claude ждёт нажатия клавиши и НЕ продолжит сам, даже
# когда лимит освободится — раньше это приходилось нажимать руками. Пункт 1
# выбран по умолчанию, поэтому просто Enter отвечает на него правильно.
#
# Стадия 2 — уведомление с точным временем сброса. Формулировка баннера
# "usage limit reached ... resets at ..." и формат времени пока не пойманы
# вживую — это лучшее предположение. Если после реального случая окажется,
# что сторож не поймал момент, подправь регэксп ниже под точный текст с
# экрана, саму проверку не убирай.
check_limit() {
  local name="$1" dir="$2" pane reset_time msg menu=""
  tmux has-session -t "=$name:" 2>/dev/null || return 0
  pane=$(tmux capture-pane -t "=$name:" -p 2>/dev/null)

  if echo "$pane" | grep -qiF 'Stop and wait for limit to reset' \
     && echo "$pane" | grep -qiF 'Upgrade your plan' \
     && echo "$pane" | grep -qiF 'What do you want to do?'; then
    menu=1
    tmux send-keys -t "=$name:" Enter 2>/dev/null
    log "limit prompt answered for $name (chose: stop and wait for reset)"
  fi

  if echo "$pane" | grep -vE '\||grep' | grep -qiE 'usage limit reached|limit reached.*resets?'; then
    [ -n "${LIMIT_NOTIFIED[$name]:-}" ] && return 0
    reset_time=$(echo "$pane" | grep -oiE 'resets?[^0-9]{0,8}[0-9]{1,2}(:[0-9]{2})?\s*(am|pm)?' | tail -1 \
      | grep -oiE '[0-9]{1,2}(:[0-9]{2})?\s*(am|pm)?')
    if [ -n "$reset_time" ]; then
      msg="${name} сейчас недоступен — кончился лимит Claude, освободится примерно в ${reset_time}."
    else
      msg="${name} сейчас недоступен — кончился лимит Claude. Точное время на экране не разобрал."
    fi
    notify_owner "$dir" "$msg" && LIMIT_NOTIFIED[$name]=1
    log "usage-limit hit for $name (reset: ${reset_time:-unknown}), notified owner"
  elif [ -n "${LIMIT_NOTIFIED[$name]:-}" ] && [ -z "$menu" ]; then
    LIMIT_NOTIFIED[$name]=""
    tmux send-keys -t "=$name:" Enter 2>/dev/null
    log "usage-limit cleared for $name, nudged"
  fi
}

# creds_expired — true when the stored Claude token is actually past its expiry.
# Second signal for check_login: the screen text alone is not enough. On
# 2026-08-26 the coder agent had this script's own test fixture on screen, the
# terminal wrapped the line so the quote that marks it as source landed on the
# NEXT visual line, and Vika got a false "вход слетел" alert. The credentials
# file cannot be faked by anything on screen. Unreadable file or missing field →
# "not expired", i.e. stay silent: a false alarm costs Vika's trust, a missed
# one is still caught by pulse() when the bridge dies.
creds_expired() {
  python3 - "$CREDS" <<'PY' 2>/dev/null
import json, sys, time
try:
    exp = json.load(open(sys.argv[1])).get("claudeAiOauth", {}).get("expiresAt", 0)
except Exception:
    sys.exit(1)
sys.exit(0 if exp and exp / 1000 <= time.time() else 1)
PY
}

# check_login — «жив, но вход в Claude слетел»: агент получает сообщения, но на
# каждое отвечает «Login expired · Please run /login». Пишем владельцу один раз;
# когда вход обновили (файл входа переписан) — перезапускаем агента, иначе он
# держит в памяти старый вход.
check_login() {
  local name="$1" dir="$2" pane mtime msg
  tmux has-session -t "=$name:" 2>/dev/null || return 0
  pane=$(tmux capture-pane -t "=$name:" -p 2>/dev/null)
  mtime=$(stat -c %Y "$CREDS" 2>/dev/null || echo 0)

  # Self-display guard, wider than check_limit()'s: agents edit and display this
  # script AND its test (which embeds the literal screen text as a fixture), so a
  # pipe/`grep` filter alone is not enough. Real claude output is bare prose —
  # `● Login expired · Please run /login` — with no quote, backtick or `=` on the
  # line, while every quoted/source form of it carries at least one. Caught before
  # shipping: the coder's own pane held the fixture line and would have self-alerted.
  if echo "$pane" | grep -vE "\||grep|[\"'\`=]" | grep -qiE 'login expired|please run /login'; then
    if [ -z "${LOGIN_NOTIFIED[$name]:-}" ]; then
      if ! creds_expired; then
        # The file says the token is fine, the screen says it is not. Both can be
        # true at once: a token that was REVOKED (a second session logging in on
        # the same subscription) keeps a future expiresAt, so creds_expired()
        # misses it entirely. That happened to Liza on 2026-09-23 — she sat
        # blocked for seven minutes on the morning of Vika's investor talk while
        # this branch logged "NOT notifying" every six seconds.
        #
        # So do not trust the file alone: watch whether the agent is actually
        # doing anything. A blocked agent's pane freezes — same bytes pass after
        # pass. A working agent that merely has this text on screen keeps
        # redrawing, which resets the counter and keeps us quiet.
        local hash; hash=$(printf '%s' "$pane" | cksum)
        if [ "$hash" = "${LOGIN_PANE[$name]:-}" ]; then
          LOGIN_FROZEN[$name]=$(( ${LOGIN_FROZEN[$name]:-0} + 1 ))
        else
          LOGIN_PANE[$name]="$hash"
          LOGIN_FROZEN[$name]=1
        fi

        if [ "${LOGIN_FROZEN[$name]}" -lt "$LOGIN_FROZEN_LIMIT" ]; then
          # Log only the first sighting: this branch runs every pass and used to
          # bury the log under one identical line per agent per six seconds.
          [ "${LOGIN_FROZEN[$name]}" -eq 1 ] && \
            log "login-expired phrase seen for $name, token file still valid — watching whether the screen is frozen"
          return 0
        fi
        log "login-expired phrase frozen on screen for $name over ${LOGIN_FROZEN[$name]} passes — token was revoked, not expired; notifying"
      fi
      msg="У меня слетел вход в Claude (${name}) — я получаю ваши сообщения, но ответить не могу. Зайдите на сервер, наберите claude и войдите заново командой /login — как вход обновится, я поднимусь сам."
      # Remember the credentials mtime AT alert time: a newer one later means Vika
      # logged in again. Flag stays empty if the alert failed to send, so she gets
      # told on the next pass rather than never.
      notify_owner "$dir" "$msg" && LOGIN_NOTIFIED[$name]="$mtime"
      log "login expired for $name, notified owner"
    elif [ "$mtime" -gt "${LOGIN_NOTIFIED[$name]}" ]; then
      # Still stuck, but the login was refreshed — restart so the new token is
      # read; the process keeps the dead one in memory and ignores Enter.
      LOGIN_NOTIFIED[$name]=""
      tmux kill-session -t "=$name:" 2>/dev/null
      log "login refreshed for $name, restarting so it picks up the new token"
    fi
  else
    # No banner on screen: whatever we were watching is over. Clear the frozen
    # counter too, or the next episode inherits a full count and fires at once.
    LOGIN_PANE[$name]=""
    LOGIN_FROZEN[$name]=0
    if [ -n "${LOGIN_NOTIFIED[$name]:-}" ]; then
      # Banner gone on its own (someone restarted it by hand) — episode over.
      LOGIN_NOTIFIED[$name]=""
      log "login restored for $name"
    fi
  fi
}

# check_login_soon — warn the owner a few days BEFORE the Claude login ends, so the
# agents never go mute on "Login expired" first (Vika 10.11.2026: every team gets
# every protection; check_login() only catches it after the fact). Deadline: a
# long-lived `claude setup-token` file wins (valid one year from when it was
# written); otherwise refreshTokenExpiresAt from the credentials file. Read from
# files only, never by running claude (live probes have revoked logins before).
# One warning per login, remembered on disk; a new login re-arms it by itself.
LONG_TOKEN="${WATCHDOG_LONG_TOKEN:-$(dirname "$CREDS")/../.claude-oauth-token}"
LOGIN_SOON_STATE="${WATCHDOG_LOGIN_SOON_STATE:-$(dirname "$LOG")/login-soon.notified}"
LOGIN_WARN_DAYS="${WATCHDOG_LOGIN_WARN_DAYS:-3}"
check_login_soon() {
  local info exp left when first
  info=$(python3 - "$CREDS" "$LONG_TOKEN" "$LOGIN_WARN_DAYS" <<'PY' 2>/dev/null
import json, os, sys, time, datetime as dt
creds, token, days = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    if os.path.isfile(token) and os.path.getsize(token) > 0:
        exp = int((os.path.getmtime(token) + 365 * 86400) * 1000)
    else:
        exp = int(json.load(open(creds))["claudeAiOauth"]["refreshTokenExpiresAt"])
except Exception:
    sys.exit(1)
left = exp / 1000 - time.time()
if not 0 < left <= days * 86400:
    sys.exit(1)
when = dt.datetime.fromtimestamp(exp / 1000, dt.timezone(dt.timedelta(hours=3))).strftime("%d.%m в %H:%M")
print(exp, max(1, round(left / 86400)), when)
PY
) || return 0
  read -r exp left when <<<"$info"
  [ "$exp" = "$(cat "$LOGIN_SOON_STATE" 2>/dev/null)" ] && return 0
  first=$(printf '%s\n' "${!AGENTS[@]}" | sort | head -1)
  if notify_owner "${AGENTS[$first]}" "Через ${left} дн. (${when} по Москве) у агентов закончится вход в Claude, и они замолчат. Заранее зайдите на сервер, наберите claude и войдите заново командой /login — тогда агенты не замолчат."; then
    echo "$exp" >"$LOGIN_SOON_STATE"
    log "login ends in ${left}d (${when}), warned owner"
  fi
}

# unblock_dialog — агент завис на окне с вопросом (подсказка «esc to cancel»),
# а сам ничего не делает: несколько проверок подряд → нажимаем Escape.
unblock_dialog() {
  local name="$1" screen
  screen=$(tmux capture-pane -p -t "=$name:" 2>/dev/null) || return 0
  if grep -qiF 'esc to interrupt' <<<"$screen" \
     || ! grep -qiE 'esc to (cancel|back)' <<<"$screen"; then
    DIALOG_SEEN[$name]=0
    return 0
  fi
  # Не с первого взгляда: диалог, который агент закрывает сам, живёт доли
  # секунды, а зависший висит все проверки подряд.
  DIALOG_SEEN[$name]=$(( ${DIALOG_SEEN[$name]:-0} + 1 ))
  [ "${DIALOG_SEEN[$name]}" -ge "$DOWN_AFTER" ] || return 0
  tmux send-keys -t "=$name:" Escape 2>/dev/null
  DIALOG_SEEN[$name]=0
  log "closed a blocking dialog for $name"
}

# check_hermes_limit UNIT DIR WHO — the GPT twin of check_limit (Vika's hard rule: tell the
# owner once when the plan limit runs out, with the time it comes back; say so again when it
# is back). Hermes keeps that state in the profile's auth.json: each ChatGPT login of the
# profile is marked "exhausted" with last_error_reset_at. While one login is still fine the
# pool just switches to it — no alert. Read from the file only, never by calling the model.
HERMES_TZ="${WATCHDOG_HERMES_TZ:-3}"
HERMES_TZ_LABEL="${WATCHDOG_HERMES_TZ_LABEL:-по Москве}"
declare -A HLIMIT_NOTIFIED=()
_hermes_limit_one() {
  local unit="$1" dir="$2" who="$3" back when
  back=$(python3 - "$dir/auth.json" "$HERMES_TZ" <<'PY' 2>/dev/null
import json, sys, time, datetime as dt
try:
    pool = (json.load(open(sys.argv[1])).get("credential_pool") or {}).get("openai-codex") or []
except Exception:
    sys.exit(1)
if not pool:
    sys.exit(1)
now, resets = time.time(), []
for c in pool:
    if c.get("last_status") != "exhausted":
        sys.exit(1)
    r = c.get("last_error_reset_at") or 0
    if r > 1e12:
        r /= 1000
    if r and r <= now:
        sys.exit(1)  # this login is already back
    resets.append(r)
if not all(resets):
    print("?"); sys.exit(0)
tz = dt.timezone(dt.timedelta(hours=float(sys.argv[2])))
print(dt.datetime.fromtimestamp(min(resets), tz).strftime("%H:%M"))
PY
)
  if [ -n "$back" ]; then
    [ -n "${HLIMIT_NOTIFIED[$unit]:-}" ] && return 0
    if [ "$back" = "?" ]; then when="когда вернётся, пока не видно"; else when="вернётся примерно в $back $HERMES_TZ_LABEL"; fi
    notify_owner "$dir/.env" "${who}: кончился лимит ChatGPT, пока не отвечаю — ${when}. Срочное лучше отдать другому агенту." \
      && HLIMIT_NOTIFIED[$unit]=1
    log "hermes $unit: ChatGPT limit, back ~$back, notified owner"
  elif [ -n "${HLIMIT_NOTIFIED[$unit]:-}" ]; then
    HLIMIT_NOTIFIED[$unit]=""
    notify_owner "$dir/.env" "${who}: лимит ChatGPT вернулся, снова отвечаю. Если последнее сообщение осталось без ответа — отправьте его ещё раз."
    log "hermes $unit: ChatGPT limit over, told owner"
  fi
}

# New Hermes (v0.23, 11.11.2026) serves every profile from ONE host gateway, so one HERMES entry
# stands for several agents, each with its own ChatGPT login. The host entry therefore also
# checks every profile that has no gateway unit of its own (old-style per-profile units are
# separate entries, or switched off on purpose) and alerts from that profile's own bot.
check_hermes_limit() {
  local unit="$1" dir="$2" who="$3" root home p name
  _hermes_limit_one "$unit" "$dir" "$who"
  [ "$unit" = hermes-gateway.service ] || return 0
  root="${dir%/profiles/*}"; home="${root%/.hermes}"
  # only new Hermes serves profiles from the host gateway; on old Hermes they run their own
  grep -qs "does not get a gateway of its own" "$home/.hermes/hermes-agent/hermes_cli/gateway.py" ${HERMES_SRC_PROBE:-/usr/local/lib/hermes-agent/hermes_cli/gateway.py} || return 0
  for p in "$root"/profiles/*/; do
    p="${p%/}"; name="${p##*/}"
    [ "$p" = "$dir" ] && continue
    [ -e "$home/.config/systemd/user/hermes-gateway-$name.service" ] && continue
    [ -f "$p/auth.json" ] || continue
    _hermes_limit_one "$unit#$name" "$p" "$name"
  done
}

main() {
  log "watchdog started (pid $$)"
  while true; do
    for name in "${!AGENTS[@]}"; do
      ensure "$name" "${AGENTS[$name]}"
      sweep  "$name" "${AGENTS[$name]}"
      pulse  "$name"
      check_limit "$name" "${AGENTS[$name]}"
      check_login "$name" "${AGENTS[$name]}"
      unblock_dialog "$name"
    done
    check_login_soon
    for unit in "${!HERMES[@]}"; do
      check_hermes "$unit" "${HERMES[$unit]}" "${HERMES_WHO[$unit]}"
      check_hermes_limit "$unit" "${HERMES[$unit]}" "${HERMES_WHO[$unit]}"
    done
    sleep "$INTERVAL"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
