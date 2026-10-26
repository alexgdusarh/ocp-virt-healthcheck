# ocp-virt-healthcheck

Health check for OpenShift Virtualization (CNV/KubeVirt), built for live,
over-the-shoulder remote sessions: each check pairs a copy/paste-able `oc`
script with an Ansible role, so the same checks can be dictated by hand or
run unattended across a fleet of clusters.

## Layout

- `oc-commands/NN_check_<name>.sh` — one executable script per check,
  prefixed with its check number (`01_`, `02_`, ...) so the dictation
  order is obvious at a glance; opened and copy/pasted command-by-command
  during a live session. `00_collect_mustgather.sh` is the one exception
  to the numbering-matches-a-check rule: it's a diagnostic *collection*
  step with no PASS/FAIL verdict, meant to be run first, and has no
  Ansible-side equivalent (see below).
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
# Collect a must-gather first (general + OpenShift Virtualization), pinned
# to the cluster's actual OCP/CNV minor version - check it first, don't guess:
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
OCP_VERSION=4.20 ./oc-commands/00_collect_mustgather.sh   # or 4.22, etc.

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
| 0 | must-gather collection (general + OpenShift Virtualization) - run first, no PASS/FAIL verdict, no Ansible role | `oc-commands/00_collect_mustgather.sh` | *(none - oc-script only)* |
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
| 13 | SDN - OVN-Kubernetes health (default CNI) | `oc-commands/13_check_sdn_ovnk.sh` | `roles/check_sdn_ovnk` |
| 14 | SDN - Cilium health (only when Cilium is the detected CNI) | `oc-commands/14_check_sdn_cilium.sh` | `roles/check_sdn_cilium` |
| 15 | Storage - NetApp Trident CSI / ONTAP (basic; optional - PASS if not installed) | `oc-commands/15_check_storage_trident.sh` | `roles/check_storage_trident` |
| 16 | HyperConverged config sanity (pre-workload): liveMigrationConfig, workloadUpdateStrategy, defaultCPUModel vs. node CPU diversity | `oc-commands/16_check_hco_config_sanity.sh` | `roles/check_hco_config_sanity` |
| 17 | Node readiness for VM scheduling (pre-workload): Ready, cordon, kubevirt.io/schedulable, KVM device, drain taint | `oc-commands/17_check_node_vm_readiness.sh` | `roles/check_node_vm_readiness` |

Checks 16/17 are pre-workload checks: pure configuration/infrastructure
review that doesn't require any VirtualMachine to exist yet - useful for
validating a cluster before the first workload lands ("white canvas"
health check). Check 16 flags HyperConverged CR settings as risky against
**HCO's own CRD defaults**, not upstream raw KubeVirt's defaults, which
differ (e.g. HCO defaults `completionTimeoutPerGiB` to 20, not upstream's
800) - don't "fix" this back to the upstream value. Check 17 checks that
`kubevirt.io/schedulable=true` (a virt-handler *liveness* heartbeat) is
corroborated by an actual `devices.kubevirt.io/kvm` allocatable count,
since the two can diverge (documented upstream gap,
[kubevirt/kubevirt#8583](https://github.com/kubevirt/kubevirt/issues/8583)).

Checks 13/14 are mutually exclusive in Ansible: `site.yaml`'s `pre_tasks`
detect the cluster's actual CNI (CiliumNode CRD presence as the primary
signal, `Network.config.openshift.io/cluster` `spec.networkType` as a
fallback) once as `detected_sdn`, and each role's `when:` runs only the
one that matches — no flag needed. The two `oc` scripts are separate
per-CNI files; open whichever matches what's actually installed on the
cluster you're looking at.

**Scope note on third-party components** (Cilium, Trident/ONTAP, and any
future non-Red-Hat component): these checks cover how the component
interacts with OpenShift/OCP-Virt (installed? reporting healthy? can
VMs actually use it?) — not a deep dive into the vendor's own internals,
which is that vendor's own support surface. Red Hat-native components
(CNV, OVN-Kubernetes, MCO, etc.) get full diagnostic depth; third-party
components get a basic presence + health check.

Check 15 known-issues references (NetApp Trident + OpenShift
Virtualization), gathered 2026-10-26 — see
[`docs/trident-known-issues.md`](docs/trident-known-issues.md) for the
full list with links. Headline items: `TridentBackend.state: online` is
a documented false-positive risk
([NetApp/trident#543](https://github.com/NetApp/trident/issues/543),
[#836](https://github.com/NetApp/trident/issues/836)); SAN-protocol
StorageClasses (`ontap-san`/`ontap-san-economy`) only support RWX
(required for live migration) when `volumeMode: Block`, not
`Filesystem`; iSCSI session recovery after node reboot has open upstream
bugs ([#1138](https://github.com/NetApp/trident/issues/1138),
[#998](https://github.com/NetApp/trident/issues/998)) that are
particularly relevant since OCP nodes reboot during upgrades.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
