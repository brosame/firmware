#!/bin/sh

set -eu

BASE_DIR=$(cd "$(dirname "$0")/.."; pwd)
CONTROL_BIN="$BASE_DIR/bin/te-control.sh"
VERSION_STABLE="0.4-5"


ACTION=help
test $# -gt 0 && ACTION=$1 && shift

# get random MAC address
# echo 'import random; print ":".join(["%02X" % random.randint(0, 255) for index in range(6)])' | python


case "$ACTION" in
	start)
		"$CONTROL_BIN" start-net switch olsr1
		"$CONTROL_BIN" start-net switch olsr2
		"$CONTROL_BIN" start-net switch client_user
		"$CONTROL_BIN" start-net switch client_wifidog
		"$CONTROL_BIN" start-net switch uplink
		"$CONTROL_BIN" start-net capture uplink eth0
		"$CONTROL_BIN" start-host 0 ap1.201 "$VERSION_STABLE" x86 olsr1 "DD:4B:E3:A7:98:F9" uplink "46:98:2C:8A:46:50"
		"$CONTROL_BIN" start-host 1 ap1.202 "$VERSION_STABLE" x86 olsr1 "5D:6E:A9:9E:AE:6F" olsr2 "FC:EF:67:F8:62:B3"
		"$CONTROL_BIN" start-host 2 ap1.203 "$VERSION_STABLE" x86 olsr2 "23:55:74:4C:5B:C9" client_user "55:16:90:6D:7A:83"
		"$CONTROL_BIN" start-host 3 client_user "$VERSION_STABLE" x86 client_user "DF:CB:6B:80:39:89"
		"$CONTROL_BIN" start-host 4 client_wifidog "$VERSION_STABLE" x86 client_wifidog "A1:D8:AC:59:91:8D"
		# wait for bootup
		echo "Waiting for bootup ..."
		sleep 10
		"$0" configure
		;;
	configure)
		# configure hosts
		config_dir="$BASE_DIR/setup.d"
		for name in ap1.201 ap1.202 ap1.203 client_user client_wifidog; do
			echo "Configuring $name ..."
			"$CONTROL_BIN" apply-config "$name" "$config_dir/_default"
			"$CONTROL_BIN" apply-config "$name" "$config_dir/$name"
			"$CONTROL_BIN" command "$name" reboot
		 done
		;;
	stop)
		for name in ap1.201 ap1.202 ap1.203 client_user client_wifidog; do
			"$CONTROL_BIN" stop-host "$name"
		 done
		for net in olsr1 olsr2 client_user client_wifidog uplink; do
			"$CONTROL_BIN" stop-net "$net"
		 done
		;;
	status)
		"$CONTROL_BIN" status
		;;
	restart)
		"$0" stop
		"$0" start
		;;
	help|--help)
		echo "Syntax $(basename "$0") {start|stop|restart|help}"
		echo
		;;
	*)
		"$0" help >&2
		exit 1
		;;
 esac

exit 0

