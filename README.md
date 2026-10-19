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
- Criteria with `check.type: html` (DPP-SEC-014) request the product
  identifier with `Accept: text/html` and list the URLs a browser loads without
  user action while it displays the HTML view (scripts, style sheets, fonts,
  images, frames, preloads, CSS `url()` and `@import`, meta refresh). With
  `external_resources: forbidden` every such URL on another host than the
  passport's fails the criterion. Without an HTML view the result is
  `skipped` (`no_evidence`). Resources added by scripts at run time are not
  seen.
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

## Deployment

`kubernetes/` holds the manifests for dpplint.ownyourdata.eu: deployment,
service, certificate (cert-manager, ClusterIssuer `letsencrypt-prod`) and ingress
(nginx).

## Tests

```
docker run --rm --platform linux/amd64 oydeu/dpplint test
```

The suite includes the JavaScript tests of the start page
(`test/javascript`), which run with the node of the image.

## Funding

<!-- funding:begin -->
The DPP Linter is part of [PACE-DPP](https://dpp-austria.at/) – Promoting and Accelerating a Digital Product Passport based Data-Service Ecosystem. This Lighthouse Project has been made possible by financial contributions from the Austrian Federal Ministry of Innovation, Mobility and Infrastructure ([BMIMI](https://www.bmimi.gv.at/en.html), formerly BMK), supported by the Austrian Research Promotion Agency (FFG) under grant number [917177](https://projekte.ffg.at/projekt/5128301), as well as from the German Federal Ministry of Research, Technology and Space (BMFTR, formerly BMWK), supported by the German Research Promotion Agency (DLR-PT).
<!-- funding:end -->

## License

Apache License 2.0 – see [LICENSE](LICENSE).
