// Tests of app/javascript/click_ids.js: the click identifiers of an ad stay in
// the address of the start page, and the address reported with a conversion
// never carries the product identifier.
// Run with: node --test test/javascript/click_ids.test.js (part of bin/rails test).
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { queryWithProductId, conversionLocation, conversionReferrer, clickIds } = require(path.join(__dirname, "../../app/javascript/click_ids.js"));

const PID = "https://dpp.example.org/01/09520123456788/21/000001";

test("without click identifiers the query is the product identifier, encoded as before", () => {
  assert.equal(queryWithProductId("", PID), "?productId=" + encodeURIComponent(PID));
  assert.equal(queryWithProductId("?productId=old", PID), "?productId=" + encodeURIComponent(PID));
  assert.equal(queryWithProductId("?utm_source=x&foo=1", PID), "?productId=" + encodeURIComponent(PID));
});

test("click identifiers of the address are kept after the product identifier", () => {
  assert.equal(queryWithProductId("?gclid=Cj0K-abc_1", PID), "?productId=" + encodeURIComponent(PID) + "&gclid=Cj0K-abc_1");
  assert.equal(queryWithProductId("?wbraid=w1&productId=old&gbraid=g1&gclid=c1", PID),
    "?productId=" + encodeURIComponent(PID) + "&gclid=c1&gbraid=g1&wbraid=w1");
  assert.deepEqual(clickIds("?gclid=&gbraid=g"), [["gbraid", "g"]]);
});

test("the conversion address has origin, path and click identifiers, never the product identifier", () => {
  assert.equal(conversionLocation("https://dpplint.ownyourdata.eu/?productId=" + encodeURIComponent(PID)), "https://dpplint.ownyourdata.eu/");
  assert.equal(conversionLocation("https://dpplint.ownyourdata.eu/?productId=" + encodeURIComponent(PID) + "&gclid=c1#top"),
    "https://dpplint.ownyourdata.eu/?gclid=c1");
  assert.equal(conversionLocation("https://dpplint.ownyourdata.eu/?gbraid=g%201&utm_term=passport"), "https://dpplint.ownyourdata.eu/?gbraid=g%201");
  for (const href of ["https://dpplint.ownyourdata.eu/?productId=" + encodeURIComponent(PID), "https://dpplint.ownyourdata.eu/?gclid=x&productId=" + PID]) {
    assert.ok(!conversionLocation(href).includes("dpp.example.org"), href);
  }
});

test("the conversion referrer is only an origin", () => {
  assert.equal(conversionReferrer("https://dpplint.ownyourdata.eu/?productId=" + encodeURIComponent(PID)), "https://dpplint.ownyourdata.eu/");
  assert.equal(conversionReferrer("https://www.google.com/search?q=dpp"), "https://www.google.com/");
  assert.equal(conversionReferrer(""), "");
  assert.equal(conversionReferrer("not a url"), "");
});
