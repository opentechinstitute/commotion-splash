module("luci.controller.commotion-splash.splash", package.seeall)

require "luci.i18n"

function index()
	entry({"admin", "services", "splash"}, cbi("commotion-splash/splash_settings"), _("Captive Portal"), 90).dependent=true
end
