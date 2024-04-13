#!/usr/bin/env bash
set -eu${XTRACE:-} -o pipefail

printenv | sed 's/^/check.prereqs.sh: /' | sort
command -v jq >/dev/null 2>&1 || { echo "jq is required but not found" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh is required but not found" >&2; exit 1; }
command -v apptainer >/dev/null 2>&1 || { echo "apptainer is required but not found" >&2; exit 1; }
command -v oras >/dev/null 2>&1 || { echo "oras is required but not found" >&2; exit 1; }

if [[ -z "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
	if [[ -z "${GITHUB_TOKEN:-}" ]]; then
		echo "::warning:: GITHUB_TOKEN is required but not found" >&2
	fi
fi
