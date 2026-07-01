# apps_ingress-nginx

Ingress NGINX offline `.run` installer package.

This repository packages `ingress-nginx` into a self-contained offline installer. The build step pulls the required images for `amd64` and `arm64`, saves them into the payload, and produces executable `.run` files plus SHA256 checksums.

## Version

- ingress-nginx controller: `v1.15.1`
- kube-webhook-certgen: `v1.6.9`
- default service type: `NodePort`

## Build locally

Requirements:

- Linux shell
- Docker
- Python 3
- `tar`
- `sha256sum`

Build one architecture:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Build both:

```bash
bash build.sh --arch all
```

Artifacts are written to `dist/`:

```text
dist/ingress-nginx-1.15.1-amd64.run
dist/ingress-nginx-1.15.1-amd64.run.sha256
dist/ingress-nginx-1.15.1-arm64.run
dist/ingress-nginx-1.15.1-arm64.run.sha256
```

## Install in an offline environment

Copy the `.run` and `.sha256` file to the target host that can access the internal image registry and Kubernetes cluster.

```bash
sha256sum -c ingress-nginx-1.15.1-amd64.run.sha256
chmod +x ingress-nginx-1.15.1-amd64.run
./ingress-nginx-1.15.1-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -n ingress-nginx \
  -y
```

Use fixed NodePorts when needed:

```bash
./ingress-nginx-1.15.1-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --nodeport-http 30080 \
  --nodeport-https 30443 \
  -y
```

If images already exist in the target registry:

```bash
./ingress-nginx-1.15.1-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -y
```

## Status and uninstall

```bash
./ingress-nginx-1.15.1-amd64.run status -n ingress-nginx
./ingress-nginx-1.15.1-amd64.run uninstall -n ingress-nginx -y
```

By default `uninstall` keeps the namespace. To delete it too:

```bash
./ingress-nginx-1.15.1-amd64.run uninstall -n ingress-nginx --delete-namespace -y
```

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds both `amd64` and `arm64` artifacts on:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are also attached to the GitHub Release.
