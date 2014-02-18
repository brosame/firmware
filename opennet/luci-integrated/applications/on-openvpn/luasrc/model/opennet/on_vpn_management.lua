--[[
Opennet Firmware

Copyright 2010 Rene Ejury <opennet@absorb.it>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

$Id: opennet.lua 5485 2009-11-01 14:24:04Z jow $
]]--

function replace_file(source, target)
	if nixio.fs.access(target) then
		nixio.fs.move(target, target.."_bak")
	end
	nixio.fs.move(source, target)
	nixio.fs.remove(target.."_bak")
	nixio.fs.chmod(target, 600)
end

-- type is user or ugw
function upload_file(type)
	local filename = "on_aps"
	if type == "ugw" then filename = "on_ugws" end
	local upload_exists = nixio.fs.access(tmpfile)
	local upload_value = luci.http.formvalue("opensslfile")
	if not upload_exists then return end
	if not nixio.fs.access(SYSROOT.."/etc/openvpn/opennet_"..type) then nixio.fs.mkdirr(SYSROOT.."/etc/openvpn/opennet_"..type) end
	if (string.find(upload_value, ".key")) then
		replace_file(tmpfile, SYSROOT.."/etc/openvpn/opennet_"..type.."/"..filename..".key")
	elseif (string.find(upload_value, ".crt")) then
		replace_file(tmpfile, SYSROOT.."/etc/openvpn/opennet_"..type.."/"..filename..".crt")
	end
end

-- type is user or ugw
function download_file(type, download)
	local filename = "on_aps"
	if type == "ugw" then filename = "on_ugws" end
	local download_fpi = io.open(SYSROOT.."/etc/openvpn/opennet_"..type.."/"..filename.."."..download, "r")
	local uci = require "luci.model.uci"
	local cursor = uci.cursor()
	local on_id = cursor:get("on-core", "settings", "on_id")
	if not on_id then on_id = "X.XX" end
	luci.http.header('Content-Disposition', 'attachment; filename="AP'..on_id..'_'..type..'_%s.'% {os.date("%Y-%m-%d")}..download..'"' )
	--	crt is actually a application/x-x509-ca-cert, but can be ignored here
	luci.http.prepare_content("application/octet-stream")
	luci.ltn12.pump.all(luci.ltn12.source.file(download_fpi), luci.http.write)
end

function check_cert_status(type, certstatus)
	local SYSROOT = os.getenv("LUCI_SYSROOT")
	if not SYSROOT then SYSROOT = "" end		-- SYSROOT is only used for local testing (make runhttpd in luci tree)
	local filename = SYSROOT.."/etc/openvpn/opennet_user/on_aps."
	if type == "ugw" then filename = SYSROOT.."/etc/openvpn/opennet_ugw/on_ugws." end
	certstatus.on_csr_exists = nixio.fs.access(filename.."csr")
	if certstatus.on_csr_exists then
		certstatus.on_csr_date = nixio.fs.stat(filename.."csr", "mtime")
		certstatus.on_csr_modulus = luci.sys.exec("openssl req -noout -modulus -in "..filename.."csr 2>/dev/null | md5sum")
	else
		certstatus.on_csr_date = ""
		certstatus.on_csr_modulus = ""
	end
	certstatus.on_key_exists = nixio.fs.access(filename.."key")
	if certstatus.on_key_exists then
		certstatus.on_key_date = nixio.fs.stat(filename.."key", "mtime")
		certstatus.on_key_modulus = luci.sys.exec("openssl rsa -noout -modulus -in "..filename.."key 2>/dev/null | md5sum")
	else
		certstatus.on_key_date = ""
		certstatus.on_key_modulus = ""
	end
	certstatus.on_crt_exists = nixio.fs.access(filename.."crt")
	if certstatus.on_crt_exists then
		certstatus.on_crt_date = nixio.fs.stat(filename.."crt", "mtime")
		certstatus.on_crt_modulus = luci.sys.exec("openssl x509 -noout -modulus -in "..filename.."crt 2>/dev/null | md5sum")
	else
		certstatus.on_crt_date = ""
		certstatus.on_crt_modulus = ""
	end
	certstatus.on_keycrt_ok = certstatus.on_key_exists and certstatus.on_crt_exists and (certstatus.on_key_modulus == certstatus.on_crt_modulus)
	certstatus.on_keycsr_ok = certstatus.on_key_exists and certstatus.on_csr_exists and (certstatus.on_key_modulus == certstatus.on_csr_modulus)
end

function fill_openssl(uciconfig, openssl)
	local uci = require "luci.model.uci"
	local cursor = uci.cursor()
	openssl.countryName = cursor:get(uciconfig, "openssl", "countryName")
	openssl.provinceName = cursor:get(uciconfig, "openssl", "provinceName")
	openssl.localityName = cursor:get(uciconfig, "openssl", "localityName")
	openssl.organizationalUnitName = cursor:get(uciconfig, "openssl", "organizationalUnitName")
	openssl.organizationName = luci.http.formvalue("openssl.organizationName")
    openssl.commonName = luci.http.formvalue("openssl.commonName")
    if not openssl.commonName then
        on_id = cursor:get("on-core", "settings", "on_id")
        if not on_id then on_id = "X.XX" end
        if (uciconfig == "on-openvpn") then	
            openssl.commonName = on_id..".aps.on"
        else
            openssl.commonName = on_id..".ugw.on"
        end
    end
	openssl.EmailAddress = luci.http.formvalue("openssl.EmailAddress")
	openssl.days = cursor:get(uciconfig, "openssl", "days")
end

function generate_csr(type, openssl)
	local filename = "on_aps"
	if type == "ugw" then filename = "on_ugws" end
	if openssl.organizationName and openssl.commonName and openssl.EmailAddress then
		local command = "export openssl_countryName='"..openssl.countryName.."'; "..
						"export openssl_provinceName='"..openssl.provinceName.."'; "..
						"export openssl_localityName='"..openssl.localityName.."'; "..
						"export openssl_organizationalUnitName='"..openssl.organizationalUnitName.."'; "..
						"export openssl_organizationName='"..openssl.organizationName.."'; "..
						"export openssl_commonName='"..openssl.commonName.."'; "..
						"export openssl_EmailAddress='"..openssl.EmailAddress.."'; "..
						"openssl req -config /etc/ssl/on_openssl.cnf -batch -nodes -new -days "..openssl.days..
							" -keyout "..SYSROOT.."/etc/openvpn/opennet_"..type.."/"..filename..".key"..
							" -out "..SYSROOT.."/etc/openvpn/opennet_"..type.."/"..filename..".csr >/tmp/ssl.out"
		os.execute(command)
		nixio.fs.chmod(SYSROOT.."/etc/openvpn/opennet_"..type.."/"..filename..".key", 600)
		nixio.fs.chmod(SYSROOT.."/etc/openvpn/opennet_"..type.."/"..filename..".csr", 600)
	end
end

SYSROOT = os.getenv("LUCI_SYSROOT")
if not SYSROOT then SYSROOT = "" end		-- SYSROOT is only used for local testing (make runhttpd in luci tree)
tmpfile = SYSROOT.."/tmp/key.file"
-- Install upload handler
local file
luci.http.setfilehandler(
	function(meta, chunk, eof)
		if not nixio.fs.access(tmpfile) and not file and chunk and #chunk > 0 then
			file = io.open(tmpfile, "w")
		end
		if file and chunk then file:write(chunk) end
		if file and eof then file:close() end
	end
)
