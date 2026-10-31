// Consent banner and Google Ads conversion measurement of the start page
// (README "Consent banner and conversion").
//
// Adapted from app/views/consent/consent.js of OwnYourData/dpp-service-public
// at commit 4f49703 (Apache License 2.0, like this repository). Changes: one
// conversion, sent by the start page when a check is completed, instead of
// conversions for links; the conversion reports the address of the page with
// its ad click identifiers but without the product identifier (click_ids.js),
// and only the origin of the referrer; banner text for the DPP Linter; the
// privacy policy is that of the DPP Service; colours from the page.
//
// ConsentController wraps this file in a function that receives `config`
// ({ id: "AW-…", conversions: { linter_check: "AW-…/label" } }). It is served
// only when a conversion ID is configured.
//
// Google Consent Mode v2, "basic": nothing is requested from Google before
// the visitor accepts. After acceptance only the Google Ads tag is loaded. It
// is not configured for the conversion ID (no config command), so it reports
// no page views and keeps no click identifier across pages; it sends
// something only when a conversion takes place, without ad personalisation.
// No analytics, no remarketing, no user data: neither the product identifier
// nor the result of a check is passed to Google. The choice is kept in
// localStorage for at most twelve months and can be changed at any time
// through an element with the attribute data-consent-settings (the
// "Cookie settings" link in the footer).
"use strict";

var STORAGE_KEY = "oyd-consent";
var STORAGE_VERSION = 1;
var MAX_AGE_MS = 365 * 24 * 60 * 60 * 1000;
var GOOGLE_COOKIE = /^(_gcl_|_gac_)/;
var TAG_URL = "https://www.googletagmanager.com/gtag/js?id=";
var PRIVACY_URL = "https://dpp-service.ownyourdata.eu/privacy#conversion-tracking";

var tagLoaded = false;
var banner = null;

function readChoice() {
  try {
    var raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    var stored = JSON.parse(raw);
    if (!stored || stored.v !== STORAGE_VERSION || typeof stored.ads !== "boolean") return null;
    var at = Date.parse(stored.at);
    if (!(at > 0) || Date.now() - at > MAX_AGE_MS) return null;
    return stored.ads;
  } catch (e) {
    return null;
  }
}

function storeChoice(ads) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ v: STORAGE_VERSION, ads: ads, at: new Date().toISOString() }));
  } catch (e) {
    // Without storage the banner simply comes back on the next visit.
  }
}

function gtag() {
  window.dataLayer.push(arguments);
}

function loadTag() {
  if (tagLoaded) return;
  tagLoaded = true;
  window.dataLayer = window.dataLayer || [];
  window.gtag = gtag;
  gtag("consent", "default", {
    ad_storage: "denied",
    ad_user_data: "denied",
    ad_personalization: "denied",
    analytics_storage: "denied"
  });
  gtag("consent", "update", { ad_storage: "granted", ad_user_data: "granted" });
  gtag("set", { allow_ad_personalization_signals: false });
  gtag("js", new Date());
  var script = document.createElement("script");
  script.async = true;
  script.src = TAG_URL + encodeURIComponent(config.id);
  document.head.appendChild(script);
}

// Sends the named conversion, only after consent and with a configured label.
// The address reported is that of the page with its click identifiers, never
// with the product identifier; the referrer only with its origin.
function convert(name) {
  var target = config.conversions[name];
  if (!tagLoaded || !target) return false;
  var ids = window.DppLintClickIds;
  if (!ids) return false;
  gtag("event", "conversion", {
    send_to: target,
    page_location: ids.conversionLocation(window.location.href),
    page_referrer: ids.conversionReferrer(document.referrer),
    transport_type: "beacon"
  });
  return true;
}

function deleteGoogleCookies() {
  var labels = window.location.hostname.split(".");
  document.cookie.split(";").forEach(function (pair) {
    var name = pair.split("=")[0].trim();
    if (!GOOGLE_COOKIE.test(name)) return;
    document.cookie = name + "=; Max-Age=0; path=/";
    for (var i = 0; i < labels.length - 1; i++) {
      document.cookie = name + "=; Max-Age=0; path=/; domain=." + labels.slice(i).join(".");
    }
  });
}

function choose(ads) {
  storeChoice(ads);
  hideBanner();
  if (ads) {
    loadTag();
    return;
  }
  deleteGoogleCookies();
  if (tagLoaded) {
    gtag("consent", "update", { ad_storage: "denied", ad_user_data: "denied", ad_personalization: "denied" });
    window.location.reload();
  }
}

var STYLE = [
  ".oyd-consent{position:fixed;left:0;right:0;bottom:0;z-index:2147483000;padding:0 12px 12px;pointer-events:none}",
  ".oyd-consent[hidden]{display:none}",
  ".oyd-consent .oc-box{pointer-events:auto;max-width:920px;margin:0 auto;background:var(--bg,#fff);color:var(--fg,#1d2330);",
  "border:1px solid var(--line,#d9dde5);border-radius:12px;box-shadow:0 6px 24px rgba(0,0,0,.18);padding:18px 20px;",
  "font:15px/1.5 system-ui,-apple-system,\"Segoe UI\",Roboto,\"Helvetica Neue\",Arial,sans-serif}",
  ".oyd-consent h2{font-size:16px;margin:0 0 6px}",
  ".oyd-consent p{margin:0 0 12px;color:var(--muted,#5b6475)}",
  ".oyd-consent a{color:var(--accent,#2457a6)}",
  ".oyd-consent .oc-actions{display:flex;gap:12px;flex-wrap:wrap}",
  ".oyd-consent button{flex:1 1 160px;max-width:240px;padding:10px 18px;border-radius:8px;font-family:inherit;font-size:15px;font-weight:600;line-height:1.2;cursor:pointer;",
  "border:1px solid var(--accent,#2457a6);background:var(--accent,#2457a6);color:var(--on-accent,#fff)}",
  ".oyd-consent button:focus-visible{outline:2px solid var(--fg,#1d2330);outline-offset:2px}",
  ".oyd-consent .oc-current{font-size:13px;margin:-4px 0 12px}"
].join("");

function hideBanner() {
  if (banner) banner.hidden = true;
}

function showBanner(focus) {
  if (!banner) {
    var style = document.createElement("style");
    style.textContent = STYLE;
    document.head.appendChild(style);
    banner = document.createElement("section");
    banner.className = "oyd-consent";
    banner.setAttribute("aria-labelledby", "oyd-consent-title");
    banner.innerHTML =
      '<div class="oc-box">' +
      '<h2 id="oyd-consent-title">Measuring our ads</h2>' +
      "<p>OwnYourData advertises these free tools with Google Ads. With your consent, Google’s conversion tag tells us " +
      "when a visit from one of our ads leads to a check in the DPP Linter. The product identifier you enter and the " +
      "result of the check are not sent to Google. Google sets cookies and receives your IP address and browser " +
      "details, possibly in the USA. No analytics, no remarketing. Without your consent nothing is loaded from Google. " +
      "You can change your choice at any time under “Cookie settings” at the bottom of the page. " +
      '<a href="' + PRIVACY_URL + '">Privacy policy</a></p>' +
      '<p class="oc-current" hidden></p>' +
      '<div class="oc-actions">' +
      '<button type="button" data-choice="decline">Decline</button>' +
      '<button type="button" data-choice="accept">Accept</button>' +
      "</div></div>";
    banner.addEventListener("click", function (event) {
      var button = event.target.closest ? event.target.closest("button[data-choice]") : null;
      if (button) choose(button.getAttribute("data-choice") === "accept");
    });
    document.body.appendChild(banner);
  }
  var current = banner.querySelector(".oc-current");
  var choice = readChoice();
  current.hidden = choice === null;
  current.textContent = choice === true ? "Your current choice: accepted." : choice === false ? "Your current choice: declined." : "";
  banner.hidden = false;
  if (focus) banner.querySelector("button").focus();
}

function init() {
  var settings = document.querySelectorAll("[data-consent-settings]");
  for (var i = 0; i < settings.length; i++) {
    settings[i].hidden = false;
    settings[i].addEventListener("click", function (event) {
      event.preventDefault();
      showBanner(true);
    });
  }

  var choice = readChoice();
  if (choice === true) {
    loadTag();
  } else if (choice === null) {
    showBanner(false);
  }
}

window.oydConsent = { open: function () { showBanner(true); }, convert: convert };

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
