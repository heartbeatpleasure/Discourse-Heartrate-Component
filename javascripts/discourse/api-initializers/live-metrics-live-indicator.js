import { apiInitializer } from "discourse/lib/api";
import { isAccessError, liveMetricsRequest } from "../lib/live-metrics-request";

const STATUS_URL = "/live-metrics/api/status";
const STATUS_EVENT = "hb-live-metrics:status-update";

// Adaptive polling keeps the badge reasonably current without polling the
// personalized status endpoint aggressively while nobody is visible.
const POLL_VISIBLE_LIVE_MS = 8000;
const POLL_VISIBLE_IDLE_MS = 60000;
const POLL_HIDDEN_MS = 120000;
const STALE_REFRESH_MS = 8000;
const DEFAULT_LIVE_THRESHOLD_MS = 20_000;

function thresholdMs(seconds, fallback = DEFAULT_LIVE_THRESHOLD_MS) {
  const parsed = Number(seconds);
  return Number.isFinite(parsed) && parsed >= 3 && parsed <= 120 ? parsed * 1000 : fallback;
}

function isVisible() {
  return !document.hidden;
}

function normalizePath(href) {
  if (!href) {
    return "";
  }

  try {
    return new URL(href, window.location.origin).pathname;
  } catch {
    return String(href).split("?")[0].split("#")[0];
  }
}

function isLiveMetricsLink(link) {
  const path = normalizePath(link?.getAttribute?.("href"));
  return path === "/live-metrics" || path === "/live-metrics/";
}

function findLiveMetricsLinksIn(root) {
  if (!root) {
    return [];
  }

  const links = [];
  if (root.matches?.("a[href]") && isLiveMetricsLink(root)) {
    links.push(root);
  }

  const descendants = root.querySelectorAll?.("a[href]") || [];
  descendants.forEach((link) => {
    if (isLiveMetricsLink(link)) {
      links.push(link);
    }
  });

  return links;
}

function findAllLiveMetricsNavLinks() {
  const containers = document.querySelectorAll(
    "#navigation-bar, .sidebar-wrapper, .sidebar-section, .hamburger-panel, .d-header, .mobile-nav, .custom-header-links"
  );
  const links = new Set();

  containers.forEach((container) => {
    findLiveMetricsLinksIn(container).forEach((link) => links.add(link));
  });

  // Conservative fallback for custom menu implementations outside the normal
  // Discourse navigation containers.
  if (!links.size) {
    document.querySelectorAll("a[href]").forEach((link) => {
      if (isLiveMetricsLink(link)) {
        links.add(link);
      }
    });
  }

  return Array.from(links);
}

function upsertBadge(link, state) {
  let badge = link.querySelector(":scope > .hb-live-metrics-live-badge");

  if (!state.live || !state.count) {
    badge?.remove();
    return;
  }

  if (!badge) {
    badge = document.createElement("span");
    badge.className = "hb-live-metrics-live-badge";
    badge.setAttribute("aria-hidden", "true");
    link.appendChild(badge);
  }

  badge.textContent = state.count > 9 ? "9+" : String(state.count);
  badge.title = `${state.count} member${state.count === 1 ? "" : "s"} sharing live heartrate`;
}

export default apiInitializer("1.8.0", (api) => {
  let state = { live: false, count: 0 };
  let lastFetchAt = 0;
  let timerId = null;
  let inFlight = false;
  let refreshRequested = false;
  let endpointUnavailable = false;
  let transientError = false;
  let verifiedAtMs = 0;
  let expiryTimerId = null;
  let liveWindowMs = DEFAULT_LIVE_THRESHOLD_MS;

  function expireUnverifiedCount() {
    if (state.live && verifiedAtMs && Date.now() >= verifiedAtMs + liveWindowMs) {
      state = { live: false, count: 0 };
      applyStateToNav();
    }
  }

  function scheduleCountExpiry() {
    clearTimeout(expiryTimerId);
    expiryTimerId = null;
    if (state.live && verifiedAtMs) {
      expiryTimerId = setTimeout(() => {
        expiryTimerId = null;
        expireUnverifiedCount();
      }, Math.max(verifiedAtMs + liveWindowMs - Date.now(), 0) + 1);
    }
  }

  function applyStateToNav() {
    findAllLiveMetricsNavLinks().forEach((link) => upsertBadge(link, state));
  }

  function applyExternalStatus(detail) {
    const count = Math.max(Number(detail?.count || 0), 0);
    liveWindowMs = Number.isFinite(Number(detail?.live_threshold_ms)) &&
      Number(detail.live_threshold_ms) >= 3000 && Number(detail.live_threshold_ms) <= 120_000
      ? Number(detail.live_threshold_ms)
      : liveWindowMs;
    state = {
      live: (typeof detail?.live === "boolean" ? detail.live : count > 0) && count > 0,
      count,
    };
    verifiedAtMs = Number(detail?.verified_at_ms) || Date.now();
    lastFetchAt = Date.now();
    expireUnverifiedCount();
    scheduleCountExpiry();
    applyStateToNav();
  }

  async function fetchStatus({ force = false } = {}) {
    if (endpointUnavailable) {
      return;
    }
    if (inFlight) {
      // An online/visibility event during an older request must still cause
      // an immediate follow-up once that request finishes or times out.
      if (force) {
        refreshRequested = true;
      }
      return;
    }

    const now = Date.now();
    if (!force && lastFetchAt && now - lastFetchAt < 1500) {
      return;
    }

    inFlight = true;
    const requestStartedAtMs = Date.now();
    try {
      const response = await liveMetricsRequest(STATUS_URL);
      if (verifiedAtMs > requestStartedAtMs) {
        return; // A fresher directory event already updated the badge.
      }
      transientError = false;
      const count = Math.max(Number(response?.count || 0), 0);
      liveWindowMs = thresholdMs(response?.live_threshold_seconds, liveWindowMs);
      state = { live: response?.live === true && count > 0, count };
      lastFetchAt = verifiedAtMs = Date.now();
      scheduleCountExpiry();
      applyStateToNav();
    } catch (error) {
      const status = Number(error?.jqXHR?.status ?? error?.status ?? 0);
      if (status === 403 || status === 404) {
        endpointUnavailable = true;
      }

      if (isAccessError(error)) {
        transientError = false;
        state = { live: false, count: 0 };
        clearTimeout(expiryTimerId);
        expiryTimerId = null;
      } else {
        // Temporary 429, 5xx or network failures keep the last confirmed
        // count only until its short visibility window ends.
        transientError = true;
        lastFetchAt = Date.now();
        expireUnverifiedCount();
      }
      applyStateToNav();
    } finally {
      inFlight = false;
      if (refreshRequested && !endpointUnavailable) {
        refreshRequested = false;
        fetchStatus({ force: true }).finally(scheduleNext);
      } else if (force && !endpointUnavailable) {
        // A forced refresh may have been scheduled while the badge was idle.
        // Re-evaluate the interval after the new count actually arrives.
        scheduleNext();
      }
    }
  }

  function nextIntervalMs() {
    if (!isVisible()) {
      return POLL_HIDDEN_MS;
    }

    // Keep retrying after a transient failure even when the count has expired.
    // Otherwise the idle interval would delay automatic recovery for a minute.
    return state.live || transientError ? POLL_VISIBLE_LIVE_MS : POLL_VISIBLE_IDLE_MS;
  }

  function scheduleNext() {
    if (endpointUnavailable) {
      return;
    }

    if (timerId) {
      clearTimeout(timerId);
      timerId = null;
    }

    const base = nextIntervalMs();
    const jitter = Math.floor(Math.random() * (state.live ? 1200 : 4000));
    timerId = setTimeout(async () => {
      await fetchStatus();
      scheduleNext();
    }, base + jitter);
  }

  function maybeRefreshBecauseNavigationAppeared() {
    applyStateToNav();

    const now = Date.now();
    if (isVisible() && (!lastFetchAt || now - lastFetchAt > STALE_REFRESH_MS)) {
      fetchStatus({ force: true });
    }
  }

  api.onPageChange(() => {
    maybeRefreshBecauseNavigationAppeared();
  });

  window.addEventListener("online", () => {
    fetchStatus({ force: true });
    scheduleNext();
  });

  document.addEventListener("visibilitychange", () => {
    if (isVisible()) {
      fetchStatus({ force: true });
    }
    scheduleNext();
  });

  window.addEventListener(STATUS_EVENT, (event) => {
    if (!event?.detail) {
      return;
    }

    applyExternalStatus(event.detail);
    scheduleNext();
  });

  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes || []) {
        if (!(node instanceof HTMLElement)) {
          continue;
        }

        if (findLiveMetricsLinksIn(node).length) {
          maybeRefreshBecauseNavigationAppeared();
          return;
        }
      }
    }
  });

  observer.observe(document.body, { childList: true, subtree: true });

  setTimeout(async () => {
    maybeRefreshBecauseNavigationAppeared();
    await fetchStatus({ force: true });
    scheduleNext();
  }, 300);
});
