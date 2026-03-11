# 💾 ADR-002: Storage Class Selection for MongoDB Workloads

## 📌 Status

**Accepted**

## 🔍 Context

MongoDB is an I/O-intensive stateful workload. The choice of StorageClass directly impacts database performance, data durability, and operational behavior during pod scheduling and rescheduling. Key parameters to decide:

1. **`volumeBindingMode`** - When to bind PVs to PVCs
2. **`reclaimPolicy`** - What happens to PVs when PVCs are deleted
3. **Filesystem vs Block** - Volume mode
4. **Provisioner** - Cloud-specific or local

### 🔗 Volume binding mode

| Mode | Behavior | Trade-off |
|------|----------|-----------|
| `Immediate` | PV created and bound as soon as PVC is submitted | May bind PV in a zone/node where no pod is scheduled, causing cross-zone I/O or scheduling failures |
| `WaitForFirstConsumer` | PV creation deferred until a pod using the PVC is scheduled | Ensures PV co-location with pod, respects topology constraints and affinity rules |

For MongoDB, data locality is critical. Cross-zone storage access introduces latency that directly impacts write performance and replication lag. With `WaitForFirstConsumer`, the scheduler places the pod first, then provisions storage on the same node/zone.

### ♻️ Reclaim policy

| Policy | Behavior | Trade-off |
|--------|----------|-----------|
| `Delete` | PV and underlying storage deleted when PVC is released | Clean, no orphaned volumes; risk of accidental data loss |
| `Retain` | PV preserved after PVC deletion, requires manual cleanup | Safer for stateful data; risk of orphaned volumes and cost accumulation |

For a database workload, accidental PVC deletion should not automatically destroy the underlying data. The backup strategy (ADR-004) provides the primary data protection mechanism, but `Retain` adds a defense-in-depth layer.

### 📂 Filesystem vs Block

MongoDB uses the WiredTiger storage engine, which manages its own data files and memory-mapped I/O. It operates on regular files within a filesystem, not raw block devices. Using `Filesystem` mode is the standard and recommended approach.

### ⚡ Performance considerations

MongoDB performance is sensitive to:

- **IOPS** - WiredTiger checkpoint writes and journal syncs require sustained random write IOPS
- **Latency** - fsync latency directly impacts write acknowledgment time
- **Throughput** - Oplog tailing and initial sync require sequential read throughput

Storage benchmarks using `fio` will be documented in `docs/benchmarks/fio-storage-results.md` once the cluster is deployed (Phase 2). The benchmark methodology will cover:

- Random read/write IOPS at 4k block size (simulates WiredTiger operations)
- Sequential read throughput at 128k block size (simulates oplog reads)
- fsync latency (simulates journal commits)
- Mixed workload (70% read / 30% write)

## ✅ Decision

We configure the StorageClass for MongoDB workloads with the following parameters:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mongodb-storage
provisioner: <cloud-specific or rancher.io/local-path for kind>
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: <cloud-specific, e.g., gp3 for AWS, Premium_LRS for Azure>
```

Key choices:

1. **`volumeBindingMode: WaitForFirstConsumer`** - Ensures storage is provisioned on the same topology domain as the pod. This is mandatory for multi-zone clusters and beneficial for single-zone clusters as it respects node affinity.

2. **`reclaimPolicy: Retain`** - Prevents accidental data loss from PVC deletion. Orphaned PVs are cleaned up through a documented operational procedure (runbook).

3. **`allowVolumeExpansion: true`** - Enables online volume resizing without pod restart, critical for growing databases.

4. **Filesystem mode** - Standard for MongoDB/WiredTiger workloads.

For local development with `kind`, the `rancher.io/local-path` provisioner is used with the same binding and reclaim settings where supported.

## 📊 Consequences

### ✅ What becomes easier

- Pod scheduling respects data locality, eliminating cross-zone storage latency
- Volume expansion can be done without downtime
- Accidental PVC deletion does not destroy data
- Consistent storage configuration across development and production

### ⚠️ What becomes harder

- `Retain` policy requires manual cleanup of orphaned PVs after intentional decommission (mitigated by runbook)
- `WaitForFirstConsumer` means PVCs remain `Pending` until a pod is scheduled, which can initially confuse operators (mitigated by documentation)
- Storage provisioner differences between `kind` (local-path) and production (cloud CSI) mean some behavior cannot be fully tested locally

### 📝 Benchmark Results

Storage benchmarks have been completed and validate the chosen StorageClass configuration. Full results with methodology, raw data, and t-shirt size recommendations are available in [fio-storage-results.md](../benchmarks/fio-storage-results.md).

Key findings:
- gp3 baseline (3,000 IOPS) meets requirements for S/M workloads
- gp3 provisioned (10,000 IOPS) required for L workloads with sub-millisecond fsync
- All journal fsync latency targets met across configurations

### 📝 Open items

- Cloud-specific provisioner parameters to be documented per target environment
