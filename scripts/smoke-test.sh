#!/usr/bin/env sh
# End-to-end check through the gateway: upload an image, wait for the worker,
# download the thumbnail and check that it is a 100x100 PNG.
set -eu

BASE_URL=${1:-http://localhost:8080}
IMAGE=${IMAGE:-app/src/test/images/good_image_400x400.png}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

response=$(curl -fsS --max-time 15 -F "file=@$IMAGE" "$BASE_URL/thumbnail") || fail "upload to $BASE_URL failed"
id=$(printf '%s' "$response" | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')
[ -n "$id" ] || fail "no job id in the response: $response"
echo "uploaded $IMAGE, job $id"

waited=0
while :; do
  # Check after a second: the API answers before it has saved the job, so an
  # immediate check can get "not found" (a 400) for a job that exists.
  sleep 1
  waited=$((waited + 1))
  status=$(curl -fs --max-time 5 "$BASE_URL/thumbnail/$id" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
  [ "$status" = complete ] && break
  [ "$status" = failed ] && fail "the job failed"
  [ "$waited" -lt 30 ] || fail "the job is still '${status:-not found}' after 30s"
done

curl -fsS --max-time 15 -o "$tmp/thumbnail.png" "$BASE_URL/thumbnail/$id/image" || fail "download failed"
# A PNG starts with an 8-byte signature, then the IHDR chunk whose width and
# height are the big-endian integers at bytes 16-23.
[ "$(od -An -tx1 -N8 "$tmp/thumbnail.png" | tr -d ' \n')" = 89504e470d0a1a0a ] || fail "the thumbnail is not a PNG"
set -- $(od -An -tu1 -j16 -N8 "$tmp/thumbnail.png")
width=$(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
height=$(( ($5 << 24) + ($6 << 16) + ($7 << 8) + $8 ))
[ "$width" -eq 100 ] && [ "$height" -eq 100 ] || fail "the thumbnail is ${width}x${height}, expected 100x100"
echo "OK: 100x100 thumbnail ready after ~${waited}s"
