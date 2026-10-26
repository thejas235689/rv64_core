# Reproducible environment for the rv64_core regression.
#
#   docker build -t rv64_core -f docker/Dockerfile .
#   docker run --rm rv64_core
#
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git python3 python3-pip make \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 dev
USER dev
WORKDIR /home/dev/rv64_core

# Icarus + Yosys, and the xezim simulator for the UVM regression
RUN ./ci/install-oss-cad-suite.sh /home/dev/ocs/oss-cad-suite 2>/dev/null || true
COPY --chown=dev:dev . .

RUN ./ci/install-oss-cad-suite.sh /home/dev/ocs/oss-cad-suite \
 && ./ci/install-xezim.sh /home/dev/xezim \
 && pip install --user cocotb

ENV PATH=/home/dev/ocs/oss-cad-suite/bin:/home/dev/.local/bin:$PATH

CMD ["bash", "-lc", "python3 sim/run.py && python3 sim/run.py --suite pmp && python3 sim/run.py --suite plic"]
