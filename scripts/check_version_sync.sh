#!/usr/bin/env bash
# Assert that every place a toolchain or service version is pinned agrees.
#
# A version gets spelled out in several files because different consumers read different ones:
# mise.toml drives local dev (and mise-action in CI), .ruby-version / .node-version /
# .python-version feed setup-ruby / setup-node / setup-python, the Dockerfile ARGs build the
# production image, package.json's `packageManager` field drives corepack, mise.lock records the
# exact release a floating mise.toml spec resolves to, and the `image:` tags
# in a compose file or config/deploy.yml decide what production runs versus what CI tests
# against. Nothing makes them agree on its own, so a bump that misses one file is silent: the
# image builds on a different Ruby than the tests ran on, or the suite goes green against a
# database server nobody deploys.
#
# Part of the dev-env standard (dev-hooks:dev-env-setup, v26) — run by the hk `versions` step and
# CI's `versions` job so the local and CI gates can't drift. Don't hand-edit the logic; the next
# policy change should be a plain re-copy of the template (a repo's own formatter may re-indent
# this file to local style, which is fine).
#
# Only files that exist get checked, and every skip is printed: a repo legitimately without a
# Dockerfile or a compose file passes, but its pass never looks like more coverage than it is.
# The gate reports and never rewrites a pin — which file holds the correct value is a judgement
# call (in one repo the right fix was to change production, not CI).
#
# Deliberately NOT checked: go.mod's `go` directive. It declares the *minimum* language version
# the module builds with, not the toolchain a build pins, so it is routinely — and correctly —
# older than mise.toml's `go`. Comparing them would fail healthy repos.
#
# Deliberately NOT enforced: Dockerfile style. Whether an image hardcodes `ARG NODE_VERSION` or
# derives the Node major from .node-version is a per-repo choice. This verifies that whatever
# pins exist agree, so adopting the standard never forces a Dockerfile rewrite.
#
# EVERY Dockerfile in the repo root is checked, not just the first one found. A repo
# commonly carries a production `Dockerfile` beside a `Dockerfile.dev`, and stopping at the first
# is how one of them sat on node:22 for months while .node-version, mise.toml and the production
# Dockerfile all said 24 — with this gate green the whole time, in the repo whose own docs claimed
# Node 24 "everywhere".
#
# CI's own setup steps are checked too: agreeing files prove nothing if the job that runs the
# tests installs some other version (see "CI setup steps" below).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
note() {
	echo "  ✗ $1"
	fail=1
}
skip() { echo "  - $1"; }

TMP=$(mktemp) || exit 1
CI_PINS=$(mktemp) || exit 1
CI_OUT=$(mktemp) || exit 1
trap 'rm -f "$TMP" "$CI_PINS" "$CI_OUT"' EXIT

# ── Toolchain pins ────────────────────────────────────────────────────────────────────
MISE=""
for f in mise.toml .mise.toml; do
	if [ -f "$f" ]; then
		MISE=$f
		break
	fi
done

# Newline-separated, because a `for f in $DOCKERFILES` would word-split a name containing a
# space. An unmatched glob is left literal by the shell (no nullglob here), so `Dockerfile.*` in
# a repo with only a plain `Dockerfile` survives as that literal string — the `[ -f ]` guard is
# what drops it, and must not be removed. `Dockerfile` itself needs the literal dot to match
# `Dockerfile.*`, so it can never be listed twice.
#
# Excluded: editor/VCS leftovers (`Dockerfile.dev.bak`, `Dockerfile.orig`) and templates
# (`Dockerfile.j2`) — neither is a build input, and a template's `ARG NODE_VERSION={{ ... }}`
# would fail forever with no correct value to change it to.
DOCKERFILES=""
for f in Dockerfile Containerfile Dockerfile.* Containerfile.*; do
	[ -f "$f" ] || continue
	case $f in
	*.bak | *.orig | *.rej | *.save | *.swp | *.swo | *.tmp | *.disabled | *~) continue ;;
	*.example | *.sample | *.j2 | *.tpl | *.template | *.erb) continue ;;
	esac
	DOCKERFILES="$DOCKERFILES$f
"
done

# A mise.toml `[tools]` value. Handles both `node = "22.4.1"` and the table form
# `ruby = { version = "4.0.2", compile = false }` by taking the first quoted string after `=`.
read_mise() {
	[ -n "$MISE" ] || return 0
	awk -v key="$1" '
    /^[[:space:]]*\[/ { intools = ($0 ~ /^[[:space:]]*\[tools\][[:space:]]*$/); next }
    !intools { next }
    {
      line = $0
      sub(/#.*/, "", line)
      if (line !~ "^[[:space:]]*\"?" key "\"?[[:space:]]*=") next
      sub(/^[^=]*=/, "", line)
      if (match(line, /"[^"]*"/)) { print substr(line, RSTART + 1, RLENGTH - 2); exit }
    }
  ' "$MISE"
}

# One Dockerfile's `ARG NAME=value` defaults, one per line, deduplicated. A multi-stage build may
# redeclare a bare `ARG NAME` to pull it into a later stage's scope; those carry no pin, so only
# `=` lines count. $1 is the file, $2 the ARG name.
#
# Strips blanks, CR and quotes but NOT newlines: `[:space:]` here used to delete the line
# separators too, which collapsed two differing defaults into one line, so `lines` could only
# ever answer 0 or 1 and the caller's "conflicting defaults" branch was unreachable. A file
# declaring 24.19.0 and 20.0.0 reported the value as "24.19.020.0.0" instead.
read_arg() {
	sed -n "s/^[[:space:]]*ARG[[:space:]]\{1,\}$2=//p" "$1" | tr -d "[:blank:]\r\"'" | sort -u
}

# package.json's `"packageManager": "pnpm@9.1.0+sha512…"` — corepack's pin, for the JS stack.
read_pkgmgr() {
	[ -f package.json ] || return 0
	sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json |
		head -n1 | awk -F'@' -v t="$1" 'NF > 1 && $1 == t { sub(/\+.*/, "", $2); print $2 }'
}

# `.ruby-version` may be bare (3.4.10) or prefixed (ruby-3.4.10); `.node-version` may carry a
# leading v (v22.4.1). Every form is valid for setup-* and mise, so normalise before comparing.
normalize() {
	local v
	v=$(printf '%s' "$2" | tr -d "[:space:]\"'")
	v=${v#"$1"-}
	v=${v#"$1"}
	case $v in v[0-9]*) v=${v#v} ;; esac
	printf '%s' "$v"
}

lines() { printf '%s' "$1" | grep -c .; }

# mise.lock's exact release for a tool: `[[tools.python]]` followed by `version = "3.14.6"`.
# It is what mise installs locally and what mise-action installs in CI, so a floating mise.toml
# spec ("latest", "lts") still has a real version to compare.
read_lock() {
	[ -f mise.lock ] || return 0
	awk -v key="$1" '
    /^\[\[tools\./ {
      h = $0
      sub(/^\[\[tools\./, "", h)
      sub(/\]\][[:space:]]*$/, "", h)
      gsub(/"/, "", h)
      cur = (h == key)
      next
    }
    /^\[/ { cur = 0; next }
    cur && /^version[[:space:]]*=/ {
      v = $0
      sub(/^[^=]*=[[:space:]]*"/, "", v)
      sub(/".*/, "", v)
      print v
      exit
    }
  ' mise.lock
}

# ── CI setup steps ────────────────────────────────────────────────────────────────────
# A CI job runs the language version its setup step names — and when it names none, the
# runner's own. A pin that agrees across every file still proves nothing about CI if the setup
# step floats (`lts/*`), hardcodes something else, or has no version at all; setup-uv in
# particular installs uv, not Python, so on its own uv takes the runner's python3. Each step
# must read the pin: a version file, or mise-action installing the tool from mise.toml in the
# same job. The standard tests one version, so a matrix expression is a failure too.
WORKFLOWS=""
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
	[ -f "$f" ] && WORKFLOWS="$WORKFLOWS$f
"
done

# One tab-separated row per setup or mise-action step:
#   file, job, action, version input, version-file input, mise `install`, mise `install_args`.
# An absent input is "<none>", distinct from an empty one. A line-based walk, not a YAML parser:
# it knows jobs, list items, `with:` and block scalars (a `run: |` body is skipped, so script
# text that looks like a step is never read as one).
ci_steps() {
	awk -v f="$1" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function clean(v) {
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      return v
    }
    function get(k) { return (k != "" && (k in w)) ? w[k] : "<none>" }
    function flush(   vk, fk) {
      vk = fk = ""
      if (act == "actions/setup-python") { vk = "python-version"; fk = "python-version-file" }
      else if (act == "astral-sh/setup-uv") vk = "python-version"
      else if (act == "actions/setup-node") { vk = "node-version"; fk = "node-version-file" }
      else if (act == "ruby/setup-ruby") vk = "ruby-version"
      else if (act == "actions/setup-go") { vk = "go-version"; fk = "go-version-file" }
      else if (act == "oven-sh/setup-bun") { vk = "bun-version"; fk = "bun-version-file" }
      if (vk != "" || act == "jdx/mise-action")
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f, job, act, get(vk), get(fk), get("install"), get("install_args")
      act = ""; step = -1; withind = -1
      split("", w)
    }
    BEGIN { blk = -1; step = -1; withind = -1; jobind = -1 }
    {
      raw = $0
      sub(/\r$/, "", raw)
      if (raw ~ /^[[:space:]]*$/) next
      i = ind(raw)
      if (blk >= 0) { if (i > blk) next; blk = -1 }
      if (raw ~ /^[[:space:]]*#/) next
      if (i == 0) { flush(); injobs = (raw ~ /^jobs:/); jobind = -1; next }
      if (!injobs) next
      if (jobind < 0) jobind = i
      if (i == jobind) {
        flush()
        job = raw
        sub(/^[[:space:]]*/, "", job)
        sub(/:.*/, "", job)
        next
      }
      line = raw
      keyind = i
      if (match(line, /^ *- +/)) {
        if (step < 0 || i <= step) { flush(); step = i }
        keyind = RLENGTH
        line = substr(line, RLENGTH + 1)
      } else sub(/^ */, "", line)
      if (!match(line, /^[A-Za-z0-9_.-]+:/)) next
      k = substr(line, 1, RLENGTH - 1)
      v = clean(substr(line, RLENGTH + 1))
      if (v ~ /^[|>][-+0-9]*$/) blk = keyind
      if (step < 0) next
      if (withind >= 0 && keyind <= withind) withind = -1
      if (withind >= 0) { w[k] = v; next }
      if (k == "with") { withind = keyind; next }
      if (k == "uses") { sub(/@.*/, "", v); act = v }
    }
    END { flush() }
  ' "$1"
}

ci_rows=""
while IFS= read -r wf; do
	[ -n "$wf" ] && ci_rows="$ci_rows$(ci_steps "$wf")
"
done <<<"$WORKFLOWS"

# Does a mise-action step in this file+job install the tool? With no install_args it installs
# every mise.toml tool; with them, only the named ones (`python@3.14` counts as python).
mise_installs() { # $1 file, $2 job, $3 tool
	local f j a inst args tok
	[ -n "$(read_mise "$3")" ] || return 1
	while IFS=$'\t' read -r f j a _ _ inst args; do
		[ "$f" = "$1" ] && [ "$j" = "$2" ] && [ "$a" = jdx/mise-action ] || continue
		[ "$inst" = false ] && continue
		[ "$args" = "<none>" ] || [ -z "$args" ] && return 0
		for tok in $args; do
			[ "${tok%%@*}" = "$3" ] && return 0
		done
	done <<<"$ci_rows"
	return 1
}

ci_ok() { echo "  ✓ $1" >>"$CI_OUT"; }
ci_bad() {
	echo "  ✗ $1" >>"$CI_OUT"
	fail=1
}

nsetup=0
while IFS=$'\t' read -r f job act ver vfile inst args; do
	[ -n "$f" ] && [ "$act" != jdx/mise-action ] || continue
	nsetup=$((nsetup + 1))
	case $act in
	actions/setup-python | astral-sh/setup-uv) tool=python ;;
	actions/setup-node) tool=node ;;
	ruby/setup-ruby) tool=ruby ;;
	actions/setup-go) tool=go ;;
	oven-sh/setup-bun) tool=bun ;;
	esac
	where="$f $job"
	# setup-ruby takes a file name in `ruby-version` itself (`ruby-version: .ruby-version`).
	if [ "$act" = ruby/setup-ruby ] && [[ $ver == .* || $ver == *.toml ]]; then
		vfile=$ver
		ver="<none>"
	fi
	if [ "$vfile" != "<none>" ]; then
		if [ -f "$vfile" ]; then
			ci_ok "$where: $act reads $vfile"
		else
			ci_bad "$where: $act reads $vfile, which does not exist"
		fi
	elif [ "$ver" != "<none>" ]; then
		key=${tool}-version
		case $ver in
		*\$\{\{*) ci_bad "$where: $act $key is an expression ($ver) — CI must run the one pinned version; read the pin file instead" ;;
		*)
			norm=$(normalize "$tool" "$ver")
			if [[ $norm =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
				printf '%s\t%s\t%s\n' "$tool" "$where $act" "$norm" >>"$CI_PINS"
			else
				ci_bad "$where: $act $key is \"$ver\", which floats — CI runs whatever is newest, not what local pins; read the pin file instead"
			fi
			;;
		esac
	elif [ "$tool" = python ] && [ -f .python-version ]; then
		ci_ok "$where: $act reads .python-version"
	elif [ "$tool" = ruby ] && [ -f .ruby-version ]; then
		ci_ok "$where: $act reads .ruby-version"
	elif mise_installs "$f" "$job" "$tool"; then
		ci_ok "$where: $tool from $MISE via mise-action"
	elif [ "$tool" = python ]; then
		ci_bad "$where: $act names no Python, so the job runs the runner's python3 — pin python in mise.toml and install it with mise-action in this job (or add .python-version)"
	else
		ci_bad "$where: $act names no version, so the job runs whatever $tool the runner has — read the pin file (${tool}-version-file) or install it with mise-action"
	fi
done <<<"$ci_rows"

n=0
first_src=""
first_ver=""
all_srcs=""
mismatch=0
add_source() { # $1 label, $2 version
	n=$((n + 1))
	all_srcs="${all_srcs:+$all_srcs, }$1"
	if [ "$n" -eq 1 ]; then
		first_src=$1
		first_ver=$2
	elif [ "$2" != "$first_ver" ]; then
		note "$1 ($2) != $first_src ($first_ver)"
		mismatch=1
	fi
}

echo "Toolchain:"
[ -n "$MISE" ] || skip "no mise.toml, so no mise pins to cross-check"
[ -n "$DOCKERFILES" ] || skip "no Dockerfile, so no image-build ARGs to cross-check"

# tool | version file (empty = no conventional one) | Dockerfile ARG
while IFS='|' read -r tool vfile arg; do
	[ -n "$tool" ] || continue
	n=0
	first_src=""
	first_ver=""
	all_srcs=""
	mismatch=0
	floating=""

	if [ -n "$vfile" ] && [ -f "$vfile" ]; then
		ver=$(normalize "$tool" "$(cat "$vfile")")
		[ -n "$ver" ] && add_source "$vfile" "$ver"
	fi

	raw=$(read_mise "$tool")
	if [ -n "$raw" ]; then
		# "latest"/"lts" and backend-prefixed specs (aqua:…, ruby-build:…) name no fixed version —
		# mise.lock is their real pin — so there is nothing to compare a version file against.
		case $raw in
		*:*) floating=$raw ;;
		*[0-9]*) add_source "$MISE $tool" "$(normalize "$tool" "$raw")" ;;
		*) floating=$raw ;;
		esac
		locked=$(read_lock "$tool")
		if [ -n "$floating" ] && [ -n "$locked" ]; then
			add_source "mise.lock $tool" "$(normalize "$tool" "$locked")"
			floating=""
		fi
	fi

	raw=$(read_pkgmgr "$tool")
	[ -n "$raw" ] && add_source "package.json packageManager" "$(normalize "$tool" "$raw")"

	# Each Dockerfile is its own source, labelled by name: with two of them the ✓ line lists both,
	# and a mismatch says which file to fix rather than just "Dockerfile".
	while IFS= read -r dockerfile; do
		[ -n "$dockerfile" ] || continue
		raw=$(read_arg "$dockerfile" "$arg")
		case "$(lines "$raw")" in
		0) ;;
		1) add_source "$dockerfile ARG $arg" "$(normalize "$tool" "$raw")" ;;
		*) note "$dockerfile declares ARG $arg with conflicting defaults: $(printf '%s' "$raw" | tr '\n' ' ')" ;;
		esac
	done <<<"$DOCKERFILES"

	while IFS=$'\t' read -r t label v; do
		[ "$t" = "$tool" ] && add_source "$label" "$v"
	done <"$CI_PINS"

	# A floating mise spec is only worth mentioning when some other file does pin the tool —
	# on its own it is the standard's normal state, not a gap.
	floating_note=""
	[ -n "$floating" ] && floating_note=" ($MISE spec is \"$floating\", no fixed version to compare)"

	case $n in
	0) ;; # this repo pins the tool nowhere — nothing to say about it
	1) skip "$tool: pinned only in $first_src ($first_ver)$floating_note, nothing to cross-check" ;;
	*)
		[ -n "$floating" ] && skip "$tool: $MISE spec is \"$floating\" (no fixed version), not compared"
		[ "$mismatch" = 0 ] && echo "  ✓ $tool $first_ver — $all_srcs"
		;;
	esac
done <<'TOOLS'
ruby|.ruby-version|RUBY_VERSION
node|.node-version|NODE_VERSION
python|.python-version|PYTHON_VERSION
go|.go-version|GO_VERSION
yarn||YARN_VERSION
pnpm||PNPM_VERSION
npm||NPM_VERSION
bun||BUN_VERSION
TOOLS

echo
echo "CI setup steps:"
if [ -z "$WORKFLOWS" ]; then
	skip "no workflows, nothing to check"
elif [ "$nsetup" -eq 0 ]; then
	if printf '%s' "$ci_rows" | grep -q $'\tjdx/mise-action\t'; then
		skip "no setup-* steps; the workflows install their toolchain with mise-action (mise.lock)"
	else
		skip "no language setup steps in the workflows"
	fi
fi
cat "$CI_OUT"

# ── Service image tags ────────────────────────────────────────────────────────────────
# CI has to exercise the services production actually runs, or the suite goes green against a
# database nobody deploys. Deployment manifests differ per repo (a compose file, Kamal's
# config/deploy.yml, a devcontainer compose), so discover whichever are present instead of
# hardcoding one, and compare every file that pins a given image against the others. An image
# named in only one file is not drift (CI may legitimately not need Redis), so it is reported
# but never fails.
echo
echo "Service image tags:"

FILES=""
nfiles=0
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml \
	config/deploy.yml config/deploy.yaml \
	.devcontainer/compose.yml .devcontainer/compose.yaml \
	.devcontainer/docker-compose.yml .devcontainer/docker-compose.yaml \
	.github/workflows/*.yml .github/workflows/*.yaml; do
	if [ -f "$f" ]; then
		FILES="$FILES$f
"
		nfiles=$((nfiles + 1))
	fi
done

if [ "$nfiles" -eq 0 ]; then
	skip "no compose / deploy / workflow files, nothing to cross-check"
else
	# `image: mysql:8.4`, `image: "mysql:8.4"`, `image: mysql:8.4@sha256:…` (CI pins by digest, so
	# match only the tag). Commented-out and templated (${…}, {{…}}, <%…%>) images are skipped, as
	# are untagged ones (a bare `image: acme/app` pins nothing).
	printf '%s' "$FILES" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		awk -v f="$f" '
      {
        line = $0
        sub(/#.*/, "", line)
        if (line !~ /^[[:space:]]*-?[[:space:]]*image:[[:space:]]*[^[:space:]]/) next
        sub(/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*/, "", line)
        gsub(/["\047]/, "", line)
        sub(/[[:space:]].*$/, "", line)
        sub(/@.*$/, "", line)
        if (line ~ /\$|\{\{|<%/) next
        nc = split(line, part, ":")
        if (nc < 2) next
        tag = part[nc]
        repo = substr(line, 1, length(line) - length(tag) - 1)
        if (repo == "" || tag == "") next
        sub(/^docker\.io\//, "", repo)
        sub(/^library\//, "", repo)
        print repo "\t" tag "\t" f
      }
    ' "$f"
	done | sort -u >"$TMP"

	if [ ! -s "$TMP" ]; then
		skip "no tagged \`image:\` pins in the $nfiles compose/deploy/workflow file(s) present"
	elif ! awk -F'\t' '
    {
      if (!($1 in seen)) { seen[$1] = 1; order[++nk] = $1 }
      fkey = $1 SUBSEP $3
      if (!(fkey in fseen)) { fseen[fkey] = 1; nf[$1]++; files[$1] = files[$1] (files[$1] ? ", " : "") $3 }
      tkey = $1 SUBSEP $2
      if (!(tkey in tseen)) { tseen[tkey] = 1; nt[$1]++ }
      onefile[$1] = $3
      onetag[$1] = $2
      detail[$1] = detail[$1] (detail[$1] ? ", " : "") $3 " (" $2 ")"
    }
    END {
      bad = 0
      for (i = 1; i <= nk; i++) {
        k = order[i]
        if (nf[k] < 2)
          printf "  - %s: pinned only in %s (%s), nothing to cross-check\n", k, onefile[k], onetag[k]
        else if (nt[k] == 1)
          printf "  ✓ %s %s — %s\n", k, onetag[k], files[k]
        else {
          printf "  ✗ %s tags disagree: %s\n", k, detail[k]
          bad = 1
        }
      }
      if (bad) print "    CI must exercise the services production runs — pick the right value and set it everywhere."
      exit bad
    }
  ' "$TMP"; then
		fail=1
	fi
fi

[ "$fail" -eq 0 ] || echo "Version pins disagree — fix the file(s) named above."
exit "$fail"
