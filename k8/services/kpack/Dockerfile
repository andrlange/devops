FROM golang:1.24-alpine AS builder
RUN apk add --no-cache git
WORKDIR /src
COPY src/go.mod src/go.sum ./
RUN go mod download
COPY src/ .
ARG BINARY=controller
ARG VERSION=0.17.0
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
    -ldflags "-s -w -X 'github.com/pivotal/kpack/cmd.Version=${VERSION}'" \
    -o /out/${BINARY} ./cmd/${BINARY}

FROM gcr.io/distroless/static:nonroot
ARG BINARY=controller
COPY --from=builder /out/${BINARY} /app
ENTRYPOINT ["/app"]
