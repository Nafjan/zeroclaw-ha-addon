# ZeroClaw 0.7.5 ARM migration fixture

The ARM64 executable in this directory is retained only for the old/new state
migration test. It is not the app runtime and is excluded from the app image.
The test checks its SHA-256 before running it in a temporary, network-isolated
container.

zeroclaw-0.7.5-manifest.json records the fixture byte hash and the existing
build/source metadata. That hash identifies the bytes in this repository; it
is not an upstream 0.7.5 release-asset digest or signature.

LICENSE-MIT, LICENSE-APACHE, and NOTICE are copied from the root of the exact
upstream source commit recorded in the manifest. The manifest records their raw
source URLs, Git blob IDs, SHA-256 digests, and byte sizes. Keep these
attribution and license files with the fixture.
