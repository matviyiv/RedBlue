# Local Dev Setup Flow

What a new developer does on their own machine to get the blue-zone Claude Code
environment running for the first time. One-time setup is `./scripts/init.sh`;
after that, day-to-day use is a single `start-cli.sh` / `run-headless.sh` call.

```mermaid
flowchart TD
    start(["New developer on local machine"]) --> prereq

    subgraph oneoff["One-time setup"]
        prereq{"Prerequisites installed?<br/>docker · docker compose · rsync<br/>(jq optional)"}
        prereq -->|no| install["Install missing tools<br/>e.g. brew install rsync jq"]
        install --> prereq
        prereq -->|yes| clone["Clone the repo<br/>+ copy claude-docker/ setup in"]
        clone --> init["./scripts/init.sh"]

        init --> i_prereq["Verify prerequisites"]
        i_prereq --> i_auth["Resolve auth (see below)"]
        i_auth --> i_perm["chmod +x scripts/*.sh"]
        i_perm --> i_env["Create .env.example if missing"]
        i_env --> i_folders["Check folders from<br/>blue-zone.config.sh"]
        i_folders --> i_build["docker compose build claude-code"]
    end

    i_build --> authq{"How to authenticate?"}

    subgraph auth["Authentication — pick one"]
        authq -->|Pro/Max subscription| a2["claude setup-token →<br/>export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat…"]
        authq -->|No token| a3["Skip — log in with /login<br/>inside the first session"]
    end

    a2 --> cfg
    a3 --> cfg

    cfg{"Project layout matches<br/>default src/ ios/ android/?"}
    cfg -->|no| edit["Edit blue-zone.config.sh<br/>BLUE_ZONE_FOLDERS=(…)"]
    cfg -->|yes| choose
    edit --> choose

    choose{"How to run?"}
    choose -->|Interactive| cli["./scripts/start-cli.sh"]
    choose -->|Headless / CI| hl["./scripts/run-headless.sh \"<prompt>\""]

    cli --> login{"Logged in?"}
    login -->|no| dologin["/login inside session<br/>→ saved to claude-home volume"]
    login -->|yes| session
    dologin --> session

    hl --> session
    session(["Claude Code runs on the blue zone<br/>changes synced back on exit"])
    session -.->|"state persists in claude-home volume"| choose

    classDef step fill:#eef,stroke:#33c,color:#229;
    classDef done fill:#efe,stroke:#0a0,color:#060;
    classDef decision fill:#ffe,stroke:#cc0,color:#770;
    class init,i_prereq,i_auth,i_perm,i_env,i_folders,i_build,a2,a3,edit,cli,hl,dologin,clone,install step;
    class start,session done;
    class prereq,authq,cfg,choose,login decision;
```

## Steps

| # | Step | Command / file | Notes |
|---|------|----------------|-------|
| 1 | **Install prerequisites** | `docker`, `docker compose`, `rsync`; `jq` optional | `init.sh` checks these and stops if a required one is missing. |
| 2 | **Get the setup** | clone the repo with the `claude-docker/` scripts | The scripts, `blue-zone.config.sh` and compose files live alongside your project. |
| 3 | **Run init** | `./scripts/init.sh` | Verifies tools, resolves auth, marks scripts executable, seeds `.env.example`, lists the configured blue-zone folders, and builds the image. |
| 4 | **Authenticate** | subscription token **or** `/login` | A token is optional — with none, just start a session and log in on the spot. |
| 5 | **Adapt to your project** (optional) | `blue-zone.config.sh` → `BLUE_ZONE_FOLDERS` | Only if your top-level folders differ from `src/ios/android`. See [blue-zone-flow.md](blue-zone-flow.md). |
| 6 | **Run a session** | `./scripts/start-cli.sh` or `./scripts/run-headless.sh "…"` | Each run prepares + validates the blue zone, mounts it, and syncs changes back on exit. |

## Auth & state persist after the first run

The container's home directory lives in the `claude-home` Docker volume, so
login credentials, onboarding answers, and session history **survive between
runs** — you go through login and Claude's setup exactly once. Later interactive
*and* headless runs reuse it. Wipe it with `./scripts/start-cli.sh --clear`.
