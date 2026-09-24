# windows-selfhost-kit

Host a **Java Spring Boot (Maven)** app on your own **Windows PC** and put it on the internet
with a real HTTPS address. There is no cloud server and no router or port-forwarding setup.
Every `git push` is tested by GitHub, then deployed to your PC automatically.

This tutorial is written so that a **beginner** can follow it, and so that you can hand it to an
**AI agent** (Claude Code, Copilot, Cursor, ...) to do most of the work for you. Steps that only
you can do (logging in, clicking "Yes", typing passwords) are marked **[HUMAN]**. Everything
else is marked **[AGENT]**: an AI agent can run it, or you can.

---

## 0. What you get

```text
  Internet (anyone)                          GitHub
        |                                      |  git push
        | https://myapp.your-tailnet.ts.net    v
        v                                   "test" job (GitHub's servers: ./mvnw verify)
  Tailscale Funnel (HTTPS, port 443)           |
        |                                      v
+-------|---------------- your Windows PC -----|-----------------------------------+
| WSL2 (Ubuntu Linux) with Docker Engine       |                                   |
|                                              v                                   |
|   +------ stack "myapp" ------------+   GitHub runner (runs "redeploy" job):    |
|   | myapp-ts   Tailscale sidecar    |   git reset to the tested commit,          |
|   | myapp      your Spring Boot app |<- rebuild ONLY the app container,         |
|   +---------------+-----------------+   check /actuator/health, roll back       |
|                   | private tailnet (WireGuard, 100.x addresses)                  |
|   +---------------v-----------------+                                            |
|   | myapp-db-ts + myapp-db Postgres |   (never on the public internet)           |
|   +---------------------------------+                                            |
+----------------------------------------------------------------------------------+
```

- **WSL2** runs a real Ubuntu Linux inside Windows. Docker and everything else runs there.
- **Tailscale** gives each "stack" (app, database) its own private address on your *tailnet*, which
  is your private network. **Funnel** publishes the app to the internet over HTTPS, with a certificate.
- **GitHub Actions** tests every push on GitHub's servers, then a **self-hosted runner** on your PC
  deploys it. Only the app container is rebuilt. The Tailscale sidecar keeps running, so your
  URL never changes.
- Secrets (the Tailscale key, database password) live only in `.env` files on your PC.

**What it is not:** a 24/7 server. When your PC sleeps or is off, the site is offline. Pushes made
in the meantime wait in GitHub and deploy when the PC is back. A job that waits more than 24 hours
is cancelled; re-run it from the Actions tab.

### Quick path (the whole tutorial on one screen)

1. Part A: put the kit in `%USERPROFILE%\windows-selfhost-kit` and fill in `kit.env`. Run `setup-windows.ps1`
   `Check`, then `Install`, install Ubuntu, `Stage`, `bootstrap.sh`, `Configure`.
2. Part B: log in to GitHub inside Ubuntu (`gh auth login`), create a Tailscale account, turn on
   HTTPS and Funnel, and generate an auth key.
3. Part C: database stack. Run `apply-template.sh --db`, paste the secrets, run `scripts/up.sh`.
4. Part D: run `apply-template.sh --project`, add the pom.xml bits, then commit and push from Windows.
5. Part E: clone the repo to `~/apps/<repo>`, paste the secrets, run `scripts/up.sh --build`. Your app is online.
6. Part F: `register-runner.sh` connects GitHub to your PC. From now on every push deploys itself.

---

## 1. Your settings: kit.env

All choices live in one file, `kit.env`, in the kit folder. Copy `kit.env.example` to `kit.env`
and change the values. This is what `kit.env.example` contains:

<!-- VARS:BEGIN -->
```ini
# windows-selfhost-kit settings.
# Copy this file to kit.env (same folder) and fill in the values BEFORE running
# "setup-windows.ps1 -Phase Stage". Plain KEY=VALUE lines only: no quotes, no spaces
# around "=", no ${...}. Nothing in this file is secret.

# Your GitHub user (or org) name and the name of the private repo of your Spring Boot app.
GITHUB_OWNER=your-github-username
REPO=your-spring-boot-repo

# Public name of the service. Lowercase letters, digits and "-" only (max 63 chars).
# It becomes the Tailscale machine name and the public URL:
#   https://<SERVICE_NAME>.<your-tailnet>.ts.net
# Note: HTTPS certificate names are published in public Certificate Transparency logs.
SERVICE_NAME=myapp

# Folder of your project on Windows (the one that contains pom.xml).
WIN_PROJECT_DIR=C:\Users\you\IdeaProjects\your-spring-boot-repo

# Port your Spring Boot app listens on inside the container (server.port).
APP_PORT=8080

# Java version used to build and run the app (must be >= <java.version> in pom.xml).
JAVA_VERSION=21

# Branch whose pushes get deployed.
BRANCH=main

# WSL2 distribution name (as shown by "wsl -l -v").
DISTRO=Ubuntu-24.04

# yes = also run a private Postgres database (tailnet-only) for this app.
WITH_DB=yes
# Name of the database stack. Empty = <SERVICE_NAME>-db
DB_SERVICE_NAME=

# yes = add service-to-service mutual TLS (advanced, Part G of the README).
WITH_MTLS=no

# ---- advanced (the defaults are fine) ----
RUNNER_LABEL=wsl
HEALTH_PATH=/actuator/health
MTLS_PORT=8443
```
<!-- VARS:END -->

In the commands below, `$REPO`, `$SERVICE_NAME`, `$DB_SERVICE_NAME`, `$GITHUB_OWNER` and `$KIT` are
filled in automatically inside Ubuntu (from `kit.env`). In **PowerShell** commands, replace
`<GITHUB_OWNER>`, `<REPO>` etc. with your values.

---

## 2. Rules for AI agents

Read this before running anything.

1. **Tags.** Only run **[AGENT]** steps. At a **[HUMAN]** step, stop, tell the human exactly what to
   do (copy the step), and wait until they confirm it's done. Then run that step's **Verify**.
2. **Secrets.** Never ask the human to paste a secret into the chat.
   - Never read, `cat`, `grep` or print any `.env` file, and never run `gh auth token`.
   - Never run unfiltered `docker inspect <name>-ts` or `docker compose config`: both print `TS_AUTHKEY`.
   - To check `.env`, use `scripts/env.sh check`, which prints only set, EMPTY or MISSING.
   - Non-secret values are set with `scripts/env.sh set KEY VALUE`. Secrets are pasted by the human
     with `scripts/env.sh secret KEY`, which hides the input.
3. **Where commands run.** Commands in `powershell` blocks run in Windows PowerShell, in the kit folder
   (`cd $env:USERPROFILE\windows-selfhost-kit`). Commands in `bash` blocks run inside Ubuntu (WSL2).
   If you are an agent working in PowerShell, run each bash command through the helper, in single quotes:
   ```powershell
   .\windows\wsl-run.ps1 'cd ~/apps/$REPO && scripts/status.sh'
   .\windows\wsl-run.ps1 -Root '$KIT/wsl/bootstrap.sh --user $KIT_USER'   # as root, no password prompt
   ```
   Don't use `wsl -- bash -c "..."` yourself: PowerShell quoting breaks it in subtle ways.
4. **Verify every step** with its **Verify** command before moving on. If it fails, look up the error in
   **Part I: Troubleshooting**, try the fix **once**, then stop and ask the human.
5. **One command to check everything:** `~/selfhost-kit/wsl/doctor.sh` prints PASS, WARN or FAIL for every
   part of the setup, each with a fix.
6. Never run `docker compose down -v`, `wsl --unregister` or `scripts/down.sh -v`: they delete data
   and identities. Ask the human first.

---

## 3. Before you start

You need:

- **Windows 11**, or **Windows 10 22H2**, with **administrator rights** (you will click "Yes" on a few prompts).
- **Virtualization enabled.** Task Manager -> Performance -> CPU -> "Virtualization: Enabled". If it says
  Disabled, enable Intel VT-x or AMD SVM in the BIOS/UEFI setup first.
- **20 GB free** on C:.
- **Git for Windows.** In PowerShell: `winget install --id Git.Git -e`, then open a new PowerShell window.
- A **Spring Boot project that uses Maven**, with the Maven wrapper (`mvnw`, `.mvn/`) committed. Projects
  made with https://start.spring.io have it.
- A **GitHub account**. The project must be (or become) a **private** repo.
- Nothing else: Docker, Java and Tailscale are installed by the kit inside WSL2. Do **not** install
  Docker Desktop. If you already have it, turn off its WSL integration for Ubuntu-24.04.

---

## Part A: Windows and WSL2

### A1. Put the kit in place and fill in kit.env  [HUMAN]

1. Put the kit folder at `%USERPROFILE%\windows-selfhost-kit`, e.g. `C:\Users\you\windows-selfhost-kit`.
   If you received the single file `windows-selfhost-kit.md`, follow "How to use this file" at its top.
2. Open PowerShell (Start menu -> "PowerShell") and run:

   ```powershell
   cd $env:USERPROFILE\windows-selfhost-kit
   Get-ChildItem -Recurse | Unblock-File
   Copy-Item kit.env.example kit.env
   notepad kit.env
   ```
3. Fill in `GITHUB_OWNER`, `REPO`, `SERVICE_NAME`, `WIN_PROJECT_DIR`. Keep the rest unless you know you need
   something else, e.g. `JAVA_VERSION=17` or `WITH_DB=no`. Save and close Notepad.

**Verify:** `Test-Path .\kit.env` prints `True`.

### A2. Check the PC  [AGENT]

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Check
```

**Verify:** no `[FAIL]` lines. `[WARN]` about WSL or Ubuntu not being installed is expected at this point.
**If it fails:** "CPU virtualization is OFF" means BIOS/UEFI (Part I). Old Windows means run Windows Update.

### A3. Install WSL2  [HUMAN: click "Yes"; maybe restart]

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Install
```

Windows asks for administrator rights: click **Yes**. If the output says **REBOOT REQUIRED**, restart
Windows and run the same command again. It is safe to repeat.

**Verify:** `wsl --version` shows `WSL version: 2.x...`, and `wsl --status` shows `Default Version: 2`.

### A4. Install Ubuntu  [HUMAN]

In PowerShell (a normal window, not "as administrator"):

```powershell
wsl --install -d Ubuntu-24.04
```

An Ubuntu window opens and asks you to create a **Linux user**. Choose a short lowercase name, e.g. `anna`,
and a password. **Remember the password**: it's your `sudo` password inside Ubuntu. When you see a prompt
like `anna@PC:~$`, type `exit`.

**Verify:** `wsl -l -v` lists `Ubuntu-24.04` with **VERSION 2**.
**If it shows VERSION 1:** `wsl --set-version Ubuntu-24.04 2`. WSL1 cannot run Docker.

### A5. Copy the kit into Ubuntu  [AGENT]

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Stage
```

This copies the kit to `~/selfhost-kit` inside Ubuntu, and fixes Windows line endings. **Run it again
whenever you change `kit.env` or the kit files on Windows.**

**Verify:** the output ends with `[PASS] kit.env: SERVICE_NAME=... REPO=...` and `[PASS] Kit staged.`

### A6. Install Docker, GitHub CLI and tools in Ubuntu  [AGENT]

```powershell
.\windows\wsl-run.ps1 -Root '$KIT/wsl/bootstrap.sh --user $KIT_USER'
```

- If it **exits with code 2** ("systemd is not running yet"): run `wsl --shutdown`, then the same command again.
- At the end it asks you to run `wsl --terminate Ubuntu-24.04`, so your user's new Docker permission takes
  effect. Do that.
- Human alternative: open Ubuntu (Start menu -> "Ubuntu 24.04") and run `sudo ~/selfhost-kit/wsl/bootstrap.sh`.

**Verify:**
```powershell
.\windows\wsl-run.ps1 'docker run --rm hello-world | grep "Hello from Docker"; ps -p 1 -o comm=; test -c /dev/net/tun && echo tun-ok'
```
It prints `Hello from Docker!`, `systemd` and `tun-ok`.

### A7. Keep WSL2 running and start everything at logon  [HUMAN: click "Yes" once]

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Configure
wsl --shutdown
```

This does three things:
- It writes two settings to `%USERPROFILE%\.wslconfig`, so WSL2 doesn't shut down when no window is open.
- It creates a logon task that starts all your stacks about 20 seconds after you log in to Windows.
  This asks for "Yes" once. If you can't give admin rights, add `-UseStartupFolder`.
- It creates three Desktop shortcuts: **Start SelfHost**, **SelfHost Status** and **Stop SelfHost**.

`wsl --shutdown` restarts WSL so the settings apply. It is fine to run now: nothing is hosted yet.

**Verify:** the three Desktop shortcuts exist, and
`Get-ScheduledTask -TaskName 'SelfHostKit-WSL-*' | Select-Object TaskName, State` shows `Ready`.
If you used `-UseStartupFolder`, check for `SelfHost autostart.lnk` in `shell:startup` instead.

---

## Part B: Accounts (GitHub and Tailscale)

### B1. Your project on GitHub, private  [HUMAN]

If your project is already a **private** GitHub repo, skip to B2. Otherwise:

1. On https://github.com/new create a repository named like `REPO` in kit.env. Choose **Private**, and
   do **not** add a README, .gitignore or license.
2. In PowerShell, in your project folder (`WIN_PROJECT_DIR`):
   ```powershell
   git init -b main          # only if it isn't a git repo yet
   git add -A
   git commit -m "Initial commit"
   git remote add origin https://github.com/<GITHUB_OWNER>/<REPO>.git
   git push -u origin main
   ```
   A browser window asks you to log in to GitHub the first time.

**Why private:** a self-hosted runner executes code from the repo on your PC. On a public repo, strangers
could make it run their code through pull requests. The kit refuses to register a runner on a public repo.

### B2. Log in to GitHub inside Ubuntu  [HUMAN]

Open **Ubuntu** (Start menu -> "Ubuntu 24.04") and run:

```bash
gh auth login -h github.com -p https -w -s workflow
gh auth setup-git
```

It shows a one-time code like `ABCD-1234`. Open https://github.com/login/device in your browser, enter the
code and approve. The `workflow` permission lets you push workflow files; the runner setup needs your login too.

**Verify [AGENT]:**
```powershell
.\windows\wsl-run.ps1 'gh auth status && gh repo view $GITHUB_OWNER/$REPO --json visibility -q .visibility'
```
It shows `Logged in to github.com` and `PRIVATE`.

### B3. Tailscale account and settings  [HUMAN]

1. **Sign up:** https://login.tailscale.com/start. Sign in with Google, Microsoft or GitHub. The free
   Personal plan is enough. This creates your **tailnet**. If the welcome screen asks you to add a device,
   you may install Tailscale on your phone or skip it: the kit adds its own machines.
2. **(Optional) Rename your tailnet**, before step 3. Go to https://login.tailscale.com/admin/dns, then
   "Tailnet DNS name" -> "Rename tailnet...", and pick a name you like. Your public URLs will be
   `https://<SERVICE_NAME>.<tailnet-name>.ts.net`. Renaming later changes them.
3. **Turn on HTTPS.** On the same **DNS** page, make sure **MagicDNS** is enabled. Then under
   **HTTPS Certificates** click **Enable HTTPS** and confirm.
4. **Allow Funnel** (public access). Go to **Access controls** (https://login.tailscale.com/admin/acls).
   If you see a Funnel banner or section, click **Add Funnel to policy**. If not, open the JSON editor
   and make sure this is present, then **Save**:
   ```json
   "nodeAttrs": [
     { "target": ["autogroup:member"], "attr": ["funnel"] }
   ]
   ```
5. **Create an auth key.** Go to **Settings -> Keys** (https://login.tailscale.com/admin/settings/keys)
   -> **Generate auth key...**:
   - Description: `selfhost` (anything)
   - **Reusable: ON**. Each stack (database, app) logs in once with it.
   - Expiration: 90 days (the maximum). Only *new* stacks need a valid key; running ones stay logged in.
   - **Ephemeral: OFF**, otherwise machines vanish when they stop.
   - **Tags: none**. Tagged machines don't get the Funnel permission from step 4.

   Click **Generate** and **copy the key**: it starts with `tskey-auth-` and is shown **only once**. Keep it
   in a password manager or a private note until you've finished Part E.

**Verify:** nothing to run yet. `scripts/up.sh` checks HTTPS, Funnel and the key in Parts C and E, and tells
you exactly what to fix.

---

## Part C: Database (optional, `WITH_DB=yes`)

Skip this part if your app has no database (`WITH_DB=no`).

### C1. Create the database stack  [AGENT]

```powershell
.\windows\wsl-run.ps1 '$KIT/wsl/apply-template.sh --db'
```

**Verify:** it prints `[PASS] Database stack ready in /home/<you>/apps/<SERVICE_NAME>-db`.

### C2. Paste the secrets  [HUMAN]

In **Ubuntu**:

```bash
cd ~/apps/$DB_SERVICE_NAME
scripts/env.sh secret TS_AUTHKEY                     # paste the tskey-auth-... key, press Enter
scripts/env.sh secret POSTGRES_PASSWORD --generate   # creates a strong random password
```

Pasting in the Ubuntu window: right-click, or Ctrl+Shift+V. Nothing appears while you paste; that is on purpose.

**Verify [AGENT]:** `.\windows\wsl-run.ps1 'cd ~/apps/$DB_SERVICE_NAME && scripts/env.sh check'` ends with
`All required keys are set.`

### C3. Start it  [AGENT]

```powershell
.\windows\wsl-run.ps1 'cd ~/apps/$DB_SERVICE_NAME && scripts/up.sh'
```

**Verify:** `[PASS] Postgres is accepting connections`, and a line `Tailnet IP: 100.x.y.z`. **Note that IP**:
the app needs it in Part E (`DB_HOST`).
Extra check: `.\windows\wsl-run.ps1 'cd ~/apps/$DB_SERVICE_NAME && scripts/psql.sh -c "select version()"'`.

From Windows, database tools such as IntelliJ or DBeaver can connect to `localhost:5432`. Database and user:
`app`. Password: in `~/apps/<SERVICE_NAME>-db/.env`, which you can open yourself in Explorer at
`\\wsl$\Ubuntu-24.04\home\<you>\apps\`.

### C4. Turn off key expiry for the database machine  [HUMAN]

Go to https://login.tailscale.com/admin/machines, find the machine named `<SERVICE_NAME>-db`, open the
**...** menu and choose **Disable key expiry**. Without this, it is logged out after 180 days.

**Verify [AGENT]:** `.\windows\wsl-run.ps1 'cd ~/apps/$DB_SERVICE_NAME && scripts/status.sh'` shows
`key expiry:  disabled (good)`.

---

## Part D: Add the kit to your project

### D1. Add the files  [AGENT]

```powershell
.\windows\wsl-run.ps1 '$KIT/wsl/apply-template.sh --project'
```

This writes into your Windows project folder (`WIN_PROJECT_DIR`):

| File | Purpose |
|---|---|
| `Dockerfile` | builds the jar with `./mvnw`, runs it on a small Java runtime as a non-root user |
| `docker-compose.yml` | the Tailscale sidecar + your app (+ database settings) |
| `ts-serve.json` | Funnel: public HTTPS on port 443 -> your app |
| `.github/workflows/deploy.yml` | CI/CD: test on GitHub, deploy on your PC, health check, roll back |
| `scripts/*.sh` | `up`, `status`, `down`, `deploy`, `healthcheck`, `env` |
| `.env.example` | template for the secret `.env` (the real `.env` is never committed) |
| `.gitattributes`, `.gitignore`, `.dockerignore` | line endings, keep secrets out of git and images |
| `src/test/java/.../SelfhostTestcontainersConfiguration.java` | a throwaway Postgres for tests in CI (if needed) |

It never overwrites your own files. It warns instead; add `--force` to replace them and keep a `.bak`.

**Verify:** it ends with `[PASS] Template applied to ...`.

### D2. Finish the "Still to do" list  [AGENT]

`apply-template.sh` prints a list at the end. Usually:

- **pom.xml**: add `spring-boot-starter-actuator`. It is required: deploys check `/actuator/health`.
  Add the Postgres and Testcontainers test dependencies if listed. Copy them from
  `project-template/spring/pom-snippets.xml`: section 3a for Spring Boot 4, 3b for Spring Boot 3.
- **The test class** annotated with `@SpringBootTest`: add `@Import(SelfhostTestcontainersConfiguration.class)`.
  The CI tests then get a real, temporary Postgres, so `contextLoads` works.

Nothing in `application.properties` needs to change. The container sets the port (`SERVER_PORT`) and the
database URL, user and password (`SPRING_DATASOURCE_*`) through environment variables.

**Verify (optional, builds the image once):**
```powershell
.\windows\wsl-run.ps1 'cd "$(wslpath -a "$WIN_PROJECT_DIR")" && docker build -t selfhost-test . && echo BUILD-OK'
```

### D3. Commit and push  [AGENT]

In PowerShell, in your project folder:

```powershell
git add --renormalize .
git add --chmod=+x mvnw scripts/*.sh
git add -A
git status
git commit -m "Add self-hosting (windows-selfhost-kit)"
git push
```

In `git status`, `.env` and anything under `certs/` must **not** be listed.

**Verify:**
- `git ls-files -s mvnw scripts/up.sh` shows mode `100755` for both.
- `git ls-files --eol mvnw` shows `i/lf`.
- On GitHub -> **Actions** -> **local-redeploy**: job **test** is green.

Job **redeploy** will show *Waiting for a runner*. **That is expected** until Part F.
**If test fails:** open the job log. The usual causes are a missing Testcontainers setup (Part I, "contextLoads")
or `mvnw` permission (Part I).

---

## Part E: First start on your PC

Your PC deploys from its **own copy** of the repo, `~/apps/<REPO>` inside Ubuntu (fast Linux disk).
You keep coding in your Windows folder as usual. **Never edit files in `~/apps/<REPO>`** except `.env`
and `certs/`: the deploy job resets that folder to the pushed commit.

### E1. Clone the deploy copy  [AGENT]

```powershell
.\windows\wsl-run.ps1 'mkdir -p ~/apps && gh repo clone $GITHUB_OWNER/$REPO ~/apps/$REPO -- --branch $BRANCH && ls ~/apps/$REPO/scripts'
```

**Verify:** the list shows `up.sh`, `deploy.sh`, `env.sh`, ...

### E2. Settings and secrets  [AGENT, then HUMAN]

**[AGENT]** non-secret settings. Use the database IP from C3:

```powershell
.\windows\wsl-run.ps1 'cd ~/apps/$REPO && scripts/env.sh set APP_UID $(id -u) && scripts/env.sh set DB_HOST 100.x.y.z'
```

**[HUMAN]** secrets, in **Ubuntu**:

```bash
cd ~/apps/$REPO
scripts/env.sh secret TS_AUTHKEY                                          # the same tskey-auth-... key
scripts/env.sh secret POSTGRES_PASSWORD --from ~/apps/$DB_SERVICE_NAME/.env  # copies it, never shown
```

**Verify [AGENT]:** `.\windows\wsl-run.ps1 'cd ~/apps/$REPO && scripts/env.sh check'` ends with `All required keys are set.`

### E3. Start the app  [AGENT]

```powershell
.\windows\wsl-run.ps1 'cd ~/apps/$REPO && scripts/up.sh --build'
```

The first build downloads Java and Maven dependencies (3-10 minutes).

**Verify:** exit code `0`, `[PASS] Health: UP`, and a line `Public URL: https://<SERVICE_NAME>.<tailnet>.ts.net`.
- **Exit code 2** means the app runs, but HTTPS or Funnel is not enabled. The output says exactly which
  setting (Part B3) to change. Then run the same command again.
- **Exit code 1**: read the message and see Part I.

### E4. Turn off key expiry for the app machine  [HUMAN]

As in C4, for the machine named `<SERVICE_NAME>`.

### E5. Open it from the internet  [HUMAN]

On your phone, turn **Wi-Fi off** (so you are really coming from the internet) and open
`https://<SERVICE_NAME>.<tailnet>.ts.net/actuator/health`. You should see `{"status":"UP"}`.
**The very first time it can take up to ~10 minutes** (DNS and certificate). An agent can check with:
`.\windows\wsl-run.ps1 'cd ~/apps/$REPO && scripts/healthcheck.sh --public'`.

---

## Part F: Automatic deploys (CI/CD)

### F1. Connect your PC to GitHub as a runner  [AGENT]

```powershell
.\windows\wsl-run.ps1 -Root '$KIT/wsl/register-runner.sh --user $KIT_USER'
```

It checks that the repo is private and that you are an admin, downloads the official runner (checksum
verified), registers it with the label `wsl`, and installs it as a service that starts with WSL.

**Verify:** `[PASS] GitHub sees runner '<pc>-<REPO>' as online.` Also, on GitHub -> Settings -> Actions ->
Runners it shows **Idle**. The job waiting since D3 now starts by itself.

### F2. Watch a full deploy  [AGENT]

```powershell
.\windows\wsl-run.ps1 'gh workflow run local-redeploy -R $GITHUB_OWNER/$REPO; sleep 5; gh run list -R $GITHUB_OWNER/$REPO -w local-redeploy -L 3'
.\windows\wsl-run.ps1 'gh run watch -R $GITHUB_OWNER/$REPO --exit-status $(gh run list -R $GITHUB_OWNER/$REPO -w local-redeploy -L 1 --json databaseId -q ".[0].databaseId")'
```

**Verify:** both jobs, `test` and `redeploy`, are green. Also:
`.\windows\wsl-run.ps1 'git -C ~/apps/$REPO log -1 --oneline'` shows the newest commit.

### F3. Try it  [HUMAN or AGENT]

Change something small in your app, then commit and push from Windows. About 3-6 minutes later the new
version is live. Each deploy does these steps:
1. Tests on GitHub.
2. Moves `~/apps/<REPO>` to exactly that commit.
3. Rebuilds and restarts **only** the app.
4. Checks `/actuator/health`.
5. If the health check fails, puts the previous version back automatically and marks the run red.

---

## Part G: Service-to-service mTLS (optional, advanced)

Use this when **two or more of your own services** call each other, and you want each call to prove which
service it comes from. Every service is set up with this kit (own repo, own stack). They can run on the
same PC or on different PCs in the same tailnet.

Why a second port: Funnel handles HTTPS for the public and cannot pass client certificates through. So each
service keeps its public port (e.g. 8080, via Funnel) and gets a second, **tailnet-only** HTTPS port `8443`
that requires a certificate from **your own certificate authority (CA)**. Paths under `/internal/` answer only
on 8443; the public port returns 404 for them.

Example: `orders` calls `billing`.

1. **[AGENT] Enable mTLS in each project.** Set `WITH_MTLS=yes` in that service's kit env file. For a
   second app, see H6. Stage again, then re-run `apply-template.sh --project --force`. That adds
   `selfhost/MtlsConfig.java`, `selfhost/MtlsAllowlistFilter.java`, `application-mtls.properties` and the
   compose lines. Spring Boot 4 also needs `spring-boot-starter-restclient` (pom-snippets section 4).
   Commit and push.
2. **[AGENT] Create the CA and certificates** (once, for all services):
   ```bash
   $KIT/mtls/gen-certs.sh orders billing
   ```
3. **[HUMAN] Back up `ca.key`.** Copy `\\wsl$\Ubuntu-24.04\home\<you>\selfhost-ca\ca.key` to a USB stick or
   password manager. Anyone with this file can create trusted service identities.
4. **[AGENT] Install each service's certificate** into its deploy copy:
   ```bash
   $KIT/mtls/install-certs.sh orders ~/apps/orders-repo
   $KIT/mtls/install-certs.sh billing ~/apps/billing-repo
   ```
5. **[AGENT] Tell the caller where the callee is**, using billing's tailnet IP (`scripts/status.sh` in its folder):
   ```bash
   $KIT/mtls/add-peer.sh ~/apps/orders-repo billing 100.x.y.z
   ```
6. **[AGENT] Turn it on**, in `log-only` mode first:
   ```bash
   cd ~/apps/billing-repo && scripts/env.sh set SPRING_PROFILES_ACTIVE mtls && scripts/env.sh set MTLS_ALLOWED_CLIENTS orders && scripts/up.sh
   cd ~/apps/orders-repo  && scripts/env.sh set SPRING_PROFILES_ACTIVE mtls && scripts/up.sh
   ```
7. **In the code of `orders`**:
   ```java
   @Autowired MtlsConfig.MtlsClients mtls;
   String answer = mtls.peer("billing").get().uri("/internal/ping").retrieve().body(String.class);
   ```
   In `billing`, `request.getAttribute("mtls.client")` tells you who called.
8. **Verify [AGENT]:** `$KIT/mtls/check-mtls.sh ~/apps/billing-repo orders` shows `with certificate: 200`.
9. **[AGENT] Enforce**, once the logs show only expected callers:
   ```bash
   cd ~/apps/billing-repo && scripts/env.sh set MTLS_CLIENT_AUTH need && docker compose up -d --no-deps --force-recreate app
   ```
   `check-mtls.sh` now reports that calls without a certificate are refused.

Certificates are valid for 2 years; the CA for 10. To renew, run `gen-certs.sh --force <name>`, then
`install-certs.sh`, then restart the app.

---

## Part H: Daily use

### H1. Starting and stopping
After you log in to Windows, everything starts by itself within about a minute.
- **Start SelfHost** (Desktop) starts every stack and prints a summary.
- **SelfHost Status** shows the status of every stack plus the full `doctor.sh` check.
- **Stop SelfHost** stops everything, for example before gaming or on battery.

In Ubuntu: `~/selfhost-kit/wsl/selfhost.sh up|status|down`. For one stack: `cd ~/apps/<name> && scripts/up.sh`.

### H2. Sleep, shutdown, travel
- While the PC is off or asleep, the site is offline and pushes wait.
- A job that waits more than **24 h** is cancelled: open it on GitHub and click **Re-run all jobs**.
- A runner that is offline for **14 days** is removed by GitHub. Run `register-runner.sh --force` again (F1).

### H3. Roll back
- **Automatic:** a deploy whose health check fails is rolled back by itself.
- **Manual:** GitHub -> Actions -> pick an older green run -> **Re-run all jobs**. That deploys that commit again.
- **Quick undo on the PC:** `cd ~/apps/$REPO && scripts/deploy.sh --rollback`.

### H4. Logs, files and updates
- **App logs:** `cd ~/apps/$REPO && docker compose logs -f --tail 100 app` (Ctrl+C to stop).
- **Ubuntu files from Windows:** Explorer -> `\\wsl$\Ubuntu-24.04\home\<you>`.
- **Update Tailscale and Postgres images** (monthly): `scripts/up.sh --pull` in each stack.
- **Update the kit:** replace the Windows kit folder, keeping your `kit.env`. Then:
  1. Run Stage again.
  2. Re-run `apply-template.sh --project --force`, review the changes with `git diff`, and push.

### H5. Backups
`cd ~/apps/$DB_SERVICE_NAME && scripts/backup.sh` writes `~/backups/<db>-<date>.dump` (keeps the last 7).
Copy them off the PC, for example into OneDrive:
`cp ~/backups/*.dump "/mnt/c/Users/<you>/OneDrive/backups/"`. Nothing backs up automatically.

### H6. A second app on the same PC
1. On Windows, copy `kit.env` to `kit.<name>.env` with the other app's values, then Stage.
2. Run `apply-template.sh --kit-env $KIT/kit.<name>.env --project`.
3. Do Parts D and E with the other repo's names.
4. Register a runner for the other repo:
   `.\windows\wsl-run.ps1 -Root '$KIT/wsl/register-runner.sh --user $KIT_USER --owner <GITHUB_OWNER> --repo <other-repo>'`

Each app gets its own machine and URL.

---

## Part I: Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `0x80370102`, "Please enable the Virtual Machine Platform" | Virtualization is off | BIOS/UEFI: enable Intel VT-x / AMD SVM. Then Part A3 again. |
| WSL distro shows VERSION 1 | Old WSL default | `wsl --set-version Ubuntu-24.04 2` |
| `$'\r': command not found`, `bash\r: No such file` | Windows (CRLF) line endings | Run Stage again. In your repo: `.gitattributes` from the kit, then `git add --renormalize .` and push. |
| `./mvnw: Permission denied` (CI or build) | Windows lost the executable bit | `git add --chmod=+x mvnw scripts/*.sh`, commit, push |
| `permission denied ... /var/run/docker.sock` | New docker group not active yet | `wsl --terminate Ubuntu-24.04`, then retry |
| `Cannot connect to the Docker daemon` | systemd off, or Docker Desktop in the way | `doctor.sh`. Run `bootstrap.sh` again, then `wsl --shutdown`. Turn off Docker Desktop's WSL integration. |
| Site goes offline a minute after closing all windows | WSL2 idle shutdown | Part A7 again (check `%USERPROFILE%\.wslconfig` has `instanceIdleTimeout=-1`), `wsl --shutdown`, log off and on. `wsl --update` for the newest WSL. |
| `up.sh`: "Tailscale did not come online", `NeedsLogin` | Key wrong, expired, not reusable, or already used | New key (B3 step 5), `scripts/env.sh secret TS_AUTHKEY`, `scripts/up.sh` |
| `up.sh` exit 2: "HTTPS certificates are OFF" / "Funnel is not allowed" | Tailnet settings | B3 steps 3 and 4, then `scripts/up.sh` |
| Public URL doesn't load, but `up.sh` is all PASS | First-time DNS or certificate | Wait 10 minutes. Test from mobile data. `scripts/healthcheck.sh --public` |
| Machine appears as `<name>-1` and the URL changed | Tailscale state volume was deleted (`down -v`) or the stack renamed | Delete the old machine in the admin console, rename the new one to `<name>` |
| `/dev/net/tun` missing | Old or custom WSL kernel | `wsl --update`, `wsl --shutdown`; `sudo modprobe tun` |
| redeploy job "Waiting for a runner" | PC off, WSL stopped, runner not registered, or label mismatch | Start SelfHost. `doctor.sh`. Part F1. The workflow's `runs-on` must include `wsl` (`RUNNER_LABEL`). |
| Health check fails / app keeps restarting | App crash: wrong `DB_HOST` or password, no actuator (404), port mismatch | `docker compose logs app`. `scripts/env.sh check`. Actuator in pom.xml. `APP_PORT` = your app's port. |
| CI test: "Failed to determine a suitable driver class", or DB connection refused | Tests need a database | Part D2: Testcontainers dependencies and `@Import(SelfhostTestcontainersConfiguration.class)` |
| mTLS: `AccessDeniedException ... .key` | Key file not readable by the app user | `scripts/env.sh set APP_UID $(id -u)`, `install-certs.sh` again, `scripts/deploy.sh` |
| mTLS: `No subject alternative DNS name matching` / `PKIX path building failed` | Called by IP, or a different CA | Call `https://<peer-name>:8443` after `add-peer.sh`. Re-install `ca.crt` from the same `~/selfhost-ca`. |
| `useradd: UID 1000 is not unique` during build | Old copy of the Dockerfile | Re-apply the template (`--force`); the kit's Dockerfile removes the `ubuntu` user first |
| `refusing to allow an OAuth App to create or update workflow` | gh login lacks the `workflow` scope | `gh auth refresh -h github.com -s workflow` |
| PowerShell: "running scripts is disabled on this system" | Execution policy | Use `powershell -NoProfile -ExecutionPolicy Bypass -File ...` as written, and `Unblock-File` (A1) |

Still stuck? Run `~/selfhost-kit/wsl/doctor.sh` and read the first `[FAIL]`.

---

## Part J: Uninstall

Undo in this order. Only the last step deletes your data.

```powershell
.\windows\wsl-run.ps1 -Root '$KIT/wsl/register-runner.sh --user $KIT_USER --remove'   # GitHub runner
.\windows\wsl-run.ps1 '~/selfhost-kit/wsl/selfhost.sh down'                         # stop all stacks
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Uninstall
```

Then:
1. In the Tailscale admin console, delete the machines and revoke the auth key.
2. In your repo, delete `.github/workflows/deploy.yml` if you don't want the workflow any more.
3. **Deletes everything** in Ubuntu, including databases and backups under `~/backups`: `wsl --unregister Ubuntu-24.04`.

---

## Appendix A: How this maps to the original Linux setup

| Original (Fedora, Go services) | This kit (Windows, Spring Boot) |
|---|---|
| Docker on the host | Docker Engine inside WSL2 Ubuntu (not Docker Desktop) |
| `tailscale` sidecar, `network_mode: service:tailscale` | Same, plus `TS_AUTH_ONCE`, a `/healthz` health check, and a pinned compose `name:` |
| `ts-serve.json` with `AllowFunnel` on 443 | Same file, port from `APP_PORT` |
| Postgres stack on the tailnet only, apps use the `100.x` IP | Same (`db-template/`) |
| `--accept-dns=false`, peers by IP | Same. mTLS peers get a name via `extra_hosts` on the sidecar (`add-peer.sh`), because Java checks the certificate name. |
| Runner as a systemd service, `runs-on: [self-hosted, fedora]` | Same inside WSL2, label `wsl`, installed by `register-runner.sh` |
| Deploy: `git pull` in the dev checkout + `compose up -d --build --no-deps app` | Separate deploy copy `~/apps/<repo>` reset to the tested commit, `deploy.sh` (`--no-deps` app only), then a health check with automatic rollback, and `concurrency` so deploys never overlap |
| `test` job on `ubuntu-latest` (Go) | Same with `setup-java` + `./mvnw verify` (+ Testcontainers) |
| mTLS: private CA, second listener on 8443, CN allow-list, soft/enforce rollout | Same design in Spring Boot: `MtlsConfig` (HTTPS 8443 via SSL bundle + plain HTTP connector), `MtlsAllowlistFilter`, `MTLS_CLIENT_AUTH=want|need` |
| Secrets in `.env` next to compose | Same, with `scripts/env.sh` so secrets are never shown or committed |

## Appendix B: Security notes

- **Funnel makes the app public.** Anyone can call its public port, so protect your endpoints with your own
  login/auth. Keep internal endpoints under `/internal/` with mTLS (Part G), or don't expose them at all.
- **Your whole tailnet can reach every stack.** With Tailscale's default policy, each device in your tailnet
  can reach every port of every stack, including Postgres 5432 and 8443. Only add devices you trust, or
  restrict access with grants in Access controls.
- **Private repos only.** Self-hosted runners execute repo code on your PC, so use them only with private
  repos. Never add a `pull_request` trigger to the redeploy job.
- **Keep `.env` private.** `.env` files are mode 600 and git-ignored. `.dockerignore` keeps `.env` and
  `certs/` out of images.
- **Keep `ca.key` offline.** The mTLS CA key (`~/selfhost-ca/ca.key`) should be backed up offline and
  guarded like a password.
- **Machine names are public.** HTTPS certificate names (your machine and tailnet names) appear in public
  Certificate Transparency logs.

## Appendix C: Files in this kit

| Path | What it is |
|---|---|
| `kit.env.example` | your settings (copy to `kit.env`) |
| `windows/setup-windows.ps1` | Windows phases: Check, Install, Stage, Configure, Uninstall |
| `windows/wsl-run.ps1` | run a bash command in WSL2 from PowerShell safely |
| `wsl/bootstrap.sh` | one-time Ubuntu setup: systemd, Docker Engine, gh, tools |
| `wsl/apply-template.sh` | copies the templates into your project (`--project`) or creates the DB stack (`--db`) |
| `wsl/register-runner.sh` | GitHub self-hosted runner as a service (`--force`, `--remove`) |
| `wsl/selfhost.sh` | start, stop or show status of all stacks, and the logon autostart |
| `wsl/doctor.sh` | checks everything, PASS / WARN / FAIL with fixes |
| `wsl/kit-vars.sh`, `wsl/lib.sh` | helpers |
| `project-template/` | what goes into your repo (Dockerfile, compose, Funnel config, workflow, scripts, Spring snippets) |
| `db-template/` | the Postgres stack (compose, init SQL, backup and psql scripts) |
| `mtls/` | CA and certificate scripts, peers, check, Spring mTLS classes |
| `tools/bundle.sh`, `tools/unbundle.*` | build or unpack the single-file edition `dist/windows-selfhost-kit.md` |
