import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import I18n from "I18n";

const PROVIDER_ORDER = ["pulsoid", "hyperate"];
const DEFAULT_VISIBILITY_OPTIONS = [
  { id: "private", label: "Only me" },
  { id: "logged_in", label: "Logged-in users" },
  { id: "public", label: "Public" },
  { id: "staff", label: "Staff only" },
];

function visibilityLabel(id) {
  const option = DEFAULT_VISIBILITY_OPTIONS.find((item) => item.id === id);
  return option?.label || String(id || "").replace(/_/g, " ");
}


function normalizeGenderDetail(value) {
  const rawValue = String(value || "").trim();
  const normalized = rawValue.toLowerCase().replace(/[\s_-]+/g, "-");

  if (["male", "man", "m"].includes(normalized)) {
    return { value: rawValue || "Male", icon: "♂", className: "live-metrics-trait--gender-male" };
  }

  if (["female", "woman", "vrouw", "f"].includes(normalized)) {
    return { value: rawValue || "Female", icon: "♀", className: "live-metrics-trait--gender-female" };
  }

  if (["non-binary", "nonbinary", "non-binair", "nb"].includes(normalized)) {
    return { value: rawValue || "Non-binary", icon: "⚧", className: "live-metrics-trait--gender-non-binary" };
  }

  return { value: rawValue, icon: null, className: "live-metrics-trait--gender-other" };
}

function decorateProfileDetails(details) {
  if (!Array.isArray(details)) {
    return [];
  }

  return details
    .map((detail) => {
      const key = String(detail?.key || "").toLowerCase();
      const value = String(detail?.value || "").trim();

      if (!value) {
        return null;
      }

      if (key === "age") {
        return { key, value, label: "Age", icon: null, className: "live-metrics-trait--age" };
      }

      if (key === "gender") {
        const gender = normalizeGenderDetail(value);
        return { key, label: "Gender", ...gender };
      }

      return null;
    })
    .filter(Boolean);
}

function decorateSettingsAccount(account) {
  if (!account) {
    return null;
  }

  const visibility = account.visibility || "private";

  return {
    ...account,
    active: account.active === true,
    visibility,
    visibility_private: visibility === "private",
    visibility_logged_in: visibility === "logged_in",
    visibility_public: visibility === "public",
    visibility_staff: visibility === "staff",
    live_error: account.live?.error,
  };
}

function decorateAccount(account, nowMs = Date.now()) {
  if (!account) {
    return null;
  }

  const live = account.live || {};
  const status = live.status || "unavailable";
  const heartRate = live.heart_rate;
  const age = liveAgeSeconds(live, nowMs);

  const user = account.user
    ? {
        ...account.user,
        avatar_url: String(account.user.avatar_template || "").replace("{size}", "64"),
        profile_details: decorateProfileDetails(account.user.profile_details),
      }
    : null;

  return {
    ...decorateSettingsAccount(account),
    user,
    row_key: `${account.provider || "provider"}:${account.user?.id || account.user?.username || account.provider_uid || "self"}`,
    bpm_label: heartRate ? `${heartRate} BPM` : "—",
    status_class: `live-metrics-status--${status}`,
    freshness_label: freshnessLabel(status, age, account.provider),
  };
}

function liveAgeSeconds(live, nowMs) {
  const measuredAtMs = Number(live?.measured_at_ms);

  if (Number.isFinite(measuredAtMs) && measuredAtMs > 0) {
    return Math.max(Math.floor((nowMs - measuredAtMs) / 1000), 0);
  }

  const measuredAt = Date.parse(live?.measured_at || "");
  if (Number.isFinite(measuredAt)) {
    return Math.max(Math.floor((nowMs - measuredAt) / 1000), 0);
  }

  return Number.isFinite(live?.age_seconds) ? live.age_seconds : null;
}

function freshnessLabel(status, age, provider) {
  if (status === "live") {
    return "Live now";
  }

  if (status === "delayed" && age !== null) {
    return `Last signal ${formatAge(age)} ago`;
  }

  if (status === "stale") {
    return "No recent signal";
  }

  if (status === "no_data") {
    return "No heart-rate data yet";
  }

  if (status === "unauthorized") {
    return provider === "hyperate" ? "Connection rejected" : "Reconnect required";
  }

  return "Unavailable";
}

function formatAge(seconds) {
  const safeSeconds = Math.max(Number(seconds) || 0, 0);

  if (safeSeconds < 60) {
    return `${safeSeconds}s`;
  }

  const minutes = Math.floor(safeSeconds / 60);
  const remainingSeconds = safeSeconds % 60;

  if (minutes < 60) {
    return remainingSeconds ? `${minutes}m ${remainingSeconds}s` : `${minutes}m`;
  }

  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  return remainingMinutes ? `${hours}h ${remainingMinutes}m` : `${hours}h`;
}

export default class LiveMetricsPage extends Component {
  @service appEvents;
  @tracked config = null;
  @tracked me = null;
  @tracked liveAccount = null;
  @tracked directoryRows = [];
  @tracked loading = true;
  @tracked refreshing = false;
  @tracked savingProvider = null;
  @tracked disconnectingProvider = null;
  @tracked connectingHyperate = false;
  @tracked activatingProvider = null;
  @tracked error = null;
  @tracked notice = null;
  @tracked nowMs = Date.now();
  @tracked hyperateDeviceId = "";
  @tracked settingsOpen = false;

  pollTimer = null;
  clockTimer = null;

  willDestroy() {
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }
    this.cleanup();
  }

  get title() {
    return I18n.t("live_metrics.title");
  }

  get rawAccounts() {
    return this.me?.accounts || (this.me?.account ? [this.me.account] : []);
  }

  get settingsAccounts() {
    return this.rawAccounts.map((account) => decorateSettingsAccount(account)).filter(Boolean);
  }

  get activeSettingsAccount() {
    return this.settingsAccounts.find((account) => account.active) || this.settingsAccounts[0] || null;
  }

  get account() {
    return decorateAccount(this.liveAccount || this.activeSettingsAccount, this.nowMs);
  }

  get directory() {
    return (this.directoryRows || [])
      .map((row) => decorateAccount(row, this.nowMs))
      .filter((row) => row?.live?.status === "live" && row?.live?.heart_rate);
  }

  get providerRows() {
    const providers = this.config?.providers || {};

    return PROVIDER_ORDER.filter((provider) => providers[provider]?.enabled === true).map((provider) => {
      const config = providers[provider] || {};
      const account = this.settingsAccounts.find((item) => item.provider === provider) || null;
      const isPulsoid = provider === "pulsoid";
      const isHyperate = provider === "hyperate";
      const connecting = isHyperate ? this.connectingHyperate : false;
      const disconnecting = this.disconnectingProvider === provider;
      const activating = this.activatingProvider === provider;
      const saving = this.savingProvider === provider;

      return {
        provider,
        label: config.label || account?.provider_label || provider,
        configured: config.configured === true,
        account,
        connected: Boolean(account?.connected),
        active: account?.active === true,
        isPulsoid,
        isHyperate,
        connect_url: config.connect_url,
        connect_disabled: !config.configured || connecting || this.databaseNotReady || !this.canShare,
        disconnecting,
        connecting,
        activating,
        provider_saving: saving,
        activate_disabled: activating || !this.canShare,
        visibility_show_private: this.showVisibilityOption(account, "private"),
        visibility_show_logged_in: this.showVisibilityOption(account, "logged_in"),
        visibility_show_public: this.showVisibilityOption(account, "public"),
        visibility_show_staff: this.showVisibilityOption(account, "staff"),
        visibility_private_disabled: this.visibilityOptionDisabled(account, "private"),
        visibility_logged_in_disabled: this.visibilityOptionDisabled(account, "logged_in"),
        visibility_public_disabled: this.visibilityOptionDisabled(account, "public"),
        visibility_staff_disabled: this.visibilityOptionDisabled(account, "staff"),
        visibility_private_label: this.visibilityOptionLabel(account, "private"),
        visibility_logged_in_label: this.visibilityOptionLabel(account, "logged_in"),
        visibility_public_label: this.visibilityOptionLabel(account, "public"),
        visibility_staff_label: this.visibilityOptionLabel(account, "staff"),
      };
    });
  }

  get connectedProviderCount() {
    return this.providerRows.filter((provider) => provider.connected).length;
  }

  get hasEnabledProviders() {
    return this.providerRows.length > 0;
  }

  get hyperateConnectDisabled() {
    const provider = this.config?.providers?.hyperate;
    return provider?.configured !== true || !this.canShare || this.connectingHyperate || this.databaseNotReady || this.hyperateDeviceId.trim().length === 0;
  }

  get directoryEnabled() {
    return this.config?.directory_enabled !== false;
  }

  get databaseNotReady() {
    return this.config?.database_ready === false;
  }

  get canShare() {
    return this.config?.permissions?.can_share !== false;
  }

  get visibilityOptionIds() {
    const options = Array.isArray(this.config?.visibility_options) ? this.config.visibility_options : DEFAULT_VISIBILITY_OPTIONS;
    const ids = options
      .map((option) => (typeof option === "string" ? option : option?.id))
      .map((id) => String(id || "").trim())
      .filter(Boolean);

    return ids.length ? ids : DEFAULT_VISIBILITY_OPTIONS.map((option) => option.id);
  }

  get visibilityOptions() {
    return this.visibilityOptionIds.map((id) => ({
      id,
      label: visibilityLabel(id),
    }));
  }

  get settingsToggleLabel() {
    return this.settingsOpen ? "Hide connection settings" : "Manage my connections";
  }

  get pollIntervalMs() {
    const seconds = Number(this.config?.poll_interval_seconds || 3);
    return Math.max(1, Math.min(seconds, 60)) * 1000;
  }

  showVisibilityOption(account, id) {
    const current = account?.visibility || "private";
    return this.visibilityOptionIds.includes(id) || current === id;
  }

  visibilityOptionDisabled(account, id) {
    const current = account?.visibility || "private";
    return current === id && !this.visibilityOptionIds.includes(id);
  }

  visibilityOptionLabel(account, id) {
    const label = visibilityLabel(id);
    return this.visibilityOptionDisabled(account, id) ? `${label} (disabled by site settings)` : label;
  }

  @action
  setup() {
    this.readUrlNotice();
    this.startClock();
    this.loadInitial();
  }

  @action
  cleanup() {
    this.stopPolling();
    this.stopClock();
  }

  readUrlNotice() {
    try {
      const params = new URLSearchParams(window.location.search);
      const connected = params.get("connected");
      const error = params.get("error");

      if (connected === "pulsoid") {
        this.notice = "Pulsoid connected and selected as your active provider.";
      }

      if (error) {
        this.error = this.errorMessage(error);
      }
    } catch {
      // Ignore malformed location data.
    }
  }

  errorMessage(errorKey) {
    switch (errorKey) {
      case "pulsoid_not_configured":
        return "Pulsoid is not configured yet. An administrator must add the OAuth client ID and secret first.";
      case "oauth_state_mismatch":
        return "Pulsoid could not be connected because the OAuth session expired. Please try again.";
      case "missing_authorization_code":
        return "Pulsoid did not return an authorization code. Please try again.";
      case "pulsoid_connect_failed":
        return "Pulsoid could not be connected. Please try again or contact staff.";
      case "sharing_not_allowed":
        return "Your account is not allowed to connect or share heartrate data.";
      default:
        return "The heartrate action could not be completed.";
    }
  }

  async loadInitial() {
    this.error = null;
    this.loading = true;

    try {
      const [config, me] = await Promise.all([
        ajax("/live-metrics/api/config"),
        ajax("/live-metrics/api/me"),
      ]);

      this.config = config;
      this.me = me;
      this.loading = false;
      this.startPolling();
      this.refreshLiveSections();
    } catch {
      this.error = "Heartrate settings could not be loaded. Please refresh the page or contact staff.";
      this.loading = false;
    }
  }

  async loadSettings() {
    const [config, me] = await Promise.all([
      ajax("/live-metrics/api/config"),
      ajax("/live-metrics/api/me"),
    ]);

    this.config = config;
    this.me = me;
  }

  async refreshLiveSections() {
    if (!this.config) {
      return;
    }

    this.refreshing = true;

    try {
      const liveRequest = ajax("/live-metrics/api/live-preview");
      const directoryRequest = this.config?.directory_enabled === false ? Promise.resolve({ users: [] }) : ajax("/live-metrics/api/directory");
      const [liveResult, directoryResult] = await Promise.allSettled([liveRequest, directoryRequest]);

      if (liveResult.status === "fulfilled") {
        this.liveAccount = liveResult.value?.account || null;
      }

      if (directoryResult.status === "fulfilled") {
        this.directoryRows = directoryResult.value?.users || [];
      }

      this.nowMs = Date.now();
    } finally {
      this.refreshing = false;
      this.startPolling();
    }
  }

  startPolling() {
    this.stopPolling();
    this.pollTimer = window.setTimeout(() => {
      this.refreshLiveSections();
    }, this.pollIntervalMs);
  }

  startClock() {
    this.stopClock();
    this.nowMs = Date.now();
    this.clockTimer = window.setInterval(() => {
      this.nowMs = Date.now();
    }, 1000);
  }

  stopPolling() {
    if (this.pollTimer) {
      window.clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
  }

  stopClock() {
    if (this.clockTimer) {
      window.clearInterval(this.clockTimer);
      this.clockTimer = null;
    }
  }

  @action
  toggleSettings() {
    this.settingsOpen = !this.settingsOpen;
  }

  @action
  connectPulsoid() {
    if (!this.canShare) {
      this.error = "Your account is not allowed to connect or share heartrate data.";
      return;
    }

    const url = this.config?.providers?.pulsoid?.connect_url || "/live-metrics/api/connect/pulsoid";
    window.location.href = url;
  }

  @action
  updateHyperateDeviceId(event) {
    this.hyperateDeviceId = event.target.value;
  }

  @action
  async connectHyperate(event) {
    event?.preventDefault?.();

    const deviceId = this.hyperateDeviceId.trim();
    if (!this.canShare) {
      this.error = "Your account is not allowed to connect or share heartrate data.";
      return;
    }

    if (!deviceId || this.connectingHyperate) {
      return;
    }

    this.connectingHyperate = true;
    this.error = null;

    try {
      this.me = await ajax("/live-metrics/api/connect/hyperate", {
        type: "PUT",
        data: { device_id: deviceId },
      });
      this.hyperateDeviceId = "";
      this.notice = "HypeRate connected and selected as your active provider.";
      this.refreshLiveSections();
    } catch (error) {
      this.error = error?.jqXHR?.responseJSON?.message || "HypeRate could not be connected. Check the device ID and try again.";
    } finally {
      this.connectingHyperate = false;
    }
  }

  @action
  async disconnectProvider(provider) {
    if (this.disconnectingProvider) {
      return;
    }

    this.disconnectingProvider = provider;
    this.error = null;

    const label = provider === "hyperate" ? "HypeRate" : "Pulsoid";
    const url = provider === "hyperate" ? "/live-metrics/api/connect/hyperate" : "/live-metrics/auth/pulsoid";

    try {
      await ajax(url, { type: "DELETE" });
      this.notice = `${label} disconnected.`;
      await this.loadSettings();
      await this.refreshLiveSections();
    } catch {
      this.error = `${label} could not be disconnected. Please try again.`;
    } finally {
      this.disconnectingProvider = null;
    }
  }

  @action
  async activateProvider(provider) {
    if (!this.canShare) {
      this.error = "Your account is not allowed to connect or share heartrate data.";
      return;
    }

    if (this.activatingProvider || this.activeSettingsAccount?.provider === provider) {
      return;
    }

    this.activatingProvider = provider;
    this.error = null;

    try {
      this.me = await ajax(`/live-metrics/api/accounts/${provider}/activate`, {
        type: "PUT",
      });
      const label = provider === "hyperate" ? "HypeRate" : "Pulsoid";
      this.notice = `${label} is now your active provider.`;
      this.liveAccount = null;
      this.refreshLiveSections();
    } catch (error) {
      this.error = error?.jqXHR?.responseJSON?.message || "Your active provider could not be changed.";
      await this.loadSettings();
    } finally {
      this.activatingProvider = null;
    }
  }

  @action
  async toggleDirectory(provider, event) {
    await this.saveSettings(provider, { show_in_directory: event.target.checked });
  }

  @action
  async changeVisibility(provider, event) {
    await this.saveSettings(provider, { visibility: event.target.value });
  }

  async saveSettings(provider, changes) {
    const account = this.settingsAccounts.find((item) => item.provider === provider);
    if (!this.canShare) {
      this.error = "Your account is not allowed to connect or share heartrate data.";
      return;
    }

    if (!account?.connected || this.savingProvider === provider) {
      return;
    }

    this.savingProvider = provider;
    this.error = null;

    try {
      this.me = await ajax(`/live-metrics/api/accounts/${provider}/settings`, {
        type: "PUT",
        data: changes,
      });
      this.refreshLiveSections();
    } catch (error) {
      this.error = error?.jqXHR?.responseJSON?.message || "Your heartrate settings could not be saved.";
      await this.loadSettings();
    } finally {
      this.savingProvider = null;
    }
  }

  @action
  handleDirectoryUserClick(row, event) {
    if (!row?.user?.username || !event) {
      return;
    }

    if (event.button && event.button !== 0) {
      return;
    }

    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
      return;
    }

    const target = event.currentTarget || event.target?.closest?.("[data-user-card]");
    if (!target || !this.appEvents?.trigger) {
      return;
    }

    event.preventDefault?.();
    event.stopPropagation?.();
    this.appEvents.trigger("topic-header:trigger-user-card", row.user.username, target, event);
  }

  <template>
    <div class="live-metrics-page" {{didInsert this.setup}}>
      <section class="live-metrics-hero">
        <div class="live-metrics-hero__copy">
          <p class="live-metrics-eyebrow">Connected apps</p>
          <h1>{{this.title}}</h1>
          <p>
            Connect heart-rate providers and share live readings in a consistent community layout. Choose one active provider, control who can see it, and keep your history private.
          </p>
        </div>

        <div class="live-metrics-hero__status">
          {{#if this.account}}
            <div class="live-metrics-bpm {{this.account.status_class}}">
              <span class="live-metrics-bpm__label">Your live preview</span>
              <span class="live-metrics-bpm__value">{{this.account.bpm_label}}</span>
              <span class="live-metrics-bpm__meta">{{this.account.provider_label}} · {{this.account.freshness_label}}</span>
            </div>
          {{else}}
            <div class="live-metrics-bpm live-metrics-status--inactive">
              <span class="live-metrics-bpm__label">Your live preview</span>
              <span class="live-metrics-bpm__value">Not connected</span>
              <span class="live-metrics-bpm__meta">Connect a provider to show live data.</span>
            </div>
          {{/if}}
        </div>
      </section>

      {{#if this.notice}}
        <div class="live-metrics-alert live-metrics-alert--success">{{this.notice}}</div>
      {{/if}}

      {{#if this.error}}
        <div class="live-metrics-alert live-metrics-alert--error">{{this.error}}</div>
      {{/if}}

      {{#if this.loading}}
        <div class="live-metrics-card live-metrics-muted">Loading heartrate settings…</div>
      {{else}}
        {{#if this.directoryEnabled}}
          <section class="live-metrics-card live-metrics-directory">
            <div class="live-metrics-card__header">
              <div>
                <h2>Community overview</h2>
                <p>Users who explicitly opted in to the overview. Live users are shown first.</p>
              </div>
            </div>

            {{#if this.directory.length}}
              <div class="live-metrics-directory__grid">
                {{#each this.directory key="row_key" as |row|}}
                  <article class="live-metrics-person-card">
                    <a
                      class="live-metrics-avatar-link trigger-user-card"
                      href={{row.user.profile_url}}
                      data-user-card={{row.user.username}}
                      title={{row.user.username}}
                      {{on "click" (fn this.handleDirectoryUserClick row)}}
                    >
                      <img class="live-metrics-avatar" src={{row.user.avatar_url}} alt="" />
                    </a>
                    <div class="live-metrics-person-card__main">
                      <a
                        class="live-metrics-person-card__name trigger-user-card"
                        href={{row.user.profile_url}}
                        data-user-card={{row.user.username}}
                        {{on "click" (fn this.handleDirectoryUserClick row)}}
                      >
                        {{row.user.username}}
                      </a>
                      <span class="live-metrics-person-card__provider">{{row.provider_label}}</span>
                      {{#if row.user.profile_details.length}}
                        <div class="live-metrics-person-card__traits" aria-label="Public profile details">
                          {{#each row.user.profile_details key="key" as |detail|}}
                            <span class="live-metrics-trait {{detail.className}}" title={{detail.label}}>
                              {{#if detail.icon}}
                                <span class="live-metrics-trait__icon" aria-hidden="true">{{detail.icon}}</span>
                              {{/if}}
                              <span class="live-metrics-trait__value">{{detail.value}}</span>
                            </span>
                          {{/each}}
                        </div>
                      {{/if}}
                    </div>
                    <div class="live-metrics-person-card__reading {{row.status_class}}">
                      <strong>{{row.bpm_label}}</strong>
                      <span>{{row.freshness_label}}</span>
                    </div>
                  </article>
                {{/each}}
              </div>
            {{else}}
              <div class="live-metrics-empty-state live-metrics-empty-state--small">
                <h3>No visible heartrate data yet</h3>
                <p>Connected users appear here only after they opt in to the overview.</p>
              </div>
            {{/if}}
          </section>
        {{/if}}

        <section class="live-metrics-card live-metrics-manage-card">
          <div class="live-metrics-manage-card__header">
            <div class="live-metrics-manage-card__title">
              <h2>Manage my heartrate sharing</h2>
              <p>Connect providers, choose your active source, and decide whether your live heart rate appears in the overview.</p>
            </div>
            <button type="button" class="btn btn-default live-metrics-manage-toggle" {{on "click" this.toggleSettings}}>
              {{this.settingsToggleLabel}}
            </button>
          </div>

          {{#unless this.canShare}}
            <div class="live-metrics-inline-warning live-metrics-inline-warning--compact">
              Your account can view shared heartrate data, but it is not allowed to connect providers or share your own heartrate data.
            </div>
          {{/unless}}

          {{#if this.settingsOpen}}
            <div class="live-metrics-grid live-metrics-grid--settings-open">
              <article class="live-metrics-card live-metrics-card--settings live-metrics-card--nested">
                <div class="live-metrics-card__header">
                  <div>
                    <h3>My connections</h3>
                    <p>Connect one or more providers, then choose which one is currently active.</p>
                  </div>
                </div>

                {{#if this.databaseNotReady}}
                  <div class="live-metrics-inline-warning">
                    Heartrate database table is not ready yet. Please run Discourse migrations and restart/rebuild.
                  </div>
                {{/if}}

                {{#if this.canShare}}
                  {{#if this.hasEnabledProviders}}
                    <div class="live-metrics-provider-list">
                      {{#each this.providerRows key="provider" as |provider|}}
                        <section class="live-metrics-provider-card {{if provider.active "live-metrics-provider-card--active"}}">
                          <div class="live-metrics-provider-row">
                            <div>
                              <strong>{{provider.label}}</strong>
                              {{#if provider.connected}}
                                <p>{{if provider.active "Connected · active" "Connected"}}</p>
                                {{#if provider.account.live_error}}
                                  <small class="live-metrics-provider-error">{{provider.account.live_error}}</small>
                                {{/if}}
                              {{else}}
                                {{#if provider.configured}}
                                  <p>Available</p>
                                {{else}}
                                  <p>Not configured yet</p>
                                {{/if}}
                              {{/if}}
                            </div>

                            {{#if provider.connected}}
                              <button type="button" class="btn btn-danger" disabled={{provider.disconnecting}} {{on "click" (fn this.disconnectProvider provider.provider)}}>
                                {{#if provider.disconnecting}}Disconnecting…{{else}}Disconnect{{/if}}
                              </button>
                            {{else}}
                              {{#if provider.isPulsoid}}
                                <button type="button" class="btn btn-primary" disabled={{provider.connect_disabled}} {{on "click" this.connectPulsoid}}>
                                  Connect your Pulsoid account
                                </button>
                              {{/if}}
                            {{/if}}
                          </div>

                          {{#unless provider.configured}}
                            <div class="live-metrics-inline-warning live-metrics-inline-warning--compact">
                              {{provider.label}} is enabled, but the required server-side settings are not configured yet.
                            </div>
                          {{/unless}}

                          {{#if provider.isHyperate}}
                            {{#unless provider.connected}}
                              <form class="live-metrics-connect-form" {{on "submit" this.connectHyperate}}>
                                <label class="live-metrics-field">
                                  <span>HypeRate device ID</span>
                                  <input type="text" value={{this.hyperateDeviceId}} disabled={{provider.connect_disabled}} {{on "input" this.updateHyperateDeviceId}} placeholder="Enter your HypeRate device ID" />
                                  <small class="live-metrics-field__help">Use the device/user ID provided by HypeRate. The site API key stays server-side.</small>
                                </label>
                                <button type="submit" class="btn btn-primary" disabled={{this.hyperateConnectDisabled}}>
                                  {{#if provider.connecting}}Connecting…{{else}}Connect HypeRate{{/if}}
                                </button>
                              </form>
                            {{/unless}}
                          {{/if}}

                          {{#if provider.account}}
                            <div class="live-metrics-settings-list">
                              <label class="live-metrics-toggle live-metrics-toggle--active-provider">
                                <input type="radio" name="active-heartrate-provider" checked={{provider.active}} disabled={{provider.activate_disabled}} {{on "change" (fn this.activateProvider provider.provider)}} />
                                <span>
                                  <strong>Use as active provider</strong>
                                  <small>Only the active provider is used for your live preview and community overview.</small>
                                </span>
                              </label>

                              {{#if provider.active}}
                                <label class="live-metrics-toggle">
                                  <input type="checkbox" checked={{provider.account.show_in_directory}} disabled={{provider.provider_saving}} {{on "change" (fn this.toggleDirectory provider.provider)}} />
                                  <span>Show on the Heartrate overview</span>
                                </label>

                                <label class="live-metrics-field">
                                  <span>Who can see my heart-rate data</span>
                                  <select disabled={{provider.provider_saving}} {{on "change" (fn this.changeVisibility provider.provider)}}>
                                    {{#if provider.visibility_show_private}}
                                      <option value="private" selected={{provider.account.visibility_private}} disabled={{provider.visibility_private_disabled}}>{{provider.visibility_private_label}}</option>
                                    {{/if}}
                                    {{#if provider.visibility_show_logged_in}}
                                      <option value="logged_in" selected={{provider.account.visibility_logged_in}} disabled={{provider.visibility_logged_in_disabled}}>{{provider.visibility_logged_in_label}}</option>
                                    {{/if}}
                                    {{#if provider.visibility_show_public}}
                                      <option value="public" selected={{provider.account.visibility_public}} disabled={{provider.visibility_public_disabled}}>{{provider.visibility_public_label}}</option>
                                    {{/if}}
                                    {{#if provider.visibility_show_staff}}
                                      <option value="staff" selected={{provider.account.visibility_staff}} disabled={{provider.visibility_staff_disabled}}>{{provider.visibility_staff_label}}</option>
                                    {{/if}}
                                  </select>
                                  <small class="live-metrics-field__help">Only the visibility choices enabled by staff are shown here.</small>
                                </label>
                              {{else}}
                                <p class="live-metrics-muted live-metrics-muted--small">Sharing settings are available after making this provider active.</p>
                              {{/if}}
                            </div>
                          {{/if}}
                        </section>
                      {{/each}}
                    </div>
                  {{else}}
                    <div class="live-metrics-empty-state">
                      <h3>No providers enabled yet</h3>
                      <p>An administrator can enable Pulsoid, HypeRate, or both in the Heartrate plugin settings.</p>
                    </div>
                  {{/if}}
                {{/if}}
              </article>

              <article class="live-metrics-card live-metrics-card--info live-metrics-card--nested">
                <div class="live-metrics-card__header">
                  <div>
                    <h3>How sharing works</h3>
                    <p>The live card at the top is your personal preview. These settings decide whether that same live status may be shown to others.</p>
                  </div>
                </div>

                <ul class="live-metrics-info-list">
                  <li>You can connect multiple providers, but only one can be active at a time.</li>
                  <li>The overview is opt-in and only uses your active provider.</li>
                  <li>Staff can limit who may view the page, who may share, and which visibility choices are available.</li>
                  <li>Historical heart-rate data is not published here.</li>
                </ul>
              </article>
            </div>
          {{/if}}
        </section>
      {{/if}}
    </div>
  </template>
}
