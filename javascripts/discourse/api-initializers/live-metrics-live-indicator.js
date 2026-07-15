import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";

const STATUS_URL = "/live-metrics/api/status";
const STATUS_EVENT = "hb-live-metrics:status-update";

// Adaptive polling keeps the badge reasonably current without polling the
// personalized status endpoint aggressively while nobody is visible.
const POLL_VISIBLE_LIVE_MS = 8000;
const POLL_VISIBLE_IDLE_MS = 60000;
const POLL_HIDDEN_MS = 120000;
const STALE_REFRESH_MS = 8000;

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
  let endpointUnavailable = false;

  function applyStateToNav() {
    findAllLiveMetricsNavLinks().forEach((link) => upsertBadge(link, state));
  }

  function applyExternalStatus(detail) {
    const count = Math.max(Number(detail?.count || 0), 0);
    state = {
      live: typeof detail?.live === "boolean" ? detail.live : count > 0,
      count,
    };
    lastFetchAt = Date.now();
    applyStateToNav();
  }

  async function fetchStatus({ force = false } = {}) {
    if (endpointUnavailable || inFlight) {
      return;
    }

    const now = Date.now();
    if (!force && lastFetchAt && now - lastFetchAt < 1500) {
      return;
    }

    inFlight = true;
    try {
      const response = await ajax(STATUS_URL);
      const count = Math.max(Number(response?.count || 0), 0);
      state = { live: response?.live === true && count > 0, count };
      lastFetchAt = Date.now();
      applyStateToNav();
    } catch (error) {
      const status = error?.jqXHR?.status;
      if (status === 403 || status === 404) {
        endpointUnavailable = true;
      }

      // The count is viewer-specific. Fail closed instead of retaining an old
      // number after permissions, blocks, or live state may have changed.
      state = { live: false, count: 0 };
      applyStateToNav();
    } finally {
      inFlight = false;
    }
  }

  function nextIntervalMs() {
    if (!isVisible()) {
      return POLL_HIDDEN_MS;
    }

    return state.live ? POLL_VISIBLE_LIVE_MS : POLL_VISIBLE_IDLE_MS;
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
