# ocp-virt-healthcheck

Health check for OpenShift Virtualization (CNV/KubeVirt), built for live,
over-the-shoulder remote sessions: each check pairs a copy/paste-able `oc`
script with an Ansible role, so the same checks can be dictated by hand or
run unattended across a fleet of clusters.

## Layout

- `oc-commands/NN_check_<name>.sh` — one executable script per check,
  prefixed with its check number (`01_`, `02_`, ...) so the dictation
  order is obvious at a glance; opened and copy/pasted command-by-command
  during a live session.
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

Check 11 (`check_vm_networking`) additionally requires the `oc` CLI itself
to be installed and on `PATH` wherever the Ansible role runs (it shells
out to `oc debug node/<node>` to read each node's physical NICs via
`nmcli` — there is no `kubernetes.core` equivalent for a node-level debug
exec, and reimplementing `oc debug`'s privileged-pod lifecycle would be
more invasive than using the tool built for it).

## Usage

Assumes you're already logged in (`oc login`) or have a valid `KUBECONFIG`
for the target cluster.

```bash
# oc commands: open and copy/paste from the script for the check you need
./oc-commands/01_check_clusterversion.sh

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

| # | Check | oc script | Role |
|---|---|---|---|
| 1 | ClusterVersion status (version, conditions, TechPreview/FeatureGate) | `oc-commands/01_check_clusterversion.sh` | `roles/check_clusterversion` |
| 2 | ClusterOperators all Available/steady | `oc-commands/02_check_clusteroperators.sh` | `roles/check_clusteroperators` |
| 3 | MachineConfigPool members ready/updated | `oc-commands/03_check_mcp_status.sh` | `roles/check_mcp_status` |
| 4 | Nodes match their pool's rendered MachineConfig | `oc-commands/04_check_nodes_mcp_render.sh` | `roles/check_nodes_mcp_render` |
| 5 | MachineSets/Machines ready (optional - not present on all bare-metal) | `oc-commands/05_check_machinesets.sh` | `roles/check_machinesets` |
| 6 | BareMetalHost linkage to Machine/MachineSet/Node (optional - IPI metal3 only) | `oc-commands/06_check_baremetalhosts.sh` | `roles/check_baremetalhosts` |
| 7 | CNV operator (CSV Succeeded) + HyperConverged CR health | `oc-commands/07_check_hco_status.sh` | `roles/check_hco_status` |
| 8 | KubeVirt CR + virt-api/virt-controller/virt-handler readiness | `oc-commands/08_check_kubevirt_components.sh` | `roles/check_kubevirt_components` |
| 9 | StorageClass + CDI (DataVolume import) readiness | `oc-commands/09_check_cdi_storage.sh` | `roles/check_cdi_storage` |
| 10 | VirtualMachine/VirtualMachineInstance health (printableStatus, phase, Ready) | `oc-commands/10_check_vm_health.sh` | `roles/check_vm_health` |
| 11 | VM networking: NMState/NNCP, physical NIC consistency per node role, dedicated networks, NAD + VLAN cross-check | `oc-commands/11_check_vm_networking.sh` | `roles/check_vm_networking` |
| 12 | Live migration readiness (failed/in-flight VMIMs, non-migratable volumes needing LiveMigrate) | `oc-commands/12_check_live_migration.sh` | `roles/check_live_migration` |

## License

Apache License 2.0 — see [LICENSE](LICENSE).
