# Smokescreen (Stripe): proxy de saída HTTP/CONNECT com ACL por domínio,
# log JSON por decisão e bloqueio de IPs privados (anti-SSRF) por padrão.
# O projeto não publica imagens nem releases, então compilamos a partir de um commit fixo.
FROM golang:1.26-alpine@sha256:8ac98ca534ac3f51e1f420a1dd2c15e74c75cfa0f23f3ad27eb5d7236c349a0c AS build
ARG SMOKESCREEN_REF
RUN test -n "${SMOKESCREEN_REF}" && apk add --no-cache git
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/stripe/smokescreen.git \
 && git fetch -q --depth 1 origin "${SMOKESCREEN_REF}" \
 && git checkout -q FETCH_HEAD
RUN CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags="-s -w" -o /out/smokescreen .

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/smokescreen /usr/local/bin/smokescreen
USER nonroot
EXPOSE 4750 9810
ENTRYPOINT ["/usr/local/bin/smokescreen"]
