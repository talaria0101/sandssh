# Decision: one fetch path, and digests that come from the release itself

Date: 2026-09-27. Status: settled.

## The fetch path

`lib/fetch.sh` owns every download and every unpack:

- `sh_fetch URL DEST` — `curl`, then `wget`, then BSD `fetch`, and a refusal that
  names the absence rather than failing as a transport error later.
- `sh_fetch_verified URL DEST EXPECTED` — fetch, digest, compare, refuse. The
  digest chain asks `sha256sum`, `shasum -a 256`, `openssl dgst`, `python3`,
  `node`, in that order, and reports which one answered.
- `sh_untar FILE DEST` — `.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`, `.tar`,
  `.zip`, with a named warning when the decompressor is absent.

## Where a digest comes from

The expected digest is taken from the release where one is published:

- Go: `https://go.dev/dl/?mode=json`, found by matching the archive's own
  `filename`, because **there is no `.sha256` sidecar**. That URL answers `200`
  with an HTML redirect page, so a naive fetch of it "succeeds" and yields
  `<!DOCTYPE` as a digest.
- Node.js: `SHASUMS256.txt` beside the release.
- Anything else: `SANDHOME_SHA256` pins a value the caller holds, and the run
  prints the computed digest when there is nothing to compare against.

## Two defects found here

1. `sh_first_line` and `sh_first_word` tested `read`'s exit status. `read`
   returns non-zero at EOF **without a newline** and still sets the variable, so
   both answered nothing for `printf 'a'` or a file that does not end in a
   newline. Go's `VERSION?m=text` lookup happened to end in one; the internal
   `sh_first_word printf` did not, and `go` could not resolve a version at all.
   Both now use `read ... || :`. Pinned in `tests/unit.sh`.
2. The schema assumption itself. `nodejs.org/dist/latest/` redirects to
   `latest-v24.x/`, a **train** and not a version; the version has to come from
   `index.json`, and its first line is `[`, not the first release. Both parsers
   are now tested against a local file through the `SANDHOME_*_URL` overrides.

## What a digest does not prove

A digest fetched from the same release as the bytes proves transport, not
authorship: whoever could replace one could replace the other. `SANDHOME_SHA256`
is the stronger check, and pinning `SANDHOME_REF` to a commit is what makes the
curl-pipe bootstrap reproducible.
