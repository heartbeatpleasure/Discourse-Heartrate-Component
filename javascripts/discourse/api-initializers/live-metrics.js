import { apiInitializer } from "discourse/lib/api";
import I18n from "I18n";

function themeSetting(key, fallback = null) {
  if (typeof settings !== "undefined" && Object.prototype.hasOwnProperty.call(settings, key)) {
    return settings[key];
  }

  return fallback;
}

function enabledSetting(value, fallback = true) {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }

  if (value === false || value === "false" || value === 0 || value === "0") {
    return false;
  }

  return true;
}

function stringSetting(value) {
  return typeof value === "string" ? value.trim() : "";
}

export default apiInitializer("1.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  const pluginEnabled = siteSettings?.live_metrics_enabled !== false;
  const navEnabled = siteSettings?.live_metrics_nav_enabled !== false;
  const themeNavEnabled = enabledSetting(themeSetting("show_nav_item", true));

  if (!pluginEnabled || !navEnabled || !themeNavEnabled) {
    return;
  }

  const customText = stringSetting(themeSetting("nav_item_text", ""));
  const label = customText.length ? customText : I18n.t("live_metrics.title");

  api.addNavigationBarItem({
    name: "live-metrics",
    displayName: label,
    href: "/live-metrics",
    title: label,
  });
});
