# Stage 1: Build GLOMAP from source (Ubuntu 24.04 has CMake 3.28+, Eigen 3.4+)
FROM ubuntu:24.04 AS glomap-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git cmake ninja-build build-essential \
    libboost-all-dev libeigen3-dev libflann-dev libfreeimage-dev \
    libmetis-dev libgoogle-glog-dev libgflags-dev libsqlite3-dev \
    libglew-dev qtbase5-dev libqt5opengl5-dev libcgal-dev \
    libatlas-base-dev libsuitesparse-dev libceres-dev \
    && rm -rf /var/lib/apt/lists/*

RUN cd /opt && git clone --recursive https://github.com/colmap/glomap.git \
    && cd glomap && mkdir build && cd build \
    && cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release \
    && ninja -j$(nproc) \
    && cp glomap/glomap /usr/local/bin/glomap

# Stage 2: Runtime with CUDA + Python
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# System deps
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-dev git curl \
    libboost-all-dev libfreeimage-dev libmetis-dev \
    libgoogle-glog-dev libgflags-dev libsqlite3-dev \
    libglew-dev libceres-dev ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy GLOMAP binary from builder, plus its Ubuntu 24.04 boost 1.83 runtime deps
# (stage 2 has boost 1.74 which GLOMAP's dynamic linker can't satisfy)
COPY --from=glomap-builder /usr/local/bin/glomap /usr/local/bin/glomap
COPY --from=glomap-builder /usr/lib/x86_64-linux-gnu/libboost_program_options.so.1.83.0 /usr/lib/x86_64-linux-gnu/
COPY --from=glomap-builder /usr/lib/x86_64-linux-gnu/libboost_filesystem.so.1.83.0 /usr/lib/x86_64-linux-gnu/
COPY --from=glomap-builder /usr/lib/x86_64-linux-gnu/libboost_system.so.1.83.0 /usr/lib/x86_64-linux-gnu/
COPY --from=glomap-builder /usr/lib/x86_64-linux-gnu/libboost_thread.so.1.83.0 /usr/lib/x86_64-linux-gnu/
COPY --from=glomap-builder /usr/lib/x86_64-linux-gnu/libboost_graph.so.1.83.0 /usr/lib/x86_64-linux-gnu/
COPY --from=glomap-builder /usr/lib/x86_64-linux-gnu/libboost_serialization.so.1.83.0 /usr/lib/x86_64-linux-gnu/
RUN ldconfig && ldd /usr/local/bin/glomap | (! grep -q "not found" || (echo "GLOMAP MISSING LIBS:" && ldd /usr/local/bin/glomap | grep "not found" && exit 1))

# Python deps
RUN pip3 install --no-cache-dir \
    torch==2.4.0 torchvision==0.19.0 --index-url https://download.pytorch.org/whl/cu118

# FastGS + submodules (TORCH_CUDA_ARCH_LIST for L4 = sm_89, builds without GPU present)
ENV TORCH_CUDA_ARCH_LIST="8.9"
RUN cd /opt && git clone --recursive https://github.com/fastgs/FastGS.git \
    && cd FastGS \
    && pip3 install --no-cache-dir plyfile tqdm opencv-python-headless websockets \
    && pip3 install --no-build-isolation submodules/diff-gaussian-rasterization_fastgs \
    && pip3 install --no-build-isolation submodules/simple-knn \
    && pip3 install --no-build-isolation submodules/fused-ssim

# LightGlue + hloc. LightGlue's pyproject.toml is broken (builds wheel as UNKNOWN);
# replace it with a working setup.py.
RUN cd /opt && git clone https://github.com/cvg/LightGlue.git \
    && cd LightGlue && git checkout 746fac2c \
    && rm -f pyproject.toml \
    && printf 'from setuptools import setup\nsetup(name="lightglue", version="0.0", packages=["lightglue"], install_requires=["torch>=1.9.1","torchvision>=0.3","numpy","opencv-python","matplotlib","kornia>=0.6.11"])\n' > setup.py \
    && pip3 install --no-cache-dir . \
    && cd /opt && git clone --recursive https://github.com/cvg/Hierarchical-Localization.git \
    && cd Hierarchical-Localization \
    && pip3 install --no-cache-dir --no-deps -e . \
    && pip3 install --no-cache-dir kornia kornia_rs

# Additional Python deps
RUN pip3 install --no-cache-dir pycolmap==3.13.0 h5py scipy Pillow av google-cloud-storage

# Pre-download model weights (avoids download at runtime)
RUN python3 -c "import torch; torch.hub.load_state_dict_from_url('https://github.com/Shiaoming/ALIKED/raw/main/models/aliked-n16.pth', map_location='cpu')"
RUN python3 -c "import torch; torch.hub.load_state_dict_from_url('https://github.com/cvg/LightGlue/releases/download/v0.1_arxiv/aliked_lightglue.pth', map_location='cpu')"

# Copy pipeline code
WORKDIR /app
COPY run_pipeline.py .
COPY video_extract.py .
COPY job.py .

# Vertex AI Custom Job: run pipeline to completion then exit
# Expects env vars: SCAN_ID, ROOM_ID, RFQ_ID
ENTRYPOINT ["python3", "job.py"]
