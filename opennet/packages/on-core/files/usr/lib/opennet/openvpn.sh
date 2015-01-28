## @defgroup openvpn OpenVPN (allgemein)
## @brief Vorbereitung, Konfiguration und Prüfung von VPN-Verbindunge (z.B. für Nutzertunnel oder UGW). 
# Beginn der opnvpn-Doku-Gruppe
## @{


VPN_DIR_TEST=/etc/openvpn/opennet_vpntest
OPENVPN_CONFIG_BASEDIR=/var/etc/openvpn


## @fn enable_openvpn_service()
## @brief Erzeuge eine funktionierende openvpn-Konfiguration (Datei + UCI).
## @param service_name Name eines Dienstes
## @details Die Konfigurationsdatei wird erzeugt und eine openvpn-uci-Konfiguration wird angelegt.
##   Falls zu diesem openvpn-Dienst kein Zertifikat oder kein Schlüssel gefunden wird, dann passiert nichts.
enable_openvpn_service() {
	trap "error_trap enable_openvpn_service '$*'" $GUARD_TRAPS
	local service_name="$1"
	if ! openvpn_service_has_certificate_and_key "$service_name"; then
		msg_info "Refuse to enable openvpn server ('$service_name'): missing key or certificate"
		trap "" $GUARD_TRAPS && return 1
	fi
	local uci_prefix="openvpn.$service_name"
	local config_file=$(get_service_value "$service_name" "config_file")
	# zukuenftige config-Datei referenzieren
	update_vpn_config "$service_name"
	# zuvor ankuendigen, dass zukuenftig diese uci-Konfiguration an dem Dienst haengt
	service_add_uci_dependency "$service_name" "$uci_prefix"
	# lege die uci-Konfiguration an und aktiviere sie
	uci set "${uci_prefix}=openvpn"
	uci set "${uci_prefix}.enabled=1"
	uci set "${uci_prefix}.config=$config_file"
	apply_changes openvpn
}


## @fn update_vpn_config()
## @brief Schreibe eine openvpn-Konfigurationsdatei.
## @param service_name Name eines Dienstes
update_vpn_config() {
	trap "error_trap update_vpn_config '$*'" $GUARD_TRAPS
	local service_name="$1"
	local config_file=$(get_service_value "$service_name" "config_file")
	service_add_file_dependency "$service_name" "$config_file"
	# Konfigurationsdatei neu schreiben
	mkdir -p "$(dirname "$config_file")"
	get_openvpn_config "$service_name" >"$config_file"
}


## @fn disable_openvpn_service()
## @brief Löschung einer openvpn-Verbindung
## @param service_name Name eines Dienstes
## @details Die UCI-Konfiguration, sowie alle anderen mit der Verbindung verbundenen Elemente werden entfernt.
##   Die openvpn-Verbindung bleibt bestehen, bis zum nächsten Aufruf von 'apply_changes openvpn'.
disable_openvpn_service() {
	trap "error_trap disable_openvpn_service '$*'" $GUARD_TRAPS
	local service_name="$1"
	# Abbruch, falls es keine openvpn-Instanz gibt
	[ -z "$(uci_get "openvpn.$service_name")" ] && return 0
	# openvpn wird automatisch neugestartet
	cleanup_service_dependencies "$service_name"
	# nach einem reboot sind eventuell die dependencies verlorengegangen - also loeschen wir manuell
	uci_delete "openvpn.$service_name"
}


## @fn is_openvpn_service_active()
## @brief Prüfung ob eine openvpn-Verbindung besteht.
## @param service_name Name eines Dienstes
## @details Die Prüfung wird anhand der PID-Datei und der Gültigkeit der enthaltenen PID vorgenommen.
is_openvpn_service_active() {
	local service_name="$1"
	local pid_file
	local pid
	# existiert ein VPN-Eintrag?
	[ -z "$(uci_get "openvpn.$service_name")" ] && trap "" $GUARD_TRAPS && return 1
	# gibt es einen Verweis auf eine passende PID-Datei?
	check_pid_file "$(get_service_value "$service_name" "pid_file")" "openvpn" && return 0
	trap "" $GUARD_TRAPS && return 1
}


## @fn get_openvpn_config()
## @brief liefere openvpn-Konfiguration eines Dienstes zurück
## @param service_name Name eines Dienstes
get_openvpn_config() {
	trap "error_trap get_openvpn_config '$*'" $GUARD_TRAPS
	local service_name="$1"
	local remote=$(get_service_value "$service_name" "host")
	local port=$(get_service_value "$service_name" "port")
	local protocol=$(get_service_value "$service_name" "protocol")
	[ "$protocol" = "tcp" ] && protocol=tcp-client
	local template_file=$(get_service_value "$service_name" "template_file")
	local pid_file=$(get_service_value "$service_name" "pid_file")
	# schreibe die Konfigurationsdatei
	echo "# automatically generated by $0"
	echo "remote $remote $port"
	echo "proto $protocol"
	echo "writepid $pid_file"
	cat "$template_file"
}


## @fn verify_vpn_connection()
## @brief Prüfe einen VPN-Verbindungsaufbau
## @param service_name Name eines Dienstes
## @param key [optional] Schluesseldatei: z.B. $VPN_DIR/on_aps.key
## @param cert [optional] Zertifikatsdatei: z.B. $VPN_DIR/on_aps.crt
## @param ca-cert [optional] CA-Zertifikatsdatei: z.B. $VPN_DIR/opennet-ca.crt
## @returns Exitcode=0 falls die Verbindung aufgebaut werden konnte
verify_vpn_connection() {
	trap "error_trap verify_vpn_connection '$*'" $GUARD_TRAPS
	local service_name="$1"
	local key_file=${2:-}
	local cert_file=${3:-}
	local ca_file=${4:-}
	local temp_config_file="/tmp/vpn_test_${service_name}-$$.conf"
	local file_opts
	local wan_dev
	local openvpn_opts
	local hostname
	local status_output

	msg_debug "start vpn test of <$temp_config_file>"

	# filtere Einstellungen heraus, die wir ueberschreiben wollen
	# nie die echte PID-Datei ueberschreiben (falls ein Prozess laeuft)
	get_openvpn_config "$service_name" | grep -v -E "^(writepid|dev|tls-verify|up|down)[ \t]" >"$temp_config_file"

	# check if it is possible to open tunnel to the gateway (10 sec. maximum)
	# Assembling openvpn parameters ...
	openvpn_opts="--dev null"
	
	# some openvpn options:
	#   ifconfig-noexec: we do not want to configure a device (and mess up routing tables)
	#   route-noexec: keinerlei Routen hinzufuegen
	openvpn_opts="$openvpn_opts --ifconfig-noexec --route-noexec"

	# some timing options:
	#   inactive: close connection after 15s without traffic
	#   ping-exit: close connection after 15s without a ping from the other side (which is probably disabled)
	openvpn_opts="$openvpn_opts --inactive 15 1000000 --ping-exit 15"

	# other options:
	#   verb: verbose level 3 is required for the TLS messages
	#   nice: testing is not too important
	#   resolv-retry: fuer ipv4/ipv6-Tests sollten wir mehrere Versuche zulassen
	openvpn_opts="$openvpn_opts --verb 3 --nice 3 --resolv-retry 3"

	# prevent a real connection (otherwise we may break our current vpn tunnel):
	#   tls-verify: force a tls handshake failure
	#   tls-exit: stop immediately after tls handshake failure
	#   ns-cert-type: enforce a connection against a server certificate (instead of peer-to-peer)
	openvpn_opts="$openvpn_opts --tls-verify /bin/false --tls-exit --ns-cert-type server"

	# nur fuer tcp-Verbindungen
	#   connect-retry: Sekunden Wartezeit zwischen Versuchen
	#   connect-timeout: Dauer eines Versuchs
	#   connect-retry-max: Anzahl moeglicher Wiederholungen
	grep -q "^proto[ \t]\+tcp" "$temp_config_file" &&
		openvpn_opts="$openvpn_opts --connect-retry 1 --connect-timeout 15 --connect-retry-max 1"

	[ -n "$key_file" ] && \
		openvpn_opts="$openvpn_opts --key $key_file" && \
		sed -i "/^key/d" "$temp_config_file"
	[ -n "$cert_file" ] && \
		openvpn_opts="$openvpn_opts --cert $cert_file" && \
		sed -i "/^cert/d" "$temp_config_file"
	[ -n "$ca_file" ] && \
		openvpn_opts="$openvpn_opts --ca $ca_file" && \
		sed -i "/^ca/d" "$temp_config_file"

	# check if the output contains a magic line
	status_output=$(openvpn --config "$temp_config_file" $openvpn_opts || true)
	# read the additional options from the config file (for debug purposes)
	file_opts=$(grep -v "^$" "$temp_config_file" | grep -v "^#" | sed 's/^/--/' | tr '\n' ' ')
	rm -f "$temp_config_file"
	echo "$status_output" | grep -q "Initial packet" && return 0
	msg_debug "openvpn test failed: openvpn $file_opts $openvpn_opts"
	trap "" $GUARD_TRAPS && return 1
}


## @fn openvpn_service_has_certificate_and_key()
## @brief Prüfe ob das Zertifikat eines openvpn-basierten Diensts existiert.
## @returns exitcode=0 falls das Zertifikat existiert
## @details Falls der Ort der Zertifikatsdatei nicht zweifelsfrei ermittelt
##   werden kann, dann liefert die Funktion "wahr" zurück.
openvpn_service_has_certificate_and_key() {
	local service_name="$1"
	local cert_file
	local key_file
	local config_template=$(get_service_value "$service_name" "template")
	# im Zweifelsfall (kein Template gefunden) liefern wir "wahr"
	[ -z "$config_template" ] && return 0
	# Verweis auf lokale config-Datei (keine uci-basierte Konfiguration)
	if [ -e "$config_template" ]; then
		cert_file=$(_get_file_dict_value "$config_template" "cert")
		key_file=$(_get_file_dict_value "$config_template" "key")
	else
		# im Zweifelsfall: liefere "wahr"
		return 0
	fi
	# das Zertifikat scheint irgendwie anders konfiguriert zu sein - im Zeifelsfall: OK
	[ -z "$cert_file" -o -z "$key_file" ] && return 0
	# existiert die Datei?
	[ -e "$cert_file" -a -e "$key_file" ] && return 0
	trap "" $GUARD_TRAPS && return 1
}


## @fn submit_csr_via_http()
## @param upload_url URL des Upload-Formulars
## @param csr_file Dateiname einer Zertifikatsanfrage
## @brief Einreichung einer Zertifikatsanfrage via http (bei http://ca.on)
## @details Eine Prüfung des Ergebniswerts ist aufgrund des auf menschliche Nutzer ausgerichteten Interface nicht so leicht moeglich.
## @todo Umstellung vom Formular auf die zu entwickelnde API
## @returns Das Ergebnis ist die html-Ausgabe des Upload-Formulars.
submit_csr_via_http() {
	trap "error_trap submit_csr_via_http '$*'" $GUARD_TRAPS
        # upload_url: z.B. http://ca.on/csr/csr_upload.php
	local upload_url="$1"
	local csr_file="$2"
	local helper="${3:-}"
	local helper_email="${4:-}"
	curl -q --silent --capath /etc/ssl/certs --form "file=@$csr_file" --form "opt_name=$helper" --form "opt_mail=$helper_email" "$upload_url" && return 0
	# ein technischer Verbindungsfehler trat auf
	trap "" $GUARD_TRAPS && return 1
}

# Ende der openvpn-Doku-Gruppe
## @}
