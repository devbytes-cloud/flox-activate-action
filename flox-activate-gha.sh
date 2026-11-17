#!/usr/bin/env bash
#
# Activate a Flox environment and export it to every following step of a
# GitHub Actions job, via $GITHUB_ENV and $GITHUB_PATH.
#
# Configuration comes from environment variables, so input values are never
# parsed as shell. The names avoid the FLOX_ prefix because flox reads every
# FLOX_* variable as configuration.
#
#   INPUT_ENVIRONMENT  FloxHub environment to activate (owner/name), passed as -r
#   INPUT_DIR          directory containing a .flox/ directory, passed as -d
#   INPUT_TRUST        "true" to pass --trust (FloxHub environments only)
#
# Any positional arguments are passed through to `flox activate` unchanged.
#
# Outside of GitHub Actions ($GITHUB_ENV / $GITHUB_PATH unset), whatever would
# be exported is written to stderr instead, which is handy for local testing.

set -euo pipefail

args=()
if [[ -n "${INPUT_ENVIRONMENT:-}" ]]; then
	args+=(--remote "$INPUT_ENVIRONMENT")
fi
if [[ -n "${INPUT_DIR:-}" ]]; then
	args+=(--dir "$INPUT_DIR")
fi
if [[ "${INPUT_TRUST:-false}" == "true" ]]; then
	args+=(--trust)
fi
args+=(${@+"$@"})

github_env="${GITHUB_ENV:-/dev/stderr}"
github_path="${GITHUB_PATH:-/dev/stderr}"

# Variables that describe the activation's own shell process, or that flox
# uses to track an activation in progress. Exporting them would make later
# steps (or a later `flox activate`) believe they are inside that activation.
skip_var() {
	case "$1" in
	_ | PWD | OLDPWD | SHLVL) return 0 ;;
	_FLOX_* | _flox_* | _activate_d) return 0 ;;
	FLOX_PROMPT_* | FLOX_ACTIVATE_START_SERVICES) return 0 ;;
	# Set by the flox CLI wrapper for its own use, not by the environment.
	BUILDENV_NIX | GLOW_BIN | NIX_BIN | NIX_PLUGINS | PROCESS_COMPOSE_BIN) return 0 ;;
	BASH_FUNC_*) return 0 ;;
	esac
	# Names GitHub Actions or bash can't handle
	[[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
	return 1
}

env_file="$(mktemp)"
trap 'rm -f "$env_file"' EXIT

# Print a NUL before the environment so anything written to stdout by the
# on-activate hook is fenced off from the `env -0` output.
flox activate ${args[@]+"${args[@]}"} -- bash -c 'printf "\0"; env -0' >"$env_file"

{
	# Everything before the first NUL is hook output: pass it through.
	IFS= read -r -d '' hook_output || true
	if [[ -n "$hook_output" ]]; then
		printf '%s' "$hook_output"
	fi

	while IFS= read -r -d '' entry; do
		name="${entry%%=*}"
		value="${entry#*=}"

		if skip_var "$name"; then
			continue
		fi

		if [[ "$name" == "PATH" ]]; then
			IFS=: read -r -a entries <<<"$value"
			# Appending to $GITHUB_PATH *prepends* to PATH in later steps, so
			# write entries last-to-first to preserve their order.
			for ((i = ${#entries[@]} - 1; i >= 0; i--)); do
				dir="${entries[$i]}"
				[[ -n "$dir" && -d "$dir" ]] || continue
				[[ ":$PATH:" == *":$dir:"* ]] && continue
				printf '%s\n' "$dir" >>"$github_path"
			done
			continue
		fi

		# Skip variables the step already has with the same value (treating
		# unset and empty as the same).
		if [[ "${!name:-}" == "$value" ]]; then
			continue
		fi

		# Heredoc syntax handles multi-line values; a random delimiter keeps a
		# value from ending the heredoc early.
		# https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#multiline-strings
		delimiter="ghadelimiter_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
		if [[ "$value" == *"$delimiter"* ]]; then
			echo "::error::Value of $name contains the random delimiter $delimiter; please retry." >&2
			exit 1
		fi
		printf '%s<<%s\n%s\n%s\n' "$name" "$delimiter" "$value" "$delimiter" >>"$github_env"
	done
} <"$env_file"
