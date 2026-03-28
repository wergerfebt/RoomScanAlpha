FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY main.py .
COPY pipeline/ pipeline/

# Download model from GCS at build time (if GCS bucket is configured).
# Falls back gracefully if model is missing — USE_DNN_STAGE3 defaults to false.
# To include the model, build with:
#   docker build --build-arg MODEL_GCS_PATH=gs://roomscanalpha-models/roomformer_s3d.pt .
ARG MODEL_GCS_PATH=""
RUN mkdir -p models && \
    if [ -n "$MODEL_GCS_PATH" ]; then \
        pip install --no-cache-dir google-cloud-storage && \
        python -c "from google.cloud import storage; \
            client = storage.Client(); \
            parts = '${MODEL_GCS_PATH}'.replace('gs://', '').split('/', 1); \
            client.bucket(parts[0]).blob(parts[1]).download_to_filename('models/roomformer_s3d.pt'); \
            print(f'Downloaded model: {parts[1]}')" || \
        echo "WARNING: Model download failed — DNN path will be disabled"; \
    else \
        echo "No MODEL_GCS_PATH — deploying without DNN model"; \
    fi

# Environment defaults
# USE_DNN_STAGE3: set to "true" to enable DNN room polygon extraction
# ROOMFORMER_MODEL_PATH: path to TorchScript model inside the container
ENV USE_DNN_STAGE3=false
ENV ROOMFORMER_MODEL_PATH=/app/models/roomformer_finetuned.pt

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
