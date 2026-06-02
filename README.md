# hotstack-patch-ironic

Patches the running `ironic-operator` on a hotstack instance using the OpenShift
internal registry, without going through quay.io or manually updating the CSV each time.

The script handles registry setup, token management, cloning/updating the ironic-operator
repo, building and pushing the image, and patching the `openstack-operator` CSV to use it.

## Prerequisites

`podman`, `oc`, `git`, `python3`

## Usage

```bash
# Interactive — prompts for PR/branch or Enter for main
./hotstack-patch-ironic.sh

# PR by URL
./hotstack-patch-ironic.sh https://github.com/openstack-k8s-operators/ironic-operator/pull/722

# PR by number
./hotstack-patch-ironic.sh --pr 722

# Branch by name
./hotstack-patch-ironic.sh --branch osprh-27737

# Registry setup only, no build
./hotstack-patch-ironic.sh --setup-only
```

The ironic-operator repo is cloned into `~/workspace/ironic-operator` on first run and
updated automatically on subsequent runs.
