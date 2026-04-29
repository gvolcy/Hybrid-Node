# Mithril & DMQ Scripts

Template scripts for Mithril signer and DMQ node deployment on Cardano nodes.

## Scripts

### `autostart-signer.sh`
Basic Mithril signer autostart script (no DMQ). Used for nodes that only need standard Mithril signing (e.g., preview-silem).

- Downloads stable Mithril signer binary (v2617.0) if not present
- Manages signer process lifecycle with PID file tracking
- Requires `mithril.env` in the same directory for configuration

### `autostart-signer-dmq.sh`
Mithril signer autostart with DMQ (Decentralized Message Queue) support. Used for nodes that participate in DMQ (e.g., preview-volcy).

- Same signer management as `autostart-signer.sh`
- Additionally starts the DMQ node via `dmq-setup.sh`
- Waits for DMQ socket readiness before starting the signer
- Requires `DMQ_NODE_SOCKET_PATH` set in `mithril.env`

### `dmq-setup.sh`
DMQ node v0.4.2.0 setup and autostart script.

- Downloads DMQ node binary from IntersectMBO/dmq-node releases
- Generates trace-dispatcher config and topology automatically
- Preview network defaults: cardano-magic=2, dmq-magic=2147483650
- Peer: 34.76.22.193:6161

## Usage

1. Copy the appropriate script(s) to your node
2. Create/edit `mithril.env` with your pool's configuration
3. Set the script as executable and add to cron or systemd
4. For DMQ: copy both `autostart-signer-dmq.sh` and `dmq-setup.sh`

## Version Reference

| Component       | Version  | Tag/Commit |
|----------------|----------|------------|
| Mithril Signer | 2617.0   | 2478748    |
| DMQ Node       | 0.4.2.0  | latest     |
