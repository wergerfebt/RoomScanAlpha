FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
COPY web/ ./web/

ENV BUILD_TS=1743638400
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
