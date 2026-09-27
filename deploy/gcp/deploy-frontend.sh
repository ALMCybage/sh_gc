#!/usr/bin/env bash
#
# Build the React SPA and publish it to Cloud Storage behind Cloud CDN.
#
#   PROJECT_ID=my-project ./deploy/gcp/deploy-frontend.sh
#
# There are no pods in this tier: the bundle is static files on GCS, served from
# Google's edge. That is what "Zero Pod Autoscaling" in the architecture means -
# a traffic spike on the frontend costs nothing in cluster capacity.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?export PROJECT_ID first}"
BUCKET="${FRONTEND_BUCKET:-${PROJECT_ID}-sequifi-frontend}"
REGION="${REGION:-us-central1}"
URL_MAP="${URL_MAP:-sequifi-url-map}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="${ROOT}/frontend/dist"

echo "==> Building the SPA"
(cd "${ROOT}/frontend" && npm ci && npm run build)

if [[ ! -f "${DIST}/index.html" ]]; then
    echo "!! Build produced no index.html" >&2
    exit 1
fi

echo "==> Ensuring bucket gs://${BUCKET}"
if ! gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${BUCKET}" \
        --location="${REGION}" \
        --uniform-bucket-level-access \
        --public-access-prevention=inherited

    # The backend bucket serves through the load balancer, so the objects have to
    # be readable by allUsers. There is nothing secret in a client bundle - the
    # API is what enforces authorisation.
    gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
        --member=allUsers --role=roles/storage.objectViewer

    # SPA routing: any unknown path must return index.html so client-side routes
    # deep-link correctly. 404 -> index.html is what makes /payroll/<uuid> work
    # on a cold load.
    gcloud storage buckets update "gs://${BUCKET}" \
        --web-main-page-suffix=index.html \
        --web-error-page=index.html
fi

echo "==> Uploading hashed assets (immutable, 1 year)"
# Assets first, index.html last. Doing it in this order means a client that
# fetches the new index.html always finds the assets it references already
# present - the reverse order leaves a window of 404s mid-deploy.
if [[ -d "${DIST}/assets" ]]; then
    gcloud storage rsync "${DIST}/assets" "gs://${BUCKET}/assets" \
        --recursive \
        --cache-control="public, max-age=31536000, immutable"
fi

echo "==> Uploading index.html (never cached)"
# index.html must not be cached anywhere, or users keep running last week's
# bundle against this week's API.
gcloud storage cp "${DIST}/index.html" "gs://${BUCKET}/index.html" \
    --cache-control="no-cache, no-store, must-revalidate"

for extra in favicon.svg robots.txt; do
    if [[ -f "${DIST}/${extra}" ]]; then
        gcloud storage cp "${DIST}/${extra}" "gs://${BUCKET}/${extra}" \
            --cache-control="public, max-age=3600"
    fi
done

echo "==> Invalidating the CDN cache for index.html"
# Only index.html needs invalidating; the hashed assets are immutable by
# construction and new filenames are simply new cache entries.
if gcloud compute url-maps describe "${URL_MAP}" >/dev/null 2>&1; then
    gcloud compute url-maps invalidate-cdn-cache "${URL_MAP}" \
        --path="/index.html" --async
    gcloud compute url-maps invalidate-cdn-cache "${URL_MAP}" \
        --path="/" --async
else
    echo "    url-map ${URL_MAP} not found; run deploy/gcp/shared-lb.sh first"
fi

echo "==> Frontend published to gs://${BUCKET}"
