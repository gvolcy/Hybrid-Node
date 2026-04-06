# Monitoring

## Overview

Hybrid-Node nodes expose Prometheus metrics on port 12798 by default. This directory
contains ready-to-use monitoring configurations.

## Components

```
monitoring/
├── prometheus/
│   └── cardano-targets.yml    # Scrape targets for all nodes
├── grafana/
│   └── hybrid-node.json       # Grafana dashboard
└── alerts/
    └── cardano-alerts.yml     # Prometheus alerting rules
```

## Quick Setup

### 1. Add scrape targets to your Prometheus config

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'cardano-nodes'
    file_sd_configs:
      - files:
          - 'cardano-targets.yml'
    scrape_interval: 15s
```

### 2. Add alert rules

```yaml
# prometheus.yml
rule_files:
  - 'cardano-alerts.yml'
```

### 3. Import Grafana dashboard

Import `grafana/hybrid-node.json` via Grafana UI → Dashboards → Import.

## Key Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `cardano_node_metrics_blockNum_int` | Gauge | Current block number |
| `cardano_node_metrics_slotNum_int` | Gauge | Current slot number |
| `cardano_node_metrics_epoch_int` | Gauge | Current epoch |
| `cardano_node_metrics_density_real` | Gauge | Chain density |
| `cardano_node_metrics_mempoolBytes_int` | Gauge | Mempool size in bytes |
| `cardano_node_metrics_txsInMempool_int` | Gauge | Transactions in mempool |
| `cardano_node_net_peers_hot` | Gauge | Hot peer connections |
| `cardano_node_net_peers_warm` | Gauge | Warm peer connections |
| `cardano_node_metrics_remainingKESPeriods_int` | Gauge | KES periods remaining |
| `cardano_node_metrics_Forge_node_is_leader_int` | Counter | Slots where node was leader |
| `cardano_node_metrics_Forge_adopted_int` | Counter | Blocks adopted |
| `cardano_node_metrics_Forge_didnt_adopt_int` | Counter | Blocks not adopted |

## Midnight Metrics

Midnight nodes expose Substrate metrics on port 9615:

| Metric | Description |
|--------|-------------|
| `substrate_block_height` | Current block height |
| `substrate_number_leaves` | Number of chain leaves |
| `substrate_ready_transactions_number` | Pending transactions |
