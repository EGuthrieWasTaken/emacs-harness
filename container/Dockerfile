# emacs-harness image (DESIGN.md §5.1).  One image, three run modes,
# selected by the entrypoint: server | run | doctor.
#
# Debian's emacs-gtk is an X11 + cairo GTK build -- deliberately *not*
# the pgtk build Arch ships, because xdotool needs a real X11 window and
# `x-export-frames` (the primary screenshot path, DESIGN §6.4) is what
# survives a future move to Wayland unchanged (DESIGN §13.1).

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NO_AT_BRIDGE=1 \
    EH_ROOT=/opt/eh \
    EH_ELISP_DIR=/opt/eh/elisp \
    EH_PROFILES_ROOT=/srv/profiles \
    EH_VAR_RUN=/run/eh \
    EH_RUNS_ROOT=/var/lib/eh/runs \
    EH_SOCK=/run/eh/eh.sock \
    PATH=/opt/eh/bin:$PATH

# The HTTP API (DESIGN §6.1, §14 phase 4 -- what the MCP server in
# mcp-server/ talks to) is off by default; set EH_HTTP_ENABLE=1 plus
# EH_HTTP_CLIENT_ID/EH_HTTP_CLIENT_SECRET at `docker run` time to turn it
# on, and publish 8080 alongside 6080. It has no business being reachable
# from the open internet directly -- put it behind the same Cloudflare
# Tunnel + Access application pattern §10.2 already uses for the noVNC
# view, on its own hostname.

RUN apt-get update && apt-get install -y --no-install-recommends \
        emacs-gtk \
        xvfb openbox x11-utils x11-xserver-utils xdotool \
        imagemagick ffmpeg \
        fonts-dejavu-core fontconfig \
        x11vnc novnc websockify \
        python3 python3-minimal \
        supervisor \
        ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# Pin fontconfig: bake exactly one monospace font's metrics into the
# pixel baselines (DESIGN §7.2). fonts-dejavu-core is the only font
# family installed, so fontconfig has nothing else to pick.
RUN fc-cache -f

COPY container/Xresources /etc/X11/Xresources
ENV XENVIRONMENT=/etc/X11/Xresources
COPY elisp/ /opt/eh/elisp/
COPY ehd/ /opt/eh/ehd/
COPY bin/ /opt/eh/bin/
COPY container/ /opt/eh/container/
COPY container/ehd-cli /usr/local/bin/ehd-cli
COPY container/ehd-server /usr/local/bin/ehd-server
COPY container/supervisord.conf /etc/supervisor/supervisord.conf
COPY container/eh-programs.conf /etc/supervisor/conf.d/eh-programs.conf
COPY profiles/ /srv/profiles/

RUN chmod +x /opt/eh/bin/eh /opt/eh/bin/eh-fake-bridge \
             /opt/eh/ehd/ehd.py /opt/eh/ehd/ehd_cli.py \
             /usr/local/bin/ehd-cli /usr/local/bin/ehd-server \
             /opt/eh/container/entrypoint.sh /opt/eh/container/bootstrap-server.sh \
    && mkdir -p /run/eh /var/lib/eh/runs /var/lib/eh/elpa-cache /var/log/eh

EXPOSE 6080 8080

ENTRYPOINT ["/opt/eh/container/entrypoint.sh"]
CMD ["server"]
