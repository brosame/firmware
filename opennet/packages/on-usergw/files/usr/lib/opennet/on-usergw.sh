UGW_STATUS_FILE=/tmp/on-ugw_gateways.status
ON_USERGW_DEFAULTS_FILE=/usr/share/opennet/usergw.defaults
OPENVPN_CONFIG_BASEDIR=/var/etc/openvpn
SPEEDTEST_UPLOAD_PORT=22222
SPEEDTEST_SECONDS=20


# hole einen der default-Werte der aktuellen Firmware
# Die default-Werte werden nicht von der Konfigurationsverwaltung uci verwaltet.
# Somit sind nach jedem Upgrade imer die neuesten Standard-Werte verfuegbar.
get_on_usergw_default() { _get_file_dict_value "$ON_USERGW_DEFAULTS_FILE" "$1"; }


#################################################################################
# Auslesen einer Gateway-Information
# Parameter ip: IP-Adresse des Gateways
# Parameter key: Informationsschluessel ("age", "status", ...)
get_ugw_value() {
	_get_file_dict_value "$UGW_STATUS_FILE" "${1}_${2}"
}


#################################################################################
# Aendere eine gateway-Information
# Parameter ip: IP-Adresse des Gateways
# Parameter key: Informationsschluessel ("age", "status", ...)
# Parameter value: der neue Inhalt
set_ugw_value() {
	_set_file_dict_value "$UGW_STATUS_FILE" "${1}_${2}" "$3"
}


# Ermittle den aktuell definierten UGW-Portforward.
# Ergebnis (tab-separiert fuer leichte 'cut'-Behandlung des Output):
#   lokale IP-Adresse fuer UGW-Forward
#   externer Gateway
# TODO: siehe auch http://dev.on-i.de/ticket/49 - wir duerfen uns nicht auf die iptables-Ausgabe verlassen
get_ugw_portforward() {
	local chain=zone_${ZONE_MESH}_prerouting
	# TODO: vielleicht lieber den uci-Portforward mit einem Namen versehen?
	iptables -L "$chain" -t nat -n | awk 'BEGIN{FS="[ :]+"} /udp dpt:1600 to:/ {printf $3 "\t" $5 "\t" $10; exit}'
}


# Schreibe eine openvpn-Konfigurationsdatei fuer eine mesh-Anbindung.
# Der erste und einzige Parameter ist ein uci-Praefix unterhalb von "on-usergw" (on-usergw.@uplink[x])
rebuild_openvpn_ugw_config() {
	local uci_prefix=$1
	local config_name=$(uci_get "${uci_prefix}.name")
	local hostname=$(uci_get "${uci_prefix}.hostname")
	local port=$(uci_get "${uci_prefix}.port")
	local template=$(uci_get "${uci_prefix}.template")
	local config_file=$OPENVPN_CONFIG_BASEDIR/${config_name}.conf
	# Konfigurationsdatei neu schreiben
	mkdir -p "$(dirname "$config_file")"
	(
		for ipaddr in $(resolve_hostname "$(uci_get "${uci_prefix}.hostname")"); do
			echo "remote $ipaddr $port"
		done
		cat "$template"
	) >"$config_file"
}

# Pruefe alle openvpn-Konfigurationen fuer UGW-Verbindungen.
# Quelle: on-usergw.@uplink[x]
# Ziel: openvpn.on_ugw_*
update_openvpn_ugw_settings() {
	local config_file
	local config_name
	local uci_prefix
	find_all_uci_sections on-usergw uplink type=openvpn | while read uci_prefix; do
		rebuild_openvpn_ugw_config "$uci_prefix"
		config_name=$(uci_get "${uci_prefix}.name")
		# uci-Konfiguration setzen
		uci set "openvpn.${config_name}=openvpn"
		uci set "openvpn.${config_name}.config=$config_file"
		# das Attribut "enable" belassen wir unveraendert
	done
	apply_changes openvpn
}


# Erzeuge einen neuen ugw-Service.
# Ignoriere doppelte Eintraege.
add_openvpn_ugw_service() {
	local hostname=$1
	local port=$2
	local protocol=$3
	local details=$4
	local uci_prefix
	local ipaddr
	local template
	local config_name
	local safe_hostname
	local config_prefix
	if [ "$protocol" = "udp" ]; then
		template=/usr/share/opennet/ugw-openvpn-udp.template
		config_prefix=on_ugw
	else
		msg_info "failed to add openvpn service for UGW due to invalid protocol ($protocol)"
		return 1
	fi
	[ "$protocol" != "tcp" -a "$protocol" != "udp" ] && \
		msg_info "failed to set up openvpn settings for invalid protocol ($protocol)" && return 1
	# Hostnamen anhaengen
	safe_hostname=$(echo "$hostname" | sed 's/[^a-zA-Z0-9]/_/g')
	config_name=openvpn_${config_prefix}_${safe_hostname}_${protocol}_${port}
	uci_prefix=$(find_first_uci_section on-usergw uplink "name=$config_name")
	[ -z "$uci_prefix" ] && uci_prefix=on-usergw.$(uci add on-usergw uplink)
	uci set "${uci_prefix}.name=$config_name"
	uci set "${uci_prefix}.type=openvpn"
	uci set "${uci_prefix}.hostname=$hostname"
	uci set "${uci_prefix}.template=$template"
	uci set "${uci_prefix}.port=$port"
	uci set "${uci_prefix}.details=$details"
	# Zeitstempel auffrischen
	set_ugw_value "$config_name" last_seen "$(date +%s)"
	apply_changes on-usergw
}


# Parse die Liste der via olsrd-nameservice announcierten ugw-Dienste.
# Falls keine UGW-Dienste gefunden werden, bzw. vorher konfiguriert waren, werden die Standard-Opennet-Server eingetragen.
# Speichere diese Liste als on-user.@uplink-Liste.
# Anschliessend werden eventuell Dienste (z.B. openvpn) neu konfiguriert.
update_ugw_services() {
	trap "error_trap update_ugw_services $*" $GUARD_TRAPS
	local scheme
	local ipaddr
	local port
	local proto
	local details
	local hostname
	local service_description
	get_services mesh | cut -f 1,2,3,5,7 | while read scheme ipaddr port proto details; do
		service_description="$scheme://$ipaddr:$port ($proto) $details"
		if [ "$scheme" = "openvpn" ]; then
			hostname=$(echo "$details" | get_from_key_value_list hostname :)
			if [ -n "$hostname" ]; then
				add_openvpn_ugw_service "$hostname" "$port" "$proto" "$details"
			else
				msg_info "ignoring service due to missing hostname: $service_description"
			fi
		else
			msg_info "update_ugw_services: unbekannter ugw-Service: $service_description"
		fi
	done
	# pruefe ob keine UGWs konfiguriert sind - erstelle andernfalls die Standard-UGWs von Opennet
	[ -z "$(find_all_uci_sections on-usergw uplink)" ] && add_default_openvpn_ugw_services
}


# Lies die vorkonfigurierten Opennet-UGW-Server ein und uebertrage sie in die on-usergw-Konfiguration.
# Diese Aktion sollte nur ausgefuehrt werden, wenn keine UGWs eintragen sind (z.B. weil der Nutzende sie versehentlich geloescht hat).
add_default_openvpn_ugw_services() {
	local index=1
	local hostname
	local port
	local proto
	local details
	while [ -n "$(get_on_ugw_default "openvpn_ugw_preset_$index")" ]; do
		get_on_ugw_default "openvpn_ugw_preset_$index" | while read hostname port proto details; do
			add_openvpn_ugw_service "$hostname" "$port" "$proto" "$details"
		done
		: $((index++))
	done
}


get_wan_device() {
	uci_get network.wan.ifname | cut -f 1 -d :
}


# Messung des durchschnittlichen Verkehrs ueber ein Netzwerkinterface innerhalb einer gewaehlten Zeitspanne.
# Parameter: physisches Netzwerkinterface (z.B. eth0)
# Parameter: Anzahl von Sekunden der Messung
# Ergebnis (tab-separiert):
#   RX TX
# (empfangene|gesendete KBytes/s)
get_device_traffic() {
	local device=$1
	local seconds=$2
	ifstat -q -b -i "$(get_wan_device)" "$seconds" 1 | tail -n 1 | awk '{print int($1 + 0.5) "\t" int($2 + 0.5)}'
}


# Pruefe Bandbreite durch kurzen Download-Datenverkehr
measure_download_speed() {
	local host=$1
	wget -q -O /dev/null "http://$host/.big" &
	local pid=$!
	sleep 3
	[ ! -d "/proc/$pid" ] && return
	get_device_traffic "$(get_wan_device)" "$SPEEDTEST_SECONDS" | cut -f 1
	kill "$pid" 2>/dev/null || true
}


# Pruefe Bandbreite durch kurzen Upload-Datenverkehr
measure_upload_speed() {
	local host=$1
	nc "$host" "$SPEEDTEST_UPLOAD_PORT" </dev/zero >/dev/null 2>&1 &
	local pid=$!
	sleep 3
	[ ! -d "/proc/$nc_pid" ] && return
	get_device_traffic "$(get_wan_device)" "$SPEEDTEST_SECONDS" | cut -f 2
	kill "$pid" 2>/dev/null || true
}

