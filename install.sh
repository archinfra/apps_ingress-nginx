#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="ingress-nginx"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_NAMESPACE="ingress-nginx"
DEFAULT_WAIT_TIMEOUT="180s"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

REGISTRY="${DEFAULT_REGISTRY}"
REGISTRY_USER=""
REGISTRY_PASS=""
NAMESPACE="${DEFAULT_NAMESPACE}"
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
SERVICE_TYPE="NodePort"
INGRESS_CLASS="nginx"
CONTROLLER_CLASS="k8s.io/ingress-nginx"
SKIP_IMAGE_PREPARE=0
YES=0
DELETE_NAMESPACE=0
NODEPORT_HTTP=""
NODEPORT_HTTPS=""
WORKDIR=""
IMAGE_INDEX=""

usage() {
  cat <<USAGE
Usage:
  ./ingress-nginx-<version>-<arch>.run install [options]
  ./ingress-nginx-<version>-<arch>.run status [options]
  ./ingress-nginx-<version>-<arch>.run uninstall [options]
  ./ingress-nginx-<version>-<arch>.run help

Actions:
  install      Extract payload, load/tag/push images, render manifests, and install ingress-nginx.
  status       Show ingress-nginx Kubernetes resources.
  uninstall    Delete ingress-nginx resources. Namespace is kept unless --delete-namespace is set.
  help         Show this help.

Options:
  --registry <repo-prefix>       Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>         Registry username for docker login.
  --registry-pass <pass>         Registry password for docker login.
  --skip-image-prepare           Skip docker load/tag/push; still render images to --registry prefix.
  -n, --namespace <namespace>    Kubernetes namespace. Default: ${DEFAULT_NAMESPACE}
  --wait-timeout <duration>      kubectl wait/rollout timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --service-type <type>          Service type: NodePort, LoadBalancer, or ClusterIP. Default: NodePort
  --nodeport-http <port>         Optional fixed NodePort for HTTP, for example 30080.
  --nodeport-https <port>        Optional fixed NodePort for HTTPS, for example 30443.
  --ingress-class <name>         IngressClass name. Default: nginx
  --controller-class <class>     Controller class string. Default: k8s.io/ingress-nginx
  --delete-namespace             During uninstall, also delete the namespace.
  -y, --yes                      Do not ask for confirmation.
  -h, --help                     Show this help.

Examples:
  ./ingress-nginx-1.15.1-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --registry-user admin \
    --registry-pass 'passw0rd' \
    -n ingress-nginx -y

  ./ingress-nginx-1.15.1-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --skip-image-prepare -y
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --service-type) SERVICE_TYPE="${2:-}"; shift 2 ;;
    --nodeport-http) NODEPORT_HTTP="${2:-}"; shift 2 ;;
    --nodeport-https) NODEPORT_HTTPS="${2:-}"; shift 2 ;;
    --ingress-class) INGRESS_CLASS="${2:-}"; shift 2 ;;
    --controller-class) CONTROLLER_CLASS="${2:-}"; shift 2 ;;
    --delete-namespace) DELETE_NAMESPACE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi

[[ -n "${REGISTRY}" ]] || die "--registry cannot be empty"
[[ -n "${NAMESPACE}" ]] || die "--namespace cannot be empty"
case "${SERVICE_TYPE}" in NodePort|LoadBalancer|ClusterIP) ;; *) die "--service-type must be NodePort, LoadBalancer, or ClusterIP" ;; esac

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  WORKDIR="$(mktemp -d -t ${PACKAGE_NAME}.XXXXXX)"
  IMAGE_INDEX="${WORKDIR}/images/image-index.tsv"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${IMAGE_INDEX}" ]] || die "payload missing images/image-index.tsv"
  [[ -f "${WORKDIR}/manifests/ingress-nginx.yaml.tmpl" ]] || die "payload missing manifests/ingress-nginx.yaml.tmpl"
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} ${PACKAGE_NAME} in namespace '${NAMESPACE}'."
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

retarget_image() {
  local default_ref="$1"
  local name_tag
  name_tag="${default_ref#*/}"
  while [[ "${name_tag}" == */*/* ]]; do
    name_tag="${name_tag#*/}"
  done
  if [[ "${default_ref}" == sealos.hub:5000/kube4/* ]]; then
    name_tag="${default_ref#sealos.hub:5000/kube4/}"
  fi
  printf '%s/%s\n' "${REGISTRY%/}" "${name_tag}"
}

image_ref_by_name() {
  local wanted="$1"
  awk -F'|' -v name="${wanted}" 'NR > 1 && $1 == name { print $4; exit }' "${IMAGE_INDEX}"
}

target_ref_by_name() {
  local wanted="$1" default_ref
  default_ref="$(image_ref_by_name "${wanted}")"
  [[ -n "${default_ref}" ]] || die "image not found in index: ${wanted}"
  retarget_image "${default_ref}"
}

prepare_images() {
  [[ "${SKIP_IMAGE_PREPARE}" == "1" ]] && { info "skip image prepare"; return 0; }
  need docker

  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "both --registry-user and --registry-pass are required for docker login"
    local login_host="${REGISTRY%%/*}"
    info "docker login ${login_host}"
    printf '%s' "${REGISTRY_PASS}" | docker login "${login_host}" -u "${REGISTRY_USER}" --password-stdin
  fi

  tail -n +2 "${IMAGE_INDEX}" | while IFS='|' read -r name tar_name load_ref default_ref platform pull dockerfile; do
    [[ -n "${name}" ]] || continue
    local tar_path="${WORKDIR}/images/${tar_name}"
    local target_ref
    [[ -f "${tar_path}" ]] || die "image tar not found: ${tar_path}"
    target_ref="$(retarget_image "${default_ref}")"
    info "docker load ${tar_name}"
    docker load -i "${tar_path}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      info "docker tag ${load_ref} ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi
    info "docker push ${target_ref}"
    docker push "${target_ref}"
  done
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

render_manifest() {
  local controller_image webhook_image rendered
  local http_line https_line
  controller_image="$(target_ref_by_name controller)"
  webhook_image="$(target_ref_by_name kube-webhook-certgen)"
  rendered="${WORKDIR}/rendered-ingress-nginx.yaml"

  http_line=""
  https_line=""
  if [[ -n "${NODEPORT_HTTP}" ]]; then http_line="    nodePort: ${NODEPORT_HTTP}"; fi
  if [[ -n "${NODEPORT_HTTPS}" ]]; then https_line="    nodePort: ${NODEPORT_HTTPS}"; fi

  sed \
    -e "s/__NAMESPACE__/$(escape_sed "${NAMESPACE}")/g" \
    -e "s/__CONTROLLER_IMAGE__/$(escape_sed "${controller_image}")/g" \
    -e "s/__WEBHOOK_CERTGEN_IMAGE__/$(escape_sed "${webhook_image}")/g" \
    -e "s/__SERVICE_TYPE__/$(escape_sed "${SERVICE_TYPE}")/g" \
    -e "s/__INGRESS_CLASS__/$(escape_sed "${INGRESS_CLASS}")/g" \
    -e "s/__CONTROLLER_CLASS__/$(escape_sed "${CONTROLLER_CLASS}")/g" \
    -e "s|__NODEPORT_HTTP_LINE__|$(escape_sed "${http_line}")|g" \
    -e "s|__NODEPORT_HTTPS_LINE__|$(escape_sed "${https_line}")|g" \
    "${WORKDIR}/manifests/ingress-nginx.yaml.tmpl" > "${rendered}"

  sed -i '/^[[:space:]]*$/d' "${rendered}"
  printf '%s\n' "${rendered}"
}

install_app() {
  need kubectl
  extract_payload
  confirm
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  info "delete old admission jobs if present"
  kubectl delete job ingress-nginx-admission-create ingress-nginx-admission-patch -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
  info "kubectl apply -f rendered manifest"
  kubectl apply -f "${rendered}"
  info "waiting for deployment/${PACKAGE_NAME}-controller"
  kubectl rollout status deployment/ingress-nginx-controller -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl get pods,svc,deploy,job -n "${NAMESPACE}"
}

status_app() {
  need kubectl
  echo "Namespace: ${NAMESPACE}"
  kubectl get pods,svc,deploy,job -n "${NAMESPACE}" || true
  kubectl get ingressclass "${INGRESS_CLASS}" || true
  kubectl get validatingwebhookconfiguration ingress-nginx-admission || true
}

uninstall_app() {
  need kubectl
  extract_payload
  confirm
  local rendered
  rendered="$(render_manifest)"
  info "kubectl delete -f rendered manifest"
  kubectl delete -f "${rendered}" --ignore-not-found=true || true
  if [[ "${DELETE_NAMESPACE}" == "1" ]]; then
    info "delete namespace ${NAMESPACE}"
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true || true
  else
    info "namespace kept: ${NAMESPACE}"
  fi
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
