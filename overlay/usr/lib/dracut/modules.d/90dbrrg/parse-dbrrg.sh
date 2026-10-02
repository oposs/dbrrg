#!/bin/bash
# parse-dbrrg.sh - Parse kernel command line

type info >/dev/null 2>&1 || . /lib/dracut-lib.sh
. /lib/dbrrg-lib.sh

ramroot=$(getarg ramroot=)

if [ -z "$ramroot" ]; then
    warn "No ramroot= parameter found"
    die "Boot parameter ramroot= is required"
fi

# dbrrg_log, not info: under systemd, dracut-lib.sh's info() is a bare echo to
# stdout, and dracut-cmdline.service sends stdout only to the journal
# (StandardError=journal+console, no StandardOutput=). rd.info changes
# nothing about that, so these lines never reached the console.
dbrrg_log "dbrrg: ramroot=$ramroot"
echo "$ramroot" > /tmp/dbrrg-ramroot

# Tell dracut we handle root mounting ourselves
root="dbrrg"
rootok=1

if is_remote_url "$ramroot"; then
    dbrrg_log "dbrrg: Network boot detected"
    echo "rd.neednet=1" >> /etc/cmdline.d/99-dbrrg-network.conf
fi

if getargbool 0 rd.dbrrg.debug; then
    dbrrg_log "dbrrg: Debug mode enabled"
    echo "dbrrg_debug=1" > /tmp/dbrrg-debug
fi

return 0
