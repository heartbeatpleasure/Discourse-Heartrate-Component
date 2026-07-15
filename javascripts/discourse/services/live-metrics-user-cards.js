import { tracked } from "@glimmer/tracking";
import Service, { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";

const USER_CARD_SURFACE = "user_card";
const DIRECTORY_SURFACE = "directory";
const DEFAULT_LIVE_WINDOW_MS = 12_000;
const MAX_USERNAMES_PER_REQUEST = 50;

function normalizeUsername(username) {
  return String(username || "").trim().toLowerCase();
}

function normalizeSurface(surface) {
  return surface === DIRECTORY_SURFACE ? DIRECTORY_SURFACE : USER_CARD_SURFACE;
}

function registrationKey(username, surface) {
  return `${normalizeSurface(surface)}:${normalizeUsername(username)}`;
}

function readingExpiryMs(reading) {
  const explicitExpiry = Number(reading?.expires_at_ms);
  if (Number.isFinite(explicitExpiry) && explicitExpiry > 0) {
    return explicitExpiry;
  }

  const measuredAtMs = Number(reading?.measured_at_ms);
  if (Number.isFinite(measuredAtMs) && measuredAtMs > 0) {
    return measuredAtMs + DEFAULT_LIVE_WINDOW_MS;
  }

  const measuredAt = Date.parse(reading?.measured_at || "");
  if (Number.isFinite(measuredAt)) {
    return measuredAt + DEFAULT_LIVE_WINDOW_MS;
  }

  return 0;
}

function validReading(reading, nowMs = Date.now()) {
  const heartRate = Number(reading?.heart_rate);
  const expiresAtMs = readingExpiryMs(reading);

  return Number.isFinite(heartRate) && heartRate > 0 && expiresAtMs > nowMs;
}

export default class LiveMetricsUserCardsService extends Service {
  @service siteSettings;

  registrations = new Map();
  @tracked readings = new Map();
  pollTimer = null;
  expiryTimer = null;
  requestInFlight = false;
  refreshRequested = false;
  blocked = false;

  get enabled() {
    return this.siteSettings?.live_metrics_enabled !== false;
  }

  get pollIntervalMs() {
    const seconds = Number(
      this.siteSettings?.live_metrics_poll_interval_seconds || 3
    );

    return Math.max(1, Math.min(seconds, 60)) * 1000;
  }

  register(username, surface) {
    const normalizedUsername = normalizeUsername(username);
    if (!this.enabled || this.blocked || !normalizedUsername) {
      return null;
    }

    const normalizedSurface = normalizeSurface(surface);
    const key = registrationKey(normalizedUsername, normalizedSurface);
    const existing = this.registrations.get(key);

    this.registrations.set(key, {
      username: normalizedUsername,
      surface: normalizedSurface,
      count: (existing?.count || 0) + 1,
    });

    if (this.requestInFlight) {
      this.refreshRequested = true;
    } else {
      this.scheduleRefresh(0);
    }

    return key;
  }

  unregister(key) {
    if (!key) {
      return;
    }

    const existing = this.registrations.get(key);
    if (!existing) {
      return;
    }

    if (existing.count > 1) {
      this.registrations.set(key, { ...existing, count: existing.count - 1 });
    } else {
      this.registrations.delete(key);
      const nextReadings = new Map(this.readings);
      nextReadings.delete(key);
      this.readings = nextReadings;
    }

    if (this.registrations.size === 0) {
      this.stopTimers();
      this.readings = new Map();
    } else {
      this.scheduleExpiry();
    }
  }

  readingFor(username, surface) {
    const key = registrationKey(username, surface);
    const reading = this.readings.get(key);
    return validReading(reading) ? reading : null;
  }

  scheduleRefresh(delayMs) {
    if (!this.enabled || this.registrations.size === 0) {
      return;
    }

    if (this.pollTimer) {
      window.clearTimeout(this.pollTimer);
    }

    this.pollTimer = window.setTimeout(() => {
      this.pollTimer = null;
      this.refresh();
    }, Math.max(Number(delayMs) || 0, 0));
  }

  async refresh() {
    if (!this.enabled || this.registrations.size === 0) {
      return;
    }

    if (this.requestInFlight) {
      this.refreshRequested = true;
      return;
    }

    this.requestInFlight = true;
    this.refreshRequested = false;

    const uniqueRegistrations = [...this.registrations.values()].map(
      ({ username, surface }) => ({ username, surface })
    );
    const requestBatches = [];

    for (
      let index = 0;
      index < uniqueRegistrations.length;
      index += MAX_USERNAMES_PER_REQUEST
    ) {
      const batch = uniqueRegistrations.slice(
        index,
        index + MAX_USERNAMES_PER_REQUEST
      );
      const popupUsernames = batch
        .filter(({ surface }) => surface === USER_CARD_SURFACE)
        .map(({ username }) => username);
      const directoryUsernames = batch
        .filter(({ surface }) => surface === DIRECTORY_SURFACE)
        .map(({ username }) => username);
      const data = {};

      if (popupUsernames.length) {
        data.usernames = popupUsernames.join("|");
      }
      if (directoryUsernames.length) {
        data.directory_usernames = directoryUsernames.join("|");
      }

      requestBatches.push(data);
    }

    try {
      const responses = await Promise.all(
        requestBatches.map((data) =>
          ajax("/live-metrics/api/user-cards", { data })
        )
      );
      const nextReadings = new Map();
      const nowMs = Date.now();

      for (const reading of responses.flatMap(
        (response) => response?.readings || []
      )) {
        const key = registrationKey(reading?.username, reading?.surface);
        if (this.registrations.has(key) && validReading(reading, nowMs)) {
          nextReadings.set(key, reading);
        }
      }

      this.readings = nextReadings;
      this.scheduleExpiry();
    } catch (error) {
      const status = Number(error?.jqXHR?.status || error?.status);

      // User-card visibility is privacy-sensitive. Never retain a reading from
      // an earlier successful request when the current permission check fails or
      // the endpoint is temporarily unavailable.
      this.readings = new Map();

      if ([403, 404, 503].includes(status)) {
        this.blocked = true;
        this.stopTimers();
      }
    } finally {
      this.requestInFlight = false;

      if (!this.blocked && this.registrations.size > 0) {
        if (this.refreshRequested) {
          this.scheduleRefresh(0);
        } else {
          this.scheduleRefresh(this.pollIntervalMs);
        }
      }
    }
  }

  pruneExpiredReadings() {
    const nowMs = Date.now();
    const nextReadings = new Map();

    for (const [key, reading] of this.readings) {
      if (this.registrations.has(key) && validReading(reading, nowMs)) {
        nextReadings.set(key, reading);
      }
    }

    if (nextReadings.size !== this.readings.size) {
      this.readings = nextReadings;
    }

    this.scheduleExpiry();
  }

  scheduleExpiry() {
    if (this.expiryTimer) {
      window.clearTimeout(this.expiryTimer);
      this.expiryTimer = null;
    }

    const nowMs = Date.now();
    const expiries = [...this.readings.values()]
      .map((reading) => readingExpiryMs(reading))
      .filter((expiresAtMs) => expiresAtMs > nowMs);

    if (!expiries.length) {
      return;
    }

    const delayMs = Math.max(Math.min(...expiries) - nowMs + 50, 50);
    this.expiryTimer = window.setTimeout(() => {
      this.expiryTimer = null;
      this.pruneExpiredReadings();
    }, delayMs);
  }

  stopTimers() {
    if (this.pollTimer) {
      window.clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }

    if (this.expiryTimer) {
      window.clearTimeout(this.expiryTimer);
      this.expiryTimer = null;
    }
  }

  willDestroy() {
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }

    this.stopTimers();
  }
}
