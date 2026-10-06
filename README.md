# Arcane Lab & Traefik Reverse Proxy

A production-grade, local container orchestration and observability laboratory powered by **Arcane Manager** and **Traefik v3**.

---

## Architecture Overview

```
                      +-----------------------------+
                      |   Client (Browser / API)    |
                      +--------------+--------------+
                                     |
                                [Port 80/443]
                                     v
                      +-----------------------------+
                      |       Traefik Proxy         |
                      |  (https://proxy.chetan.local) |
                      +--------------+--------------+
                                     |
                     [Docker Network: 'proxy']
                                     |
         +---------------------------+---------------------------+
         |                                                       |
         v                                                       v
+-------------------------------+               +-------------------------------+
|         Arcane Manager        |               |       Future Projects         |
| (https://dockermgr.chetan.local) |             |  (e.g., monitoring, apps...)  |
+-------------------------------+               +-------------------------------+
```

### Core Endpoints

| Service | Local URL | EntryPoint | TLS Status |
| :--- | :--- | :--- | :--- |
| **Traefik Dashboard** | `https://proxy.chetan.local` | HTTPS (443) | Active (Wildcard SAN) |
| **Arcane Manager** | `https://dockermgr.chetan.local` | HTTPS (443) | Active (Wildcard SAN) |

- **HTTP Port 80**: Automatically redirects to **HTTPS Port 443**.
- **Shared Network**: All exposed containers connect to the `proxy` Docker network.
- **TLS Wildcard**: Traefik automatically terminates TLS for all `*.chetan.local` domains using the certificates located in `traefik/certs/`.

### Initial Login Credentials

- **Default Username**: `arcane`
- **Default Password**: `arcane-admin`
- **Documentation Reference**: [Arcane Installation & Setup](https://getarcane.app/docs/get-started/installation#open-arcane)

> [!NOTE]
> You will be prompted to change these default credentials after logging in for the first time.

---

## Adding New Projects in Arcane

Because global Docker networking (`network: proxy`) and global TLS (`http.tls: {}`) are configured in `traefik/traefik.yaml`, **you do not need to configure SSL certificates or entrypoints for new applications**.

You only need:
1. **3 Traefik Labels** on your service.
2. The **`default` network bridge** pointing to `proxy`.

---

### Step 1: Add Local DNS Entry

Windows `hosts` files (`C:\Windows\System32\drivers\etc\hosts`) do not support wildcards (`*.chetan.local`). For each new domain you want to use, add a record pointing to `127.0.0.1`:

```hosts
127.0.0.1  monitoring.chetan.local
127.0.0.1  app.chetan.local
```

---

### Step 2: Add the Project in Arcane

Open Arcane WebUI at [https://dockermgr.chetan.local](https://dockermgr.chetan.local) and create a new project using one of the following methods:

#### Method A: Direct Compose (Quickest & Recommended)

Best for standalone tools like Grafana, Portainer, Uptime Kuma, or single-container web apps.

1. In Arcane, click **New Project** and name it (e.g., `grafana`).
2. Paste the following into the **Compose** editor:

```yaml
services:
  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    restart: unless-stopped
    labels:
      - traefik.enable=true
      - 'traefik.http.routers.grafana.rule=Host(`monitoring.chetan.local`)'
      - traefik.http.services.grafana.loadbalancer.server.port=3000

networks:
  default:
    name: proxy
    external: true
```

3. Click **Deploy**. Your app is immediately live at `https://monitoring.chetan.local`.

> [!TIP]
> **The `default` Network Trick**: By setting `networks.default.name: proxy` with `external: true`, every service defined in that file automatically joins Traefik's `proxy` network without having to specify `networks: [proxy]` on each service.

---

#### Method B: Environment-Driven (Clean DevOps Pattern)

Best when you want a standard, reusable compose template and prefer configuring the domain and port in Arcane's **Environment (.env)** tab.

1. In the project's **Environment (.env)** tab:
```env
APP_NAME=grafana
APP_HOST=monitoring.chetan.local
APP_PORT=3000
```

2. In the project's **Compose** tab:
```yaml
services:
  app:
    image: grafana/grafana-oss:latest
    container_name: ${APP_NAME}
    restart: unless-stopped
    labels:
      - traefik.enable=true
      - "traefik.http.routers.${APP_NAME}.rule=Host(`${APP_HOST}`)"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=${APP_PORT}"

networks:
  default:
    name: proxy
    external: true
```

3. Click **Deploy**.

---

#### Method C: Multi-Container Apps (App + Private Isolated Database)

Best for applications that include private backends, databases, or Redis caches (e.g., Nextcloud + Postgres, WordPress + MariaDB).

Only the web-facing container should join the `proxy` network; the database stays completely isolated on an internal network.

```yaml
services:
  app:
    image: wordpress:latest
    container_name: wordpress-app
    restart: unless-stopped
    networks:
      - proxy
      - internal
    labels:
      - traefik.enable=true
      - 'traefik.http.routers.wordpress.rule=Host(`blog.chetan.local`)'
      - traefik.http.services.wordpress.loadbalancer.server.port=80
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: wppassword
      WORDPRESS_DB_NAME: wordpress

  db:
    image: mariadb:10.11
    container_name: wordpress-db
    restart: unless-stopped
    networks:
      - internal
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: wppassword
    volumes:
      - db-data:/var/lib/mysql

networks:
  proxy:
    external: true
  internal:

volumes:
  db-data:
```

---

## Traefik Label Cheat Sheet

| Label | Purpose | Example |
| :--- | :--- | :--- |
| `traefik.enable=true` | Tells Traefik to route this container | `true` |
| `traefik.http.routers.<name>.rule` | Domain / host rule for routing | `Host(\`app.chetan.local\`)` |
| `traefik.http.services.<name>.loadbalancer.server.port` | Internal container port to forward to | `3000` or `80` |
| `traefik.http.routers.<name>.priority` | *(Optional)* Priority if rules overlap | `10` |

---

## Customizing the Backup Folder Location

Arcane's backup engine internally expects a Docker volume named `arcane-backups`. In `compose.yaml`, this volume is bound to your host filesystem using `driver_opts`.

To change the backup folder to any custom location (e.g., `./data/arcane-backups/` or `D:/Backups/`):

1. Update the `device` path under `volumes` in [compose.yaml](file:///c:/Projects/My_Projects/Arcane-lab/compose.yaml):
   ```yaml
   volumes:
     arcane-backups:
       name: arcane-backups            # Keep as 'arcane-backups' for Arcane compatibility
       driver: local
       driver_opts:
         type: none
         o: bind
         device: ${PWD}/data/arcane-backups   # <--- Change this to any folder on your host
   ```
2. Recreate the stack:
   ```powershell
   docker compose down
   docker volume rm arcane-backups
   docker compose up -d
   ```

---

## Traefik Observability: Access Logs, Metrics & Tracing

Traefik has built-in observability features configured in `traefik/traefik.yaml`:

### 1. Access Logs (JSON Format)
- Formatted as structured JSON with client IP, request method, path, response status, duration, TLS cipher, and OpenTelemetry trace IDs.
- Outputs directly to Docker standard output (`stdout`).

### 2. Metrics (Prometheus)
- Live Prometheus metrics are served directly on the secure entrypoint at:
  ```
  https://proxy.chetan.local/metrics
  ```
- **Host storage impact**: **0 MB** (metrics counters are stored entirely in RAM and reset on container restart).

### 3. Distributed Tracing (OpenTelemetry OTLP)
- Traefik traces incoming and outgoing HTTP spans using OpenTelemetry standards.
- Traces are streamed over network to an OTLP collector (e.g., Tempo, Jaeger).
- **Host storage impact**: **0 MB** (traces are never written to host disk).

### 4. Storage Protection & FIFO Log Capping
To ensure Docker logs **never fill up host machine storage**, Docker's `json-file` logging driver is configured with strict First-In, First-Out (FIFO) log rotation.

You can configure the maximum cap directly in [.env](file:///c:/Projects/My_Projects/Arcane-lab/.env):

```env
# Logging Capping & Retention (FIFO log rotation)
LOG_MAX_SIZE=10m    # Maximum size of an individual log chunk before rotating
LOG_MAX_FILE=5      # Keep at most 5 rotated files (Total disk cap = 10m * 5 = 50MB max)
```

When the log limit is reached, Docker automatically purges the oldest log file in a circular FIFO queue.

---

## Project Structure

```
Arcane-lab/
├── compose.yaml              # Core stack (Arcane + Traefik)
├── .env                      # Arcane production environment configuration
├── arcane-backups/           # Host storage for volume & system backups (/backups)
├── arcane-data/              # Internal Arcane application data (SQLite DB, sessions)
├── projects/                 # Mounted host directory for all Arcane compose projects
│   └── .env.global           # Global environment variables shared across all projects
└── traefik/
    ├── traefik.yaml          # Static configuration (entrypoints, providers, logging)
    ├── dynamic/
    │   └── tls.yaml          # Dynamic TLS configuration loading local certificates
    └── certs/
        ├── domain_public_certificate.crt  # Public wildcard certificate (*.chetan.local)
        └── domain_secret_private.key      # Secret private key
```

---

## Management & Troubleshooting Commands

- **Check Running Containers**:
  ```powershell
  docker compose ps
  ```

- **View Traefik Logs (Routing / Discovery)**:
  ```powershell
  docker logs -f traefik
  ```

- **View Arcane Logs**:
  ```powershell
  docker logs -f arcane
  ```

- **Restart the Core Stack**:
  ```powershell
  docker compose down
  docker compose up -d
  ```

---

## Air-Gapped Deployment (Offline Ubuntu Server)

To deploy this entire stack into an air-gapped Ubuntu server with no internet access (reachable only via SSH):

### 1. From your workstation (Connected to internet + SSH access to server):
Run the bundling script to pull the Docker images, package the configurations and certificates, transfer via SSH/SCP, and automatically run the installer:

**Using Bash (Git Bash / Linux / WSL / macOS):**
```bash
# Interactive mode:
./bundle_and_push.sh

# Non-interactive mode with auto-deploy:
./bundle_and_push.sh -t ubuntu@192.168.1.100 -i ~/.ssh/id_rsa -r
```

**Using PowerShell (Windows):**
```powershell
# Interactive mode:
.\bundle_and_push.ps1

# Non-interactive mode with auto-deploy:
.\bundle_and_push.ps1 -Target "ubuntu@192.168.1.100" -AutoRun
```

**Offline / USB Mode:**
If you don't have direct SSH and need to transfer via USB or external drive:
```bash
./bundle_and_push.sh --bundle-only
```
This generates `arcane-airgap-bundle.tar.gz` containing all Docker images (`docker-images.tar.gz`), project files, and the deployment script.

### 2. On the Air-Gapped Ubuntu Server:
If you did not use the auto-run (`-r` / `-AutoRun`) flag, unpack the bundle and run the server installer:

```bash
mkdir -p /opt/arcane-docker-manager
tar -xzf arcane-airgap-bundle.tar.gz -C /opt/arcane-docker-manager
cd /opt/arcane-docker-manager
sudo ./deploy_on_server.sh
```

The script will:
1. Verify system Docker and Compose installations.
2. Load offline Docker images from the bundle (`docker load`).
3. Create the `proxy` Docker network.
4. Set secure permissions on TLS keys (`chmod 600`).
5. Start the stack in background mode (`docker compose up -d`).
6. Perform container health checks and display access endpoints.

