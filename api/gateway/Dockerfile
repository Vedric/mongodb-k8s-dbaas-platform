# Multi-stage build for the DBaaS API gateway prototype
FROM golang:1.26.8-alpine3.23@sha256:a8fa79c5bd40d880b52bd3b6d7669ecdcfd00e85facdd427d279efb5ddd79cb1 AS builder

ENV GOTOOLCHAIN=local

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -mod=readonly -o /gateway .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /gateway /gateway
USER nonroot:nonroot
EXPOSE 8081
ENTRYPOINT ["/gateway"]
