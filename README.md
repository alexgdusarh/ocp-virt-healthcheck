# ocp-virt-healthcheck

Health check for OpenShift Virtualization (CNV/KubeVirt), built for live,
over-the-shoulder remote sessions: each check pairs a copy/paste-able `oc`
script with an Ansible role, so the same checks can be dictated by hand or
run unattended across a fleet of clusters.

## Layout

- `oc-commands/check_<name>.sh` — one executable script per check, meant to
  be opened and copy/pasted command-by-command during a live session.
- `roles/check_<name>/` — the equivalent Ansible role, using
  `kubernetes.core.k8s_info` (no shelling out to `oc`).
- `site.yaml` — runs all checks (or a subset via `--tags`) against one
  cluster, then writes a JSON report and prints a PASS/FAIL/WARN summary.
- `reports/` — per-cluster JSON reports (git-ignored).

## Requirements

```
pyenv virtualenv ansible-ocp   # see .python-version
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yaml
```

## Usage

Assumes you're already logged in (`oc login`) or have a valid `KUBECONFIG`
for the target cluster.

```bash
# oc commands: open and copy/paste from the script for the check you need
./oc-commands/check_clusterversion.sh

# Ansible: run all checks against the cluster pointed to by KUBECONFIG
KUBECONFIG=/path/to/cluster.kubeconfig ansible-playbook -i inventory/hosts.yaml site.yaml

# ...or with an explicit API token instead of a kubeconfig's embedded creds
KUBECONFIG=/path/to/cluster.kubeconfig K8S_AUTH_API_TOKEN=sha256~... \
  ansible-playbook -i inventory/hosts.yaml site.yaml

# ...or pass both as flags instead of env vars
ansible-playbook -i inventory/hosts.yaml site.yaml \
  -e k8s_auth_kubeconfig=/path/to/cluster.kubeconfig \
  -e k8s_auth_api_token=sha256~...

# Run a single check by tag
ansible-playbook -i inventory/hosts.yaml site.yaml --tags check_clusterversion
```

To check another cluster in the fleet, run the same playbook again with a
different `KUBECONFIG` — each run produces its own report under `reports/`.

## Checks implemented

| Check | oc script | Role |
|---|---|---|
| ClusterVersion status (version, conditions, TechPreview/FeatureGate) | `oc-commands/check_clusterversion.sh` | `roles/check_clusterversion` |

## License

Apache License 2.0 — see [LICENSE](LICENSE).
