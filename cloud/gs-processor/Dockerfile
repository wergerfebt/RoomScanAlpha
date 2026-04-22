# Stage 1: Build GLOMAP from source on Ubuntu 22.04 (matches runtime ABI — glibc 2.35,
# libstdc++ GLIBCXX_3.4.30, boost 1.74). Ubuntu 22.04 ships CMake 3.22 but GLOMAP needs
# 3.28+, so we pull CMake from Kitware's PPA. Eigen 3.4.0 is already in 22.04 apt.
FROM ubuntu:22.04 AS glomap-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git ninja-build build-essential curl ca-certificates gpg wget \
    libboost-all-dev libeigen3-dev libflann-dev libfreeimage-dev \
    libmetis-dev libgoogle-glog-dev libgflags-dev libsqlite3-dev \
    libglew-dev qtbase5-dev libqt5opengl5-dev libcgal-dev \
    libatlas-base-dev libsuitesparse-dev libceres-dev \
    && wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null \
        | gpg --dearmor - | tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ jammy main" \
        > /etc/apt/sources.list.d/kitware.list \
    && apt-get update && apt-get install -y cmake \
    && rm -rf /var/lib/apt/lists/*

RUN cd /opt && git clone --recursive https://github.com/colmap/glomap.git \
    && cd glomap && mkdir build && cd build \
    && cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release \
    && ninja -j$(nproc) \
    && cp glomap/glomap /usr/local/bin/glomap

# Stage 2: Runtime with CUDA + Python (same Ubuntu version as builder — no ABI skew)
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# System deps — includes GLOMAP runtime deps (suitesparse, flann, arpack, atlas)
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-dev git curl \
    libboost-all-dev libfreeimage-dev libmetis-dev \
    libgoogle-glog-dev libgflags-dev libsqlite3-dev \
    libglew-dev libceres-dev ffmpeg ca-certificates \
    libsuitesparse-dev libflann-dev libarpack2 libatlas-base-dev \
    && rm -rf /var/lib/apt/lists/*

# GLOMAP binary (runtime libs match builder stage — both Ubuntu 22.04)
COPY --from=glomap-builder /usr/local/bin/glomap /usr/local/bin/glomap
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
