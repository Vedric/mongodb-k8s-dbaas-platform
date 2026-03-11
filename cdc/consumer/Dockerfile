# Multi-stage build for the CDC event consumer.
# Stage 1: Build the Go binary.
# Stage 2: Create a minimal runtime image.
FROM golang:1.22-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s" \
    -o /cdc-consumer .

# Runtime stage
FROM gcr.io/distroless/static-debian12:nonroot

LABEL org.opencontainers.image.title="MongoDB CDC Event Consumer"
LABEL org.opencontainers.image.description="Kafka consumer for Debezium MongoDB change events"
LABEL org.opencontainers.image.source="https://github.com/Vedric/mongodb-k8s-dbaas-platform"

COPY --from=builder /cdc-consumer /cdc-consumer

USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/cdc-consumer"]
