// Runs a check through the dpplint API for the start page, with a time limit,
// and turns every way it can fail into a message for people; oneAtATime keeps
// the page to one running check. The start page includes it as DppLintCheck;
// test/javascript loads it with require().
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DppLintCheck = api;
})(typeof self !== "undefined" ? self : this, function () {
  const isJson = (type) => /json/i.test(type || "");

  // { ok: true, data } or { ok: false, kind, status?, contentType?, error? }.
  // kind: "timeout" (no answer within timeoutMs), "unreachable" (no answer at
  // all, e.g. no connection), "http" (an error status with a JSON error),
  // "no_result" (an answer that is not JSON), "invalid_json".
  async function runCheck(url, { timeoutMs, fetchImpl } = {}) {
    const doFetch = fetchImpl || fetch;
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
    try {
      const res = await doFetch(url, { headers: { Accept: "application/json" }, signal: controller.signal });
      const contentType = res.headers.get("Content-Type") || "";
      if (!isJson(contentType)) return { ok: false, kind: "no_result", status: res.status, contentType };
      let data;
      try {
        data = await res.json();
      } catch (e) {
        if (timedOut) return { ok: false, kind: "timeout" };
        return { ok: false, kind: "invalid_json", status: res.status, contentType };
      }
      if (!res.ok) return { ok: false, kind: "http", status: res.status, error: data && data.error };
      return { ok: true, data };
    } catch (e) {
      return { ok: false, kind: timedOut ? "timeout" : "unreachable" };
    } finally {
      clearTimeout(timer);
    }
  }

  // Message for people, without HTML. Number and unit are kept on one line.
  function failureText(failure, timeoutMs) {
    const seconds = Math.round(timeoutMs / 1000);
    switch (failure.kind) {
      case "timeout":
        return `The DPP Linter did not answer within ${seconds}\u00a0s, so the page stopped waiting. ` +
               "A slow passport host or a slow DID check can cause this.";
      case "unreachable":
        return "The DPP Linter could not be reached. Check your connection, or try again in a moment.";
      case "http":
        return `The DPP Linter answered with HTTP\u00a0${failure.status}` + (failure.error ? `: ${failure.error}` : ".");
      case "invalid_json":
        return `The DPP Linter answered with HTTP\u00a0${failure.status}, but its result could not be read.`;
      default:
        return failure.status >= 400
          ? `The DPP Linter answered with HTTP\u00a0${failure.status} and no result. The service may be restarting or busy; try again in a moment.`
          : `The DPP Linter answered with HTTP\u00a0${failure.status} but without a result (${failure.contentType || "no content type"}).`;
    }
  }

  // Wraps an async function so that it never runs twice at the same time: a
  // call while it runs is refused and returns false.
  function oneAtATime(fn) {
    let running = false;
    const wrapped = async (...args) => {
      if (running) return false;
      running = true;
      try {
        await fn(...args);
      } finally {
        running = false;
      }
      return true;
    };
    wrapped.running = () => running;
    return wrapped;
  }

  return { runCheck, failureText, oneAtATime };
});
