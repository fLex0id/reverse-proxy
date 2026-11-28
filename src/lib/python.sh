#!/usr/bin/env bash
# ── Python-генератор ─────────────────────────────────────────────────────
py() { RP_CONF=$CONF RP_CLIENTS=$CLIENTS RP_ETC=$ETC python3 -I "$RP_PY" "$@"; }

py_install() { mkdir -p "$LIB"; py_source >"$LIB/rp.py.new" && mv "$LIB/rp.py.new" "$LIB/rp.py" && chmod 644 "$LIB/rp.py"; }
