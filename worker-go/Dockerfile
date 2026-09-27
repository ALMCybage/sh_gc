# syntax=docker/dockerfile:1
#
# Go Microservice Worker Pod Pool - the calculation engine.

########################################################################
# Stage 1: build
########################################################################
FROM golang:1.24-alpine AS build

WORKDIR /src

# Module files first: the dependency download layer is then reused whenever only
# application code changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev
ARG COMMIT=unknown

# CGO_ENABLED=0 produces a fully static binary, which is what lets the final
# image be distroless/static (no libc, no shell, minimal CVE surface).
# -trimpath keeps build paths out of the binary; -s -w drops the symbol table.
RUN CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
        -o /out/worker ./cmd/worker

########################################################################
# Stage 2: runtime
########################################################################
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

# Certificates are needed for the TLS handshake with pubsub.googleapis.com and
# firestore.googleapis.com; distroless/static ships them already.
COPY --from=build /out/worker /worker

# Matches the "nonroot" user baked into the base image (uid 65532).
USER 65532:65532

EXPOSE 8081

ENTRYPOINT ["/worker"]
