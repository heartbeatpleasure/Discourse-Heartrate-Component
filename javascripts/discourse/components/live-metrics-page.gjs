import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import I18n from "I18n";


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
  @tracked disconnecting = false;
  @tracked error = null;
  @tracked notice = null;
  @tracked nowMs = Date.now();

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

  get account() {
    return decorateAccount(this.me?.account, this.nowMs);
  }

  get directory() {
    return (this.directoryRows || []).map((row) => decorateAccount(row, this.nowMs));
  }

  get isConnected() {
    return Boolean(this.me?.account?.connected);
  }

  get providerConfigured() {
    return this.config?.providers?.pulsoid?.configured === true;
  }

  get providerEnabled() {
    return this.config?.providers?.pulsoid?.enabled !== false;
  }

  get connectUrl() {
    return this.config?.providers?.pulsoid?.connect_url || "/live-metrics/auth/pulsoid/start";
  }

  get connectDisabled() {
    return !this.providerConfigured;
  }

  get pollIntervalMs() {
    const seconds = Number(this.config?.poll_interval_seconds || 6);
    return Math.max(3, Math.min(seconds, 60)) * 1000;
  }

  get directoryEnabled() {
    return this.config?.directory_enabled !== false;
  }

  get showConfiguredWarning() {
    return this.providerEnabled && !this.providerConfigured;
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
      this.error = "Live metrics could not be loaded. Please refresh the page or contact staff.";
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

  @action
  connectPulsoid() {
    window.location.href = this.connectUrl;
  }

  @action
  async disconnectPulsoid() {
    if (this.disconnecting) {
      return;
    }

    this.disconnecting = true;
    this.error = null;

    try {
      await ajax("/live-metrics/auth/pulsoid", { type: "DELETE" });
      this.notice = "Pulsoid disconnected.";
      await this.loadAll();
    } catch {
      this.error = "Pulsoid could not be disconnected. Please try again.";
    } finally {
      this.disconnecting = false;
    }
  }

  @action
  async toggleDirectory(event) {
    await this.saveSettings({ show_in_directory: event.target.checked });
  }

  @action
  async changeVisibility(event) {
    await this.saveSettings({ visibility: event.target.value });
  }

  async saveSettings(changes) {
    if (!this.isConnected || this.saving) {
      return;
    }

    this.saving = true;
    this.error = null;

    try {
      this.me = await ajax("/live-metrics/api/me/settings", {
        type: "PUT",
        data: changes,
      });
      await this.loadAll();
    } catch {
      this.error = "Your live metrics settings could not be saved.";
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
              <span class="live-metrics-bpm__meta">{{this.account.freshness_label}}</span>
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
                <p>Connect your Pulsoid account and decide whether your current heart rate may appear in the community overview.</p>
              </div>
            </div>

            {{#if this.showConfiguredWarning}}
              <div class="live-metrics-inline-warning">
                Pulsoid is enabled, but the OAuth client ID and secret are not configured yet.
              </div>
            {{/if}}

            {{#if this.databaseNotReady}}
              <div class="live-metrics-inline-warning">
                Heartrate database table is not ready yet. Please run Discourse migrations and restart/rebuild.
              </div>
            {{/if}}

            {{#if this.account}}
              <div class="live-metrics-provider-row">
                <div>
                  <strong>Pulsoid</strong>
                  <p>Connected</p>
                </div>
                <button type="button" class="btn btn-danger" disabled={{this.disconnecting}} {{on "click" this.disconnectPulsoid}}>
                  {{#if this.disconnecting}}Disconnecting…{{else}}Disconnect{{/if}}
                </button>
              </div>

              <div class="live-metrics-settings-list">
                <label class="live-metrics-toggle">
                  <input type="checkbox" checked={{this.account.show_in_directory}} disabled={{this.saving}} {{on "change" this.toggleDirectory}} />
                  <span>Show on the Heartrate overview</span>
                </label>

                <label class="live-metrics-field">
                  <span>Who can see my heart-rate data</span>
                  <select disabled={{this.saving}} {{on "change" this.changeVisibility}}>
                    <option value="private" selected={{this.account.visibility_private}}>Only me</option>
                    <option value="logged_in" selected={{this.account.visibility_logged_in}}>Logged-in users</option>
                    <option value="public" selected={{this.account.visibility_public}}>Public</option>
                    <option value="staff" selected={{this.account.visibility_staff}}>Staff only</option>
                  </select>
                  <small class="live-metrics-field__help">This applies to the Heartrate overview.</small>
                </label>
              </div>
            {{else}}
              <div class="live-metrics-empty-state">
                <h3>No provider connected yet</h3>
                <p>Connect your Pulsoid account through OAuth. You do not need to create a paid manual Pulsoid API token for this flow.</p>
                <button type="button" class="btn btn-primary" disabled={{this.connectDisabled}} {{on "click" this.connectPulsoid}}>
                  Connect your Pulsoid account
                </button>
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
