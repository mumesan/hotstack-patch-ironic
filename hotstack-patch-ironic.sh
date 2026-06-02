#!/usr/bin/env bash
# dev-deploy-ironic.sh
#
# Set up the OpenShift internal registry if needed, build and push a dev
# ironic-operator image, and update the running operator on hotstack.
#
# Usage:
#   ./dev-deploy-ironic.sh                                         # interactive
#   ./dev-deploy-ironic.sh https://github.com/.../pull/722        # PR by URL
#   ./dev-deploy-ironic.sh --pr 722                               # PR by number
#   ./dev-deploy-ironic.sh --branch osprh-27737                   # branch
#   ./dev-deploy-ironic.sh --setup-only                           # registry setup only
#
# Prerequisites: podman, oc, git, python3 on the bastion.

set -euo pipefail

REPO_URL="https://github.com/openstack-k8s-operators/ironic-operator.git"
WORKSPACE_DIR="$HOME/workspace"
REPO_DIR="$WORKSPACE_DIR/ironic-operator"
NAMESPACE="openstack-operators"
IMAGE_TAG="dev"
ENV_VAR="RELATED_IMAGE_IRONIC_OPERATOR_MANAGER_IMAGE_URL"
TOKEN_FILE="$HOME/.dev-deploy-ironic-token"
TOKEN_MAX_AGE=3000  # 50 minutes — safely under the 1h default token expiry

# ── Parse arguments ───────────────────────────────────────────────────────────

BRANCH=""
PR=""
INTERACTIVE=false
SETUP_ONLY=false

if [[ $# -eq 0 ]]; then
    INTERACTIVE=true
else
    while [[ $# -gt 0 ]]; do
        case $1 in
            --branch)
                BRANCH="$2"; shift 2 ;;
            --pr)
                PR="$2"; shift 2 ;;
            --setup-only)
                SETUP_ONLY=true; shift ;;
            https://github.com/*/pull/*)
                PR=$(basename "$1"); shift ;;
            *)
                echo "ERROR: Unknown argument: $1"
                echo "Usage: $0 [PR-URL | --pr <n> | --branch <name> | --setup-only]"
                echo "       No arguments → interactive mode"
                exit 1 ;;
        esac
    done
fi

# ── 1. Registry setup (idempotent — safe to run every time) ──────────────────

echo "==> Checking registry setup..."

# Start the registry if not already available
REGISTRY_READY=$(oc get deployment image-registry -n openshift-image-registry \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [[ "${REGISTRY_READY:-0}" -lt 1 ]]; then
    echo "==> Registry not ready. Configuring storage..."
    oc patch configs.imageregistry.operator.openshift.io cluster \
        --type merge \
        --patch '{"spec":{"storage":{"emptyDir":{}},"managementState":"Managed"}}'
    echo "==> Waiting for registry deployment to become ready..."
    oc rollout status deployment/image-registry \
        -n openshift-image-registry \
        --timeout=120s
fi
echo "==> Registry is ready."

# Expose the registry via a Route if not already done
if ! oc get route default-route -n openshift-image-registry &>/dev/null; then
    echo "==> Exposing registry route..."
    oc patch configs.imageregistry.operator.openshift.io cluster \
        --type merge \
        --patch '{"spec":{"defaultRoute":true}}'
    sleep 5
fi

# Grant push access to the target namespace (idempotent)
oc policy add-role-to-user system:image-builder \
    system:serviceaccount:openshift-image-registry:default \
    -n "$NAMESPACE" &>/dev/null || true

echo "==> Registry setup OK."
[[ "$SETUP_ONLY" == "true" ]] && { echo "Done."; exit 0; }

# ── 2. Get registry hostname ──────────────────────────────────────────────────

REGISTRY=$(oc get route default-route \
    -n openshift-image-registry \
    -o jsonpath='{.spec.host}')
echo "==> Registry: $REGISTRY"

# ── 3. Token — reuse if still valid, create new if expired ───────────────────

token_age() {
    # Returns age of token file in seconds, or a large number if file missing
    [[ -f "$TOKEN_FILE" ]] || { echo 99999; return; }
    echo $(( $(date +%s) - $(stat -c %Y "$TOKEN_FILE") ))
}

TOKEN=""
if [[ $(token_age) -lt $TOKEN_MAX_AGE ]]; then
    TOKEN=$(cat "$TOKEN_FILE")
    echo "==> Reusing existing token ($(token_age)s old)."
fi

# Only attempt login with existing token if we actually have one
if [[ -z "$TOKEN" ]] || ! podman login "$REGISTRY" -u unused -p "$TOKEN" --tls-verify=false 2>/dev/null; then
    echo "==> Creating new registry token..."
    TOKEN=$(oc create token default -n openshift-image-registry)
    printf '%s' "$TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    podman login "$REGISTRY" -u unused -p "$TOKEN" --tls-verify=false
fi

echo "==> Logged in to registry."

# ── 4. Clone or update the repo ──────────────────────────────────────────────

# Create ~/workspace if it doesn't exist
mkdir -p "$WORKSPACE_DIR"

if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "==> Cloning ironic-operator into $REPO_DIR..."
    git clone "$REPO_URL" "$REPO_DIR"
else
    echo "==> Repo exists. Pulling latest main..."
fi

cd "$REPO_DIR"

# Ensure origin points to the upstream repo, not a fork
CURRENT_ORIGIN=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$CURRENT_ORIGIN" != "$REPO_URL" && "$CURRENT_ORIGIN" != "${REPO_URL%.git}" ]]; then
    echo "==> Updating remote origin from $CURRENT_ORIGIN to upstream..."
    git remote set-url origin "$REPO_URL"
fi

git fetch origin

# Always start from a clean up-to-date main
git checkout main
git pull origin main
echo "==> main: $(git log --oneline -1)"

# ── 5. Interactive prompt if no PR or branch given ────────────────────────────

sanitize() {
    # Trim leading/trailing whitespace and trailing slashes
    local val
    val=$(echo "$1" | xargs)   # trims both ends and collapses internal whitespace
    val="${val%/}"              # strip trailing slash (common from browser copy-paste)
    echo "$val"
}

parse_input() {
    local raw
    raw=$(sanitize "$1")

    if [[ -z "$raw" ]]; then
        echo "main"
        return
    fi

    # Full PR URL: https://github.com/.../pull/722 or .../pull/722/files etc.
    if [[ "$raw" =~ ^https://.*pull/([0-9]+) ]]; then
        echo "pr:${BASH_REMATCH[1]}"
        return
    fi

    # Bare PR number
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "pr:$raw"
        return
    fi

    # Treat anything else as a branch name
    echo "branch:$raw"
}

if [[ "$INTERACTIVE" == "true" ]]; then
    echo ""
    read -rp "Enter PR URL, PR number, or branch name (Enter for main): " RAW_INPUT
    PARSED=$(parse_input "$RAW_INPUT")
else
    # Non-interactive: build a token from the already-parsed BRANCH/PR variables
    if [[ -n "$PR" ]]; then
        PARSED="pr:$PR"
    elif [[ -n "$BRANCH" ]]; then
        PARSED="branch:$BRANCH"
    else
        PARSED="main"
    fi
fi

case "$PARSED" in
    main)
        : # already on latest main
        ;;
    pr:*)
        PR="${PARSED#pr:}"
        ;;
    branch:*)
        BRANCH="${PARSED#branch:}"
        ;;
esac

# ── 6. Checkout PR or branch ─────────────────────────────────────────────────

if [[ -n "$PR" ]]; then
    echo "==> Resolving branch name for PR #${PR}..."
    PR_JSON=$(curl -sf \
        "https://api.github.com/repos/openstack-k8s-operators/ironic-operator/pulls/${PR}")
    PR_BRANCH=$(echo "$PR_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['head']['ref'])")
    PR_REPO=$(echo "$PR_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['head']['repo']['clone_url'])")
    PR_REPO_FULL=$(echo "$PR_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['head']['repo']['full_name'])")
    if [[ -z "$PR_BRANCH" ]]; then
        echo "ERROR: Could not resolve branch for PR #${PR}. Check the PR number and network access."
        exit 1
    fi
    echo "==> PR #${PR} is branch: ${PR_BRANCH} (from ${PR_REPO_FULL})"
    UPSTREAM_FULL="openstack-k8s-operators/ironic-operator"
    if [[ "$PR_REPO_FULL" != "$UPSTREAM_FULL" ]]; then
        # Fork PR — fetch from the contributor's fork
        echo "==> Fork PR detected. Fetching from: ${PR_REPO}"
        git fetch "$PR_REPO" "$PR_BRANCH"
    else
        git fetch origin "$PR_BRANCH"
    fi
    # Use FETCH_HEAD to avoid creating a local branch with slashes in the name
    git checkout -B "pr-${PR}" FETCH_HEAD
elif [[ -n "$BRANCH" && "$BRANCH" != "main" ]]; then
    echo "==> Checking out branch: ${BRANCH}..."
    git checkout "$BRANCH"
    if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
        git pull origin "$BRANCH"
    else
        echo "==> Branch not on origin — using local state as-is."
    fi
else
    echo "==> Using latest main."
fi

echo "==> Building from: $(git log --oneline -1)"

# ── 7. Build and push ────────────────────────────────────────────────────────

EXTERNAL_IMG="$REGISTRY/$NAMESPACE/ironic-operator:$IMAGE_TAG"
INTERNAL_IMG="image-registry.openshift-image-registry.svc:5000/$NAMESPACE/ironic-operator:$IMAGE_TAG"

echo "==> Building image..."
podman build -t "$EXTERNAL_IMG" .

echo "==> Pushing image..."
podman push "$EXTERNAL_IMG" --tls-verify=false

# ── 8. Patch the openstack-operator CSV ──────────────────────────────────────
#
# The ironic-operator has no CSV of its own — it is managed by the
# openstack-operator meta-operator via the env var above.
# Patching the Deployment directly does not work; OLM reverts it immediately.
# The CSV version (v0.5.0 etc.) is found dynamically so version bumps don't break this.

CSV_NAME=$(oc get csv -n "$NAMESPACE" -o name | grep openstack-operator | head -1)
if [[ -z "$CSV_NAME" ]]; then
    echo "ERROR: Could not find openstack-operator CSV in namespace $NAMESPACE"
    exit 1
fi
CSV_BARE=$(basename "$CSV_NAME")
echo "==> Patching CSV: $CSV_BARE"

PATCH=$(oc get csv/"$CSV_BARE" -n "$NAMESPACE" -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
patches = []
for di, dep in enumerate(data['spec']['install']['spec']['deployments']):
    for ci, c in enumerate(dep['spec']['template']['spec']['containers']):
        for ei, env in enumerate(c.get('env', [])):
            if env['name'] == '$ENV_VAR':
                patches.append({
                    'op': 'replace',
                    'path': f'/spec/install/spec/deployments/{di}/spec/template/spec/containers/{ci}/env/{ei}/value',
                    'value': '$INTERNAL_IMG'
                })
if not patches:
    raise SystemExit('ERROR: $ENV_VAR not found in CSV')
print(json.dumps(patches))
")

oc patch csv/"$CSV_BARE" -n "$NAMESPACE" --type json -p "$PATCH"
echo "==> CSV patched."

# ── 9. Wait for rollout and verify ───────────────────────────────────────────

echo "==> Waiting for rollout..."
oc rollout status deployment/ironic-operator-controller-manager \
    -n "$NAMESPACE" \
    --timeout=120s

NEW_POD=$(oc get pods -n "$NAMESPACE" \
    -l control-plane=controller-manager \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}')

echo "==> New pod: $NEW_POD"
echo "==> Image in use:"
oc get pod "$NEW_POD" -n "$NAMESPACE" \
    -o jsonpath='{.spec.containers[*].image}' && echo

echo "==> Startup logs:"
oc logs -n "$NAMESPACE" "$NEW_POD" -c manager | head -15

# ── 10. Clean up local image ─────────────────────────────────────────────────
# The image is now in the cluster registry; the local copy just wastes disk.

echo "==> Removing local image..."
podman rmi "$EXTERNAL_IMG" 2>/dev/null || true
podman image prune -f 2>/dev/null || true

echo ""
echo "Done."
