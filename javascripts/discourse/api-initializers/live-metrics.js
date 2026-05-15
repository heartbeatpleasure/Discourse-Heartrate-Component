import { apiInitializer } from "discourse/lib/api";
import I18n from "I18n";

export default apiInitializer("1.0", (api) => {
  const themeSettings = api.container.lookup("service:theme-settings");
  const siteSettings = api.container.lookup("service:site-settings");

  const pluginEnabled = siteSettings?.live_metrics_enabled !== false;
  const navEnabled = siteSettings?.live_metrics_nav_enabled !== false;
  const themeNavEnabled = themeSettings?.getSetting?.("show_nav_item") !== false;

  if (!pluginEnabled || !navEnabled || !themeNavEnabled) {
    return;
  }

  const customText = themeSettings?.getSetting?.("nav_item_text") || "";
  const label = customText.trim().length ? customText.trim() : I18n.t("live_metrics.title");

  api.addNavigationBarItem({
    name: "live-metrics",
    displayName: label,
    href: "/live-metrics",
    title: label,
  });
});
