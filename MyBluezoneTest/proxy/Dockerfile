FROM alpine:3.22

RUN apk add --no-cache tinyproxy \
    && (id tinyproxy >/dev/null 2>&1 || adduser -S -D -H tinyproxy)

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter /etc/tinyproxy/filter

USER tinyproxy

EXPOSE 8888

# -d keeps tinyproxy in the foreground so the container stays up
CMD ["tinyproxy", "-d"]
