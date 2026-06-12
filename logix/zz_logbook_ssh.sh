#!/bin/bash
# MindLab Report Logbook: log SSH interactive login once per session.
# Safe: no popup, no blocking, no bot.py dependency.
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

if [ -n "$SSH_CONNECTION" ] && [ -z "$LOGBOOK_SSH_LOGGED" ]; then
    export LOGBOOK_SSH_LOGGED=1
    export COMPCHEM_SESSION_TYPE="SSH"
    export LOGBOOK_SESSION_ID="ssh-${USER:-unknown}-$$-$(date +%s)"
    if [ -x /opt/software/logix/logbook_ssh_login.py ]; then
        ( /usr/bin/python3 /opt/software/logix/logbook_ssh_login.py >/dev/null 2>&1 & )
    fi
elif [ -z "$COMPCHEM_SESSION_TYPE" ]; then
    export COMPCHEM_SESSION_TYPE="LOCAL"
fi
