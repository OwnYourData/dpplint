// Browser check of the consent banner and the conversion of the start page
// (README "Consent banner and conversion"), with Playwright.
//
//   node test/browser/consent_check.mjs <base URL> [--inspect-tag] [--screenshots <dir>]
//   node test/browser/consent_check.mjs <base URL> --no-id
//
// The instance must have GOOGLE_ADS_ID and GOOGLE_ADS_LABEL_LINTER_CHECK set;
// with --no-id it must have no GOOGLE_ADS_ID, and the check only confirms that
// no page shows a banner or a cookie settings link or requests anything from
// Google, and that the footer links the privacy policy.
// Requests to Google are recorded and blocked, so no conversion reaches
// Google. With --inspect-tag the Google Ads tag itself (gtag.js) is loaded
// from Google, while every other request to Google is still blocked; the
// check then also reads the conversion request the tag would send. With
// --screenshots the banner is saved in light and dark at 375 and 1280 px.
//
// Checks, in a fresh browser profile:
//  1. Before any choice, the start page, a result page, a page whose check
//     fails, the API documentation and an unknown path send no request to a
//     Google domain, and the start page shows the banner with Decline and
//     Accept alike.
//  2. After Decline: still no request to Google, also after a check and a
//     reload.
//  3. "Cookie settings" opens the banner again; after Accept the tag is
//     requested, with ad personalisation and analytics denied, and is not
//     configured for the ID.
//  4. A completed check sends the conversion once, with the configured label,
//     and the address it reports keeps the click identifier but not the
//     product identifier; the address bar keeps the click identifier. A check
//     that cannot be run (the API does not answer with a result) sends none;
//     a check that ends with a result, also one saying the passport could not
//     be retrieved, sends one.
//  5. Declining again reloads the page without the tag and deletes the _gcl_
//     cookies.
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const args = process.argv.slice(2);
const shotsDir = args.includes("--screenshots") ? args[args.indexOf("--screenshots") + 1] : null;
const positional = args.filter((a, i) => !a.startsWith("--") && args[i - 1] !== "--screenshots");
const base = (positional[0] || "http://localhost:3000").replace(/\/$/, "");
const inspectTag = args.includes("--inspect-tag");
const noId = args.includes("--no-id");
const GOOGLE = /(^|\.)(google(-analytics|adservices|apis|syndication|tagmanager|usercontent)?|gstatic|doubleclick)\.[a-z.]+$/i;
const PRODUCT_ID = "https://dpp.oydapp.eu/01/09520123456788/21/000001";
const UNREACHABLE = "https://dpplint-consent-check.invalid/01/1";
// The check of this identifier is answered by the browser itself with HTTP 503,
// so that the page shows "The check could not be run".
const API_FAILURE = "https://dpplint-consent-check-api-failure.invalid/01/1";
const CLICK_ID = "consent-check-gclid";

let failures = 0;
function check(ok, what) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${what}`);
  if (!ok) failures += 1;
}

// Chromium refuses its sandbox when run as root (e.g. in a container).
const browser = await chromium.launch({ args: process.getuid && process.getuid() === 0 ? ["--no-sandbox"] : [] });
const context = await browser.newContext();
const google = [];
await context.route("**/*", (route) => {
  const url = new URL(route.request().url());
  if (url.pathname.startsWith("/api/v1/validate/") && decodeURIComponent(url.pathname).includes("api-failure.invalid")) {
    return route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "not available (consent check)" }) });
  }
  if (GOOGLE.test(url.hostname)) {
    google.push(url.href);
    if (inspectTag && url.hostname === "www.googletagmanager.com" && url.pathname === "/gtag/js") return route.continue();
    return route.abort();
  }
  return route.continue();
});
const page = await context.newPage();
const dataLayer = () => page.evaluate(() => (window.dataLayer || []).map((entry) => Array.from(entry)));
const conversions = async () => (await dataLayer()).filter((e) => e[0] === "event" && e[1] === "conversion").map((e) => e[2]);
const runCheck = async (productId) => {
  await page.fill("#productId", productId);
  await page.click("#run");
  await page.waitForFunction(() => document.querySelector(".summary") || !document.getElementById("failure").hidden, null, { timeout: 60000 });
};
const productIdIn = (text) => text.includes(PRODUCT_ID) || text.includes(encodeURIComponent(PRODUCT_ID)) || text.includes("dpp.oydapp.eu");

// 1. Nothing before a choice.
const pages = [
  ["/", "start page"],
  ["/?productId=" + encodeURIComponent(PRODUCT_ID), "result page"],
  ["/?productId=" + encodeURIComponent(UNREACHABLE), "result page of a passport that cannot be retrieved"],
  ["/?productId=" + encodeURIComponent(API_FAILURE), "page whose check cannot be run"],
  ["/api-docs/index.html", "API documentation"],
  ["/no-such-page", "unknown path"]
];
for (const [path, what] of pages) {
  await page.goto(base + path, { waitUntil: "networkidle" });
  if (path.includes("productId")) {
    await page.waitForFunction(() => document.querySelector(".summary") || !document.getElementById("failure").hidden, null, { timeout: 60000 });
  }
  check(google.length === 0, `no request to Google before a choice on the ${what}`);
}
if (noId) {
  await page.goto(base + "/", { waitUntil: "networkidle" });
  check((await page.locator(".oyd-consent").count()) === 0, "no banner without a conversion ID");
  check((await page.locator("[data-consent-settings]").count()) === 0, "no cookie settings without a conversion ID");
  check((await page.locator('script[src="/consent.js"]').count()) === 0, "the page does not embed /consent.js");
  check(await page.locator('footer a[href="https://dpp-service.ownyourdata.eu/privacy"]').isVisible(), "the footer links the privacy policy of the DPP Service");
  const script = await (await page.request.get(base + "/consent.js")).text();
  check(!/googletagmanager|gtag/.test(script), "/consent.js does nothing");
  await runCheck(PRODUCT_ID);
  check(google.length === 0, "no request to Google, also after a check");
  await browser.close();
  console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
  process.exit(failures === 0 ? 0 : 1);
}
await page.goto(base + "/", { waitUntil: "networkidle" });
const banner = page.locator(".oyd-consent");
check(await banner.isVisible(), "the banner is shown before a choice");
const styles = await page.$$eval(".oyd-consent button", (buttons) =>
  buttons.map((b) => {
    const s = getComputedStyle(b);
    return { text: b.textContent, look: [s.backgroundColor, s.color, s.fontSize, s.fontWeight, s.borderColor, s.padding].join("|"), width: b.offsetWidth, height: b.offsetHeight };
  })
);
check(styles.map((s) => s.text).join(",") === "Decline,Accept", "the banner offers Decline and Accept");
check(styles.length === 2 && styles[0].look === styles[1].look && styles[0].height === styles[1].height && Math.abs(styles[0].width - styles[1].width) <= 2,
  "Decline and Accept look alike");
check(await page.locator('.oyd-consent a[href="https://dpp-service.ownyourdata.eu/privacy#conversion-tracking"]').isVisible(), "the banner links the privacy policy");
check(await page.locator("footer [data-consent-settings]").isVisible(), "the footer offers the cookie settings");
check(await page.locator('footer a[href="https://dpp-service.ownyourdata.eu/privacy"]').isVisible(), "the footer links the privacy policy of the DPP Service");

if (shotsDir) {
  mkdirSync(shotsDir, { recursive: true });
  for (const scheme of ["light", "dark"]) {
    for (const width of [375, 1280]) {
      const shot = await browser.newPage({ viewport: { width, height: 800 }, colorScheme: scheme });
      await shot.goto(base + "/", { waitUntil: "networkidle" });
      await shot.screenshot({ path: join(shotsDir, `banner-${scheme}-${width}.png`) });
      const overflow = await shot.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
      check(!overflow, `no horizontal scrolling with the banner, ${scheme}, ${width} px`);
      await shot.close();
    }
  }
}

// 2. Decline.
await page.click('.oyd-consent button[data-choice="decline"]');
check(!(await banner.isVisible()), "the banner closes after Decline");
await runCheck(PRODUCT_ID);
await page.reload({ waitUntil: "networkidle" });
await page.waitForFunction(() => document.querySelector(".summary") || !document.getElementById("failure").hidden, null, { timeout: 60000 });
check(!(await banner.isVisible()), "the banner stays closed after a reload");
check(google.length === 0, "no request to Google after Decline, also after a check");
check((await conversions()).length === 0, "no conversion after Decline");

// 3. Accept through the cookie settings, on an address with a click identifier.
await page.goto(base + "/?gclid=" + CLICK_ID, { waitUntil: "networkidle" });
await page.click("footer [data-consent-settings]");
check(await banner.isVisible(), "Cookie settings opens the banner again");
check((await page.locator(".oyd-consent .oc-current").textContent()) === "Your current choice: declined.", "the banner names the current choice");
await page.click('.oyd-consent button[data-choice="accept"]');
await page.waitForTimeout(inspectTag ? 3000 : 1000);
const tag = google.filter((url) => url.startsWith("https://www.googletagmanager.com/gtag/js?id=AW-"));
check(tag.length === 1 && tag[0] === "https://www.googletagmanager.com/gtag/js?id=AW-894120911",
  `only the tag for the ID is requested after Accept (${tag[0] || "none"})`);
const layer = await dataLayer();
const consentDefault = layer.find((e) => e[0] === "consent" && e[1] === "default");
const consentUpdate = layer.find((e) => e[0] === "consent" && e[1] === "update");
const config = layer.find((e) => e[0] === "config");
const set = layer.find((e) => e[0] === "set");
check(consentDefault && Object.values(consentDefault[2]).every((v) => v === "denied"), "consent default: everything denied");
check(consentUpdate && JSON.stringify(consentUpdate[2]) === JSON.stringify({ ad_storage: "granted", ad_user_data: "granted" }),
  "consent update: only ad_storage and ad_user_data granted");
check(!config, "the tag is not configured for the ID, so it reports no page views");
check(set && set[1].allow_ad_personalization_signals === false, "ad personalisation signals are switched off");
const beforeConversion = google.length;
check(google.length === tag.length, "nothing but the tag is requested from Google before a conversion");

// 4. Conversions.
await runCheck(PRODUCT_ID);
await page.waitForTimeout(inspectTag ? 4000 : 500);
const sent = await conversions();
console.log(`      conversion: ${JSON.stringify(sent)}`);
check(sent.length === 1 && sent[0].send_to === "AW-894120911/VeXiCK3G_K4dEM_nrKoD", "a completed check sends one conversion with the label");
check(sent.length === 1 && new URL(sent[0].page_location).searchParams.get("gclid") === CLICK_ID, "the reported address keeps the click identifier");
check(sent.length === 1 && !productIdIn(JSON.stringify(sent[0])), "the conversion carries neither the product identifier nor the result");
const address = new URL(page.url());
check(address.searchParams.get("gclid") === CLICK_ID && address.searchParams.get("productId") === PRODUCT_ID,
  "the address bar keeps the click identifier next to the product identifier");
if (inspectTag) {
  const requests = google.slice(beforeConversion);
  console.log(`      requests of the tag after the check: ${requests.length}`);
  check(requests.length > 0 && requests.every((url) => new URL(url).searchParams.get("label") === "VeXiCK3G_K4dEM_nrKoD"),
    "the tag sends the conversion with the label (blocked here)");
  check(requests.length > 0 && requests.every((url) => !productIdIn(decodeURIComponent(url))), "no request of the tag contains the product identifier");
  check(requests.some((url) => new URL(url).searchParams.get("gclaw") === CLICK_ID), "the tag reads the click identifier for the attribution");
}
await runCheck(API_FAILURE);
await page.waitForTimeout(500);
check(await page.locator("#failure").isVisible() && (await conversions()).length === 1, "a check that cannot be run sends no conversion");
await runCheck(UNREACHABLE);
await page.waitForTimeout(500);
check((await conversions()).length === 2, "a completed check whose passport cannot be retrieved sends one more conversion");

// 5. Withdraw.
await page.evaluate(() => { document.cookie = "_gcl_au=test; path=/"; });
const before = google.length;
await page.click("footer [data-consent-settings]");
await Promise.all([page.waitForEvent("load"), page.click('.oyd-consent button[data-choice="decline"]')]);
await page.waitForLoadState("networkidle");
await page.waitForFunction(() => document.querySelector(".summary") || !document.getElementById("failure").hidden, null, { timeout: 60000 });
check(google.length === before, "after withdrawing, the reloaded page sends no request to Google");
check(!(await page.evaluate(() => document.cookie)).includes("_gcl_"), "after withdrawing, the _gcl_ cookies are gone");

await browser.close();
console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
