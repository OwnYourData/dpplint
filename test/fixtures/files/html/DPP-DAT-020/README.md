# Test vectors for DPP-DAT-020

`valid/` and `invalid/` hold HTML views; the files in `valid/` have no error
in the Nu Html Checker, every file in `invalid/` has at least one.
`invalid/legacy-encoding.html` is encoded in windows-1252 and is served with
that charset; all others are UTF-8.

`checker/` holds the answers of the Nu Html Checker 26.10.12 (the image
`ghcr.io/validator/validator` that `kubernetes/deployment.yaml` names) to
these files, posted the way dpplint posts them. The tests answer with them
instead of running the checker. To record them again, start the checker and
post every file:

```
docker run --rm -d --name vnu -p 127.0.0.1:8888:8888 ghcr.io/validator/validator@sha256:8f21030474e68e06905cfa801b37376e99c0e37867c653c5b6cd7e2dcaf3f503
for f in valid/*.html invalid/*.html; do
  n=$(basename "$f" .html); cs=utf-8; [ "$n" = legacy-encoding ] && cs=windows-1252
  curl -s -H "Content-Type: text/html; charset=$cs" --data-binary @"$f" \
    "http://127.0.0.1:8888/?out=json" | python3 -m json.tool --no-ensure-ascii > "checker/$(dirname "$f")-$n.json"
done
docker stop vnu
```
