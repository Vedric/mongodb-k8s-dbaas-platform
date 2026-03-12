# Multi-stage build for the DBaaS API gateway prototype
FROM golang:1.23-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /gateway .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /gateway /gateway
USER nonroot:nonroot
EXPOSE 8081
ENTRYPOINT ["/gateway"]
