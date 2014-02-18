--[[
LuCI - Lua Configuration Interface

Copyright 2008 Steven Barth <steven@midlink.org>
Copyright 2008 Jo-Philipp Wich <xm@leipzig.freifunk.net>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

$Id: passwd.lua 5448 2009-10-31 15:54:11Z jow $
]]--
f = SimpleForm("password", translate("Router Password"))

pw1 = f:field(Value, "pw1", translate("Password"))
pw1.password = true
pw1.rmempty = false

pw2 = f:field(Value, "pw2", translate("Confirmation"))
pw2.password = true
pw2.rmempty = false

function pw2.validate(self, value, section)
	return pw1:formvalue(section) == value and value
end

function f.handle(self, state, data)
	if state == FORM_VALID then
		local stat = luci.sys.user.setpasswd("root", data.pw1) == 0
		
		if stat then
			f.message = translate("Password successfully changed!")
		else
			f.errmessage = translate("Unknown Error, password not changed!")
		end
		
		data.pw1 = nil
		data.pw2 = nil
    end
	return true
end

return f