# SuperAgent Helm Chart

Self-host a single-tenant [SuperAgent](https://github.com/SkillfulAgents/Gamut)
on your own Kubernetes cluster. The chart deploys one long-lived **host-app** pod
that orchestrates **per-agent pods** via the in-cluster Kubernetes API.

## Architecture

```
namespace
├── Deployment  host-app (1 replica, SQLite single-writer)
│     └── creates/deletes ──▶ Pod  agent-<id>  +  Service agent-<id>
├── Service + Ingress  →  host-app UI/API
├── PVC  (shared, RWX)  ←  host-app data dir + agent workspaces
│       backend: any POSIX-compliant RWX provider
│       e.g. NFS · Longhorn · CephFS · AWS EFS · S3 Files (efs.csi) · Azure Files · Filestore
├── ServiceAccount + Role/RoleBinding  (pods/services CRUD)
└── NetworkPolicy  (agent ingress confined to host-app)
```

The host-app and every agent pod **share one PVC**: the runtime mounts each agent's
`workspaces/<id>/workspace` subPath into the agent pod. The backend can be **any
POSIX-compliant RWX provider** — NFS, Longhorn, CephFS, AWS EFS, S3 Files (via the
`efs.csi.aws.com` driver), Azure Files, GCP Filestore, etc. SuperAgent runs SQLite,
git and npm in the workspace, so the volume must support real POSIX semantics
(random writes, `fcntl` locking), not plain object storage.

On a multi-node cluster the PVC **must be `ReadWriteMany`** so host-app and agent
pods can mount it from different nodes. A single-node cluster can use `ReadWriteOnce`.

## Shared PVCs and subPaths

For a dedicated PVC, leave `storage.subPath` empty; host-app owns the whole
claim. When multiple installs share one backing filesystem, set
`storage.subPath` so each install sees only its own data directory.

Some RWX backends require the parent directory to already exist before Kubernetes
can mount a nested `subPath`. In that case, set `storage.subPathParent` to an
existing writable parent and `storage.subPath` to the child directory; the chart
will create the child directory during init:

```yaml
storage:
  existingClaim: shared-workspaces
  subPathParent: tenants
  subPath: tenants/acme/superagent-data

agent:
  workspacesSubPathPrefix: tenants/acme/superagent-data/agents
```

The chart also runs a permissions init step. Some managed filesystems ignore
`chown`, so the init uses broad write permissions for the mounted data directory.

## Prerequisites

Before installing, have these ready:

1. **A Kubernetes cluster** (1.24+) and `kubectl` + `helm` configured against it.
2. **A `ReadWriteMany` StorageClass** (NFS, Longhorn, EFS, …) for multi-node
   clusters. A single-node cluster can use `ReadWriteOnce` (set
   `storage.accessMode=ReadWriteOnce`).
3. **A way to reach host-app.** By default the chart only creates a `ClusterIP`
   Service — verify with `kubectl port-forward` (no public exposure). Exposing it
   publicly is your cluster's job; see [Exposing host-app](#exposing-host-app).
4. **An LLM provider API key** when you are ready to run agents. Self-host
   defaults to Anthropic — get a key from <https://console.anthropic.com> →
   *API Keys*. You can provide it during install, or add it later in the UI.

### Which key, by provider

`hostApp.settings.llmProvider` selects the provider. You can either set the
matching key in `secrets.env` (or your `existingSecret`) during install, or add
it later from the host-app UI:

| `llmProvider` | Secret key to set | Where to get it |
|---------------|-------------------|-----------------|
| `anthropic` (default) | `ANTHROPIC_API_KEY` | console.anthropic.com |
| `openrouter` | `OPENROUTER_API_KEY` | openrouter.ai/keys |
| `bedrock` | `AWS_BEARER_TOKEN_BEDROCK` | AWS Bedrock console |

## Providing secrets (there is no `.env`)

Helm does **not** read a `.env` file. You can start without an LLM key, sign in
as the first admin, and add the key in the UI before starting agents.

If you want the key available at first boot, provide it one of two ways:

> Install from a local clone of this repo (`git clone … && cd k8s-runtime-helm`).
> The commands below use the chart path `./k8s-runtime-helm`; an OCI-published
> chart will come later.

**Option A — let the chart create the Secret** (simplest). Pass keys via
`secrets.env`; the chart renders a Kubernetes `Secret` and wires it into host-app
with `envFrom`:

```sh
helm install superagent ./k8s-runtime-helm \
  --namespace superagent --create-namespace \
  --set hostPublicUrl=https://superagent.example.com \
  --set storage.storageClassName=<your-rwx-class> \
  --set-string secrets.env.ANTHROPIC_API_KEY=sk-ant-...
```

> Avoid putting real keys in a values file you commit. Use `--set-string` on the
> CLI, or Option B.

**Option B — reference a Secret you created** (keeps keys out of Helm entirely):

```sh
kubectl create namespace superagent
kubectl -n superagent create secret generic superagent-secrets \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-...

helm install superagent ./k8s-runtime-helm \
  -n superagent \
  --set hostPublicUrl=https://superagent.example.com \
  --set storage.storageClassName=<your-rwx-class> \
  --set secrets.existingSecret=superagent-secrets
```

The Secret's keys become env vars on host-app verbatim, so name them exactly as
the provider expects (e.g. `ANTHROPIC_API_KEY`).

## Exposing host-app

By default the chart creates a `ClusterIP` Service, so host-app stays reachable
inside the cluster without being exposed publicly. Public exposure depends a lot
on your setup (ingress controller, load balancer, gateway, DNS, TLS), so the chart
leaves that choice to you.

**Access it during setup / testing:**

```sh
kubectl -n superagent port-forward svc/superagent 8080:80
# then open http://localhost:8080
```

**When you want public access, pick whatever fits your cluster:**

- Point your existing ingress controller at the `superagent` Service, or
- Set `service.type=LoadBalancer` to get a cloud load balancer, or
- Enable the example Ingress and fill in settings for your controller:

```yaml
ingress:
  enabled: true
  className: alb            # or nginx / traefik / … — no default
  host: superagent.example.com
  annotations:              # provider-specific; e.g. for AWS ALB:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
  tls:
    enabled: true
    secretName: superagent-tls
```

The bundled Ingress is just a convenience template that works with any
controller. See [`ci/eks-alb-efs-values.yaml`](./ci/eks-alb-efs-values.yaml) for a
full AWS ALB example.

## Authentication (multi-user login)

`auth.mode` defaults to `true` — host-app runs as a **multi-user** deployment with
login. **No OIDC setup is required**: it uses email/password (local auth) out of
the box. The **first user to sign up becomes the admin**; by default further
signups are invitation-only and need admin approval (tunable in host-app's auth
settings).

Optionally, add **OIDC/social login** by setting `AUTH_PROVIDERS_JSON`. It carries
a `clientSecret`, so put it in `secrets.env` or your `existingSecret`, never in a
committed values file:

```yaml
secrets:
  env:
    ANTHROPIC_API_KEY: sk-ant-...
    AUTH_PROVIDERS_JSON: |
      [
        {
          "id": "google",
          "type": "oidc",
          "displayName": "Google",
          "discoveryUrl": "https://accounts.google.com/.well-known/openid-configuration",
          "clientId": "<your-oidc-client-id>",
          "clientSecret": "<your-oidc-client-secret>",
          "scopes": ["openid", "email", "profile"]
        }
      ]
```

Notes:

- OIDC redirect/callback URLs are derived from `hostPublicUrl` — register that
  origin in your OIDC app.
- Enabling auth requires a **clean data directory** on first boot. Enabling it on
  a PVC that already holds non-auth agents is rejected at startup.
- Running a **single-user** instance with no login? Set `auth.mode=false`.

## Key values

| Key | Default | Notes |
|-----|---------|-------|
| `hostPublicUrl` | `""` | **Required.** External URL of the host-app. |
| `auth.mode` | `true` | Multi-user login (email/password by default). `false` = single-user. |
| `storage.existingClaim` | `""` | Bring-your-own PVC; chart skips creating one. |
| `storage.subPath` | `""` | Optional host-app data subPath when sharing one backing filesystem. |
| `storage.subPathParent` | `""` | Existing parent subPath used to create a nested `storage.subPath`. |
| `storage.storageClassName` | `""` | RWX-capable class; `""` = cluster default. |
| `storage.accessMode` | `ReadWriteMany` | `ReadWriteOnce` only on single-node. |
| `secrets.env` | `{}` | Provider keys injected as env (e.g. `ANTHROPIC_API_KEY`). |
| `secrets.existingSecret` | `""` | Reference a pre-created Secret instead. |
| `ingress.enabled` | `false` | Example Ingress; off by default. Expose host-app yourself. |
| `ingress.className` | `""` | Your ingress controller class (alb / nginx / …). No default. |
| `agent.resources` | `cpu: 1, memory: 2Gi` | Per-agent pod resources. |
| `image.hostApp.tag` / `image.agentContainer.tag` | `""` | Default to chart `appVersion`. |
| `networkPolicy.enabled` | `true` | Confine agent ingress to host-app. |

See [`values.yaml`](./values.yaml) for the full list.

## Notes

- `hostApp.replicas` is pinned to `1`; the chart refuses to render with more
  (host-app is a single-writer over the shared PVC).
- `settings.json` is seeded **only on first boot**; later changes to
  `hostApp.settings` won't re-apply (host-app persists its own settings).
- Agent pods are garbage-collected via an `ownerReference` to the host-app pod:
  if host-app dies, the cluster cleans up orphaned agent pods.
