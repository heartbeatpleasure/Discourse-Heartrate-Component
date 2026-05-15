import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import I18n from "I18n";

const PROVIDER_ORDER = ["pulsoid", "hyperate"];

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
      }
    : null;

  const visibility = account.visibility || "private";

  return {
    ...account,
    user,
    visibility,
    visibility_private: visibility === "private",
    visibility_logged_in: visibility === "logged_in",
    visibility_public: visibility === "public",
    visibility_staff: visibility === "staff",
    bpm_label: heartRate ? `${heartRate} BPM` : "—",
    status_class: `live-metrics-status--${status}`,
    freshness_label: freshnessLabel(status, age),
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

function freshnessLabel(status, age) {
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
    return "Reconnect required";
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
  @tracked config = null;
  @tracked me = null;
  @tracked directoryRows = [];
  @tracked loading = true;
  @tracked refreshing = false;
  @tracked saving = false;
  @tracked disconnectingProvider = null;
  @tracked connectingHyperate = false;
  @tracked error = null;
  @tracked notice = null;
  @tracked nowMs = Date.now();
  @tracked hyperateDeviceId = "";

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

  get accounts() {
    const accounts = this.me?.accounts || (this.me?.account ? [this.me.account] : []);
    return accounts.map((account) => decorateAccount(account, this.nowMs)).filter(Boolean);
  }

  get account() {
    return this.accounts.find((account) => account.live?.status === "live") || this.accounts[0] || null;
  }

  get directory() {
    return (this.directoryRows || []).map((row) => decorateAccount(row, this.nowMs));
  }

  get providerRows() {
    const providers = this.config?.providers || {};

    return PROVIDER_ORDER.filter((provider) => providers[provider]?.enabled === true).map((provider) => {
      const config = providers[provider] || {};
      const account = this.accounts.find((item) => item.provider === provider) || null;
      const isPulsoid = provider === "pulsoid";
      const isHyperate = provider === "hyperate";
      const connecting = isHyperate ? this.connectingHyperate : false;
      const disconnecting = this.disconnectingProvider === provider;

      return {
        provider,
        label: config.label || account?.provider_label || provider,
        configured: config.configured === true,
        account,
        connected: Boolean(account?.connected),
        isPulsoid,
        isHyperate,
        connect_url: config.connect_url,
        connect_disabled: !config.configured || connecting || this.databaseNotReady,
        disconnecting,
        connecting,
      };
    });
  }

  get hasEnabledProviders() {
    return this.providerRows.length > 0;
  }

  get hyperateConnectDisabled() {
    const provider = this.config?.providers?.hyperate;
    return provider?.configured !== true || this.connectingHyperate || this.databaseNotReady || this.hyperateDeviceId.trim().length === 0;
  }

  get directoryEnabled() {
    return this.config?.directory_enabled !== false;
  }

  get databaseNotReady() {
    return this.config?.database_ready === false;
  }

  @action
  setup() {
    this.readUrlNotice();
    this.startClock();
    this.loadAll({ initial: true });
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
        this.notice = "Pulsoid connected. Choose where your live data may be shown.";
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
      default:
        return "The live metrics action could not be completed.";
    }
  }

  async loadAll({ initial = false } = {}) {
    this.error = null;
    if (initial) {
      this.loading = true;
    } else {
      this.refreshing = true;
    }

    try {
      const config = await ajax("/live-metrics/api/config");
      const me = await ajax("/live-metrics/api/me");

      let directory = { users: [] };
      if (config?.directory_enabled !== false) {
        directory = await ajax("/live-metrics/api/directory");
      }

      this.config = config;
      this.me = me;
      this.directoryRows = directory?.users || [];
      this.nowMs = Date.now();
      this.startPolling();
    } catch {
      this.error = "Heartrate data could not be loaded. Please refresh the page or contact staff.";
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  startPolling() {
    this.stopPolling();
    this.pollTimer = window.setTimeout(() => this.loadAll(), this.pollIntervalMs);
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

  get pollIntervalMs() {
    const seconds = Number(this.config?.poll_interval_seconds || 6);
    return Math.max(3, Math.min(seconds, 60)) * 1000;
  }

  @action
  connectPulsoid() {
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
      this.notice = "HypeRate connected. Choose where your live data may be shown.";
      await this.loadAll();
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
      await this.loadAll();
    } catch {
      this.error = `${label} could not be disconnected. Please try again.`;
    } finally {
      this.disconnectingProvider = null;
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
    const account = this.accounts.find((item) => item.provider === provider);
    if (!account?.connected || this.saving) {
      return;
    }

    this.saving = true;
    this.error = null;

    try {
      this.me = await ajax(`/live-metrics/api/accounts/${provider}/settings`, {
        type: "PUT",
        data: changes,
      });
      await this.loadAll();
    } catch {
      this.error = "Your heartrate settings could not be saved.";
    } finally {
      this.saving = false;
    }
  }

  <template>
    <div class="live-metrics-page" {{didInsert this.setup}}>
      <section class="live-metrics-hero">
        <div class="live-metrics-hero__copy">
          <p class="live-metrics-eyebrow">Connected apps</p>
          <h1>{{this.title}}</h1>
          <p>
            Connect heart-rate providers and share live readings in a consistent community layout. You control where your current heart rate is visible, while your history stays private.
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
        <div class="live-metrics-card live-metrics-muted">Loading heartrate data…</div>
      {{else}}
        <section class="live-metrics-grid">
          <article class="live-metrics-card live-metrics-card--settings">
            <div class="live-metrics-card__header">
              <div>
                <h2>My connections</h2>
                <p>Connect one or more providers and decide whether your current heart rate may appear in the community overview.</p>
              </div>
            </div>

            {{#if this.databaseNotReady}}
              <div class="live-metrics-inline-warning">
                Heartrate database table is not ready yet. Please run Discourse migrations and restart/rebuild.
              </div>
            {{/if}}

            {{#if this.hasEnabledProviders}}
              <div class="live-metrics-provider-list">
                {{#each this.providerRows as |provider|}}
                  <section class="live-metrics-provider-card">
                    <div class="live-metrics-provider-row">
                      <div>
                        <strong>{{provider.label}}</strong>
                        {{#if provider.connected}}
                          <p>Connected</p>
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
                        <label class="live-metrics-toggle">
                          <input type="checkbox" checked={{provider.account.show_in_directory}} disabled={{this.saving}} {{on "change" (fn this.toggleDirectory provider.provider)}} />
                          <span>Show on the Heartrate overview</span>
                        </label>

                        <label class="live-metrics-field">
                          <span>Who can see my heart-rate data</span>
                          <select disabled={{this.saving}} {{on "change" (fn this.changeVisibility provider.provider)}}>
                            <option value="private" selected={{provider.account.visibility_private}}>Only me</option>
                            <option value="logged_in" selected={{provider.account.visibility_logged_in}}>Logged-in users</option>
                            <option value="public" selected={{provider.account.visibility_public}}>Public</option>
                            <option value="staff" selected={{provider.account.visibility_staff}}>Staff only</option>
                          </select>
                          <small class="live-metrics-field__help">This applies to the Heartrate overview for {{provider.label}}.</small>
                        </label>
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
          </article>

          <article class="live-metrics-card live-metrics-card--info">
            <div class="live-metrics-card__header">
              <div>
                <h2>How sharing works</h2>
                <p>The live card at the top is your personal preview. These settings decide whether that same live status may be shown to others.</p>
              </div>
            </div>

            <ul class="live-metrics-info-list">
              <li>The overview is opt-in and only shows users who enabled it.</li>
              <li>Visibility controls who may see your live heart-rate data.</li>
              <li>Historical heart-rate data is not published here.</li>
            </ul>
          </article>
        </section>

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
                {{#each this.directory as |row|}}
                  <a class="live-metrics-person-card" href={{row.user.profile_url}}>
                    <img class="live-metrics-avatar" src={{row.user.avatar_url}} alt="" />
                    <div class="live-metrics-person-card__main">
                      <span class="live-metrics-person-card__name">{{row.user.username}}</span>
                      <span class="live-metrics-person-card__provider">{{row.provider_label}}</span>
                    </div>
                    <div class="live-metrics-person-card__reading {{row.status_class}}">
                      <strong>{{row.bpm_label}}</strong>
                      <span>{{row.freshness_label}}</span>
                    </div>
                  </a>
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
      {{/if}}
    </div>
  </template>
}
