#!/usr/bin/env bash
# Check: Capacity inventory (pre-workload)
#
# Informational, not a PASS/FAIL health check: reports what the cluster
# actually has to work with before any VM workload lands - Capacity vs.
# Allocatable (system-reserved overhead subtracted) CPU, memory, and
# hugepages, per node and summed both cluster-wide and for the
# kubevirt.io/schedulable=true pool specifically (the nodes VMs will
# actually land on).
set -euo pipefail

# Kubernetes resource.Quantity memory values are NOT guaranteed to be in
# Ki - the kubelet canonicalizes to the largest binary-SI suffix that
# divides the byte count evenly, so a node could legitimately report
# e.g. "4Gi" or "512Mi" instead of "...Ki" (verified: no spec guarantee,
# only an empirical pattern for typical physical RAM sizes). This jq
# function converts any Ki/Mi/Gi/Ti-suffixed (or bare-byte) value to Ki.
MEM_TO_KI='def mem_to_ki:
  if   test("Ki$") then (sub("Ki$";"") | tonumber)
  elif test("Mi$") then (sub("Mi$";"") | tonumber) * 1024
  elif test("Gi$") then (sub("Gi$";"") | tonumber) * 1024 * 1024
  elif test("Ti$") then (sub("Ti$";"") | tonumber) * 1024 * 1024 * 1024
  else (tonumber / 1024)
  end;'

echo "### Per-node: CPU/memory Capacity vs Allocatable ###"
oc get nodes -o json \
  | jq -r '
      ["NODE","SCHEDULABLE","CPU_CAPACITY","CPU_ALLOCATABLE","MEM_CAPACITY","MEM_ALLOCATABLE"],
      (.items[] | [
        .metadata.name,
        (.metadata.labels["kubevirt.io/schedulable"] // "false"),
        .status.capacity.cpu,
        .status.allocatable.cpu,
        .status.capacity.memory,
        .status.allocatable.memory
      ])
      | @tsv' \
  | column -t

echo
echo "### Per-node: hugepages allocatable (if configured) ###"
oc get nodes -o json \
  | jq -r '
      .items[]
      | .metadata.name as $n
      | (.status.allocatable | to_entries[] | select(.key | startswith("hugepages-")))
      | select(.value != "0")
      | "\($n)\t\(.key)\t\(.value)"' \
  | awk 'BEGIN{print "NODE\tHUGEPAGE_SIZE\tALLOCATABLE"} {print}'
echo "(empty above = no hugepages configured on any node)"

echo
echo "### Cluster-wide totals: all nodes ###"
oc get nodes -o json | jq -r "
  ${MEM_TO_KI}
  {
    node_count: (.items | length),
    cpu_allocatable_millicores: ([.items[].status.allocatable.cpu
        | if test(\"m\$\") then (sub(\"m\$\";\"\") | tonumber) else (tonumber * 1000) end] | add),
    memory_allocatable_ki: ([.items[].status.allocatable.memory | mem_to_ki] | add)
  }"

echo
echo "### Cluster-wide totals: kubevirt.io/schedulable=true nodes only (the VM-landing pool) ###"
oc get nodes -o json | jq -r "
  ${MEM_TO_KI}
  [.items[] | select((.metadata.labels[\"kubevirt.io/schedulable\"] // \"false\") == \"true\")] as \$sched
  | {
      schedulable_node_count: (\$sched | length),
      cpu_allocatable_millicores: ([\$sched[].status.allocatable.cpu
          | if test(\"m\$\") then (sub(\"m\$\";\"\") | tonumber) else (tonumber * 1000) end] | add // 0),
      memory_allocatable_ki: ([\$sched[].status.allocatable.memory | mem_to_ki] | add // 0)
    }"
