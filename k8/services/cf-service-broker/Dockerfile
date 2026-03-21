FROM golang:1.26 AS build
WORKDIR /app
COPY src/go.mod src/go.sum ./
RUN go mod download
COPY src/ ./
RUN CGO_ENABLED=0 go build -o /cf-service-broker .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /cf-service-broker /cf-service-broker
ENTRYPOINT ["/cf-service-broker"]
