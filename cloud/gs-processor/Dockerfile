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
    python3 python3-pip python3-dev git \
    libboost-all-dev libfreeimage-dev libmetis-dev \
    libgoogle-glog-dev libgflags-dev libsqlite3-dev \
    libglew-dev libceres-dev ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Copy GLOMAP binary from builder
COPY --from=glomap-builder /usr/local/bin/glomap /usr/local/bin/glomap

# Python deps
RUN pip3 install --no-cache-dir \
    torch==2.4.0 torchvision==0.19.0 --index-url https://download.pytorch.org/whl/cu118

# FastGS + submodules
RUN cd /opt && git clone --recursive https://github.com/fastgs/FastGS.git \
    && cd FastGS \
    && pip3 install --no-cache-dir plyfile tqdm opencv-python-headless websockets \
    && pip3 install --no-build-isolation submodules/diff-gaussian-rasterization_fastgs \
    && pip3 install --no-build-isolation submodules/simple-knn \
    && pip3 install --no-build-isolation submodules/fused-ssim

# hloc (ALIKED + LightGlue)
RUN cd /opt && git clone --recursive https://github.com/cvg/Hierarchical-Localization.git \
    && cd Hierarchical-Localization && pip3 install --no-cache-dir -e .

# Additional Python deps
RUN pip3 install --no-cache-dir pycolmap h5py scipy Pillow av

# Pre-download model weights (avoids download at runtime)
RUN python3 -c "import torch; torch.hub.load_state_dict_from_url('https://github.com/Shiaoming/ALIKED/raw/main/models/aliked-n16.pth', map_location='cpu')"
RUN python3 -c "import torch; torch.hub.load_state_dict_from_url('https://github.com/cvg/LightGlue/releases/download/v0.1_arxiv/aliked_lightglue.pth', map_location='cpu')"

# Copy pipeline code
WORKDIR /app
COPY run_pipeline.py .
COPY video_extract.py .
COPY server.py .

# Cloud Run expects a web server on PORT
ENV PORT=8080
CMD ["python3", "server.py"]
