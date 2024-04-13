#!/usr/bin/env bash
set "-eEu${XTRACE:-}" -o pipefail
shopt -qs lastpipe

export BUILD_LABELS_PATH="${BUILD_LABELS_PATH:-${RUNNER_TEMP:-/tmp}/.build.labels}"

GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-"$(gh auth token || true)"}}"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    GH_TOKEN="${GITHUB_TOKEN}"
fi
export GITHUB_TOKEN GH_TOKEN

printenv | sed 's/^/main.sh: /' >&2

function require_programs() {

    while [[ -n "${1:-}" ]]; do
        if ! command -v "${1:-}" >/dev/null 2>&1; then
            echo "::error::\"${1:-}\" is required but not found"
            return 1
        fi
        shift
    done
}

function check_prereqs() {
    require_program jq gh apptainer oras || return 1
}

function find_deffile() {
    if [[ -z "${DEFFILE:=${INPUT_DEFFILE:-}}" ]]; then
        FOUND_DEFFILES="$(find "${INPUT_DEFFILES_ROOTDIR:-.}" -type f \( -name 'Apptainer' -or -name 'Singularity' -or -name '*.def' \) -printf '%p\t%f\n' | awk -F$'\t' -v OFS=$'\t' '{print $2 == "Apptainer" ? 1: ($2 == "Singularity" ? 2 : 3), $1}' | awk -F'/' -v OFS=$'\t' '{print NF -1, $0}' | sort --key=1n,2n | cut -f3 | head -n 1 || true)"
        [[ -z "${FOUND_DEFFILES:-}" ]] && { echo "::error::No definition file found"; return 1; }
        mapfile -t deffiles_array <<<"${FOUND_DEFFILES}"
        echo "Found ${#deffiles_array[@]} definition files:" >&2
        for deffile in "${deffiles_array[@]}"; do
            printf "\t%q\n" "${deffile}" >&2
        done
        DEFFILE="${deffiles_array[0]}"
    fi

    if [[ -n "${DEFFILE:-}" ]]; then
        export DEFFILE
    else
        echo "::error::No definition file found"
        return 1
    fi

    export IMAGE_VERSION="${IMAGE_VERSION:-${INPUT_IMAGE_VERSION:-}}"

    # Set image name:
    export IMAGE_NAME="${INPUT_NAME:-$(basename "$(dirname "$(realpath "${DEFFILE}")")")}"

}

function create_labels {
    IMAGE_VERSION="${INPUT_IMAGE_VERSION:-${IMAGE_VERSION}}"
    # Get the image version from the release if possible:
    if [[ -z "${IMAGE_VERSION:-}" ]] && [[ "${GITHUB_EVENT_NAME:-}" == "release" ]] && [[ -n "${GITHUB_REF:-}" ]]; then
        IMAGE_VERSION="${GITHUB_REF#refs/tags/}"
        [[ -n "${IMAGE_VERSION:-}" ]] && echo "::notice::Set IMAGE_VERSION=${IMAGE_VERSION:-} via github release's GITHUB_REF"
    fi

    # Get image version from the definition file if possible:
    if [[ -z "${IMAGE_VERSION:-}" ]] && [[ -f "${DEFFILE:-}" ]]; then
        IMAGE_VERSION="$(awk '/^\s*%labels/{flag=1;next}/^\s*%\S+/{flag=0}flag' "${DEFFILE}" | grep -m1 -oiP '^\s*version\s+\K.+' | sed 's/^\s*//g; s/\s*$//g' || true)"
        [[ -n "${IMAGE_VERSION:-}" ]] && echo "::notice::Set IMAGE_VERSION=${IMAGE_VERSION:-} via definition file ${DEFFILE}"

    fi

    IMAGE_CREATED="${IMAGE_CREATED:-"$(date --rfc-3339=seconds --date="@$(git log -1 --format=%ct)")"}"
    IMAGE_VERSION="${IMAGE_VERSION:-${INPUT_IMAGE_VERSION:-"$(date +%s --date="${IMAGE_CREATED}")"}}"
    IMAGE_AUTHORS="${IMAGE_AUTHORS:-"$(gh api "/users/${GITHUB_ACTOR}" --jq 'if .name == "" then .login else .name end' || echo "${GITHUB_ACTOR:-}")"}"
    IMAGE_SOURCE="${IMAGE_SOURCE:-https://github.com/${GITHUB_REPOSITORY}}"
    IMAGE_REVISION="${IMAGE_REVISION:-${GITHUB_SHA}}"
    IMAGE_URL="${IMAGE_URL:-${INPUT_IMAGE_URL:-oras://ghcr.io/${GITHUB_REPOSITORY}/${IMAGE_NAME}:${IMAGE_VERSION}}}"
    IMAGE_VENDOR="${IMAGE_VENDOR:-${GITHUB_REPOSITORY_OWNER}}"
    IMAGE_LICENSES="${IMAGE_LICENSES:-"$(gh api "/repos/${GITHUB_REPOSITORY}" --jq '.license.spdx_id?' || true)"}"
    IMAGE_TITLE="${IMAGE_TITLE:-"${IMAGE_NAME:-"${GITHUB_REPOSITORY##*/}"}"}"

    HELP_SECTION="$(awk '/^\s*%help/{flag=1;next}/^\s*%\S+/{flag=0}flag' Singularity | tr '\n' ' ' | sed -E 's/^\s*//g; s/\s*$//g; s/\s+/ /g' || true)"
    if [[ -n "${HELP_SECTION}" ]]; then
        IMAGE_DESCRIPTION="${IMAGE_DESCRIPTION:-"${HELP_SECTION}"}"
    fi
    IMAGE_DESCRIPTION="${IMAGE_DESCRIPTION:-"$(gh api "/repos/${GITHUB_REPOSITORY}" --jq '.description?' || true)"}"

    IMAGE_FROM="$(grep -oiP '^\s*From:\s*\K\S+' "${DEFFILE}" || true)"
    if [[ -n "${IMAGE_FROM:-}" ]]; then
        grep -qiE '^\s*Bootstrap:\s*docker' "${DEFFILE}" && IMAGE_FROM="docker.io/${IMAGE_FROM}"
    fi
    IMAGE_BASE_NAME="${IMAGE_BASE_NAME:-${IMAGE_FROM:-}}"

    # Write each image label to the file if the label is set:
    if [[ -n "${BUILD_LABELS_PATH:-}" ]]; then
        test -n "${IMAGE_CREATED:-}" && echo org.opencontainers.image.created "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_CREATED
        test -n "${IMAGE_VERSION:-}" && echo org.opencontainers.image.version "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_VERSION
        test -n "${IMAGE_AUTHORS:-}" && echo org.opencontainers.image.authors "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_AUTHORS
        test -n "${IMAGE_SOURCE:-}" && echo org.opencontainers.image.source "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_SOURCE
        test -n "${IMAGE_REVISION:-}" && echo org.opencontainers.image.revision "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_REVISION
        test -n "${IMAGE_URL:-}" && echo org.opencontainers.image.url "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_URL
        test -n "${IMAGE_VENDOR:-}" && echo org.opencontainers.image.vendor "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_VENDOR
        test -n "${IMAGE_LICENSES:-}" && echo org.opencontainers.image.licenses "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_LICENSES
        test -n "${IMAGE_TITLE:-}" && echo org.opencontainers.image.title "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_TITLE
        test -n "${IMAGE_DESCRIPTION:-}" && echo org.opencontainers.image.description "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_DESCRIPTION
        test -n "${IMAGE_BASE_NAME:-}" && echo org.opencontainers.image.base.name "$_" >>"${BUILD_LABELS_PATH}" && export IMAGE_BASE_NAME

        # Reverse the order of the labels so that custom labels added as an input are not overridden by the default ones:
        tac "${BUILD_LABELS_PATH}" >"${BUILD_LABELS_PATH}.tmp" && mv "${BUILD_LABELS_PATH}.tmp" "${BUILD_LABELS_PATH}"
    fi
}

function build_container() {
    declare -a apptainer_args=()

    for arg in bind build-args build-arg-file disable-cache fakeroot fix-perms force json mount notest section update userns writable-tmpfs; do
        arg_envvar="${arg//-/_}"
        arg_envvar="INPUT_${arg_envvar^^}"
        if [[ -n "${!arg_envvar:-}" ]]; then
            apptainer_args+=("--${arg}=\"${!arg_envvar}\"")
        fi
    done

    if [[ -n "${DEFFILE:-}" ]] && [[ -n "${BUILD_LABELS_PATH:-}" ]] && [[ -f "${BUILD_LABELS_PATH}" ]] && [[ -r "${BUILD_LABELS_PATH}" ]]; then

        BUILD_DEFFILE_LINES="$(wc -l <"${BUILD_LABELS_PATH}" || true)"
        if [[ "${BUILD_DEFFILE_LINES:-0}" -gt 0 ]]; then
            BUILD_DEFFILE="${RUNNER_TEMP}/${IMAGE_NAME}.def"
            cp "${DEFFILE}" "${BUILD_DEFFILE}"
            printf "\n%%files\n\t%q %q\n" "$(realpath "${BUILD_LABELS_PATH}")" "${APPTAINER_LABELS:-/.build.labels}" >>"${BUILD_DEFFILE}"
        fi
    fi

    IMAGE_DIR="${INPUT_IMAGE_DIR:-${GITHUB_WORKSPACE}}"
    IMAGE_PATH="${INPUT_IMAGE_PATH:-${IMAGE_DIR}/${IMAGE_NAME}.sif}"

    mkdir -p "$(dirname "${IMAGE_PATH}")"

    printf "::notice::Free space in the image directory \"${IMAGE_DIR}\": %s\n" "$(df -hlT "${IMAGE_DIR}" || true)"

    if [[ -n "${INPUT_APPTAINER_TMPDIR:-${APPTAINER_TMPDIR:-}}" ]]; then
        mkdir -p "${APPTAINER_TMPDIR}" && export APPTAINER_TMPDIR="${INPUT_APPTAINER_TMPDIR:-${APPTAINER_TMPDIR}}"
        printf "::notice:: Free space in APPTAINER_TMPDIR \"${APPTAINER_TMPDIR}\": %s\n" "$(df -hlT "${APPTAINER_TMPDIR}" || true)"
        export APPTAINER_TMPDIR
    fi

    apptainer build "${apptainer_args[@]}" "${IMAGE_PATH}" "${BUILD_DEFFILE:-${DEFFILE}}"

    [[ -n "${APPTAINER_TMPDIR:-}" ]] && [[ -d "${APPTAINER_TMPDIR}" ]] && rm -rf "${APPTAINER_TMPDIR:?}/*"

    echo "::notice::Container size:" "$(du -h "${IMAGE_PATH}" | cut -f1 || true)"
    printf "::notice::Container labels:\n%s\n" "$(apptainer apptainer inspect "${IMAGE_PATH}" || true)"
    printf "::notice::IMAGE_PATH=%q\n" "${IMAGE_PATH}"
    export IMAGE_PATH

}

function push_container() {
    declare -a image_tags
    # Get the image tags:
    [[ -n "${INPUT_TAGS:-}" ]] && mapfile -t image_tags <<<"${INPUT_TAGS:-}" # Add the tags from the input

    [[ -n "${IMAGE_VERSION:-}" ]] && image_tags+=("${IMAGE_VERSION:-}") # Add the version as a tag

    [[ -n "${INPUT_ADD_TAGS:-}" ]] && image_tags+=("${INPUT_ADD_TAGS:-}") # Add the additional tags to the list of tags

    # If we have a semantic version, and if it is the newest version that is not a pre-release, add the "latest" tag:
    if [[ "${IMAGE_VERSION}" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "::notice::Trying to set IMAGE_VERSION to semantically newest tag if possible"
        SEMANTICALLY_NEWEST_TAG="$({ echo "${IMAGE_VERSION}";
        IMAGE_REPO_URL="${IMAGE_URL#oras://ghcr.io/}"
        IMAGE_REPO_URL="${IMAGE_REPO_URL%:*}"
        IMAGE_REPO_URL="$(jq -rn --arg x "${IMAGE_REPO_URL}" '$x|@uri' || true)"
        gh api "/users/${GITHUB_REPOSITORY_OWNER}/packages/container/${GITHUB_REPOSITORY#*/}%2F${IMAGE_NAME}/versions" --jq '.[].metadata.container.tags[]' ||
            true; } |
            grep -P '^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$' |
            grep -v '\-.*$' | sed -E 's/^v?(.*)$/\1\t\0/g' |
            tr - \~ |
            sort -k1V |
            tr \~ - |
            cut -f2 |
            tail -n1 ||
            true)"

        if [[ -n "${SEMANTICALLY_NEWEST_TAG:-}" ]]; then
            echo "::notice::The semantically newest tag is ${SEMANTICALLY_NEWEST_TAG:-}"
        else
            echo "::notice::No semantically newest tag found ${SEMANTICALLY_NEWEST_TAG:-}"
        fi

        if [[ "${SEMANTICALLY_NEWEST_TAG:-}" == "${IMAGE_VERSION}" ]]; then
            image_tags+=("latest")
        fi

    fi

    # Remove duplicate tags:
    if (("${#image_tags[@]}" > 1)); then
        mapfile -t image_tags < <(echo "${image_tags[@]}" | tr '[:space:]' '\n' | awk '!a[$0]++' || true)
    fi

    printf "::notice::Image tags: %s\n" "${image_tags[@]}"

    case "${IMAGE_URL:-}" in
        oras://ghcr.io/*)

            echo "::notice::Logging in to oras://ghcr.io"

            # Log in:
            apptainer remote login -u "${GITHUB_ACTOR}" -p "${GITHUB_TOKEN}" oras://ghcr.io

            # Push the image:
            echo "::notice::Pushing image to \"${IMAGE_URL}\""
            apptainer push -U "${IMAGE_PATH}" "${IMAGE_URL}"

            # Update OCI manifest using labels in container:

            oras manifest fetch -u "${GITHUB_ACTOR}" -p "${GITHUB_TOKEN}" "${IMAGE_URL#oras://}" >"${RUNNER_TEMP}/manifest.json"
            labels_json="$(apptainer inspect --json --labels "${IMAGE_PATH}" | jq -r '.data.attributes.labels' || true)"
            if [[ -n "${labels_json:-}" ]]; then
                echo "::notice::Adding labels to OCI manifest"
                jq --argjson labels "${labels_json}" '.annotations += $labels' "${RUNNER_TEMP}/manifest.json" >"${RUNNER_TEMP}/manifest-updated.json"
                oras manifest push -u "${GITHUB_ACTOR}" -p "${GITHUB_TOKEN}" --media-type 'application/vnd.oci.image.manifest.v1+json' "${IMAGE_URL#oras://}" "${RUNNER_TEMP}/manifest-updated.json"
            fi
            ;;
        *)
            echo "::error::Invalid image URL: ${IMAGE_URL}"
            return 1
            ;;
    esac

    # Tag the image with additional tags if any:
    if (("${#image_tags[@]}" > 1)); then
        printf "::notice::Tagging the image with additional tags: %s\n" "${image_tags[@]:1}"
        oras tag -u "${GITHUB_ACTOR}" -p "${GITHUB_TOKEN}" "${IMAGE_URL#oras://}" "${image_tags[@]}"
    fi

    # Set image-url output:
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "image-url=${IMAGE_URL}" >>"${GITHUB_OUTPUT}"

    echo "::notice::Pushed image to \"${IMAGE_URL}\""

}

echo "::group::check_prereqs()"
check_prereqs
echo "::endgroup::"

echo "::group::find_deffile()"
find_deffile
echo "::endgroup::"

echo "::group::create_labels()"
create_labels
echo "::endgroup::"

echo "::group::build_container()"
build_container
echo "::endgroup::"

echo "::group::push_container()"
push_container
echo "::endgroup::"

echo "::notice::Done!"
