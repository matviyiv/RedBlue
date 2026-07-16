# Blue Zone Flow

How a project's files move through the blue-zone pipeline — from the repo on the
host, through the filtered staging copy, into Claude's container, and back. The
folder set and exclusion rules come entirely from
[`blue-zone.config.sh`](../blue-zone.config.sh); every stage below reads from it,
so nothing hardcodes `src/ios/android`.

```mermaid
flowchart TD
    cfg["blue-zone.config.sh<br/>BLUE_ZONE_FOLDERS + exclusion rules<br/><i>single source of truth</i>"]

    subgraph host["Host — your repo"]
        blue["Blue-zone folders<br/>(e.g. src/ ios/ android/)"]
        red["Red zone<br/>.env*, *-api.ts, *.p12, *.jks,<br/>Pods/, build/, keystores…"]
    end

    subgraph stage["Host — /tmp/blue-zone (staging, git-ignored)"]
        staged["Filtered per-folder copies"]
        snap[".blue-zone-snapshot<br/>(what Claude was allowed to see)"]
        overlay["docker-compose.blue-zone.yml<br/>(generated per-folder mounts)"]
    end

    subgraph container["Claude Code container — /workspace"]
        ws["Mounted folders (writable)<br/>Claude reads & edits here"]
    end

    cfg -.->|reads| prep
    cfg -.->|reads| val
    cfg -.->|reads| sync

    blue -->|"prepare-blue-zone.sh<br/>rsync with --exclude"| prep((prepare))
    red -.->|stripped, never staged| xred(["✗ blocked"])
    prep --> staged
    prep --> snap
    prep --> overlay

    staged -->|"validate-blue-zone.sh<br/>secret + exclusion scan"| val{validate<br/>clean?}
    val -->|no| stop(["✗ abort — leak found"])
    val -->|yes| mount

    overlay -->|"COMPOSE_FILE overlay"| mount[["docker compose<br/>mount folders"]]
    mount --> ws

    ws -->|"session ends"| sync((sync-back))
    snap -.->|"guards updates & deletes"| sync
    sync -->|"updated / added / deleted"| blue
    sync -->|"collides with red-zone path"| xblock(["✗ blocked, left untouched"])

    classDef danger fill:#fee,stroke:#c00,color:#900;
    classDef safe fill:#efe,stroke:#0a0,color:#060;
    classDef cfgcls fill:#eef,stroke:#33c,color:#229;
    class red,xred,stop,xblock danger;
    class blue,staged,ws safe;
    class cfg cfgcls;
```

## Stages

| Stage | Script | What happens |
|-------|--------|--------------|
| **Configure** | `blue-zone.config.sh` | Declares `BLUE_ZONE_FOLDERS` and the common + per-folder exclusion rules. The only file you edit to adapt to a project. |
| **Prepare** | `prepare-blue-zone.sh` | `rsync`s each configured folder into `/tmp/blue-zone/`, stripping red-zone files. Writes the snapshot and generates the docker-compose mount overlay. |
| **Validate** | `validate-blue-zone.sh` | Confirms every configured exclusion held and scans for hardcoded secrets. A leak aborts the run before anything is mounted. |
| **Mount & run** | `start-cli.sh` / `run-headless.sh` | Layers the generated overlay onto `docker-compose.yml` via `COMPOSE_FILE` and starts Claude Code with only the blue-zone folders mounted (writable). |
| **Sync back** | `sync-back.sh` | Copies Claude's changes into the repo. The snapshot lets it update/delete only files Claude was allowed to see; a new file whose path collides with a stripped red-zone file is blocked. |

Red-zone files are never staged, never mounted, and never overwritten by
sync-back — they stay in the repo untouched throughout.
