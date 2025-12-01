#!/bin/bash
# parse-dbrrg.sh - Parse kernel command line

type info >/dev/null 2>&1 || . /lib/dracut-lib.sh
. /lib/dbrrg-lib.sh

ramroot=$(getarg ramroot=)

if [ -z "$ramroot" ]; then
    warn "No ramroot= parameter found"
    die "Boot parameter ramroot= is required"
fi

info "dbrrg: ramroot=$ramroot"
echo "$ramroot" > /tmp/dbrrg-ramroot

# Tell dracut we handle root mounting ourselves
root="dbrrg"
rootok=1

if is_remote_url "$ramroot"; then
    info "dbrrg: Network boot detected"
    echo "rd.neednet=1" >> /etc/cmdline.d/99-dbrrg-network.conf
fi

if getargbool 0 rd.dbrrg.debug; then
    info "dbrrg: Debug mode enabled"
    echo "dbrrg_debug=1" > /tmp/dbrrg-debug
fi

return 0
