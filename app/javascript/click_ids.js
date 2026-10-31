// Ad click identifiers in the address of the start page. A Google Ads
// conversion is attributed to an ad only when it is sent from the page whose
// address carries the click identifier of the ad (the tag is not configured
// and keeps no identifier across pages). The start page keeps these
// identifiers in its address when it adds the product identifier after a
// check, and the conversion reports an address that has the click
// identifiers but never the product identifier. The start page includes this
// file as DppLintClickIds; consent.js uses it; test/javascript loads it with
// require().
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DppLintClickIds = api;
})(typeof self !== "undefined" ? self : this, function () {
  const CLICK_IDS = ["gclid", "gbraid", "wbraid"];

  // The click identifiers of a query string, in the order of CLICK_IDS.
  function clickIds(search) {
    const params = new URLSearchParams(search || "");
    return CLICK_IDS.filter((name) => params.get(name)).map((name) => [name, params.get(name)]);
  }

  const encode = (pairs) => pairs.map(([name, value]) => name + "=" + encodeURIComponent(value)).join("&");

  // The query for the address bar after a check is started: the product
  // identifier, followed by the click identifiers the address already has.
  function queryWithProductId(search, productId) {
    return "?" + encode([["productId", productId], ...clickIds(search)]);
  }

  // The address reported with a conversion: origin and path of the page and
  // its click identifiers. Nothing else of the query (the product identifier)
  // and no fragment.
  function conversionLocation(href) {
    const url = new URL(href);
    const query = encode(clickIds(url.search));
    return url.origin + url.pathname + (query ? "?" + query : "");
  }

  // The referrer reported with a conversion: only its origin, so that an
  // address with a product identifier never leaves the page.
  function conversionReferrer(referrer) {
    if (!referrer) return "";
    try {
      return new URL(referrer).origin + "/";
    } catch (e) {
      return "";
    }
  }

  return { CLICK_IDS, clickIds, queryWithProductId, conversionLocation, conversionReferrer };
});
