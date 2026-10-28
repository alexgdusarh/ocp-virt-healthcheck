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
- `mg/` — client must-gather tarballs and extracted content, plus
  generated findings files. **Entirely git-ignored — 100% confidential,
  never committed or pushed.**
- `scripts/analyze-mustgather.sh` — offline must-gather analysis using
  [`omc`](https://github.com/gmeghnag/omc) (not an `oc-commands` script —
  it runs against extracted must-gather data, not a live cluster). See
  "Must-gather analysis" below.

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

## Must-gather analysis

For offline analysis of a collected must-gather (e.g. from check 00),
using [`omc`](https://github.com/gmeghnag/omc) — an actively-maintained
community tool (not Red Hat-official) that lets you run `oc`-style
`get`/`describe`/`logs` commands directly against an extracted
must-gather, same mental model as the live `oc-commands` scripts.

```bash
# One-time install (Linux x86_64):
curl -sL https://github.com/gmeghnag/omc/releases/latest/download/omc_Linux_x86_64.tar.gz \
  | tar xz -C ~/.local/bin omc && chmod +x ~/.local/bin/omc

# Drop must-gather tarball(s) in mg/ (entirely git-ignored - confidential,
# never committed/pushed), then:
./scripts/analyze-mustgather.sh mg/<general-mustgather.tgz> [mg/<virt-mustgather.tgz>]
```

Prints to the terminal and saves to `mg/findings-<timestamp>.txt` (also
git-ignored). Archives collected on macOS commonly carry AppleDouble
`._*` metadata files that `omc` can choke on — the script strips these
automatically after each extraction. `omc`'s own `use <tarball>` is not
idempotent against an already-extracted directory (re-extracts noisily,
and its "current" must-gather selection isn't reliable across repeated
`use` calls on the same paths) — the script extracts with plain `tar`
and runs `omc mg delete -a` before each `omc use` to force a clean,
deterministic selection.

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
| 18 | MTV (Migration Toolkit for Virtualization / Forklift) operator health (optional - PASS if not installed) | `oc-commands/18_check_mtv_status.sh` | `roles/check_mtv_status` |
| 19 | Capacity inventory (pre-workload, informational): CPU/memory/hugepages Capacity vs. Allocatable, per node and summed cluster-wide + for the kubevirt.io/schedulable pool | `oc-commands/19_check_capacity_inventory.sh` | `roles/check_capacity_inventory` |
| 20 | etcd health: ClusterOperator conditions, pod readiness, configured quota | `oc-commands/20_check_etcd_health.sh` | `roles/check_etcd_health` |
| 21 | RBAC/SCC sanity for CNV service accounts (kubevirt-handler/kubevirt-controller SCCs, ClusterRoleBindings, PSA drift) | `oc-commands/21_check_cnv_rbac_scc.sh` | `roles/check_cnv_rbac_scc` |
| 22 | VLAN trunk reconciliation for a dedicated bonded uplink carrying many VLANs/NADs (optional - pass `vlan_trunk_bond`) | `oc-commands/22_check_vlan_trunk_reconciliation.sh` | `roles/check_vlan_trunk_reconciliation` |
| 23 | CNV internal certificates (TLS handshake / trust diagnostics for virt-handler) | `oc-commands/23_check_cnv_certs.sh` | `roles/check_cnv_certs` |
| 24 | Orphaned PersistentVolumeClaims (CDI-managed PVC with no owner, or owning DataVolume/VirtualMachine deleted) | `oc-commands/24_check_orphaned_pvcs.sh` | `roles/check_orphaned_pvcs` |
| 25 | MTU consistency across NNCP/NNS (bond/bridge/VLAN) and the VM/UDN networks riding on top | `oc-commands/25_check_mtu_consistency.sh` | `roles/check_mtu_consistency` |

MTV is the component that migrates VMs INTO OpenShift Virtualization
from external sources (vSphere, oVirt/RHV, OpenStack, OVA) - a separate
OLM operator (`forklift.konveyor.io/v1beta1` CRDs, namespace
`openshift-mtv` by convention), not part of CNV itself. Check 18 checks
the operator CSV, its Deployments, and every `Provider`/`NetworkMap`/
`StorageMap`'s `Ready` condition using MTV's own CRD printcolumns
(`Ready`, `ConnectionTestSucceeded`, `InventoryCreated`), and surfaces
the specific critical-category condition (e.g. `ConnectionAuthFailed`,
`SecretNotValid`) when a Provider isn't Ready.

Check 19 is informational rather than a strict PASS/FAIL health check -
it reports what capacity actually exists (no "requested" computation,
since on a pre-workload/white-canvas cluster that number isn't
meaningful yet). It WARNs only if zero nodes are labeled
`kubevirt.io/schedulable=true` (OpenShift Virtualization may not be
installed/ready). Kubernetes `resource.Quantity` memory values are
**not** guaranteed to use a `Ki` suffix (verified: kubelet canonicalizes
to the largest binary-SI suffix that divides the byte count evenly, so
a node could legitimately report `4Gi` instead of `...Ki`) - both the
`oc` script's jq and the Ansible role convert Ki/Mi/Gi/Ti explicitly
rather than assuming one fixed suffix.

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

Check 21 reads live SCC/RBAC/PSA state rather than asserting fixed
expected values (e.g. specific `allowedCapabilities`), since those are
version-dependent and not reliably documented across OCP releases. The
Pod Security Admission enforce label on `openshift-cnv` is computed by
OCP's own label-sync controller from the SCCs each namespace's service
accounts are bound to — it is not something anyone edits directly, so a
drifted PSA label is a symptom of an upstream SCC/RBAC change, not the
thing to fix in isolation.

Check 22 auto-detects which of two VLAN provisioning mechanisms a
cluster uses and runs the matching checks — no flag needed on either:

- **Mechanism A** (dedicated bonded uplink, e.g. active-backup,
  trunking many VLANs via NMState, each exposed via a manually-created
  NAD — seen in practice: one bond, 59 VLANs, 59 NADs; too coarse a
  scale for check 11's basic VLAN cross-check). Only runs when
  `vlan_trunk_bond` is set (there's no reliable way to auto-detect
  "the" dedicated VM-traffic bond generically) **and** no
  ClusterUserDefinedNetworks exist; skipped (PASS, not FAIL) otherwise:

  ```bash
  ansible-playbook -i inventory/hosts.yaml site.yaml \
    --tags check_vlan_trunk_reconciliation -e vlan_trunk_bond=bond0

  BOND_NAME=bond0 ./oc-commands/22_check_vlan_trunk_reconciliation.sh
  ```

  NMState has **no trunk-list field** at the bond/bridge level
  (verified from upstream source) — "is VLAN X trunked" is answered by
  enumerating NNCP-managed `type: vlan` sub-interfaces whose
  `vlan.base-iface` matches the bond, not by reading a single field.
  Bond member link-state field names are not stable across NMState
  versions, so this check reports raw NodeNetworkState data for manual
  reading rather than parsing an unconfirmed field.

- **Mechanism B** (OVN-Kubernetes `ClusterUserDefinedNetwork`, localnet
  topology — the CUDN owns and generates its own NAD directly, Red
  Hat's documented preferred method for VLAN connectivity since OCP
  4.19). Runs automatically whenever any `ClusterUserDefinedNetwork`
  exists — no flag or var needed:

  ```bash
  ansible-playbook -i inventory/hosts.yaml site.yaml \
    --tags check_vlan_trunk_reconciliation

  ./oc-commands/22_check_vlan_trunk_reconciliation.sh
  ```

  Verifies duplicate VLAN IDs within the same `physicalNetworkName`
  (reuse across *different* `physicalNetworkName` values is normal,
  not flagged), CUDNs whose `NetworkCreated` status condition isn't
  `True`, CUDNs whose `namespaceSelector` matches zero namespaces (oc
  script only — no built-in Ansible/Jinja Kubernetes label-selector
  matcher), a per-CUDN UDN↔NAD reconciliation table (OK/ORPHAN), and
  the reverse check (a UDN-labeled NAD with no owning CUDN).

Check 23 targets virt-handler TLS handshake investigations specifically.
KubeVirt runs its own self-signed CA (not cert-manager) in Secrets under
`openshift-cnv` (`kubevirt-ca`, `kubevirt-virt-handler-certs`,
`kubevirt-virt-handler-server-certs`, `kubevirt-virt-api-certs`,
`kubevirt-controller-certs`); server certs default to a **24h** lifetime
(CA: 168h), rotating at 80% of lifetime — a stuck rotation becomes a
real outage within ~24h. Actual expiry-date decoding
(`openssl x509 -noout -dates`) needs `openssl` and stays an `oc`-script-
only capability; the Ansible role checks Secret existence, that
virt-handler's DaemonSet mounts `kubevirt-virt-handler-certs` (a
documented real failure signature — `"failed to load the certificate
/etc/virt-handler/clientcertificates/..."` is a **mount defect**, distinct
from a trust-chain problem), and greps virt-handler logs for TLS/x509
error strings. The check also surfaces whether a cluster-wide Proxy is
configured as **context, not a confirmed diagnosis** — a proxy
inadvertently intercepting virt-handler's in-cluster traffic (via an
incomplete `noProxy`) is mechanically plausible (a MITM/inspecting
proxy's re-signed cert wouldn't be in KubeVirt's closed `kubevirt-ca`
trust bundle) but is **not a documented Red Hat/KubeVirt failure mode**
— researched explicitly and found no primary source confirming this
exact chain for CNV, so the check labels it as a heuristic to rule
in/out, not a cited fact.

Check 24 was added after reviewing a real must-gather: a PVC not
currently mounted by any pod is **not** by itself a reliable orphan
signal — CDI-managed VM disk PVCs are legitimately unmounted whenever
the owning VM is stopped. Real CDI-managed PVCs were confirmed to
consistently carry the `app.kubernetes.io/managed-by: cdi-controller`
label, which the check uses to scope its "no owner at all" detection —
deliberately *not* flagging every unowned PVC cluster-wide, since
real data showed plenty of legitimate PVCs (e.g. the internal image
registry's own storage) are never owned by anything. The second,
sharper signal is a PVC whose `ownerReferences` names a DataVolume or
VirtualMachine that no longer exists — on a `Retain`-reclaim-policy
StorageClass (flagged separately when present), that PVC/PV is not
auto-cleaned when its owner is deleted, so orphans accumulate silently.

Check 25 verifies MTU consistency end-to-end: cross-node consistency
per bond name, parent/child MTU ceiling violations (a VLAN must not
exceed its parent bond's actual MTU), and — for clusters using
mechanism B above — each UDN/CUDN NAD's `mtu` against the actual bond
it rides on, resolved via the real `physicalNetworkName` →
`ovn.bridge-mappings` (on `NodeNetworkState`) → NNCP
`ovs-bridge.bridge.port[].name` chain, not by guessing from the
`physicalNetworkName` string itself (e.g. `"phys-bond1"` does not
formally mean the bond is literally named `bond1`). It also flags, as
an **informational note only** (not a FAIL), when Trident
StorageClasses exist and the storage bond isn't running jumbo frames
(MTU 9000) per NetApp's documented best practice — 1500 still works,
it just leaves throughput on the table; switch-side MTU can't be
checked from inside the cluster and must be confirmed separately. The
Ansible role deliberately does not compare NNCP-*declared* MTU against
NNS-*actual* MTU — NMState's `mtu` field is optional per-interface, and
omitting it means "use the kernel default" (1500), not "drift"; only
the oc-script prints both side by side for human review.

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
