#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
manifest="$repo_root/zeroclaw/runtime-manifest.json"

for command in curl docker git python3 sha256sum; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'native image qualification requires %s\n' "$command" >&2
        exit 2
    }
done

[[ -f "$manifest" ]] || {
    printf 'candidate manifest is missing: %s\n' "$manifest" >&2
    exit 2
}

mapfile -t pins < <(python3 - "$manifest" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
candidate = manifest["candidate"]
repository = candidate["source_repository"].removesuffix(".git")
tag = candidate["release_tag"]
asset = candidate["release_asset"]
digest = candidate["release_asset_sha256"]
commit = candidate["source_commit"]
checksums_digest = candidate["checksums_asset_sha256"]
binary_digest = candidate["runtime_binary_sha256"]
build_contract = manifest["source_build_contract"]
source_date_epoch = build_contract["source_date_epoch"]
source_lockfile_sha256 = build_contract["cargo_lock_sha256"]
if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
    raise SystemExit("candidate release tag is malformed")
if asset != "zeroclaw-aarch64-unknown-linux-musl.tar.gz":
    raise SystemExit("candidate must use the pinned aarch64 musl release asset")
for label, value in (("runtime asset SHA-256", digest), ("checksums SHA-256", checksums_digest)):
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise SystemExit(f"{label} is malformed")
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("candidate source commit is malformed")
if not re.fullmatch(r"[0-9a-f]{64}", binary_digest):
    raise SystemExit("candidate runtime executable SHA-256 is malformed")
if not re.fullmatch(r"[0-9a-f]{64}", source_lockfile_sha256) or not isinstance(source_date_epoch, int):
    raise SystemExit("candidate source build metadata is malformed")
if not repository.startswith("https://github.com/"):
    raise SystemExit("candidate source repository must be an official GitHub URL")
owner_repo = repository.removeprefix("https://github.com/")
if owner_repo != "zeroclaw-labs/zeroclaw":
    raise SystemExit("candidate source repository is not zeroclaw-labs/zeroclaw")
for value in (
    owner_repo,
    tag,
    asset,
    digest,
    commit,
    binary_digest,
):
    print(value)
PY
)
for index in "${!pins[@]}"; do
    pins[$index]="${pins[$index]%$'\r'}"
done

owner_repo="${pins[0]}"
release_tag="${pins[1]}"
asset_name="${pins[2]}"
asset_sha256="${pins[3]}"
source_commit="${pins[4]}"
expected_binary_sha256="${pins[5]}"
app_source_commit="$(git -C "$repo_root" rev-parse HEAD)"
app_image_inputs=(
    zeroclaw/Dockerfile
    zeroclaw/.dockerignore
    zeroclaw/native/entrypoint.sh
    zeroclaw/native/config.py
    zeroclaw/native/migrate.py
    zeroclaw/native/ha_preflight.py
)
if [[ -n "$(git -C "$repo_root" status --short --untracked-files=all -- "${app_image_inputs[@]}")" ]]; then
    app_source_revision="${app_source_commit}-dirty-local-qualification"
else
    app_source_revision="$app_source_commit"
fi
api_root="https://api.github.com/repos/$owner_repo"
download_root="https://github.com/$owner_repo/releases/download/$release_tag"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/zeroclaw-native.XXXXXXXX")"
candidate_image="zeroclaw-native-qualification:0.8.7-${source_commit:0:12}-$$"
image_built=0
cleanup() {
    if [[ "$image_built" == 1 ]]; then
        docker image rm "$candidate_image" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$temp_root"
}
trap cleanup EXIT HUP INT TERM

download_official() {
    local url="$1"
    local destination="$2"
    curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --header 'User-Agent: zeroclaw-native-qualification' \
        --output "$destination" "$url"
}

download_official "$api_root/releases/tags/$release_tag" "$temp_root/release.json"
download_official "$api_root/git/ref/tags/$release_tag" "$temp_root/tag-ref.json"
download_official "$api_root/commits/$source_commit" "$temp_root/source-commit.json"
download_official "$api_root/git/trees/$source_commit?recursive=1" "$temp_root/source-tree.json"
download_official "$download_root/SHA256SUMS" "$temp_root/SHA256SUMS"
download_official "$download_root/$asset_name" "$temp_root/$asset_name"
for source_file in Cargo.lock LICENSE-MIT LICENSE-APACHE NOTICE; do
    curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --header 'User-Agent: zeroclaw-native-qualification' \
        --output "$temp_root/$source_file" \
        "https://raw.githubusercontent.com/$owner_repo/$source_commit/$source_file"
done

python3 - \
    "$manifest" \
    "$temp_root/release.json" \
    "$temp_root/tag-ref.json" \
    "$temp_root/source-commit.json" \
    "$temp_root/source-tree.json" \
    "$temp_root/Cargo.lock" \
    "$temp_root/SHA256SUMS" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys
from datetime import datetime

manifest_path, release_path, ref_path, source_commit_path, tree_path, lock_path, checksums_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as source:
    manifest = json.load(source)
    candidate = manifest["candidate"]
    build_contract = manifest["source_build_contract"]
    expected_license_digests = candidate["runtime_license_sha256"]
with open(release_path, encoding="utf-8") as source:
    release = json.load(source)
with open(ref_path, encoding="utf-8") as source:
    tag_ref = json.load(source)
with open(source_commit_path, encoding="utf-8") as source:
    source_commit = json.load(source)
with open(tree_path, encoding="utf-8") as source:
    source_tree = json.load(source)

tag = candidate["release_tag"]
asset_name = candidate["release_asset"]
expected_digest = candidate["release_asset_sha256"]
expected_checksums_digest = candidate["checksums_asset_sha256"]
expected_commit = candidate["source_commit"]
expected_epoch = build_contract["source_date_epoch"]
expected_lock_digest = build_contract["cargo_lock_sha256"]
if set(expected_license_digests) != {"LICENSE-MIT", "LICENSE-APACHE", "NOTICE"}:
    raise SystemExit("candidate manifest must pin the upstream runtime license files")
if any(not re.fullmatch(r"[0-9a-f]{64}", digest) for digest in expected_license_digests.values()):
    raise SystemExit("candidate manifest contains a malformed runtime license SHA-256")
if release.get("tag_name") != tag:
    raise SystemExit("GitHub release tag did not match the candidate manifest")
if release.get("target_commitish") != expected_commit:
    raise SystemExit("GitHub release source metadata did not match the candidate commit")
if tag_ref.get("ref") != f"refs/tags/{tag}":
    raise SystemExit("GitHub source tag ref did not match the candidate release tag")
target = tag_ref.get("object", {})
if target.get("type") != "commit" or target.get("sha") != expected_commit:
    raise SystemExit("GitHub source tag did not resolve directly to the candidate commit")
if source_commit.get("sha") != expected_commit:
    raise SystemExit("GitHub source commit metadata did not match the candidate commit")
committer_date = source_commit.get("commit", {}).get("committer", {}).get("date")
if not isinstance(committer_date, str) or int(datetime.fromisoformat(committer_date.replace("Z", "+00:00")).timestamp()) != expected_epoch:
    raise SystemExit("GitHub source commit date did not match SOURCE_DATE_EPOCH in the candidate manifest")
with open(lock_path, "rb") as source:
    if hashlib.sha256(source.read()).hexdigest() != expected_lock_digest:
        raise SystemExit("official Cargo.lock did not match the candidate source lockfile SHA-256")
if source_tree.get("truncated") is not False:
    raise SystemExit("official source tree was incomplete")
source_blobs = {
    item.get("path"): item.get("sha")
    for item in source_tree.get("tree", [])
    if item.get("type") == "blob"
}
for name in ("LICENSE-MIT", "LICENSE-APACHE", "NOTICE"):
    with (Path(lock_path).parent / name).open("rb") as source:
        content = source.read()
    if hashlib.sha256(content).hexdigest() != expected_license_digests[name]:
        raise SystemExit(f"official {name} SHA-256 did not match the candidate manifest")
    git_blob = hashlib.sha1(f"blob {len(content)}\0".encode("ascii") + content).hexdigest()
    if source_blobs.get(name) != git_blob:
        raise SystemExit(f"official {name} did not match the pinned source tree blob")

assets = {item.get("name"): item for item in release.get("assets", [])}
for name, expected in (
    (asset_name, f"sha256:{expected_digest}"),
    ("SHA256SUMS", f"sha256:{expected_checksums_digest}"),
):
    actual = assets.get(name, {}).get("digest")
    if actual != expected:
        raise SystemExit(f"GitHub release digest mismatch for {name}")

with open(checksums_path, "rb") as source:
    checksums_bytes = source.read()
if hashlib.sha256(checksums_bytes).hexdigest() != expected_checksums_digest:
    raise SystemExit("downloaded SHA256SUMS did not match the GitHub release asset digest")
checksums = checksums_bytes.decode("utf-8", "strict").splitlines()
matches = []
for line in checksums:
    fields = line.strip().split()
    if len(fields) == 2 and fields[1].lstrip("*") == asset_name:
        matches.append(fields[0])
if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{64}", matches[0]):
    raise SystemExit("SHA256SUMS did not contain exactly one well-formed candidate asset entry")
if matches[0] != expected_digest:
    raise SystemExit("SHA256SUMS digest did not match the candidate manifest")
print(f"PASS: official GitHub v{release.get('tag_name', '').removeprefix('v')} release and source tag metadata verified")
print(f"PASS: source tag resolves to {expected_commit}")
print(f"PASS: official source commit timestamp and Cargo.lock SHA-256 verified ({expected_epoch})")
print("PASS: pinned upstream LICENSE-MIT, LICENSE-APACHE, and NOTICE source blobs and SHA-256 values verified")
print(f"PASS: GitHub release API digest and SHA256SUMS agree for {asset_name}")
PY

actual_sha256="$(sha256sum "$temp_root/$asset_name" | awk '{print $1}')"
[[ "$actual_sha256" == "$asset_sha256" ]] || {
    printf 'downloaded runtime digest mismatch: expected %s, got %s\n' "$asset_sha256" "$actual_sha256" >&2
    exit 1
}
printf 'PASS: downloaded runtime archive SHA-256 %s\n' "$actual_sha256"

candidate_binary="$temp_root/zeroclaw"
python3 - "$temp_root/$asset_name" "$candidate_binary" <<'PY'
import os
import pathlib
import sys
import tarfile

archive_path, output_path = map(pathlib.Path, sys.argv[1:])
with tarfile.open(archive_path, mode="r:gz") as archive:
    candidates = [member for member in archive.getmembers() if pathlib.PurePosixPath(member.name).name == "zeroclaw"]
    if len(candidates) != 1 or not candidates[0].isfile():
        raise SystemExit("official runtime archive did not contain exactly one regular zeroclaw binary")
    member = candidates[0]
    path = pathlib.PurePosixPath(member.name)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit("official runtime archive contained an unsafe binary path")
    source = archive.extractfile(member)
    if source is None:
        raise SystemExit("unable to read the runtime binary from the official archive")
    with source, output_path.open("wb") as destination:
        destination.write(source.read())
os.chmod(output_path, 0o700)
PY
candidate_binary_sha256="$(sha256sum "$candidate_binary" | awk '{print $1}')"
[[ "$candidate_binary_sha256" == "$expected_binary_sha256" ]] || {
    printf 'extracted runtime binary digest mismatch: expected %s, got %s\n' "$expected_binary_sha256" "$candidate_binary_sha256" >&2
    exit 1
}
printf 'PASS: extracted runtime executable SHA-256 %s\n' "$candidate_binary_sha256"

docker_platform="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
[[ "$docker_platform" == linux/* ]] || {
    printf 'runtime qualification needs a Linux-container Docker daemon; got %s\n' "$docker_platform" >&2
    exit 2
}

docker_path_env=()
docker_repo_root="$repo_root"
if [[ -n "${MSYSTEM:-}" ]]; then
    command -v cygpath >/dev/null 2>&1 || {
        printf 'Git Bash runtime qualification requires cygpath\n' >&2
        exit 2
    }
    docker_path_env=(env MSYS_NO_PATHCONV=1)
    docker_repo_root="$(cygpath -w "$repo_root")"
fi
for required_file in \
    zeroclaw/Dockerfile \
    zeroclaw/.dockerignore \
    zeroclaw/native/entrypoint.sh \
    zeroclaw/native/config.py \
    zeroclaw/native/migrate.py \
    zeroclaw/native/ha_preflight.py \
    zeroclaw/tests/native_image_smoke.py; do
    [[ -f "$repo_root/$required_file" ]] || {
        printf 'native image qualification input is missing: %s\n' "$required_file" >&2
        exit 2
    }
done

printf 'Building the inactive native app candidate from zeroclaw/ for linux/arm64.\n'
"${docker_path_env[@]}" docker build \
    --platform linux/arm64 \
    --tag "$candidate_image" \
    --build-arg "APP_SOURCE_REVISION=$app_source_revision" \
    --file "$docker_repo_root/zeroclaw/Dockerfile" \
    "$docker_repo_root/zeroclaw"
image_built=1

python3 "$repo_root/zeroclaw/tests/native_image_smoke.py" \
    --image "$candidate_image" \
    --binary-sha256 "$expected_binary_sha256" \
    --app-source-revision "$app_source_revision"

candidate_image_id="$(docker image inspect --format '{{.Id}}' "$candidate_image")"
printf 'PASS: ARM64 native app candidate image %s passed the isolated image smoke.\n' "$candidate_image_id"
printf 'PASS: 0.8.7 archive verification, native image build, and runtime qualification completed without changing the active descriptor or binary.\n'
