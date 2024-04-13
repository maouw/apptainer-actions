#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2312
[[ "${XTRACE:-0}" != 0 ]] && set -x
set -eEuo pipefail

# Get the image tags:
declare -a image_tags=()

if [[ -n "${INPUT_TAGS:-}" ]]; then
	IFS=" " read -r -a REPLY <<<"${INPUT_TAGS:-}"
	image_tags+=("${REPLY[@]}") # Add the tags from the input
fi

[[ -n "${INPUT_IMAGE_VERSION:-}" ]] && image_tags+=("${INPUT_IMAGE_VERSION:-}") # Add the version as a tag

if [[ -n "${INPUT_ADD_TAGS:-}" ]]; then
	IFS=" " read -r -a REPLY <<<"${INPUT_ADD_TAGS:-}"
	image_tags+=("${REPLY[@]}") # Add the tags from the input
fi

# If we have a semantic version, and if it is the newest version that is not a pre-release, add the "latest" tag:
if [[ -n "${INPUT_IMAGE_VERSION:-}" ]] && [[ "${INPUT_IMAGE_VERSION:-}" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
	SEMANTICALLY_NEWEST_TAG="$({ echo "${INPUT_IMAGE_VERSION}";
	IMAGE_REPO_URL="${INPUT_IMAGE_URL#oras://ghcr.io/}"
	IMAGE_REPO_URL="${IMAGE_REPO_URL%:*}"
	IMAGE_REPO_URL="$(jq -rn --arg x "${IMAGE_REPO_URL}" '$x|@uri' || true)"
	gh api "/users/${GITHUB_REPOSITORY_OWNER}/packages/container/${GITHUB_REPOSITORY#*/}%2F${INPUT_IMAGE_NAME}/versions" --jq '.[].metadata.container.tags[]' ||
		true; } |
		grep -P '^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$' |
		grep -v '\-.*$' | sed -E 's/^v?(.*)$/\1\t\0/g' |
		tr - \~ |
		sort -k1V |
		tr \~ - |
		cut -f2 |
		tail -n1 ||
		true)"
	if [[ "${SEMANTICALLY_NEWEST_TAG}" == "${INPUT_IMAGE_VERSION}" ]]; then
		image_tags+=("latest")
	fi
fi

# Remove duplicate tags:
# shellcheck disable=SC2207
image_tags=($(echo "${image_tags[@]}" | tr '[:space:]' '\n' | awk '!a[$0]++'))
if ! [[ "${INPUT_IMAGE_URL:-}" =~ ^oras://ghcr\.io/ ]]; then
	echo "::error::Invalid image URL (should be oras://ghcr.io/...): \"${INPUT_IMAGE_URL}\""
	exit 1
fi

# Tag the image with additional tags if any:
if (("${#image_tags[@]}" > 1)); then
	echo "Tagging the image with additional tags: ${image_tags[*]:1}" >&2
	oras tag -u "${GITHUB_ACTOR}" -p "${GH_TOKEN}" "${INPUT_IMAGE_URL#oras://}" "${image_tags[@]}"
fi

echo "image-tags=${image_tags[*]}" >>"${GITHUB_OUTPUT}"
echo "::notice::Image at \"${INPUT_IMAGE_URL}\" has been tagged with: ${image_tags[*]}"