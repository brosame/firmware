--[[
Opennet Firmware

Copyright 2015 Lars Kruse <devel@sumpfralle.de>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

]]--

require("luci.model.opennet.funcs")
require("nixio.fs")
local report_filename = "/tmp/on_report.tar.gz"


function action_report()
	require("luci.sys")
	if luci.http.formvalue("download") and nixio.fs.access(report_filename) then
		local timestamp = nixio.fs.stat(report_filename, "mtime")
		local fhandle = io.open(report_filename, "r")
		luci.http.header('Content-Disposition', 'attachment; filename="AP-report-%s-%s.tar.gz"' % {
			luci.sys.hostname(), os.date("%Y-%m-%d_%H%M", timestamp)})
		luci.http.prepare_content("application/x-targz")
		luci.ltn12.pump.all(luci.ltn12.source.file(fhandle), luci.http.write)
	else
		if luci.http.formvalue("delete") and nixio.fs.access(report_filename) then
			nixio.fs.remove(report_filename)
		elseif luci.http.formvalue("generate") then
			on_function("run_delayed_in_background", {"0", "generate_report"})
		end
		luci.template.render("opennet/on_report")
	end
end


function get_report_timestamp()
	local info
	if nixio.fs.access(report_filename) then
		info = nixio.fs.stat(report_filename, "mtime")
	else
		info = nil
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json(info)
end


function action_modules()
	require("luci.sys")
	local delay_hint = luci.i18n.translate("Please wait a minute before reloading this page for an updated status.")
	local on_errors = {}
	local on_hints = {}
	-- teile den Query-String als komma-separierte Liste in Token
	local function get_splitted_package_names(text)
		local result = {}
		-- nur gueltige Paketnamen (entsprechend der erlaubten Zeichen) verwenden
		for _, token in ipairs(generic_split(text, "[^,]+")) do
			if parse_string_pattern(token, "a-z-") then
				table.insert(result, token)
			end
		end
		return result
	end
	local remove_packages = get_splitted_package_names(luci.http.formvalue("remove"))
	if not table_is_empty(remove_packages) then
		local args = {}
		for index, value in ipairs(remove_packages) do table.insert(args, value) end
		on_function_background("remove_opennet_modules", args)
		table.insert(on_hints, luci.i18n.translate("Removing modules in background."))
		table.insert(on_hints, delay_hint)
	end
	local install_packages = get_splitted_package_names(luci.http.formvalue("install"))
	if not table_is_empty(install_packages) then
		local args = {}
		for index, value in ipairs(install_packages) do table.insert(args, value) end
		on_function_background("install_from_opennet_repository", args)
		table.insert(on_hints, luci.i18n.translate("Installing modules in background."))
		table.insert(on_hints, delay_hint)
	end
	-- Repository-URL ändern oder Module an- und abschalten
	if luci.http.formvalue("save") then
		-- Modulaktivierung
		for _, module in ipairs(line_split(on_function("get_on_modules"))) do
			if on_bool_function("is_package_installed", {module}) then
				local enabled = on_bool_function("is_on_module_installed_and_enabled", {module})
				if luci.http.formvalue(module .. "_enabled") then
					if not enabled then on_function("enable_on_module", {module}) end
				else
					if enabled then on_function("disable_on_module", {module}) end
				end
			end
		end
		-- Repository-URL
		local current_url = on_function("get_configured_opennet_opkg_repository_url")
		local new_url
		if luci.http.formvalue("repository_url") == "custom" then
			new_url = luci.http.formvalue("repository_url_custom")
		else
			new_url = luci.http.formvalue("repository_url")
		end
		if new_url ~= current_url then
			on_function("set_configured_opennet_opkg_repository_url", {new_url})
		end
	end
	-- das log auslesen
	local modules_log = on_function("get_custom_log_content", {"opkg_opennet"})
	luci.template.render("opennet/on_modules", { on_errors=on_errors, on_hints=on_hints, modules_log=modules_log })
end


function action_settings()
	require("luci.sys")
	local on_errors = {}
	if luci.http.formvalue("save") then
		-- Dienst-Sortierung
		for _, key in ipairs({"use_olsrd_dns", "use_olsrd_ntp"}) do
			if luci.http.formvalue(key) then
				luci.sys.exec("uci set on-core.settings." .. key .. "=1")
			else
				luci.sys.exec("uci set on-core.settings." .. key .. "=0")
			end
		end
		local services_sorting = luci.http.formvalue("services_sorting")
		if services_sorting then
			on_function("set_service_sorting", {services_sorting})
		end
	end
	-- POE passthrough
	if luci.http.formvalue("has_poe_passthrough") then
		if luci.http.formvalue("gpio_switch_poe_passthrough") then
			luci.sys.exec("uci set system.gpio_switch_poe_passthrough.value=1")
		else
			luci.sys.exec("uci set system.gpio_switch_poe_passthrough.value=0")
		end
	end
	on_function("apply_changes", {"on-core"})
	luci.template.render("opennet/on_settings", { on_errors=on_errors })
end


function action_portmapping()
	local uci = require "luci.model.uci"
	local cursor = uci.cursor()
	
	local zones = {}
	if on_bool_function("is_function_available", {"get_active_mig_connections"}) then
		table.insert(zones, on_function("get_variable", {"ZONE_TUNNEL"}))
	end
	table.insert(zones, on_function("get_variable", {"ZONE_MESH"}))
	table.insert(zones, on_function("get_variable", {"ZONE_LOCAL"}))
	table.insert(zones, on_function("get_variable", {"ZONE_WAN"}))
	
	local zone
	for index = 1, #zones do if luci.http.formvalue(zones[index]) then zone = zones[index] end end

	local del_section
	for index = 1, #zones do del_section = luci.http.formvalue(zones[index].."_del_section") if del_section then break end end
	
	local new_src_dport = luci.http.formvalue("src_dport")
	local new_dest_ip = luci.http.formvalue("dest_ip")
	local new_dest_port = luci.http.formvalue("dest_port")
	
	
	if del_section then
		cursor:delete("firewall", del_section)
	elseif zone then
		cursor:section("firewall", "redirect", nil, { src = zone, proto = 'tcpudp', src_dport = new_src_dport, dest_ip = new_dest_ip, dest_port = new_dest_port, target = 'DNAT' })
	end
	if del_section or zone then
		on_function("apply_changes", {"firewall"})
		cursor:unload("firewall")
	end

	luci.template.render("opennet/on_portmapping", { show_more_info = show_more_info })
end
