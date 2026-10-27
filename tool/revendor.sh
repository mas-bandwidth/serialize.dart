#!/bin/sh
# Re-vendors the wire-format standard and the shared conformance corpus from
# a released tag (or a full commit sha) of mas-bandwidth/serialize, verbatim:
#
#   tool/revendor.sh v2.0.0
#
# Copies STANDARD.md, conformance/ and conformance-controls/ from a fresh
# fetch of that ref, then shows what changed. Port whatever the diff implies,
# set SERIALIZE_TAG in .github/workflows/ci.yml to the same ref, and commit
# the code and the vendored files together.
set -eu

if [ $# -ne 1 ]; then
    echo "usage: tool/revendor.sh <tag or full commit sha>" >&2
    exit 2
fi
tag=$1
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/.dart_tool"
scratch=$(mktemp -d "$root/.dart_tool/revendor.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

# init + fetch rather than clone --branch, so a commit sha works as well as a tag
git init --quiet "$scratch/serialize"
git -C "$scratch/serialize" fetch --quiet --depth 1 \
    https://github.com/mas-bandwidth/serialize.git "$tag"
git -C "$scratch/serialize" -c advice.detachedHead=false checkout --quiet FETCH_HEAD

cp "$scratch/serialize/STANDARD.md" "$root/STANDARD.md"
for dir in conformance conformance-controls; do
    rm -r "${root:?}/$dir"
    cp -R "$scratch/serialize/$dir" "$root/$dir"
done

echo "vendored mas-bandwidth/serialize $tag ($(git -C "$scratch/serialize" rev-parse HEAD))"
git -C "$root" status --short -- STANDARD.md conformance conformance-controls
