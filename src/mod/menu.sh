#!/usr/bin/env bash
# ── Меню ─────────────────────────────────────────────────────────────────
menu_clients() {
  local c
  while :; do cls; banner "Клиенты WG" "OpenWrt и другие"; cl_list
    mhead "Действия"; mi 1 "Добавить"; mi 2 "Конфиг и QR"; mi 3 "Удалить"; mi 0 "Назад"; mpick c
    case $c in 1) (lock; cl_add); pause ;; 2) (cl_show); pause ;; 3) (lock; cl_del); pause ;; 0) return ;; *) warn "Введите число от 0 до 3"; sleep 1 ;; esac
  done
}
menu_ru() {
  local c
  while :; do cls; banner "Российские сайты напрямую" "списки .dat"; cmd_ru status
    mhead "Действия"; mi 1 "Обновить списки"; mi 2 "Включить"; mi 3 "Выключить"; mi 4 "Исключение: через туннель"; mi 5 "Исключение: напрямую"; mi 0 "Назад"; mpick c
    case $c in 1) (lock; cmd_ru update); pause ;; 2) (lock; cmd_ru on); pause ;; 3) (lock; cmd_ru off); pause ;;
      4) local d=""; ask d "Домен" "" '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$' "Нужен домен"; (lock; cmd_ru proxy "$d"); pause ;;
      5) local d=""; ask d "Домен" "" '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$' "Нужен домен"; (lock; cmd_ru direct "$d"); pause ;;
      0) return ;; *) warn "Введите число от 0 до 5"; sleep 1 ;; esac
  done
}
menu_dns() {
  local c v
  while :; do cls; banner "DNS" "DoH через туннель"; cmd_dns show
    mhead "Действия"; mi 1 "Выбрать серверы"; mi 2 "Проверить серверы"; mi 3 "Быстро: Quad9 + Cloudflare"; mi 4 "Быстро: только Quad9"; mi 5 "Российский DNS (IPv4)"; mi 0 "Назад"; mpick c
    case $c in
      1) v=""; ask v "Серверы через пробел (quad9 cloudflare google adguard или https://…/dns-query)" "$(cf DNS_REMOTE)" '^[A-Za-z0-9:/._ -]+$' "Недопустимые символы"; (lock; cmd_dns set "$v"); pause ;;
      2) (lock; cmd_dns test); pause ;; 3) (lock; cmd_dns set quad9 cloudflare); pause ;; 4) (lock; cmd_dns set quad9); pause ;;
      5) v=""; ask v "IPv4 российского DNS (yandex или адрес)" "$(cf DNS_RU 77.88.8.8)" '^[A-Za-z0-9.]+$' "Укажите IPv4"; (lock; cmd_dns ru "$v"); pause ;;
      0) return ;; *) warn "Введите число от 0 до 5"; sleep 1 ;; esac
  done
}
menu_upd() {
  local c
  while :; do cls; banner "Обновления" "Xray, Hysteria2, списки"; cmd_upgrade check
    mhead "Действия"; mi 1 "Обновить Xray"; mi 2 "Обновить Hysteria2"; mi 3 "Обновить списки РФ"; mi 4 "Обновить rp из GitHub (rp.sh)"; mi 0 "Назад"; mpick c
    case $c in 1) (lock; cmd_upgrade xray); pause ;; 2) (lock; cmd_upgrade hy2); pause ;; 3) (lock; cmd_upgrade ru); pause ;; 4) (lock; cmd_upgrade self); pause ;; 0) return ;; *) warn "Введите число от 0 до 4"; sleep 1 ;; esac
  done
}
menu_tunnel() {
  local c
  while :; do cls; banner "Туннель к VPS-2" "$(cf TRANSPORT_ORDER)"; cmd_door list
    mhead "Действия"; mi 1 "Строка для VPS-2 (он сам скачает блок)"; mi 2 "Блок для VPS-2 (вставка вручную)"; mi 3 "Обновить VPS-2 по SSH (откат 30 мин)"; mi 4 "SSH на VPS-2"
    mi 5 "Двери (Reality)"; mi 6 "Сменить секреты"; mi 7 "Проверка сайтов SNI"; mi 8 "Транспорты: результаты проверки"; mi 9 "Исключить неработающие транспорты"; mi 10 "Выбрать активный транспорт (авто / вручную)"; mi 0 "Назад"; mpick c
    case $c in 1) (lock; cmd_link); pause ;; 2) (lock; cmd_block); pause ;; 3) (lock; cmd_push); pause ;; 4) (cmd_ssh); pause ;; 5) (cmd_door list); pause ;; 6) (lock; cmd_rotate); pause ;; 7) (cmd_sni); pause ;;
      8) (cmd_transports); pause ;; 9) (lock; cmd_prune); pause ;; 10) (lock; cmd_tunnel select); pause ;; 0) return ;; *) warn "Введите число от 0 до 10"; sleep 1 ;; esac
  done
}
menu_main() {
  local c
  conf_load
  if (($(cf CONF_VER 1) < 2)); then   # конфигурация от версии 1.0: без перехода меню покажет устаревшие значения
    warn "Конфигурация создана версией 1.0 — нужен переход на $SELF_VERSION (ключи и клиенты сохраняются)"
    yesno "Выполнить rp migrate сейчас?" y && { (lock; cmd_migrate); pause; }
  fi
  while :; do
    conf_load; cls; banner "rp" "VPS-1 · $(cf PUBLIC_IP) · v$SELF_VERSION"
    printf '  Xray %s   WG %s\n' "$(dot_state rp-xray)" "$(dot_state wg-quick@wg0)"
    mhead "Клиенты и туннель"
    mi 1 "Клиенты WG ›" "$(client_names | wc -l) шт."
    mi 2 "Туннель к VPS-2 ›" "$(cf TRANSPORT_ORDER)"
    mi 3 "Российские сайты напрямую ›" "$([[ $(cf RU_DIRECT) == 1 ]] && echo вкл || echo выкл)"
    mi 4 "DNS ›" "DoH: $(cf DNS_REMOTE)"
    mhead "Контроль"
    mi 5 "Проверка T1–T8"; mi 6 "Диагностика выхода (по участкам)"; mi 7 "Сводка (doctor)"; mi 8 "Статус"; mi 9 "Журнал"
    mhead "Обслуживание"
    mi 10 "Обновления (Xray, Hysteria2) >"; mi 11 "Перезапуск"; mi 12 "Удалить rp"
    mi 13 "Сохранить эту версию как команду rp"; mi 14 "Обновить rp из GitHub"; mi 0 "Выход"; mpick c
    case $c in
      1) menu_clients ;; 2) menu_tunnel ;; 3) menu_ru ;; 4) menu_dns ;;
      5) (lock; cmd_test); pause ;; 6) (lock; cmd_diag --fix); pause ;; 7) (cmd_doctor); pause ;; 8) (cmd_status); pause ;; 9) (cmd_logs 60); pause ;;
      10) menu_upd ;; 11) (lock; cmd_restart); pause ;; 12) (lock; cmd_uninstall); pause; [[ -d $STATE ]] || exit 0 ;;   # после удаления меню не нужно
      13) (lock; self_install); pause ;; 14) (lock; self_upgrade); pause ;;
      0) exit 0 ;; *) warn "Введите число от 0 до 14"; sleep 1 ;;
    esac
  done
}

# ── VPS-2 из этого же скрипта ────────────────────────────────────────────
vps2_entry() {
  banner "VPS-2" "выход в интернет"
  note "На VPS-2 всё ставится блоком, который создаёт VPS-1 командой «rp block»."
  note "Блок — чистый bash: бинарники закреплены по SHA256, входящие порты не открываются, туннель инициирует VPS-2."
  yesno "Вставить блок сейчас (в конце — Ctrl-D)?" y || { note "Позже: вставьте блок в консоль или выполните bash block.sh"; return 0; }
  local f; f=$(mktemp); cat >"$f" </dev/tty; [[ -s $f ]] || die "Пусто"
  bash "$f"; local rc=$?; rm -f "$f"; return $rc
}

usage() {
  cat <<EOT
rp $SELF_VERSION — цепочка «клиенты WG → VPS-1 → туннель, устойчивый к ТСПУ → VPS-2»

  rp                       меню (VPS-1) или установка
  rp install               установка; роль VPS-1 / VPS-2 выбирается здесь
  rp migrate               применить версию команды rp с откатом при ошибке
  rp migrate-recover       повторить восстановление прерванной миграции
  rp save                  сохранить запущенную сборку как /usr/local/bin/rp
  rp update                скачать rp.sh из GitHub, установить и выполнить migrate
  VPS-1:
  rp client add|del|list|show [имя]   клиенты WG (конфиг и QR; QR строит сам скрипт)
  rp link [порт]           короткая строка для VPS-2: он сам скачает блок с VPS-1 (одноразовый HTTPS, TTL 30 мин)
  rp block [каталог]       блок для VPS-2 вручную (при большом размере — части с SHA256)
  rp push                  передать блок на VPS-2 по SSH, проверить все T1–T3 (откат через 30 мин)
  rp ssh [команда]         SSH на VPS-2 через туннель (по ключу, с отпечатком host key)
  rp door list|add имя порт хост:порт|del имя    «двери» в Reality-режимах
  rp test [--long] [--restart]   безопасные T1–T7 (T8 только с --restart)
  rp diag [--fix]          диагностика выхода по участкам; --fix исправляет найденное
  rp transports            транспорты и результаты их проверки на VPS-2
  rp tunnel [status|select|sync|recover ТРАНСПОРТ|auto|reality-xhttp2|reality-xhttp|hy2-wg|hy2o-wg]
                           автоматический режим или фиксация одного транспорта на VPS-2
  rp prune                 ручное исключение транспортов (по умолчанию НЕТ; сторож пробует все)
  rp dns [show|set СЕРВЕРЫ|ru [IPv4|yandex]|test]  зарубежные DoH и DNS РФ
  rp doctor                версии на обоих концах, выход
  rp rotate                сменить UUID, пароли, shortId, ключи Reality (с откатом)
  rp upgrade [check|xray [версия]|hy2 [версия]|ru|self]   Xray, Hysteria2, списки, сам rp.sh (с откатом)
  rp ru update|on|off|proxy ДОМЕН|direct ДОМЕН|del ДОМЕН|status   списки РФ
  rp sni [хост…]           проверка кандидатов SNI/masquerade
  rp apply | status | logs [N] | restart | uninstall
  rp --ascii               текстовое оформление для VNC/SPICE Linux-консоли
  rp version | help
Запуск с GitHub: bash <(curl -fsSL $RP_URL)
Настройки: $CONF (после правки — rp apply). Переменная ASSUME_YES=1 — без вопросов.
EOT
}

cmd_install() {
  need_root; os_check; mkdir -p "$ETC" "$STATE"; chmod 755 "$STATE"; : >>"$LOG"; chmod 600 "$LOG"
  conf_load; ROLE_CHOICE=${ROLE_CHOICE:-}
  if [[ $(cf ROLE) == vps1 ]]; then
    local act=""; choose act "rp уже установлен на этом VPS-1" menu \
      "menu|Открыть управление|" "migrate|Перейти на версию $SELF_VERSION|обновить конфигурацию и службы, ключи сохраняются" \
      "reinstall|Изменить настройки|заново пройти вопросы (ключи клиентов сохранятся)" "update|Обновить списки РФ|только списки"
    case $act in menu) maybe_save_launched_build; menu_main; return ;; migrate) lock; cmd_migrate; return ;; update) lock; ru_update --latest; return ;; esac
  fi
  banner "rp $SELF_VERSION" "установка"
  choose ROLE_CHOICE "Роль этого сервера" vps1 \
    "vps1|VPS-1 (Россия)|принимает WG-клиентов и ведёт трафик в туннель" \
    "vps2|VPS-2 (за границей)|выход в интернет; ставится блоком, созданным на VPS-1"
  case $ROLE_CHOICE in vps1) lock; vps1_install ;; vps2) vps2_entry ;; esac
}
