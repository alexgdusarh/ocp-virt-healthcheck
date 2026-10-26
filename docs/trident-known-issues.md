# NetApp Trident / ONTAP + OpenShift Virtualization — known issues

Gathered 2026-10-26. Scope: how Trident/ONTAP interacts with OpenShift
and OCP-Virt specifically — not a general Trident troubleshooting guide
(see NetApp's own docs for that). Check 15 (`check_storage_trident`)
covers presence/health in `roles/check_storage_trident` and
`oc-commands/15_check_storage_trident.sh`; this file is reference
material for the known issues it can't fully diagnose on its own.

## Backend status can be a false positive

`TridentBackend.state: online` / `online: true` does not guarantee the
backend is fully functional:

- [NetApp/trident#543](https://github.com/NetApp/trident/issues/543) — backends can report "online" even when not actually available.
- [NetApp/trident#836](https://github.com/NetApp/trident/issues/836) — Trident reports an offline volume as online.

The check surfaces `state` as reported. Treat it as a strong signal,
not proof — a real test provision (a throwaway PVC) is the only way to
be certain.

## RWX for live migration depends on protocol AND volumeMode

Live migration requires the VM's disk PVC to support `ReadWriteMany`.
Trident/ONTAP support for RWX depends on both the backend protocol and
the PVC's `volumeMode`:

- `ontap-nas` / `ontap-nas-economy` (NFS): RWX natively, any volumeMode.
- `ontap-san` / `ontap-san-economy` (iSCSI/FC/NVMe-TCP): RWX **only**
  when `volumeMode: Block`. A SAN-backed StorageClass with
  `volumeMode: Filesystem` and `accessModes: [ReadWriteMany]` is
  accepted by Kubernetes but will not actually support live migration.

Sources:
[NetApp OCP-Virt live migration doc](https://docs.netapp.com/us-en/netapp-solutions-virtualization/openshift/osv-vm-live-migration.html),
[Red Hat storage considerations for OpenShift Virtualization](https://developers.redhat.com/articles/2025/07/10/storage-considerations-openshift-virtualization).

Check 15 flags any Trident StorageClass whose `backendType` parameter
matches `san`, with a note to manually verify `volumeMode` on PVCs
using it — it cannot safely assume every PVC's volumeMode without a
cluster-wide PVC scan, which is out of scope for a basic check.

## iSCSI/multipath session recovery after node reboot

Relevant because OCP nodes reboot during MachineConfigPool rollouts
and cluster upgrades:

- [NetApp/trident#1138](https://github.com/NetApp/trident/issues/1138) — iSCSI self-healing fails to recover sessions stuck in `REOPEN` after a node reboot (~1-in-10 reboots reported, non-deterministic).
- [NetApp/trident#998](https://github.com/NetApp/trident/issues/998) — multipath drops to a single path against ONTAP 9.15.1P7 and doesn't recover.
- [NetApp/trident#864](https://github.com/NetApp/trident/issues/864) — self-healing interval/wait-time are tunable (`iscsiSelfHealingInterval`, `iscsiSelfHealingWaitTime`) if you hit the above.
- [NetApp/trident#961](https://github.com/NetApp/trident/issues/961) — self-healing logic itself has caused additional instability in some scenarios.

Issue open/closed status and fix-version were not independently
re-verified — check the live issue state before assuming any of these
are still present in a specific Trident version.

## Worker node prep (iSCSI/FC)

`multipath.conf` must have `find_multipaths: no` — NetApp states
`yes`/`smart` **will cause mount failures**, not just suboptimal
behavior. Trident 24.10+ added a `nodePrep` field on the
`TridentOrchestrator` CR to automate this.
Source: [Trident worker node prep docs](https://docs.netapp.com/us-en/trident/trident-use/worker-node-prep.html).

## CDI DataVolume import performance on NFS

Red Hat KCS [7144746](https://access.redhat.com/solutions/7144746)
("Suggested NFS mount optimizations with NetApp Trident storage on
OpenShift") covers elevated latency under concurrent workloads
including OCP-Virt, recommending `sec=sys,nconnect=8` mount options and
tuning the ONTAP SVM's `-v4.x-session-num-slots`. This article is
paywalled — full text not independently verified; pull it directly if
you have Red Hat portal access.

## Golden-image cloning requires matching StorageClass

Cloning a PVC (KubeVirt's golden-image/VM-template path) only works
as a fast CSI/FlexClone when the source DataSource and target VM PVC
use the **same StorageClass**. If a cluster has separate StorageClasses
per protocol/pool (e.g. NFS for golden images, iSCSI for VM disks),
cross-StorageClass cloning falls back to a full CDI import instead.
Source: [NetApp StorageProfile cloneStrategy blog](https://community.netapp.com/t5/Tech-ONTAP-Blogs/Demystifying-Clone-Strategy-in-Storage-Profile-and-its-relationship-with-Trident/ba-p/462426).

## Further reading

- [Trident objects reference](https://docs.netapp.com/us-en/trident/trident-reference/objects.html) — `TridentOrchestrator`, `TridentBackend`, `TridentBackendConfig`, `TridentNode`, etc.
- [Trident troubleshooting guide](https://docs.netapp.com/us-en/trident/troubleshooting.html)
- [Trident requirements (incl. OCP-Virt driver list)](https://docs.netapp.com/us-en/trident/trident-get-started/requirements.html)
- [Trident release notes](https://docs.netapp.com/us-en/trident/trident-rn.html) — `nodePrep`, 25.02 OCP-Virt enhancements.
- [Red Hat: OpenShift Virtualization storage considerations](https://developers.redhat.com/articles/2025/07/10/storage-considerations-openshift-virtualization)
- [Red Hat: Trident Operator is Red Hat-certified](https://www.redhat.com/en/blog/seamless-hybrid-cloud-storage-netapps-certified-openshift-operator-trident)
