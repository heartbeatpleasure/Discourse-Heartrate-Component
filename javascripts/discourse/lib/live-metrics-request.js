import { ajax } from "discourse/lib/ajax";

// jQuery's timeout aborts the XHR; the independent deadline also protects our
// polling loops if a transport/adapter leaves the returned promise unresolved.
export const LIVE_REQUEST_TIMEOUT_MS = 10_000;

export function isAccessError(error) {
  const status = Number(error?.jqXHR?.status ?? error?.status ?? 0);
  return status >= 400 && status < 500 && status !== 429;
}

export function liveMetricsRequest(url, options = {}) {
  let watchdog;
  const request = ajax(url, { ...options, timeout: LIVE_REQUEST_TIMEOUT_MS });
  const deadline = new Promise((_, reject) => {
    watchdog = setTimeout(() => reject(new Error("Heartrate API request timed out")), LIVE_REQUEST_TIMEOUT_MS + 500);
  });

  return Promise.race([request, deadline]).finally(() => clearTimeout(watchdog));
}
