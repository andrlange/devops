FROM golang:1.26 AS build
WORKDIR /app
COPY src/go.mod src/go.sum ./
RUN go mod download
COPY src/ ./
RUN CGO_ENABLED=0 go build -o /cf-marketplace-broker .

FROM artifactory.cfapps.cool/docker-local/gcr.io/distroless/static:nonroot-arm64
COPY --from=build /cf-marketplace-broker /cf-marketplace-broker
ENTRYPOINT ["/cf-marketplace-broker"]
