# dpplint

Checks the digital product passport (DPP) data retrievable for a product
identifier against the automated passport criteria of
[dpp-criteria](https://github.com/OwnYourData/dpp-criteria) (EN 18219, EN 18223
and related regulation).

Results state how many automated checks passed. They are not a certification
and do not establish a presumption of conformity. dpplint is part of a research
project and shares what we currently know; the checks make no claim to be
complete and are not a legal assessment.

## How it works

- `/` is a start page: enter a product identifier (the URL encoded in the data
  carrier) and see the result per criterion. `/?productId=<identifier>` runs
  the check directly and can be linked. The page runs one check at a time and
  waits for it at most `CHECK_TIMEOUT` seconds (default: `CHECK_DEADLINE` plus
  5, so 40). If the check API answers with an error, without a result or not
  in time, the page says what happened, links the API call and offers to try
  again.
- `GET /api/v1/validate/<product identifier>` retrieves the passport like a
  phone scanning a data carrier (plain HTTPS GET, no credentials) and checks it.
- Every check ends within `CHECK_DEADLINE` seconds (default 35). The limits of
  single requests (name lookup 5 s, connection 10 s, answer 20 s for GET and
  10 s for the links, per redirect; SOyA web-cli 5 s and 30 s; didlint, see
  below) are cut to the time left. When the time is up, no further request is
  sent: the criteria evaluated so far keep their results, the others are
  reported as `skipped` (`not_evaluated`) with the reason, and `timeLimit` and
  `notices` in the result say that the limit was reached.
- `POST /api/v1/validate` checks a passport sent as JSON, or as compact JWS
  with `Content-Type: application/vc+jwt` (also `application/jwt`,
  `application/jose`).
- Criteria with `check.type: shacl` are validated with
  [SOyA](https://github.com/OwnYourData/soya): the passport goes through the
  SOyA web-cli endpoints `acquire` and `validate` for the structure named in
  the criterion. Results belong to a criterion by the criterion ID at the start
  of each message.
- Criteria with `check.type: resolve` request the product identifier
  themselves (with the Accept header the criterion names) and need
  `GET /api/v1/validate/<product identifier>`; with `POST` they are skipped.
  `expect` checks status and content type first (media type without
  parameters, case-insensitive; for `application/json` and `+json` types the
  body must be a single JSON object) and the header fields
  (`exists`, `equals`, `contains`, `matches`; field names case-insensitive,
  several fields of one name combined with commas) only if both hold. A media
  type in `content_type_with_warning` satisfies the content type with a
  warning instead of a failure.
  `matches` is an ECMA-262 regular expression without flags, searched
  anywhere in the value and case-sensitive (`^` and `$` anchor the whole
  value); a criterion with a pattern that is not valid ECMA-262, or that uses
  lookaround, named groups or backreferences, is skipped with the reason.
  `further_requests` are sent afterwards with their own Accept header and
  evaluated independently. A
  criterion fails if a check with severity error fails; if only checks with
  `severity: warning` fail, the result is `warning`.
- `applies_if` supports the paths `$.<member>` and
  `$.<member>[?search(@, '<regex>')]` or `[?match(@, '<regex>')]`. The
  regular expression of `search()` and `match()` is an I-Regexp (RFC 9485) as
  RFC 9535 requires: `match()` needs the entire value, `search()` a substring.
  The pattern is checked before the JSONPath is evaluated; an invalid I-Regexp
  or one with `^` or `$` outside a character class skips the criterion with
  the reason. `matches` of the condition itself is ECMA-262 as above and holds
  only for JSON strings (numbers, booleans, null, arrays and objects never
  satisfy it). Any other condition dpplint cannot evaluate also skips the
  criterion with the reason.
- Criteria with `check.type: did` send the DIDs of the passport to
  [didlint](https://didlint.ownyourdata.eu) (DID Core, DID Resolution) and
  check linked verifiable presentations for the VC Data Model 2.0 context. The
  didlint instance is set with `DIDLINT_URL` (default
  `https://didlint.ownyourdata.eu`); it is the only service dpplint calls
  besides the passport and the resources it links. A check waits for didlint
  at most `DIDLINT_TIMEOUT` seconds per request (default 10) and
  `DIDLINT_BUDGET` seconds in total (default 20). If didlint does not answer in
  time, or answers with something other than JSON, the criteria that need it
  are reported as `skipped` (`not_evaluated`) with the reason, and the rest of
  the check goes on.
- Criteria with `check.type: proof` check integrity proofs of the passport.
  Without `key_from` (DPP-SEC-002) every proof found is verified with the key
  it names:
  - W3C Data Integrity proofs in the passport (`DataIntegrityProof`,
    cryptosuite `eddsa-jcs-2022`, key from `verificationMethod`);
  - the passport as compact JWS (VC-JOSE-COSE, `EdDSA` or `ES256`, key from
    `kid`). With `GET`, dpplint also requests the identifier with
    `Accept: application/vc+jwt, application/jwt, application/jose`; a JWS
    delivered that way has to carry the same passport as the JSON answer;
  - the passport DID (`digitalProductPassportId`, `did:oyd`): its DID
    document, resolved by didlint in the current version, carries in the
    service of type `DigitalProductPassport` a `payloadHash` (SHA-256
    multihash, base58btc) of the passport bytes delivered by that service's
    `serviceEndpoint` in the full representation. dpplint requests the
    `serviceEndpoint` with `representation=full` (EN 18222 8.1; without it an
    EN 18222 service answers in the compressed representation) and compares
    the hash with these bytes and with the bytes delivered for the product
    identifier (with `POST`: with the content sent).

  With `key_from` (DPP-SEC-013) at least one verified proof has to be issued
  with a key of the DID at that path (the economic operator); otherwise the
  result is a warning. Keys are taken from a `did:key` or from the DID document
  resolved by didlint (Ed25519 or P-256, as `publicKeyMultibase` or
  `publicKeyJwk`). Passports without a proof, and other proof formats, are
  reported as `skipped`.
- Criteria with `check.type: links` check every `RelatedResource` of the
  passport for the required attributes and send a HEAD request to its URL
  (at most 20 URLs per passport). A URL that does not answer gives a warning.
- Criteria with `check.type: html` (DPP-SEC-014, DPP-SEC-021, DPP-DAT-020)
  request the product identifier with `Accept: text/html`. Without an HTML view the result
  is `skipped` (`no_evidence`).
  - With `external_resources: forbidden` dpplint lists the URLs a browser loads
    without user action while it displays the HTML view (scripts, style
    sheets, fonts, images, frames, preloads, CSS `url()` and `@import`, meta
    refresh); every such URL on another host than the passport's fails the
    criterion. Resources added by scripts at run time are not seen.
  - With `device_features: forbidden` dpplint searches, without running any
    script, the inline scripts, event handler attributes and `javascript:`
    URLs of the HTML view and the scripts it loads from its own host (at most
    10, the first 2 MB of each) for browser interfaces that use functions of
    the reader's device (location, camera, microphone, notifications,
    contacts, sensors, network information and others), and the markup for
    frames granted such permissions, file inputs with `capture` and permission
    elements. Every finding fails the criterion. Code assembled at run time,
    obfuscated or loaded by a script, and scripts from other hosts, are not
    seen; an interface name in a comment or string counts.
  - With `markup_errors: forbidden` dpplint posts the HTML view, as received
    and with the media type and charset of the response, to the Nu Html
    Checker that it runs itself (`NU_CHECKER_URL`; see "Deployment"). It never
    sends the document to a public instance. Every message of type `error`
    fails the criterion; warnings and other `info` messages do not count.
    Without a checker, or if the checker does not answer or cannot check the
    document, the criterion is `skipped` (`not_evaluated`).
- Criteria with `check.type: element_ids` (DPP-DAT-017, DPP-DAT-021) check
  that elementIds are unique. In the expanded full serialization dpplint
  compares the elementIds within every array of data elements (`unique:
  level`, a repeated elementId fails) or across the whole passport (`unique:
  passport`, an elementId at two places gives a warning; the items of a
  MultiValuedDataElement count as one place). In the compressed serialization
  `level` looks for a member name repeated within one JSON object of the
  passport as delivered (the response, or the posted body), and `passport` is
  `skipped`.
- Criteria whose condition does not hold are reported as `skipped`.
- Every `skipped` criterion carries a `reason` and a `reason_code`
  (`not_applicable`, `no_evidence`, `not_evaluated`, … as defined under
  "Results" in CRITERIA-FORMAT.md of dpp-criteria); the summary counts them per
  code in `skipped_by_reason`. A passport without any integrity proof gives
  `no_evidence` for DPP-SEC-002.
- dpplint only contacts public addresses: URLs whose host resolves to loopback,
  private or link-local ranges are not retrieved.
  `DPPLINT_ALLOW_PRIVATE_NETWORKS=1` lifts this for local development.
- API documentation: `/api-docs`.
- `GET /version` names the versions of dpplint, dpp-criteria and the SOyA
  web-cli. `GET /ready` answers 200 when the instance can check passports
  (the SOyA web-cli and the SOyA repository with the structures of the image
  answer) and 503 with the reason when not; the result is held and renewed at
  most every 30 s, every second while not ready.

The image contains everything it needs at run time: the Rails API, the SOyA
web-cli (`oydeu/soya-web-cli`) and the criteria and SOyA structures of
dpp-criteria, built with `soya init` when the image is built. It does not
contact soya.ownyourdata.eu. The SOyA context the structures import is
fetched when the image is built; if it cannot be retrieved, the build uses
the cached copy of dpp-criteria. `GET /version` shows which (`soya-context`),
and results checked against such a structure say so in `notices`.

## Build and run

```
./build.sh
docker run --rm --platform linux/amd64 -p 3000:3000 oydeu/dpplint
curl -s http://localhost:3000/api/v1/validate/https://dpp.oydapp.eu/01/09520123456788/21/000001
```

`./build.sh <ref>` builds with a given commit or tag of dpp-criteria; the
default is `main`. Branch and tag names are resolved to their commit first, so
that the Docker build cache never reuses an older dpp-criteria. `GET /version` shows the commit in use. The image is built
for linux/amd64, like the SOyA web-cli it contains.

Without `NU_CHECKER_URL` the criteria that need the Nu Html Checker are
skipped. To run them locally, start the checker on a network of its own next
to dpplint:

```
docker network create dpplint
docker run --rm -d --name nu-html-checker --network dpplint ghcr.io/validator/validator@sha256:8f21030474e68e06905cfa801b37376e99c0e37867c653c5b6cd7e2dcaf3f503
docker run --rm --platform linux/amd64 --network dpplint -p 3000:3000 -e NU_CHECKER_URL=http://nu-html-checker:8888/ oydeu/dpplint
```

## Deployment

`kubernetes/` holds the manifests for dpplint.ownyourdata.eu: deployment,
pod disruption budget, service, certificate (cert-manager, ClusterIssuer
`letsencrypt-prod`) and ingress (nginx).

The deployment runs two replicas with 16 threads each (`RAILS_MAX_THREADS`),
spread over different nodes where possible (`topologySpreadConstraints`,
`ScheduleAnyway`). The pod disruption budget keeps at least one replica
running while nodes are drained. Replicas keep no state of their own: every
check is answered by one replica from the criteria and structures in the
image. A replica whose threads are all busy, or whose SOyA web-cli does not
answer, fails its readiness probe (`/ready`) and is taken out of the ingress
until it answers again; the liveness probe only checks that the port is open,
so a busy replica is not restarted.

Each pod also runs the Nu Html Checker (`ghcr.io/validator/validator`, MIT
licence) as a second container, named by its digest like the dpplint image.
It listens on 127.0.0.1:8888 only, so it is reachable from dpplint in the same
pod and from nowhere else, and it runs with a heap of 192 MB within a memory
limit of 512 Mi. dpplint finds it through `NU_CHECKER_URL`. The pod's
readiness does not depend on it: if the checker is down or still starting,
only the criteria that need it are skipped. Its liveness probe restarts it if
it stops answering.

The deployment names the image by its digest (`oydeu/dpplint@sha256:…`), so
that all replicas run the same image and a restart never picks up a newer
one. The digest of a new image gets into the manifest when the image is
pushed: `DOCKERHUB=1 ./build.sh` builds and pushes it and writes its digest
into `kubernetes/deployment.yaml`. The changed manifest is committed and
applied like any other change. `kubernetes/` is not part of the image, so
writing the digest does not change the image.

The Nu Html Checker in the manifest is version 26.10.12. Its digest is
compared with the latest release once a month, and at once when a security
notice concerns the checker or its image:

```
docker buildx imagetools inspect ghcr.io/validator/validator:latest
```

If the digest shown there differs from the one in `kubernetes/deployment.yaml`,
the checker is updated in one pull request:

1. Write the new digest into `kubernetes/deployment.yaml` and into
   `test/fixtures/files/html/DPP-DAT-020/README.md`, and the new version into
   both READMEs.
2. Record the answers of the new checker to the test vectors again, as that
   README describes, and run the test suite. Every file in `valid/` must still
   have no error and every file in `invalid/` at least one; if a new rule of
   the checker moves a vector, the pull request says which and why.
3. Check the HTML views of the example passports with the new checker before
   the manifest is applied.

The dpplint image does not change for this; the manifest is applied like any
other change.

## Consent banner and conversion

OwnYourData advertises the DPP Linter with Google Ads. With the visitor's
consent, the start page measures whether a visit that started with an ad leads
to a check. Without configuration the feature is off: no banner, no script, no
"Cookie settings" link and no request to Google.

| Variable | Value |
|---|---|
| `GOOGLE_ADS_ID` | Conversion ID of the Google Ads account, `AW-` followed by digits. Empty or malformed: off. |
| `GOOGLE_ADS_LABEL_LINTER_CHECK` | Conversion label of a completed check (the part of `send_to` after the slash). Without a valid label the banner still works, but nothing is measured. |

- With `GOOGLE_ADS_ID` set, the start page embeds `/consent.js`
  (`app/javascript/consent.js`, adapted from the DPP Service) and shows
  "Cookie settings" in the footer. Without it `/consent.js` is an empty script.
- Before the visitor decides, nothing is loaded from Google. The banner offers
  "Decline" and "Accept" in the same style; the choice is kept in
  `localStorage` (`oyd-consent`) for twelve months, and "Cookie settings"
  opens the banner again. Declining after accepting deletes the `_gcl_` and
  `_gac_` cookies on the host and its parent domains and reloads the page
  without the tag.
- After "Accept", Google Consent Mode v2 is set (everything denied by default,
  then `ad_storage` and `ad_user_data` granted; `ad_personalization` and
  `analytics_storage` stay denied), ad personalisation signals are switched off
  and `gtag.js` is loaded for the ID. The tag is not configured for the ID (no
  `gtag("config")`): no page views, no Google Analytics, no remarketing, no
  enhanced conversions.
- A completed check (the API answered with a result, whatever the result) sends
  one conversion. A check that cannot be run sends none.
- No user data goes to Google. The conversion reports the address of the start
  page with its ad click identifier (`gclid`, `gbraid`, `wbraid`) but without
  the product identifier, and only the origin of the referrer
  (`app/javascript/click_ids.js`); the result is not sent either. The start
  page keeps the click identifier in its address when it adds the product
  identifier, so that the conversion can be attributed to the ad without a
  configured tag and without help from the server.
- The API documentation loads no web fonts from Google
  (`app/views/rswag/ui/home/index.html.erb`, the template of rswag-ui without
  them).

The privacy policy is that of the DPP Service:
<https://dpp-service.ownyourdata.eu/privacy>.

`test/integration/consent_test.rb` checks the server side.
`test/browser/consent_check.mjs` checks a running instance in a browser
(Node.js and Playwright); requests to Google are blocked, so no conversion
reaches Google:

```
node test/browser/consent_check.mjs https://dpplint.ownyourdata.eu --no-id
node test/browser/consent_check.mjs http://localhost:3000 --screenshots tmp/consent
```

The first form is for an instance without `GOOGLE_ADS_ID`. With
`--inspect-tag` the tag itself is loaded from Google (everything else stays
blocked) and the check also reads the conversion request it would send.

## Tests

```
docker run --rm --platform linux/amd64 oydeu/dpplint test
```

The suite includes the JavaScript tests of the start page
(`test/javascript`), which run with the node of the image.

## Related tools

These repositories and services of OwnYourData belong together. Each is a
project of its own; the list shows how they depend on each other.

- [dpp-criteria](https://github.com/OwnYourData/dpp-criteria) – the criteria
  and SOyA structures that dpplint checks. The image contains them at a fixed
  commit; `GET /version` names it.
- [dpp-validator](https://github.com/OwnYourData/dpp-validator) – runs the
  service criteria against the listed DPP services every day and calls the
  API of dpplint for their example passports; results at
  <https://ownyourdata.github.io/dpp-validator/>.
- [DIDlint](https://github.com/OwnYourData/didlint) – validates DID
  documents, at <https://didlint.ownyourdata.eu>; dpplint calls it for the
  DIDs in a passport (see "How it works").
- [SOyA](https://ownyourdata.github.io/soya/)
  ([source](https://github.com/OwnYourData/soya)) – dpplint validates
  passports with the SOyA web-cli contained in its image.
- [OYDID](https://ownyourdata.github.io/oydid/)
  ([source](https://github.com/OwnYourData/oydid)) – the DID method
  `did:oyd`; DIDlint resolves `did:oyd` through the OYDID resolver.

OwnYourData also operates one of the DPP services whose passports are checked
in the daily runs, the OwnYourData DPP Service; its passports go through the
same checks as every other passport.

## Funding

<!-- funding:begin -->
The DPP Linter is part of [PACE-DPP](https://dpp-austria.at/) – Promoting and Accelerating a Digital Product Passport based Data-Service Ecosystem. This Lighthouse Project has been made possible by financial contributions from the Austrian Federal Ministry of Innovation, Mobility and Infrastructure ([BMIMI](https://www.bmimi.gv.at/en.html), formerly BMK), supported by the Austrian Research Promotion Agency (FFG) under grant number [917177](https://projekte.ffg.at/projekt/5128301), as well as from the German Federal Ministry of Research, Technology and Space (BMFTR, formerly BMWK), supported by the German Research Promotion Agency (DLR-PT).
<!-- funding:end -->

## License

Apache License 2.0 – see [LICENSE](LICENSE).
