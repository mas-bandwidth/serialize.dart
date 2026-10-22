#!/bin/sh
# Re-vendors the wire-format standard and the shared conformance corpus from
# a released tag of mas-bandwidth/serialize, verbatim:
#
#   tool/revendor.sh v2.0.0
#
# Copies STANDARD.md, conformance/ and conformance-controls/ from a fresh
# clone at the tag, then shows what changed. Port whatever the diff implies,
# set SERIALIZE_TAG in .github/workflows/ci.yml to the same tag, and commit
# the code and the vendored files together.
set -eu

if [ $# -ne 1 ]; then
    echo "usage: tool/revendor.sh <tag>" >&2
    exit 2
fi
tag=$1
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "$root/.dart_tool/revendor.XXXXXX")
trap 'rm -r "$scratch"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" \
    https://github.com/mas-bandwidth/serialize.git "$scratch/serialize"

cp "$scratch/serialize/STANDARD.md" "$root/STANDARD.md"
for dir in conformance conformance-controls; do
    rm -r "${root:?}/$dir"
    cp -R "$scratch/serialize/$dir" "$root/$dir"
done

echo "vendored mas-bandwidth/serialize $tag ($(git -C "$scratch/serialize" rev-parse HEAD))"
git -C "$root" status --short -- STANDARD.md conformance conformance-controls
