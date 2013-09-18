module("luci.controller.commotion-splash.splash", package.seeall)

require "luci.sys"
require "luci.http"
require "luci.model.uci"
require "commotion_helpers"
require "nixio.fs"

function index()
	entry({"admin", "services", "splash"}, call("config_splash"), _("Captive Portal"), 90).dependent=true
	entry({"admin", "services", "splash", "splashtext" }, form("commotion-splash/splashtext"), _("Splashtext"), 10).dependent=true
	entry({"admin", "services", "splash", "submit" }, call("config_submit")).dependent=true
	entry({"commotion","splash"}, template("commotion-splash/splash"))
end

function config_splash(error_info, bad_settings)
  local splash
  
  -- get settings
  if bad_settings then
    splash = bad_settings
  else
    local current_ifaces = luci.sys.exec("grep '^GatewayInterface' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
    local list = list_ifaces()
    splash = {zones={}, selected_zones={}, whitelist={}, blacklist={}, ipaddrs={}}
    
    -- get current zone(s) set in nodogsplash --> splash.zone_selected
    for zone, iface in pairs(list.zone_to_iface) do
      table.insert(splash.zones,zone)
      if current_ifaces:match(iface) then
        table.insert(splash.selected_zones, zone)
      end
    end
  
    -- get redirect
    splash.redirecturl = html_encode(luci.sys.exec("grep -o -E '^RedirectURL .*' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2"):sub(0,-2))
    splash.redirect = splash.redirecturl ~= '' and 1 or 0
    
    -- get autoauth
    local auth = luci.sys.exec("grep -o -E '^AuthenticateImmediately .*' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2"):sub(0,-2)
    splash.autoauth = (auth == "yes" or auth == "true" or auth == "1") and 1 or 0
    
    -- get splash.leasetime
    splash.leasetime = html_encode(luci.sys.exec("grep -o -E '^ClientIdleTimeout [[:digit:]]+' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2"):sub(0,-2))
  
    -- get whitelist, blacklist, ipaddrs
    local whitelist_str = luci.sys.exec("grep -o -E '^TrustedMACList .*' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
    for mac in whitelist_str:gmatch("%x%x:%x%x:%x%x:%x%x:%x%x:%x%x") do
      mac = html_encode(mac)
      table.insert(splash.whitelist,mac)
    end
    
    local blacklist_str = luci.sys.exec("grep -o -E '^BlockedMACList .*' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 2")
    for mac in blacklist_str:gmatch("%x%x:%x%x:%x%x:%x%x:%x%x:%x%x") do
      mac = html_encode(mac)
      table.insert(splash.blacklist,mac)
    end
    
    local ipaddrs_str = luci.sys.exec("grep -o -E '^[^#]*FirewallRule allow from .* #FirewallRule preauthenticated-users' /etc/nodogsplash/nodogsplash.conf |cut -d ' ' -f 4")
    for ipaddr in ipaddrs_str:gmatch("[^%s]+") do
      log(ipaddr)
      ipaddr = html_encode(ipaddr)
      table.insert(splash.ipaddrs,ipaddr)
    end
    
  end
  
  luci.template.render("commotion-splash/splash_settings", {splash=splash, err=error_info})
end

function config_submit()
  local error_info = {}
  local list = list_ifaces()
  local settings = {
    leasetime = luci.http.formvalue("cbid.commotion-splash.leasetime"),
    redirect = luci.http.formvalue("cbid-commotion-splash-redirect"),
    redirecturl = luci.http.formvalue("cbid-commotion-splash-redirecturl"),
    autoauth = luci.http.formvalue("cbid.commotion-splash.autoauth"),
  }
  local range

  for _, opt in pairs({'selected_zones','whitelist','blacklist','ipaddrs'}) do
    if type(luci.http.formvalue("cbid.commotion-splash." .. opt)) == "string" then
      settings[opt] = {luci.http.formvalue("cbid.commotion-splash." .. opt)}
    elseif type(luci.http.formvalue("cbid.commotion-splash." .. opt)) == "table" then
      settings[opt] = luci.http.formvalue("cbid.commotion-splash." .. opt)
    else
      DIE(translate("splash: invalid parameters"))
      return
    end
  end
  
  --input validation and sanitization
  if (not settings.leasetime or settings.leasetime == '' or not is_uint(settings.leasetime)) then
    error_info.leasetime = translate("Clearance time must be an integer greater than zero")
  end
  
  if settings.redirect and settings.redirect ~= "1" then
    DIE(translate("Invalid redirect"))
    return
  end
  
  if settings.redirecturl and settings.redirecturl ~= '' then
    settings.redirecturl = url_encode(settings.redirecturl)
  end
  
  if settings.autoauth and settings.autoauth ~= "1" then
    DIE(translate("Invalid autoauth"))
    return
  end
  
  for _, selected_zone in pairs(settings.selected_zones) do
    if selected_zone and selected_zone ~= "" and not list.zone_to_iface[selected_zone] then
      DIE(translate("Invalid submission...zone ") .. selected_zone .. translate(" doesn't exist"))
      return
    end
  end
  
  for _, mac in pairs(settings.whitelist) do
    if mac and mac ~= "" and not is_macaddr(mac) then
      error_info.whitelist = translate("Whitelist entries must be a valid MAC address")
    end
  end
  
  for _, mac in pairs(settings.blacklist) do
    if mac and mac ~= "" and not is_macaddr(mac) then
      error_info.blacklist = translate("Blacklist entries must be a valid MAC address")
    end
  end
  
  for _, ipaddr in pairs(settings.ipaddrs) do
    if ipaddr and ipaddr ~= "" and is_ip4addr_cidr(ipaddr) then
      range = true
    elseif ipaddr and ipaddr ~= "" and not is_ip4addr(ipaddr) then
      error_info.ipaddrs = translate("Entry must be a valid IPv4 address or address range in CIDR notation")
    end
  end
  
  --finish
  if next(error_info) then
    local list = list_ifaces()
    settings.zones={}
    for zone, iface in pairs(list.zone_to_iface) do
      table.insert(settings.zones,zone)
    end
    error_info.notice = translate("Invalid entries. Please review the fields below.")
    config_splash(error_info, settings)
    return
  else
    --set new values
    local options = {
      gw_ifaces = '',
      ipaddrs = '',
      redirect = settings.redirect and settings.redirecturl and ("RedirectURL " .. settings.redirecturl) or "",
      autoauth = settings.autoauth and "AuthenticateImmediately yes" or "",
      leasetime = settings.leasetime,
      blacklist = '',
      whitelist = ''
    }
    local new_conf_tmpl = [[${gw_ifaces}

FirewallRuleSet authenticated-users {
  FirewallRule allow all
}

FirewallRuleSet preauthenticated-users {
  FirewallRule allow tcp port 53
  FirewallRule allow udp port 53
  FirewallRule allow tcp port 443
  FirewallRule allow to 101.0.0.0/8
  FirewallRule allow to 102.0.0.0/8
  FirewallRule allow to 103.0.0.0/8
  FirewallRule allow to 5.0.0.0/8
  FirewallRule allow to 192.168.1.20
  ${ipaddrs}
}

EmptyRuleSetPolicy users-to-router allow

GatewayName Commotion
${redirect}
${autoauth}
MaxClients 100
ClientIdleTimeout ${leasetime}
ClientForceTimeout ${leasetime}

${blacklist}
${whitelist}
]]

    local gw_iface = "GatewayInterface ${iface}"
    local ipaddr = "FirewallRule allow from ${ip_cidr} #FirewallRule preauthenticated-users"
    
    for _, selected_zone in pairs(settings.selected_zones) do
      if selected_zone and selected_zone ~= '' then
        options.gw_ifaces = options.gw_ifaces .. printf(gw_iface, {iface=list.zone_to_iface[selected_zone]}) .. "\n"
      end
    end
    
    for _, ip_cidr in pairs(settings.ipaddrs) do
      if ip_cidr and ip_cidr ~= '' then
	options.ipaddrs = options.ipaddrs .. printf(ipaddr, {ip_cidr=ip_cidr}) .. "\n"
      end
    end
    
    first = true; for _, mac in pairs(settings.whitelist) do
      if mac and mac ~= '' then
        if first then first = false else options.whitelist = options.whitelist .. ',' end
        options.whitelist = options.whitelist .. mac
      end
    end
    if options.whitelist ~= '' then options.whitelist = "TrustedMACList " .. options.whitelist end
    
    first = true; for _, mac in pairs(settings.blacklist) do
      if mac and mac ~= '' then
        if first then first = false else options.blacklist = options.blacklist .. ',' end
        options.blacklist = options.blacklist .. mac
      end
    end
    if options.blacklist ~= '' then options.blacklist = "BlockedMACList " .. options.blacklist end
    
    local new_conf = printf(new_conf_tmpl, options)
    if not nixio.fs.writefile("/etc/nodogsplash/nodogsplash.conf",new_conf) then
      DIE("splash: failed to write nodogsplash.conf")
    end
    
    luci.http.redirect(".")
    luci.sys.exec("/etc/init.d/nodogsplash stop; sleep 5; /etc/init.d/nodogsplash start")
  end
end
