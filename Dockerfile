# syntax=docker/dockerfile:1
#
# Two stages: build the three challenger allocators from pinned source, then
# bake them next to a ready-to-run railsbench. glibc malloc needs no build --
# it is whatever ships in the base image, which is the point of the baseline.

ARG RUBY_IMAGE=ruby:4.0-slim-trixie

FROM ${RUBY_IMAGE} AS alloc-builder

ARG JEMALLOC_VER=5.3.1
ARG GPERFTOOLS_VER=2.18.1
ARG MIMALLOC_VER=v3.5.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libtool cmake git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth 1 --branch "${JEMALLOC_VER}" https://github.com/jemalloc/jemalloc.git \
 && cd jemalloc \
 && ./autogen.sh --prefix=/opt/alloc/jemalloc \
 && make -j"$(nproc)" && make install_lib_shared install_include

# --enable-minimal builds libtcmalloc_minimal.so: the allocator only, no heap
# profiler, no libunwind dependency. It is also the .so most people actually
# LD_PRELOAD in production. Reported as "tcmalloc_minimal", not "tcmalloc".
RUN git clone --depth 1 --branch "gperftools-${GPERFTOOLS_VER}" https://github.com/gperftools/gperftools.git \
 && cd gperftools \
 && ./autogen.sh \
 && ./configure --prefix=/opt/alloc/tcmalloc --enable-minimal --disable-static \
 && make -j"$(nproc)" && make install

RUN git clone --depth 1 --branch "${MIMALLOC_VER}" https://github.com/microsoft/mimalloc.git \
 && cd mimalloc && mkdir build && cd build \
 && cmake .. -DCMAKE_INSTALL_PREFIX=/opt/alloc/mimalloc -DMI_BUILD_STATIC=OFF \
             -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release \
 && make -j"$(nproc)" && make install

# Flatten to stable filenames so run.sh does not have to know version suffixes.
RUN mkdir -p /alloc \
 && cp -L /opt/alloc/jemalloc/lib/libjemalloc.so.2      /alloc/libjemalloc.so \
 && cp -L /opt/alloc/tcmalloc/lib/libtcmalloc_minimal.so /alloc/libtcmalloc.so \
 && cp -L "$(ls /opt/alloc/mimalloc/lib/libmimalloc.so.* | head -1)" /alloc/libmimalloc.so \
 && ls -l /alloc


FROM ${RUBY_IMAGE}

ARG YJIT_BENCH_SHA=a5d4ae82fa6b3e7f2caca7ceba83ac352893e694

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates libsqlite3-dev libyaml-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*

COPY --from=alloc-builder /alloc /alloc

WORKDIR /app
RUN git clone https://github.com/Shopify/yjit-bench.git . \
 && git checkout "${YJIT_BENCH_SHA}"

ENV RUBYOPT="--yjit" \
    RAILS_ENV=production \
    RAILS_MAX_THREADS=5 \
    SECRET_KEY_BASE=benchmarkbenchmarkbenchmarkbenchmark \
    BUNDLE_PATH=/bundle

# Bake gems and the seeded sqlite DB into the image so that no round pays for
# bundle install or db:seed -- those would show up as allocator noise.
WORKDIR /app/benchmarks/railsbench
RUN bundle install --jobs "$(nproc)" \
 && bin/rails db:migrate db:seed \
 && rm -f log/production.log

COPY bench/driver.rb /bench/driver.rb

WORKDIR /app/benchmarks/railsbench
ENTRYPOINT ["ruby", "/bench/driver.rb"]
