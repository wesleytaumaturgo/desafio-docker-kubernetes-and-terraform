# Contexto de build = app/api: docker build -f app/docker/api.Dockerfile -t mural-api:<tag> app/api
# Final distroless static nonroot: sem shell nem toolchain, com usuário nonroot, CA certs e tzdata.
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/api"]
