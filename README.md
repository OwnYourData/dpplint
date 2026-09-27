# dpplint

Checks the digital product passport (DPP) data retrievable for a product
identifier against the automated passport criteria of
[dpp-criteria](https://github.com/OwnYourData/dpp-criteria) (EN 18219, EN 18223
and related regulation).

Results state how many automated checks passed. They are not a certification
and do not establish a presumption of conformity.

## How it works

- `/` is a start page: enter a product identifier (the URL encoded in the data
  carrier) and see the result per criterion. `/?productId=<identifier>` runs
  the check directly and can be linked.
- `GET /api/v1/validate/<product identifier>` retrieves the passport like a
  phone scanning a data carrier (plain HTTPS GET, no credentials) and checks it.
- `POST /api/v1/validate` checks a passport sent as JSON.
- Criteria with `check.type: shacl` are validated with
  [SOyA](https://github.com/OwnYourData/soya): the passport goes through the
  SOyA web-cli endpoints `acquire` and `validate` for the structure named in
  the criterion. Results belong to a criterion by the criterion ID at the start
  of each message.
- Criteria with `check.type: resolve` request the product identifier
  themselves (with the Accept header the criterion names) and need
  `GET /api/v1/validate/<product identifier>`; with `POST` they are skipped.
- Criteria with `check.type: did` send the DIDs of the passport to
  [didlint](https://didlint.ownyourdata.eu) (DID Core, DID Resolution) and
  check linked verifiable presentations for the VC Data Model 2.0 context. The
  didlint instance is set with `DIDLINT_URL` (default
  `https://didlint.ownyourdata.eu`); it is the only service dpplint calls
  besides the passport and the resources it links.
- Check types not implemented yet (`proof`, `links`) and criteria whose
  condition does not hold are reported as `skipped`.
- API documentation: `/api-docs`.

The image contains everything it needs at run time: the Rails API, the SOyA
web-cli (`oydeu/soya-web-cli`) and the criteria and SOyA structures of
dpp-criteria, built with `soya init` when the image is built. It does not
contact soya.ownyourdata.eu.

## Build and run

```
./build.sh
docker run --rm --platform linux/amd64 -p 3000:3000 oydeu/dpplint
curl -s http://localhost:3000/api/v1/validate/https://dpp.oydapp.eu/01/09520123456788/21/000001
```

`./build.sh <ref>` builds with a given commit or tag of dpp-criteria; the
default is `main`. `GET /version` shows the commit in use. The image is built
for linux/amd64, like the SOyA web-cli it contains.

## Deployment

`kubernetes/` holds the manifests for dpplint.ownyourdata.eu: deployment,
service, certificate (cert-manager, ClusterIssuer `letsencrypt-prod`) and ingress
(nginx).

## Tests

```
docker run --rm --platform linux/amd64 oydeu/dpplint test
```

## License

Apache License 2.0 – see [LICENSE](LICENSE).
